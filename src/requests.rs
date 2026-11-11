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
        match ask(addons, &mut session.lock().unwrap(), note, false, None) {
            Ok(true) => *looking.lock().unwrap() = Some(session_began(addons)),
            Ok(false) => {}
            Err(err) => {
                eprintln!("  looking again failed: {err}");
                tell_failure(addons, &err);
            }
        }
    }
}

/// Replies sent lately: when, their first line, and the message itself. A reply
/// sent while the game was reloading reached a UI session that was going away.
pub(crate) static REPLIES: Mutex<Vec<(SystemTime, String, String)>> = Mutex::new(Vec::new());

/// A new UI session began (the save file was just written). After the addon has
/// loaded: send again every reply from the 10 minutes before the save that the
/// save's log does not hold, then where every request stands.
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
        // the board it saved at the reload and this is what corrects it. Read when
        // the channel is ours (send_inbox_once), so it is never older than a reply
        // sent before it; and its job states only move the game's forward anyway.
        if let Err(err) = send_inbox(&addons, BOARD_NOW) {
            eprintln!("  resync: {err}");
        }
    });
}

/// Stands for the board as it is when the channel is free to send it.
pub(crate) const BOARD_NOW: &str = "{ kind = \"board\", now = true }";

/// The board: each conversation's running request (`working`, what every addon
/// reads) and every recent request's state (`list`, from the ledger, which the
/// addon merges forward only).
pub(crate) fn board_inbox() -> String {
    let entries: Vec<String> = jobs::working()
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
    format!(
        "{{ kind = \"board\", resync = true, working = {{ {} }}, list = {{ {} }} }}",
        entries.join(", "),
        jobs::entries(&jobs::recent())
    )
}

/// End agent processes (each with its whole tree: its shell commands too,
/// never the companion).
fn end_processes(pids: &[u32]) {
    for pid in pids {
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

/// Tell the game where these jobs stand now, after a cancel, whether or not it
/// changed anything: the game waits on this to resolve its "cancelling...".
/// `older` keeps the fields addons before the ledger read.
fn tell_states(addons: &Path, slot: &str, ids: &[u64], older: &str) {
    let message = format!(
        "{{ kind = \"stopped\", slot = {}{older}, list = {{ {} }} }}",
        lua_string(slot),
        jobs::entries(&jobs::get(ids))
    );
    if let Err(err) = send_inbox(addons, &message) {
        eprintln!("  telling the game failed: {err}");
    }
}

/// One message's Cancel or Send now (the game names the job). Cancel ends it
/// wherever it is; on a running one, the run it shares. Send now on a queued
/// message ends the run in front of it, so the queue goes on at once. Both are
/// idempotent: the game may repeat them until it sees the job end.
pub(crate) fn cancel_request(addons: &Path, slot: &str, req: u64, send_now: bool) {
    let before = jobs::state(req);
    println!(
        "{} [{}] request {req} ({})",
        if send_now { "send now" } else { "cancel" },
        if slot.is_empty() { "main" } else { slot },
        before.map_or("unknown", jobs::State::name)
    );
    if send_now {
        if before != Some(jobs::State::Queued) {
            println!("  send now: request {req} is not waiting; nothing to end");
            tell_states(addons, slot, &[req], "");
            return;
        }
        let running = jobs::live(slot, Some(jobs::State::Running));
        let done = jobs::cancel(&running);
        end_processes(&done.pids);
        let lead = running.first().copied().unwrap_or_default();
        tell_states(addons, slot, &running, &format!(", req = {lead}, dropped = false, sendNow = true"));
        return;
    }
    let done = jobs::cancel(&[req]);
    end_processes(&done.pids);
    let older = match before {
        Some(jobs::State::Running) => format!(", req = {req}, dropped = false"),
        Some(state) if !state.ended() => format!(", req = {req}, wasQueued = true"),
        _ => {
            println!("  request {req} had already ended: too late");
            format!(", req = {req}, wasQueued = true, tooLate = true")
        }
    };
    let mut ids = vec![req];
    ids.extend(done.ended.iter().map(|job| job.id).filter(|id| *id != req));
    tell_states(addons, slot, &ids, &older);
}

/// Cancel pressed on a conversation's "hearing" line, before the game knew the
/// job. `press`: when, by the game's clock (unix ms, to the second). It meant
/// the clip let go by then: still being heard, its words are dropped; already a
/// request, that request is cancelled, never a later one.
pub(crate) fn cancel_hearing(addons: &Path, slot: &str, press: u128) {
    println!("cancel hearing [{}]", if slot.is_empty() { "main" } else { slot });
    match jobs::pressed_for(slot, press) {
        Some(id) if jobs::state(id).is_some_and(|state| !state.ended()) => {
            if jobs::state(id) == Some(jobs::State::Hearing) {
                jobs::cancel(&[id]);
                tell_states(addons, slot, &[id], ", hearing = true");
            } else {
                println!("  the clip already became request {id}: cancelling that");
                cancel_request(addons, slot, id, false);
            }
        }
        found => {
            println!("  nothing to cancel for that press");
            tell_states(addons, slot, &found.into_iter().collect::<Vec<_>>(), ", hearing = true, nothing = true");
        }
    }
}

/// Stop: end the running request; `drop_queue` drops everything waiting too
/// (Send now on the conversation ends only the running one).
pub(crate) fn stop(addons: &Path, slot: &str, drop_queue: bool) {
    let ids = jobs::live(slot, if drop_queue { None } else { Some(jobs::State::Running) });
    let done = jobs::cancel(&ids);
    println!("stop [{}]: {} ended", if slot.is_empty() { "main" } else { slot }, done.ended.len());
    end_processes(&done.pids);
    tell_states(addons, slot, &ids, &format!(", dropped = {drop_queue}"));
}

/// Every queued request of this conversation, taken as one run led by `lead`,
/// as the words to ask; None when another run took `lead`, or it was cancelled.
pub(crate) fn run_queued(addons: &Path, slot: &str, lead: u64) -> Option<String> {
    let taken = jobs::take_queued(slot, lead)?;
    // the others' lines leave the queue too: their request starts with this one
    for (id, _) in &taken {
        if *id != lead {
            let _ = send_inbox(
                addons,
                &format!("{{ started = true, kind = \"progress\", text = \"thinking\", slot = {}{} }}", lua_string(slot), jobs::fields(*id, jobs::State::Running)),
            );
        }
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
                        cancel_hearing(addons, &main(slot), press.unwrap_or_else(jobs::now_ms));
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

/// A request that failed: its job ends failed and the game is told, unless a
/// cancel ended it first (then the failure is only the kill, and is dropped).
fn failed(addons: &Path, slot: &str, group: u64, err: io::Error) -> io::Result<bool> {
    if !jobs::finish(group, jobs::State::Failed) {
        println!("  ended by a cancel");
        return Ok(false);
    }
    eprintln!("  not delivered: {err}");
    let line = log_inbox_in(Some(slot), "error", &format!("That request failed: {err}"), None, None)
        .replacen("{ kind = \"log\"", &format!("{{ kind = \"log\"{}", jobs::fields(group, jobs::State::Failed)), 1);
    send_inbox(addons, &line)?;
    Ok(false)
}

/// Returns whether the agent wants to look at the results before it is done.
/// `job`: the request's job, queued or already running (a run taken from the
/// queue); None makes one (a resumed look).
pub(crate) fn ask(addons: &Path, session: &mut agent::Session, spoken: &str, shown: bool, job: Option<u64>) -> io::Result<bool> {
    println!("asking: {spoken}");
    let group = job.unwrap_or_else(|| jobs::create(&session.slot, spoken, jobs::State::Queued));
    if let Err(state) = jobs::advance(group, jobs::State::Running) {
        println!("  dropped: {} before it started", state.name());
        return Ok(false);
    }
    let req_field = jobs::fields(group, jobs::State::Running);
    jobs::set_doing(group, "thinking");
    // start the agent before announcing ourselves: the announcement costs a bell
    // wait, the agent costs several seconds, and they may as well run together
    voice::mark(&format!("agent starting [{}]", session.slot));
    let mut context = agent_context_for(addons, &session.slot);
    if wants_chat(spoken) {
        jobs::set_doing(group, "reading chat");
        if let Some(chat) = live_chat(addons) {
            context = Some(format!("{}
== live chat ==
-- read from the game just now, through the data strip
{chat}", context.unwrap_or_default()));
        }
    }
    let waiting = match session.start(spoken, context) {
        Ok(waiting) => waiting,
        Err(err) => return failed(addons, &session.slot, group, err),
    };
    // cancelled before its process existed: end it now
    if !jobs::set_pid(group, waiting.id()) {
        end_processes(&[waiting.id()]);
        println!("  cancelled before it started");
        return Ok(false);
    }
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
                        let inbox = format!("{{ kind = \"progress\", text = {}, slot = {}, job = {group} }}", lua_string(&latest), lua_string(&slot));
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
            jobs::set_doing(group, doing);
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
            if jobs::state(group).is_some_and(jobs::State::ended) {
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
                    if !jobs::set_pid(group, next.id()) {
                        end_processes(&[next.id()]);
                        break Err(io::Error::other("stopped"));
                    }
                    next
                }
                Err(err) => break Err(err),
            };
        };
        drop(tell);
        let _ = courier.join();
        match answer {
            Ok(answer) => answer,
            Err(err) => return failed(addons, &slot, group, err),
        }
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
    // the race with a cancel is decided here, once: whichever ended the job
    // first stands, and a reply that lost is dropped (the game shows cancelled)
    if !jobs::finish(group, jobs::State::Answered) {
        println!("  cancelled while answering: reply dropped");
        return Ok(false);
    }
    let reply = log_inbox_in(Some(&session.slot), "claude", &say, None, answer.inbox.as_deref())
        .replacen("{ kind = \"log\"", &format!("{{ kind = \"log\"{}", jobs::fields(group, jobs::State::Answered)), 1);
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
