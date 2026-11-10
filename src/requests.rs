//! Requests to the agent: asking, progress, auto-continue, what each
//! conversation is doing, re-sync after a reload, typed requests.

use super::*;

// how often the window hears what the agent is doing, and how many times per
// request at most: every update spends one of the session's 64 slots
// Measured: progress lines were 29 of a session's 64 slots, nearly half. The
// window's seconds count already shows the agent is alive, so two will do.
// a long turn (a build, a research run) went quiet after two lines and read as
// stuck; with 512 slots a line every 15 s is affordable
pub(crate) const PROGRESS_EVERY: Duration = Duration::from_secs(15);
pub(crate) const PROGRESS_LIMIT: u32 = 16;
// how many times a request that ran out of steps carries on by itself
pub(crate) const CONTINUES: u32 = 3;
// at this many slots used, offer the Reload button once, while slots remain
// Margins below the slots the game knows (see known_slots): offer Reload at 16
// left, stop progress lines at 14 left, and from 8 left every reply says so.
pub(crate) const SLOTS_OFFER_RELOAD: u32 = 16;
pub(crate) const SLOTS_LOW: u32 = 8;
// the UI session in which the Reload button was last offered for low slots
pub(crate) static RELOAD_OFFERED: Mutex<String> = Mutex::new(String::new());
// requests to the agent running right now; a restart waits for zero
pub(crate) static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);
/// Counts a request out of IN_FLIGHT however its thread ends.
pub(crate) struct InFlight;

impl Drop for InFlight {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::SeqCst);
    }
}
/// Hand what was said to Claude, show its line in the companion window, and
/// deliver whatever command it chose. The line goes first, so the player sees the
/// reasoning before the game changes under them.
/// The other half of looking. The agent ran something and asked to see what it
/// did; the only way results reach disk is a reload, which the player was offered
/// as a button. When the save lands, hand the agent the refreshed context and let
/// it carry on, so one press is all the player does.
pub(crate) fn watch_for_looks(addons: &Path, session: &Mutex<agent::Session>, looking: &Mutex<Option<Option<u128>>>) {
    loop {
        thread::sleep(Duration::from_secs(1));
        let waiting = *looking.lock().unwrap();
        let Some(since) = waiting else { continue };
        if session_began(addons) == since {
            continue;
        }
        *looking.lock().unwrap() = None;
        // the save lands before the UI is back; give the addon time to listen again
        thread::sleep(Duration::from_secs(4));
        let note = "(I reloaded so you can look. Your steps' results are in <character>, \
                    under code runs and the slots; carry on with what I asked.)";
        IN_FLIGHT.fetch_add(1, Ordering::SeqCst);
        let _done = InFlight;
        match ask(addons, &mut session.lock().unwrap(), note, false) {
            Ok(true) => *looking.lock().unwrap() = Some(session_began(addons)),
            Ok(false) => {}
            Err(err) => {
                eprintln!("  looking again failed: {err}");
                tell_failure(addons, &err);
            }
        }
    }
}

/// What each conversation is doing ("" is the main one), with when it began. The
/// game keeps its spinners and board only in memory, so a /reload wiped them while
/// the agents worked on; `resync` tells the fresh UI session again.
pub(crate) static WORKING: Mutex<Vec<(String, String, Instant)>> = Mutex::new(Vec::new());

pub(crate) fn set_working(slot: &str, doing: &str) {
    let mut working = WORKING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    match working.iter_mut().find(|(at, _, _)| at == slot) {
        Some(entry) => entry.1 = doing.to_string(),
        None => working.push((slot.to_string(), doing.to_string(), Instant::now())),
    }
}

/// Clears a conversation's entry in WORKING however its request ends.
pub(crate) struct Working(String);
impl Drop for Working {
    fn drop(&mut self) {
        WORKING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).retain(|(at, _, _)| *at != self.0);
    }
}

/// Replies sent lately: when, their first line, and the message itself. A reply
/// sent while the game was reloading reached a UI session that was going away.
pub(crate) static REPLIES: Mutex<Vec<(SystemTime, String, String)>> = Mutex::new(Vec::new());

/// A new UI session began (the save file was just written). After the addon has
/// loaded: send again every reply from the 10 minutes before the save that the
/// save's log does not hold, then each conversation's current state.
pub(crate) fn resync(addons: &Path) {
    let addons = addons.to_path_buf();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(8));
        let saved_at = session_began(&addons).unwrap_or_default();
        let saved = saved_variables_text(&addons).unwrap_or_default();
        let replies = REPLIES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
        for (sent, first, inbox) in replies {
            let millis = sent.duration_since(UNIX_EPOCH).map(|at| at.as_millis()).unwrap_or_default();
            if millis > saved_at || saved_at - millis > 600_000 {
                continue;
            }
            // the save writes strings escaped; a prefix is enough to recognise one
            let escaped: String = first.replace('\\', "\\\\").replace('"', "\\\"").chars().take(60).collect();
            if !escaped.is_empty() && !saved.contains(&escaped) {
                println!("resync: a reply the game never logged, sent again: {first}");
                if let Err(err) = send_inbox(&addons, &inbox) {
                    eprintln!("  resync: {err}");
                }
            }
        }
        // One `board` message, always, even with nothing working: the addon shows
        // the board it saved at the reload and this is what corrects it, so a
        // conversation that finished during the loading screen stops spinning.
        let working = WORKING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
        if let Err(err) = send_inbox(&addons, &board_inbox(&working)) {
            eprintln!("  resync: {err}");
        }
    });
}

/// Every conversation still working, for the addon's `board` handler.
pub(crate) fn board_inbox(working: &[(String, String, Instant)]) -> String {
    let entries: Vec<String> = working
        .iter()
        .map(|(slot, doing, since)| {
            format!(
                "{{ slot = {}, text = {}, since = {} }}",
                lua_string(slot),
                lua_string(doing),
                since.elapsed().as_secs()
            )
        })
        .collect();
    format!("{{ kind = \"board\", resync = true, working = {{ {} }} }}", entries.join(", "))
}

/// Stopping a conversation (the player, 2026-11-10: "manage jobs in progress,
/// queued messages, things I want to cancel"). Stop in the Companion window
/// draws a command on the data strip, `watch_commands` reads it, and here the
/// running agent's process tree ends and what was queued behind it is dropped.
/// Per conversation: the running agent's process id, and (stops so far, stops
/// when its last request began), so a request queued before a stop is dropped.
static RUNNING: Mutex<Vec<(String, u32)>> = Mutex::new(Vec::new());
/// Each request's id (per message panels in the window): set on the request's
/// own thread before it queues, read by `ask`, carried on its lines as `req`.
static NEXT_REQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
thread_local! {
    static REQ: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}
/// The running request of each conversation, and queued ones the player cancelled.
static RUNNING_REQ: Mutex<Vec<(String, u64)>> = Mutex::new(Vec::new());
static CANCELLED: Mutex<Vec<u64>> = Mutex::new(Vec::new());
/// Cancels of a clip still being heard: (conversation, when). A clip released
/// before the cancel is dropped when its words arrive.
static HEARING_CANCELLED: Mutex<Vec<(String, u128)>> = Mutex::new(Vec::new());
/// When the newest clip was let go, wall clock (unix ms): the game stamps its
/// cancel with its own clock, and a cancel read late off the strip must not
/// reach a clip let go after the press (the player, 2026-11-10: a cancel
/// dropped the message after the one meant).
static RELEASE_WALL: Mutex<u128> = Mutex::new(0);

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default()
}

pub(crate) fn note_release() {
    *RELEASE_WALL.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = now_ms();
}

/// Messages waiting for their conversation: (conversation, request id, words).
static WAITING: Mutex<Vec<(String, u64, String)>> = Mutex::new(Vec::new());

pub(crate) fn queue_message(slot: &str, req: u64, text: &str) {
    WAITING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push((slot.to_string(), req, text.to_string()));
}

/// Every message still waiting in this conversation, as one request, once the
/// conversation is free; None when another waiting request took them already.
/// Cancelled ones are left out; the others' lines are marked started.
pub(crate) fn take_queued(addons: &Path, slot: &str, req: u64) -> Option<String> {
    let taken: Vec<(u64, String)> = {
        let mut waiting = WAITING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !waiting.iter().any(|(at, id, _)| at == slot && *id == req) {
            return None;
        }
        let mut taken = Vec::new();
        waiting.retain(|(at, id, text)| {
            if at == slot {
                taken.push((*id, text.clone()));
                false
            } else {
                true
            }
        });
        taken
    };
    let taken: Vec<(u64, String)> = {
        let mut cancelled = CANCELLED.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        taken
            .into_iter()
            .filter(|(id, _)| {
                match cancelled.iter().position(|c| c == id) {
                    Some(at) => {
                        cancelled.remove(at);
                        false
                    }
                    None => true,
                }
            })
            .collect()
    };
    // the others' lines leave the queue too: their request starts with this one
    for (id, _) in &taken {
        if *id != req {
            let _ = send_inbox(addons, &format!("{{ started = true, kind = \"progress\", text = \"thinking\", slot = {}, req = {id} }}", lua_string(slot)));
        }
    }
    if taken.is_empty() {
        return None;
    }
    if taken.len() == 1 {
        return taken.into_iter().next().map(|(_, text)| text);
    }
    let mut out = String::from("(Several messages, said one after another while you were busy; answer them together:)");
    for (i, (_, text)) in taken.iter().enumerate() {
        out.push_str(&format!("\n{}. {}", i + 1, text));
    }
    Some(out)
}

/// A new request on this thread: its id, for its lines and for cancelling it.
pub(crate) fn new_request() -> u64 {
    let id = NEXT_REQ.fetch_add(1, Ordering::SeqCst);
    REQ.with(|req| req.set(id));
    id
}

/// `released`: when the clip whose words just arrived was let go.
/// Words just arrived for this conversation: drop them when a Cancel was
/// pressed after their clip was let go. `_released` is kept for the callers.
pub(crate) fn hearing_cancelled(slot: &str, _released: Option<Instant>) -> bool {
    let released = *RELEASE_WALL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut all = HEARING_CANCELLED.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let now = now_ms();
    all.retain(|(_, press)| now.saturating_sub(*press) < 30_000);
    let hit = all.iter().position(|(at, press)| at == slot && released <= *press + 1000);
    hit.map(|i| all.remove(i)).is_some()
}

fn running_req(slot: &str) -> Option<u64> {
    RUNNING_REQ.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().find(|(at, _)| at == slot).map(|(_, req)| *req)
}

fn end_running(slot: &str) {
    {
        let mut all = INTERRUPTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        match all.iter_mut().find(|(at, _)| at == slot) {
            Some(entry) => entry.1 += 1,
            None => all.push((slot.to_string(), 1)),
        }
    }
    let pid = RUNNING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().find(|(at, _)| at == slot).map(|(_, pid)| *pid);
    if let Some(pid) = pid {
        let mut kill = std::process::Command::new("taskkill");
        kill.args(["/T", "/F", "/PID", &pid.to_string()]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            kill.creation_flags(0x0800_0000);
        }
        let _ = kill.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
    }
}

/// One message's Cancel or Send now. Cancel on the running request ends it;
/// on a queued one, drops just that one. Send now ends the running request so
/// the queued ones go on.
pub(crate) fn cancel_request(addons: &Path, slot: &str, req: u64, send_now: bool) {
    let running = running_req(slot);
    println!("{} [{}] request {req} (running: {running:?})", if send_now { "send now" } else { "cancel" }, if slot.is_empty() { "main" } else { slot });
    let message = if send_now {
        // Send now on a message no longer waiting (taken by a batch that is
        // already running) must not end that batch: several presses in a row
        // ended each new request in turn (the player, 2026-11-10)
        let still_waiting = WAITING
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .iter()
            .any(|(at, id, _)| at == slot && *id == req);
        if !still_waiting {
            println!("  send now: request {req} already started; nothing to end");
            return;
        }
        if running.is_some() {
            let running = running.unwrap_or_default();
            end_running(slot);
            format!("{{ kind = \"stopped\", slot = {}, req = {running}, dropped = false, sendNow = true }}", lua_string(slot))
        } else {
            return;
        }
    } else if running == Some(req) {
        end_running(slot);
        format!("{{ kind = \"stopped\", slot = {}, req = {req}, dropped = false }}", lua_string(slot))
    } else {
        CANCELLED.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(req);
        format!("{{ kind = \"stopped\", slot = {}, req = {req}, wasQueued = true }}", lua_string(slot))
    };
    if let Err(err) = send_inbox(addons, &message) {
        eprintln!("  telling the game failed: {err}");
    }
}

/// The newest request each conversation made from a clip, and when.
static LAST_REQ: Mutex<Vec<(String, u64, u128)>> = Mutex::new(Vec::new());

pub(crate) fn note_request(slot: &str, req: u64) {
    let released = *RELEASE_WALL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut all = LAST_REQ.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    all.retain(|(at, _, _)| at != slot);
    all.push((slot.to_string(), req, released));
}

/// `press`: when the X was pressed, by the game's clock (unix ms, to the second).
pub(crate) fn cancel_hearing(addons: &Path, slot: &str, press: u128) {
    println!("cancel hearing [{}]", if slot.is_empty() { "main" } else { slot });
    let latest = *RELEASE_WALL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let newest = LAST_REQ
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .iter()
        .find(|(at, _, _)| at == slot)
        .map(|(_, req, released)| (*req, *released));
    let slack = 1000; // the game's clock is to the second
    // a clip let go before the press and not yet a request: drop its words
    let transcribing = latest <= press + slack && newest.is_none_or(|(_, released)| latest > released);
    if transcribing {
        HEARING_CANCELLED.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push((slot.to_string(), press));
        let _ = send_inbox(addons, &format!("{{ kind = \"stopped\", slot = {}, hearing = true }}", lua_string(slot)));
        return;
    }
    // too late to drop the words (the player, 2026-11-10): the clip it meant
    // became a request, so cancel that request, never a later one
    if let Some((req, released)) = newest {
        if released <= press + slack && now_ms().saturating_sub(released) < 120_000 {
            println!("  the clip already became request {req}: cancelling that");
            cancel_request(addons, slot, req, false);
            return;
        }
    }
    println!("  nothing to cancel for that press");
}
static STOPS: Mutex<Vec<(String, u64, u64)>> = Mutex::new(Vec::new());
/// Per conversation, how many times its running request was ended (by Stop or
/// by Send now), so the request knows not to report a failure.
static INTERRUPTS: Mutex<Vec<(String, u64)>> = Mutex::new(Vec::new());

fn interrupts(slot: &str) -> u64 {
    INTERRUPTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().find(|(at, _)| at == slot).map_or(0, |(_, n)| *n)
}

fn stops(slot: &str) -> (u64, u64) {
    let all = STOPS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    all.iter().find(|(at, _, _)| at == slot).map(|(_, count, began)| (*count, *began)).unwrap_or((0, 0))
}

fn set_stops(slot: &str, count: Option<u64>, began: Option<u64>) {
    let mut all = STOPS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if !all.iter().any(|(at, _, _)| at == slot) {
        all.push((slot.to_string(), 0, 0));
    }
    if let Some(entry) = all.iter_mut().find(|(at, _, _)| at == slot) {
        if let Some(count) = count {
            entry.1 = count;
        }
        if let Some(began) = began {
            entry.2 = began;
        }
    }
}

fn set_running(slot: &str, pid: Option<u32>) {
    let mut running = RUNNING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    running.retain(|(at, _)| at != slot);
    if let Some(pid) = pid {
        running.push((slot.to_string(), pid));
    }
}

/// `drop_queue`: Stop ends the running request and drops the queue; Send now
/// (false) ends only the running one, so the next queued request starts at once.
pub(crate) fn stop(addons: &Path, slot: &str, drop_queue: bool) {
    if drop_queue {
        let (count, _) = stops(slot);
        set_stops(slot, Some(count + 1), None);
    }
    {
        let mut all = INTERRUPTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        match all.iter_mut().find(|(at, _)| at == slot) {
            Some(entry) => entry.1 += 1,
            None => all.push((slot.to_string(), 1)),
        }
    }
    let pid = RUNNING
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .iter()
        .find(|(at, _)| at == slot)
        .map(|(_, pid)| *pid);
    println!(
        "stop [{}]: {}",
        if slot.is_empty() { "main" } else { slot },
        pid.map_or("nothing running".to_string(), |pid| format!("ending agent {pid}"))
    );
    if let Some(pid) = pid {
        // the agent's whole tree (its shell commands too), never the companion
        let mut kill = std::process::Command::new("taskkill");
        kill.args(["/T", "/F", "/PID", &pid.to_string()]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            kill.creation_flags(0x0800_0000);
        }
        let _ = kill.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
    }
    let message = format!("{{ kind = \"stopped\", slot = {}, dropped = {} }}", lua_string(slot), drop_queue);
    if let Err(err) = send_inbox(addons, &message) {
        eprintln!("  telling the game it stopped failed: {err}");
    }
}

/// The game's commands, read off the data strip by `tools/strip.py --serve`, a
/// child that ends when we do (its stdin is ours). "WCCMD <nonce> stop <slot>".
pub(crate) fn watch_commands(addons: &Path) {
    use std::io::BufRead;
    loop {
        let script = crate::home().join("tools").join("strip.py");
        let mut command = std::process::Command::new("python");
        command
            .args(["-I", &script.to_string_lossy(), "--serve"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(err) => {
                eprintln!("  command watcher did not start: {err}");
                thread::sleep(Duration::from_secs(60));
                continue;
            }
        };
        let _keep = child.stdin.take();
        if let Some(out) = child.stdout.take() {
            for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                let words: Vec<&str> = line.split_whitespace().collect();
                let main = |slot: &str| if slot == "main" { String::new() } else { slot.to_string() };
                match words.as_slice() {
                    ["WCCMD", _nonce, verb @ ("cancel" | "now"), slot, req, ..] => {
                        if let Ok(req) = req.parse::<u64>() {
                            cancel_request(addons, &main(slot), req, *verb == "now");
                        }
                    }
                    ["WCCMD", nonce, "hear", slot, ..] => {
                        // the nonce opens with the game's time() in seconds
                        let press = nonce.get(..10).and_then(|secs| secs.parse::<u128>().ok()).map(|secs| secs * 1000 + 999);
                        cancel_hearing(addons, &main(slot), press.unwrap_or_else(now_ms));
                    }
                    ["WCCMD", _nonce, verb @ ("stop" | "now"), slot] => stop(addons, &main(slot), *verb == "stop"),
                    _ => {}
                }
            }
        }
        let _ = child.wait();
        thread::sleep(Duration::from_secs(10));
    }
}

/// Returns whether the agent wants to look at the results before it is done.
pub(crate) fn ask(addons: &Path, session: &mut agent::Session, spoken: &str, shown: bool) -> io::Result<bool> {
    println!("asking: {spoken}");
    // a request that waited behind one the player stopped was dropped with it
    let (stopped_before, began) = stops(&session.slot);
    if shown && stopped_before > began {
        println!("  dropped: queued behind a request that was stopped");
        return Ok(false);
    }
    set_stops(&session.slot, None, Some(stopped_before));
    let interrupted_before = interrupts(&session.slot);
    let was_stopped = |slot: &str| interrupts(slot) != interrupted_before;
    let req = REQ.with(|req| req.get());
    if req != 0 {
        let mut cancelled = CANCELLED.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(at) = cancelled.iter().position(|id| *id == req) {
            cancelled.remove(at);
            println!("  dropped: cancelled while queued");
            return Ok(false);
        }
        drop(cancelled);
        let mut running = RUNNING_REQ.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        running.retain(|(at, _)| at != &session.slot);
        running.push((session.slot.clone(), req));
    }
    let req_field = if req != 0 { format!(", req = {req}") } else { String::new() };
    let _working = Working(session.slot.clone());
    WORKING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).retain(|(at, _, _)| *at != session.slot);
    set_working(&session.slot, "thinking");
    // start the agent before announcing ourselves: the announcement costs a bell
    // wait, the agent costs several seconds, and they may as well run together
    voice::mark(&format!("agent starting [{}]", session.slot));
    let mut context = agent_context_for(addons, &session.slot);
    if wants_chat(spoken) {
        set_working(&session.slot, "reading chat");
        if let Some(chat) = live_chat(addons) {
            context = Some(format!("{}
== live chat ==
-- read from the game just now, through the data strip
{chat}", context.unwrap_or_default()));
        }
    }
    let waiting = session.start(spoken, context)?;
    set_running(&session.slot, Some(waiting.id()));
    // a queued request already showed its words; now it only starts thinking
    if shown {
        // `started` first, so this one is not advisory: it is what ends the queued
        // mark on the request's line, and must not be dropped on a busy channel
        send_inbox(addons, &format!("{{ started = true, kind = \"progress\", text = \"thinking\", slot = {}{req_field} }}", lua_string(&session.slot)))?;
    } else {
        let line = log_inbox_in(Some(&session.slot), "you", spoken, Some("thinking"), None)
            .replacen("{ kind = \"log\"", &format!("{{ kind = \"log\"{req_field}"), 1);
        send_inbox(addons, &line)?;
    }
    let answer = {
        // Progress goes to the spinner, newest only, at most every few seconds: each
        // update costs a slot, and there are 64 per UI session. Its own thread, so
        // the agent never waits on the game.
        let (tell, heard) = std::sync::mpsc::channel::<String>();
        let courier = {
            let addons = addons.to_path_buf();
            let slot = session.slot.clone();
            thread::spawn(move || {
                let mut sent = 0;
                while let Ok(mut latest) = heard.recv() {
                    thread::sleep(PROGRESS_EVERY);
                    while let Ok(newer) = heard.try_recv() {
                        latest = newer;
                    }
                    if sent < PROGRESS_LIMIT {
                        let inbox = format!("{{ kind = \"progress\", text = {}, slot = {} }}", lua_string(&latest), lua_string(&slot));
                        if send_inbox(&addons, &inbox).is_ok() {
                            sent += 1;
                        }
                    }
                }
            })
        };
        let slot = session.slot.clone();
        let mut progress = |doing: &str| {
            voice::mark(&format!("agent: {}", doing.chars().take(60).collect::<String>()));
            println!("  ... {doing}");
            set_working(&slot, doing);
            let _ = tell.send(doing.to_string());
        };
        // A request that runs out of steps carries on by itself, a few times: the
        // work so far stands, and the turn just ended early. Without this, a long
        // job (L1's addon split, 2026-11-10) stopped dead until someone said
        // "continue". The step limit still bounds each round.
        let mut waiting = waiting;
        let mut round = 0;
        let answer = loop {
            let finished = session.finish(waiting, &mut progress);
            if was_stopped(&slot) {
                break Err(io::Error::other("stopped"));
            }
            let answer = match finished {
                Ok(answer) => answer,
                Err(err) => break Err(err),
            };
            if !answer.out_of_steps {
                break Ok(answer);
            }
            round += 1;
            if round > CONTINUES {
                break Err(io::Error::other(format!(
                    "ran out of steps {} times in a row; what it did so far stands. Say \"continue\" to carry on.",
                    CONTINUES + 1
                )));
            }
            println!("  out of steps: continuing ({round} of {CONTINUES})");
            progress(&format!("continuing ({round} of {CONTINUES})"));
            waiting = match session.start(
                "(The step limit ended your last turn before you answered. Carry on where you left off, then answer as usual.)",
                None,
            ) {
                Ok(next) => {
                    set_running(&slot, Some(next.id()));
                    next
                }
                Err(err) => break Err(err),
            };
        };
        set_running(&slot, None);
        RUNNING_REQ.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).retain(|(at, _)| at != &slot);
        drop(tell);
        let _ = courier.join();
        if was_stopped(&slot) {
            // the game already said so (the `stopped` message)
            println!("  stopped by the player");
            return Ok(false);
        }
        answer?
    };
    voice::mark("agent answered");
    println!("claude: {}", answer.say);
    // One message, not two: the reply and the action it describes arrive together,
    // so there is no second bell and no two-second gap between reading the answer
    // and being offered the button. This one carries no `pending`, which stops the
    // spinner.
    // running low: offer the cure once per UI session, while a slot remains for it
    let used = slots_used(addons);
    if used + SLOTS_OFFER_RELOAD >= known_slots(addons) {
        let stamp = saved_variables_stamp(addons).unwrap_or_default();
        let mut offered = RELOAD_OFFERED.lock().unwrap();
        if *offered != stamp {
            *offered = stamp;
            let _ = send_inbox(addons, "{ kind = \"reload\" }");
        }
    }
    // near the end of the session's slots, say so while a reply can still arrive
    let say = if slots_used(addons) + SLOTS_LOW >= known_slots(addons) {
        format!("{}\n(Messages are running low for this session: press Reload soon.)", answer.say)
    } else {
        answer.say.clone()
    };
    // modules go into git before they go into the game (src/modules.rs)
    for (name, code) in &answer.modules {
        if let Err(err) = modules::save(addons, name, code.as_deref()) {
            eprintln!("  module {name} not saved to modules/: {err}");
        }
    }
    let reply = log_inbox_in(Some(&session.slot), "claude", &say, None, answer.inbox.as_deref());
    {
        let first = say.lines().find(|line| !line.trim().is_empty()).unwrap_or_default().to_string();
        let mut replies = REPLIES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        replies.push((SystemTime::now(), first, reply.clone()));
        let excess = replies.len().saturating_sub(20);
        replies.drain(..excess);
    }
    send_inbox(addons, &reply)?;
    if answer.look {
        println!("  waiting for the reload to look at the results");
    }
    Ok(answer.look)
}

pub(crate) fn think(addons: &Path, spoken: &str) -> io::Result<()> {
    let mut session = agent::Session::default();
    let started = Instant::now();
    let mut context = agent_context_for(addons, &session.slot);
    if wants_chat(spoken) {
        set_working(&session.slot, "reading chat");
        if let Some(chat) = live_chat(addons) {
            context = Some(format!("{}
== live chat ==
-- read from the game just now, through the data strip
{chat}", context.unwrap_or_default()));
        }
    }
    let waiting = session.start(spoken, context)?;
    let answer = session.finish(waiting, |doing| println!("  ... {doing}"))?;
    println!("({:.1}s) say: {}", started.elapsed().as_secs_f32(), answer.say);
    println!("would send: {}", answer.inbox.as_deref().unwrap_or("nothing"));
    Ok(())
}

/// Built field by field rather than by patching a finished string: the first attempt
/// spliced `andThen` onto the end and dropped the comma, which the client reported as
/// a Lua syntax error from inside a slot.
pub(crate) fn log_inbox(who: &str, text: &str, pending: Option<&str>, also: Option<&str>) -> String {
    log_inbox_in(None, who, text, pending, also)
}

/// A log line that belongs to one conversation ("" is the main one, "l2" a
/// trigger slot), so the window files it there.
pub(crate) fn log_inbox_in(slot: Option<&str>, who: &str, text: &str, pending: Option<&str>, also: Option<&str>) -> String {
    let mut fields = vec![
        "kind = \"log\"".to_string(),
        format!("who = {}", lua_string(who)),
        format!("text = {}", lua_string(text)),
    ];
    if let Some(slot) = slot {
        fields.push(format!("slot = {}", lua_string(slot)));
    }
    if let Some(label) = pending {
        fields.push(format!("pending = {}", lua_string(label)));
    }
    if let Some(inbox) = also {
        fields.push(format!("andThen = {inbox}"));
    }
    format!("{{ {} }}", fields.join(", "))
}

/// A request that failed says so in the window, and stops the spinner: a console
/// line nobody is watching is how a stuck-looking agent happens.
pub(crate) fn tell_failure(addons: &Path, err: &io::Error) {
    let line = format!("That request failed: {err}");
    if let Err(also) = send_inbox(addons, &log_inbox("error", &line, None, None)) {
        eprintln!("  and telling the game failed too: {also}");
    }
}

/// Where typed requests wait for the running companion.
pub(crate) fn typed_dir() -> Option<PathBuf> {
    let dir = PathBuf::from(env::var_os("LOCALAPPDATA")?).join("wow-companion").join("typed");
    fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

pub(crate) fn tell(slot: &str, words: &str) -> io::Result<()> {
    let slot = slot.to_lowercase();
    let slot = match slot.as_str() {
        "main" | "" => "",
        "l1" | "l2" | "r1" | "r2" => slot.as_str(),
        other => return Err(io::Error::other(format!("no conversation {other:?}: main, l1, l2, r1 or r2"))),
    };
    let dir = typed_dir().ok_or_else(|| io::Error::other("LOCALAPPDATA is not set"))?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_millis()).unwrap_or_default();
    // written whole under another name, then renamed: never read half-written
    let part = dir.join(format!("{stamp}.part"));
    fs::write(&part, format!("{slot}\n{words}\n"))?;
    fs::rename(&part, dir.join(format!("{stamp}.txt")))?;
    println!("left for the companion: [{}] {words}", if slot.is_empty() { "main" } else { slot });
    Ok(())
}
