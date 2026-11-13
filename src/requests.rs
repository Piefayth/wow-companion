//! Requests to the agent: asking, progress, auto-continue, cancels and stops,
//! typed requests.

use super::*;
use crate::message::{job_entry, Line, Msg};

// how often the window hears what the agent is doing, and how many times per
// request at most: every update spends one of the session's 512 slots
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
/// Request threads alive, from the words arriving (or typed) to the reply sent:
/// an exit waits for none (lifecycle::idle). A thread, not a job: a job ends
/// before its reply goes out, so the race with a cancel is decided once.
pub(crate) static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);
/// One request thread, counted in IN_FLIGHT from `start` until it is dropped,
/// however the thread ends.
pub(crate) struct InFlight;

impl InFlight {
    pub(crate) fn start() -> InFlight {
        IN_FLIGHT.fetch_add(1, Ordering::SeqCst);
        InFlight
    }
}

impl Drop for InFlight {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Request threads following an agent's run (src/runs.rs), delivery included:
/// an exit need not wait for them, since the next companion follows the run.
pub(crate) static FOLLOWING: AtomicUsize = AtomicUsize::new(0);

struct Following;

impl Following {
    fn start() -> Following {
        FOLLOWING.fetch_add(1, Ordering::SeqCst);
        Following
    }
}

impl Drop for Following {
    fn drop(&mut self) {
        FOLLOWING.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Request threads waiting behind another request in their conversation, their
/// words on disk (runs::queue): an exit need not wait for them either.
pub(crate) static WAITING: AtomicUsize = AtomicUsize::new(0);

pub(crate) struct Waiting;

impl Waiting {
    pub(crate) fn start() -> Waiting {
        WAITING.fetch_add(1, Ordering::SeqCst);
        Waiting
    }
}

impl Drop for Waiting {
    fn drop(&mut self) {
        WAITING.fetch_sub(1, Ordering::SeqCst);
    }
}

/// This copy is leaving (a restart's hand-over, `stop`, the game closing):
/// followers leave their runs to the next companion, and no reply goes out from
/// here once it is set. `delivering` counts replies on their way out, which
/// finish first.
struct Handover {
    leaving: bool,
    delivering: usize,
}

static HANDOVER: Mutex<Handover> = Mutex::new(Handover { leaving: false, delivering: 0 });

fn handover() -> std::sync::MutexGuard<'static, Handover> {
    HANDOVER.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub(crate) fn leaving() -> bool {
    handover().leaving
}

/// A reply on its way out; None once this copy is leaving (the next one
/// delivers it).
struct Delivering;

impl Delivering {
    fn begin() -> Option<Delivering> {
        let mut state = handover();
        if state.leaving {
            return None;
        }
        state.delivering += 1;
        Some(Delivering)
    }
}

impl Drop for Delivering {
    fn drop(&mut self) {
        handover().delivering -= 1;
    }
}

/// Leave every run to the next companion: from now nothing is delivered from
/// here; returns once the replies on their way out have gone and every
/// follower has let go of its run.
pub(crate) fn hand_over() {
    handover().leaving = true;
    while handover().delivering > 0 || FOLLOWING.load(Ordering::SeqCst) > 0 {
        thread::sleep(Duration::from_millis(20));
    }
}

/// The main conversation's agent waiting to look: when it asked (the save's
/// time then), until a reload changes it. On disk, so a companion that takes
/// over goes on waiting.
fn look_file() -> Option<PathBuf> {
    companion_dir().ok().map(|dir| dir.join("looking.txt"))
}

fn looking() -> Option<Option<u128>> {
    let text = fs::read_to_string(look_file()?).ok()?;
    Some(text.trim().parse().ok())
}

/// The agent asked to look: its next turn comes after the reload.
pub(crate) fn look_after_reload(addons: &Path) {
    if let Some(file) = look_file() {
        let since = session_began(addons).map(|millis| millis.to_string()).unwrap_or_default();
        if let Err(err) = fs::write(&file, since) {
            eprintln!("  the look could not be remembered ({}): {err}", file.display());
        }
    }
}

/// A new request in the main conversation supersedes a look still waiting.
pub(crate) fn stop_looking() {
    if let Some(file) = look_file() {
        let _ = fs::remove_file(file);
    }
}

/// The other half of looking. The agent ran something and asked to see what it
/// did; the only way results reach disk is a reload, which the player was offered
/// as a button. When the save lands, hand the agent the refreshed context and let
/// it carry on, so one press is all the player does.
pub(crate) fn watch_for_looks(addons: &Path, session: &Mutex<agent::Session>) {
    loop {
        thread::sleep(Duration::from_secs(1));
        let Some(since) = looking() else { continue };
        if session_began(addons) == since {
            continue;
        }
        stop_looking();
        // sent at once: a message made before the new UI polls waits on its rung
        // bell for it (docs/proposals/slot-bells.md)
        let note = "(I reloaded so you can look. Your steps' results are in <character>, \
                    under code runs and the slots; carry on with what I asked.)";
        let _in_flight = InFlight::start();
        match ask(addons, &mut session.lock().unwrap(), note, false, None) {
            Ok(true) => look_after_reload(addons),
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
fn tell_states(addons: &Path, slot: &str, ids: &[u64]) {
    let message = Msg::new("stopped").text("slot", slot).list("list", jobs::get(ids).iter().map(|job| job_entry(job.id, &job.slot, job.state)).collect());
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
            tell_states(addons, slot, &[req]);
            return;
        }
        // the run in front is interrupted, not cancelled: its message joins the
        // queued ones in the next run (run_queued), which starts as it ends
        end_processes(&jobs::interrupt(slot));
        // the press was read: the game stops drawing it again now, not when the
        // next run starts seconds later (a redraw is only for a missed capture)
        let ack = Msg::new("ack").text("verb", "now").text("slot", slot).int("job", req);
        if let Err(err) = send(addons, &ack) {
            eprintln!("  telling the game failed: {err}");
        }
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
    tell_states(addons, slot, &ids);
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

/// The game's commands, read off the data strip in this process (src/strip.rs):
/// "WCCMD <nonce> cancel|now <slot> <job>", a message's Cancel or Send now,
/// "fresh <slot>" (the conversation menu's Start over), and the settings
/// page's `bind` and `set` (src/settings_page.rs). `session` finds a
/// conversation's session.
pub(crate) fn watch_commands(addons: &Path, session: impl Fn(&str) -> std::sync::Arc<Mutex<agent::Session>>) {
    crate::strip::serve(|line| {
        if line.starts_with("WCCMD") {
            crate::audit::note("cmd", "", &line);
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        // the game shows one command at a time and draws the next once this one
        // is read (Strip.lua), so every command is answered at once
        if let ["WCCMD", nonce, ..] = words.as_slice() {
            if let Err(err) = crate::send(addons, &crate::message::Msg::new("read").text("nonce", nonce)) {
                eprintln!("  command {nonce}: the read was not delivered: {err}");
            }
        }
        let main = |slot: &str| if slot == "main" { String::new() } else { slot.to_string() };
        match words.as_slice() {
            ["WCCMD", _nonce, verb @ ("cancel" | "now"), slot, req, ..] => {
                if let Ok(req) = req.parse::<u64>() {
                    cancel_request(addons, &main(slot), req, *verb == "now");
                }
            }
            // forgotten once a request it is running ends: a session is held for
            // the whole request, so the wait is on a thread of its own
            ["WCCMD", _nonce, "fresh", slot] => {
                let (slot, held) = (main(slot), session(&main(slot)));
                thread::spawn(move || {
                    held.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).forget();
                    println!("  [{slot}] starts over (the conversation menu)");
                });
            }
            ["WCCMD", _nonce, "bind", key, what] => crate::settings_page::bind(addons, key, what),
            // the value is the rest of the line as drawn (a mic's name has spaces)
            ["WCCMD", _nonce, "set", key, ..] => {
                let value = line.splitn(5, ' ').nth(4).unwrap_or_default();
                crate::settings_page::set(addons, key, value);
            }
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
    crate::runs::finished(group);
    if !jobs::finish(group, jobs::State::Failed) {
        println!("  ended by a cancel");
        return Ok(false);
    }
    eprintln!("  not delivered: {err}");
    let line = Line::new(slot, "error", &format!("That request failed: {err}")).job(group, jobs::State::Failed).ended(jobs::members(group));
    post(addons, line)?;
    Ok(false)
}

/// Hand what was said to the agent, show its line in the window, and deliver
/// what it chose, the reply and its steps in one message. Returns whether the
/// agent wants to look at the results before it is done. `job`: the request's
/// job, queued or already running (a run taken from the queue); None makes one
/// (a resumed look).
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
    let run = match session.start(group, 0, spoken_for_agent, context) {
        Ok(run) => run,
        Err(err) => return failed(addons, &session.slot, group, err),
    };
    // cancelled before its process existed: end it now
    if !jobs::set_pid(group, run.pid) {
        end_processes(&[run.pid]);
        crate::runs::finished(group);
        println!("  cancelled before it started");
        return Ok(false);
    }
    // a queued request already showed its words; now it only starts thinking.
    // The agent is already running: an announcement that can't go out (the game
    // closed) must not end the request, or the agent works on unheard and its
    // reply is lost
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
    follow(addons, session, group, run)
}

/// Follow job `group`'s run to its answer and deliver it: a run this copy
/// started, or one a companion left going (src/runs.rs). Returns whether the
/// agent wants to look at the results before it is done.
pub(crate) fn follow(addons: &Path, session: &mut agent::Session, group: u64, run: crate::runs::Run) -> io::Result<bool> {
    let _following = Following::start();
    let answer = {
        // Progress goes to the window, newest only, every PROGRESS_EVERY at most:
        // each update costs a slot. Its own thread, so the agent never waits on
        // the game; it ends the moment the request does, so a reply never waits
        // on it.
        let (tell, heard) = std::sync::mpsc::channel::<String>();
        let courier = {
            let addons = addons.to_path_buf();
            let slot = session.slot.clone();
            thread::spawn(move || {
                let mut sent = 0;
                while let Ok(mut latest) = heard.recv() {
                    let due = Instant::now() + PROGRESS_EVERY;
                    loop {
                        match heard.recv_timeout(due.saturating_duration_since(Instant::now())) {
                            Ok(newer) => latest = newer,
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => break,
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
                        }
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
        // job stops dead until someone says "continue". The step limit still
        // bounds each round.
        let mut run = run;
        let answer = loop {
            let finished = match session.finish(&run, &mut progress, leaving) {
                Ok(None) => {
                    println!("  left to the next companion: its agent goes on");
                    return Ok(false);
                }
                Ok(Some(answer)) => Ok(answer),
                Err(err) => Err(err),
            };
            // Send now interrupted this run: the next one takes its messages
            if jobs::interrupted(group) {
                println!("  interrupted: the next run takes it");
                crate::runs::finished(group);
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
            let round = run.round + 1;
            if round > CONTINUES {
                break Err(io::Error::other(format!(
                    "ran out of steps {} times in a row; what it did so far stands. Say \"continue\" to carry on.",
                    CONTINUES + 1
                )));
            }
            println!("  out of steps: continuing ({round} of {CONTINUES})");
            progress(&format!("continuing ({round} of {CONTINUES})"));
            run = match session.start(
                group,
                round,
                "(The step limit ended your last turn before you answered. Carry on where you left off, then answer as usual.)",
                None,
            ) {
                Ok(next) => {
                    if !jobs::set_pid(group, next.pid) {
                        end_processes(&[next.pid]);
                        break Err(io::Error::other("stopped"));
                    }
                    next
                }
                Err(err) => break Err(err),
            };
        };
        drop(tell);
        let _ = courier.join();
        // how full the conversation is, for its row in game
        if let Some((tokens, window)) = session.context {
            let _ = send(addons, &Msg::new("context").text("slot", &slot).int("tokens", tokens).int("window", window));
        }
        match answer {
            Ok(answer) => answer,
            Err(err) => return failed(addons, &slot, group, err),
        }
    };
    // nothing goes out from a copy that is leaving: the next one follows the
    // finished run and delivers it
    let Some(_delivering) = Delivering::begin() else { return Ok(false) };
    voice::mark("agent answered");
    println!("claude: {}", answer.say);
    // One message, not two: the reply and the action it describes arrive together,
    // so there is no second bell and no two-second gap between reading the answer
    // and being offered the button. This one carries no `pending`, which stops the
    // spinner.
    // running low: offer the cure once per UI session, while a slot remains for it
    let used = slots_used(addons);
    if used + SLOTS_OFFER_RELOAD >= known_slots(addons) {
        let stamp = session_key(addons).unwrap_or_default();
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
        crate::runs::finished(group);
        println!("  cancelled while answering: reply dropped");
        return Ok(false);
    }
    let reply = Line::new(&session.slot, "claude", &say)
        .job(group, jobs::State::Answered)
        .ended(jobs::members(group))
        .steps(answer.inbox.clone());
    post(addons, reply)?;
    // the reply is in the ledger: the run is done with
    crate::runs::finished(group);
    // asked to start over: the next request begins a new conversation
    if answer.fresh {
        println!("  this conversation starts over");
        session.forget();
        return Ok(false);
    }
    if answer.look {
        println!("  waiting for the reload to look at the results");
    }
    Ok(answer.look)
}

pub(crate) fn think(addons: &Path, spoken: &str) -> io::Result<()> {
    let mut session = agent::Session::default();
    let started = Instant::now();
    let context = agent_context_for(addons, &session.slot);
    // a run of its own, with no job: its folder goes when it is done
    let id = jobs::now_ms() as u64;
    let run = session.start(id, 0, spoken, context)?;
    let answer = session.finish(&run, |doing| println!("  ... {doing}"), || false);
    crate::runs::finished(id);
    let answer = answer?.ok_or_else(|| io::Error::other("the run was left"))?;
    println!("({:.1}s) say: {}", started.elapsed().as_secs_f32(), answer.say);
    println!("would send: {}", answer.inbox.as_ref().map(Msg::lua).unwrap_or_else(|| "nothing".into()));
    if let Some((tokens, window)) = session.context {
        println!("context: {tokens} of {window} tokens");
    }
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

/// `tell <conversation> <words>` (and an agent's `strip --then`): a typed request
/// for the running companion. The conversation is one of `voice::Slot`'s, by
/// its name ("main" for the main one).
pub(crate) fn tell(slot: &str, words: &str) -> io::Result<()> {
    let named = slot.to_lowercase();
    let slot = voice::Slot::CONVERSATIONS
        .iter()
        .map(|slot| slot.key())
        .find(|key| *key == named || (key.is_empty() && named == "main"))
        .ok_or_else(|| io::Error::other(format!("no conversation {named:?}: main, l1, l2, r1, r2 or quick")))?;
    let dir = typed_dir().ok_or_else(|| io::Error::other("LOCALAPPDATA is not set"))?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_millis()).unwrap_or_default();
    // written whole under another name, then renamed: never read half-written
    let part = dir.join(format!("{stamp}.part"));
    fs::write(&part, format!("{slot}\n{words}\n"))?;
    fs::rename(&part, dir.join(format!("{stamp}.txt")))?;
    println!("left for the companion: [{}] {words}", if slot.is_empty() { "main" } else { slot });
    Ok(())
}
