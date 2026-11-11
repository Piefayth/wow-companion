//! Requests to the agent: asking, progress, auto-continue, cancels and stops,
//! typed requests.

use super::*;
use crate::message::{job_entry, Line, Msg};

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
                tell_failure(addons, "", &err);
            }
        }
    }
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
fn tell_states(addons: &Path, slot: &str, ids: &[u64], flags: &[(&'static str, bool)]) {
    let mut message = Msg::new("stopped").text("slot", slot);
    for (flag, on) in flags {
        message = message.flag(flag, *on);
    }
    let message = message.list("list", jobs::get(ids).iter().map(|job| job_entry(job.id, &job.slot, job.state)).collect());
    if let Err(err) = send(addons, &message) {
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
            println!("  send now: request {req} is not waiting; nothing to do");
            tell_states(addons, slot, &[req], &[]);
            return;
        }
        // the run in front is interrupted, not cancelled: its message joins the
        // queued ones in the next run (run_queued), which starts as it ends
        end_processes(&jobs::interrupt(slot));
        return;
    }
    let done = jobs::cancel(&[req]);
    end_processes(&done.pids);
    if before.is_some_and(|state| state.ended()) {
        println!("  request {req} had already ended: too late");
    }
    // the list says each job's state; that is the whole answer
    let mut ids = vec![req];
    ids.extend(done.ended.iter().map(|job| job.id).filter(|id| *id != req));
    tell_states(addons, slot, &ids, &[]);
}


/// Stop: end the running request and drop everything waiting; `drop_queue`
/// false is Send now on the conversation: the running request is interrupted
/// and joins the queued ones (cancel_request).
pub(crate) fn stop(addons: &Path, slot: &str, drop_queue: bool) {
    if !drop_queue {
        end_processes(&jobs::interrupt(slot));
        return;
    }
    let ids = jobs::live(slot, None);
    let done = jobs::cancel(&ids);
    println!("stop [{}]: {} ended", if slot.is_empty() { "main" } else { slot }, done.ended.len());
    end_processes(&done.pids);
    tell_states(addons, slot, &ids, &[("dropped", true)]);
}

/// Every queued request of this conversation, taken as one run led by `lead`,
/// as the words to ask; None when another run took `lead`, or it was cancelled.
pub(crate) fn run_queued(addons: &Path, slot: &str, lead: u64) -> Option<String> {
    let taken = jobs::take_queued(slot, lead)?;
    // the others' lines leave the queue too: their request starts with this one
    for (id, _, interrupted) in &taken {
        if *id != lead && !interrupted {
            let _ = send(addons, &started(slot, *id));
        }
    }
    if taken.len() == 1 {
        return taken.into_iter().next().map(|(_, text, _)| text);
    }
    let mut out = if taken.iter().any(|(_, _, interrupted)| *interrupted) {
        String::from("(The player pressed Send now while you were on the first of these: that run was interrupted, not cancelled. Answer them all together:)")
    } else {
        String::from("(Several messages, said one after another while you were busy; answer them together:)")
    };
    for (i, (_, text, _)) in taken.iter().enumerate() {
        out.push_str(&format!("\n{}. {}", i + 1, text));
    }
    Some(out)
}

/// The game's commands, read off the data strip in this process (src/strip.rs,
/// no Python). "WCCMD <nonce> stop <slot>".
pub(crate) fn watch_commands(addons: &Path) {
    crate::strip::serve(|line| {
        if line.starts_with("WCCMD") {
            crate::audit::note("cmd", "", &line);
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        let main = |slot: &str| if slot == "main" { String::new() } else { slot.to_string() };
        match words.as_slice() {
            ["WCCMD", _nonce, verb @ ("cancel" | "now"), slot, req, ..] => {
                if let Ok(req) = req.parse::<u64>() {
                    cancel_request(addons, &main(slot), req, *verb == "now");
                }
            }
            ["WCCMD", _nonce, verb @ ("stop" | "now"), slot] => stop(addons, &main(slot), *verb == "stop"),
            _ => {}
        }
    })
}

/// `{ kind = "progress", started = true, ... }`: a request has started; it
/// ends the queued mark on its line.
fn started(slot: &str, id: u64) -> Msg {
    Msg::new("progress").flag("started", true).text("text", "thinking").text("slot", slot).int("job", id).text("state", jobs::State::Running.name())
}

/// A request that failed: its job ends failed and the game is told, unless a
/// cancel ended it first (then the failure is only the kill, and is dropped).
pub(crate) fn failed(addons: &Path, slot: &str, group: u64, err: io::Error) -> io::Result<bool> {
    if !jobs::finish(group, jobs::State::Failed) {
        println!("  ended by a cancel");
        return Ok(false);
    }
    eprintln!("  not delivered: {err}");
    let line = Line::new(slot, "error", &format!("That request failed: {err}")).job(group, jobs::State::Failed).ended(jobs::members(group));
    post(addons, line)?;
    Ok(false)
}

/// Returns whether the agent wants to look at the results before it is done.
/// `job`: the request's job, queued or already running (a run taken from the
/// queue); None makes one (a resumed look).
pub(crate) fn ask(addons: &Path, session: &mut agent::Session, spoken: &str, shown: bool, job: Option<u64>) -> io::Result<bool> {
    println!("asking: {spoken}");
    let group = job.unwrap_or_else(|| jobs::create(&session.slot, spoken, jobs::State::Queued));
    // a panic on this thread ends this job failed (src/crash.rs)
    let _working = crate::crash::working_on(group);
    if let Err(state) = jobs::advance(group, jobs::State::Running) {
        println!("  dropped: {} before it started", state.name());
        return Ok(false);
    }
    // start the agent before announcing ourselves: the announcement costs a bell
    // wait, the agent costs several seconds, and they may as well run together
    voice::mark(&format!("agent starting [{}]", session.slot));
    let context = agent_context_for(addons, &session.slot);
    // what you cancelled after the agent had it is in its conversation; it
    // must know those words were withdrawn
    let withdrawn = jobs::take_withdrawn(&session.slot);
    let told;
    let spoken_for_agent = if withdrawn.is_empty() {
        spoken
    } else {
        let list: Vec<String> = withdrawn.iter().map(|text| format!("- \"{}\"", text.replace('\n', " "))).collect();
        told = format!(
            "(The player cancelled these earlier messages while you were on them; they are withdrawn: do not answer or act on them, and do not count them as said:\n{})\n\n{spoken}",
            list.join("\n")
        );
        &told
    };
    let waiting = match session.start(spoken_for_agent, context) {
        Ok(waiting) => waiting,
        Err(err) => return failed(addons, &session.slot, group, err),
    };
    // cancelled before its process existed: end it now
    if !jobs::set_pid(group, waiting.id()) {
        end_processes(&[waiting.id()]);
        println!("  cancelled before it started");
        return Ok(false);
    }
    // a queued request already showed its words; now it only starts thinking.
    // The agent is already running: an announcement that can't go out (the game
    // closed) must not end the request, or the agent works on unheard and its
    // reply is lost (L1's, 2026-11-11)
    let announced = if shown {
        // a `started` progress is never dropped on a busy channel: it is what
        // ends the queued mark on the request's line
        send(addons, &started(&session.slot, group))
    } else {
        post(addons, Line::new(&session.slot, "you", spoken).pending("thinking").job(group, jobs::State::Running))
    };
    if let Err(err) = announced {
        println!("  not announced ({err}); the request goes on");
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
                        let progress = Msg::new("progress").text("text", &latest).text("slot", &slot).int("job", group);
                        if send(&addons, &progress).is_ok() {
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
            // Send now interrupted this run: the next one takes its messages
            if jobs::interrupted(group) {
                println!("  interrupted: the next run takes it");
                return Ok(false);
            }
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
            let _ = send(addons, &Msg::new("reload"));
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
    let reply = Line::new(&session.slot, "claude", &say)
        .job(group, jobs::State::Answered)
        .ended(jobs::members(group))
        .steps(answer.inbox.clone());
    post(addons, reply)?;
    if answer.look {
        println!("  waiting for the reload to look at the results");
    }
    Ok(answer.look)
}

pub(crate) fn think(addons: &Path, spoken: &str) -> io::Result<()> {
    let mut session = agent::Session::default();
    let started = Instant::now();
    let context = agent_context_for(addons, &session.slot);
    let waiting = session.start(spoken, context)?;
    let answer = session.finish(waiting, |doing| println!("  ... {doing}"))?;
    println!("({:.1}s) say: {}", started.elapsed().as_secs_f32(), answer.say);
    println!("would send: {}", answer.inbox.as_ref().map(Msg::lua).unwrap_or_else(|| "nothing".into()));
    Ok(())
}

/// A request that failed says so in its conversation, and stops the spinner: a
/// console line nobody is watching is how a stuck-looking agent happens.
pub(crate) fn tell_failure(addons: &Path, slot: &str, err: &io::Error) {
    if let Err(also) = post(addons, Line::new(slot, "error", &format!("That request failed: {err}"))) {
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
