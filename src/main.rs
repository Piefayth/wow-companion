//! The PC half of WoW Companion. `install` lays the addon and its slots into the
//! game's AddOns folder, `send` delivers one command through a slot and a bell,
//! and `probe` sends numbered messages so we can watch the channel work.

mod agent;
mod bells;
mod doctor;
mod heartbeat;
mod modules;
mod channel;
mod requests;
mod context;
mod restart;
mod chat;
mod install;
mod offline;
mod jobs;
mod audit;
mod strip;
use channel::*;
use requests::*;
use context::*;
use restart::*;
use chat::*;
use install::*;

use wow_companion_pad as pad;
use wow_companion_voice as voice;
use wow_companion_settings::Settings;

use std::{
    env, fs, io,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const ADDON: &str = "WowCompanion";
// set on a build started by another to honour `engine`, so it does not hand off again
const ENGINE_CHOSEN: &str = "WOW_COMPANION_ENGINE";

/// Where the companion's own files are (addon/, modules/, integrations/,
/// player/, CLAUDE.md): the folder of the exe in a release, this checkout in
/// development. `run` executes from a copy in %LOCALAPPDATA%, which names the
/// exe it came from, so that one counts.
fn home() -> PathBuf {
    let exe = env::var_os(SOURCE_EXE).map(PathBuf::from).or_else(|| env::current_exe().ok());
    if let Some(dir) = exe.as_deref().and_then(Path::parent) {
        if dir.join("addon").join(ADDON).is_dir() {
            return dir.to_path_buf();
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}
/// When the last clip was released. A request is not "in flight" until Whisper
/// and the gather window are done with it, so a restart in those few seconds
/// could cut a request off or, by the player's report, deliver it twice: the
/// restart also waits until no clip has been released for a few seconds.
static LAST_RELEASE: Mutex<Option<Instant>> = Mutex::new(None);
fn recently_released() -> bool {
    LAST_RELEASE.lock().unwrap().is_some_and(|at| at.elapsed() < Duration::from_secs(4))
}
/// How long after the last clip a request waits for the player to add to it:
/// long enough to slip off the button and back on, short enough not to be felt.
const GATHER: Duration = Duration::from_millis(500);

fn main() {
    // A release ships a CPU build beside the GPU one. Settings `engine = "cpu"`
    // (the setup window's self-test picks it when the GPU build cannot run on
    // this machine) hands every command to that one.
    if Settings::load().get("engine") == Some("cpu") && env::var_os(ENGINE_CHOSEN).is_none() {
        let cpu = env::current_exe().ok().map(|exe| exe.with_file_name("wow-companion-cpu.exe")).filter(|cpu| cpu.exists());
        if let Some(cpu) = cpu {
            let status = std::process::Command::new(cpu).args(env::args().skip(1)).env(ENGINE_CHOSEN, "cpu").status();
            std::process::exit(status.ok().and_then(|status| status.code()).unwrap_or(1));
        }
    }
    let args: Vec<String> = env::args().skip(1).collect();
    let result = match args.as_slice() {
        [command, addons] if command == "install" => install(Path::new(addons)),
        // ask the running companion to move onto the newest build once it is idle
        [command] if command == "restart" => request_restart(),
        // a request typed into a conversation (main, l1, l2, r1, r2), taken by the
        // running companion as if spoken there
        [command, slot, words @ ..] if command == "tell" && !words.is_empty() => tell(slot, &words.join(" ")),
        [command, addons] if command == "probe" => probe(Path::new(addons)),
        [command, addons, rest @ ..] if command == "send" => send(Path::new(addons), rest),
        // the agent's answer, printed and never delivered: for trying the agent
        // without a game to send into
        [command, addons, spoken] if command == "think" => think(Path::new(addons), spoken),
        [command, addons, spoken] if command == "ask" => {
            ask(Path::new(addons), &mut agent::Session::default(), spoken, false, None).map(|_| ())
        }
        // everything from this PC's settings file (the setup window writes it)
        [command] if command == "run" => {
            let settings = Settings::load();
            match (settings.get("addons"), settings.get("model")) {
                (Some(addons), Some(model)) => run(Path::new(addons), Path::new(model), &settings.options()),
                _ => Err(io::Error::other(
                    "no AddOns folder or Whisper model set: run wow-companion-setup, or give `run <AddOns> <model>`",
                )),
            }
        }
        // options given here win over the settings file's (the first one found counts)
        [command, addons, model, options @ ..] if command == "run" => {
            let mut all = options.to_vec();
            all.extend(Settings::load().options());
            run(Path::new(addons), Path::new(model), &all)
        }
        [command, addons] if command == "bridge" => bridge(Path::new(addons)),
        [command, addons, out] if command == "api" => pull(Path::new(addons), "api", Path::new(out)),
        [command, addons, out] if command == "alive" => {
            pull(Path::new(addons), "alive", Path::new(out))
        }
        [command, addons, out] if command == "apidocs" => {
            pull(Path::new(addons), "apidocs", Path::new(out))
        }
        [command, addons, out] if command == "context" => {
            pull(Path::new(addons), "context", Path::new(out))
        }
        // what the agent and Whisper would be given, without sending anything
        [command, addons] if command == "context" => {
            let addons = Path::new(addons);
            println!("{}", agent_context(addons).unwrap_or_else(|| "no context yet".into()));
            println!("
-- vocabulary: {}", vocabulary(addons).join(", "));
            Ok(())
        }
        // the data strip: what it shows now, or `--watch <s> <file> [--then <conv>]`,
        // the agents' detached reader (src/strip.rs)
        [command, rest @ ..] if command == "strip" => strip::command(rest),
        [command] if command == "pads" => pad::list(),
        [command] if command == "buzz" => pad::buzz(),
        [command] if command == "reconnect" => voice::reconnect(),
        // every link of the chain, checked: is it broken, and where
        [command, addons] if command == "doctor" => doctor::run(Path::new(addons)),
        [command] if command == "doctor" => match Settings::load().get("addons") {
            Some(addons) => doctor::run(Path::new(addons)),
            None => Err(io::Error::other("no AddOns folder set: run wow-companion-setup, or give `doctor <AddOns>`")),
        },
        [command, id] if command == "pads" => pad::watch(id),
        [command] if command == "mics" => voice::microphones(),
        // Whisper alone on a recorded clip, timed: checks a build on a new machine
        [command, model, wav] if command == "transcribe" => voice::transcribe_file(Path::new(model), Path::new(wav)),
        [command] if command == "speakers" => voice::speakers(),
        [command, fragment] if command == "formats" => voice::formats(fragment),
        [command, fragment] if command == "miccheck" => voice::miccheck(Some(fragment), None),
        [command, fragment, wake] if command == "miccheck" => voice::miccheck(Some(fragment), Some(wake)),
        [command, model, options @ ..] if command == "voice" => {
            voice::listen(Path::new(model), options, Vec::new, |_, _| Ok(()))
        }
        [command, addons, model, options @ ..] if command == "dictate" => {
            let addons = Path::new(addons);
            voice::listen(Path::new(model), options, || vocabulary(addons), |role, text| {
                if role.ends_with(" tap") {
                    return Ok(());
                }
                send_inbox(addons, &chat_inbox(text))
            })
        }
        _ => {
            eprintln!("usage: wow-companion <command> [args]");
            eprintln!("  install <AddOns>                 lay down the addon and its slots");
            eprintln!("  probe <AddOns>                   send numbered messages, end to end");
            eprintln!("  send <AddOns> chat <text>        put text in the chat box");
            eprintln!("  send <AddOns> macro <name> <body>  create or edit a macro");
            eprintln!("  send <AddOns> reload             reload the game's UI");
            eprintln!("  pads                             list HID devices");
            eprintln!("  pads <vid:pid>                   watch one pad's raw reports");
            eprintln!("  mics                             list input devices");
            eprintln!("  speakers                         list output devices");
            eprintln!("  voice <model> [options]          hold the button and speak");
            eprintln!("  run <AddOns> <model> [options]   the whole thing");
            eprintln!("  dictate <AddOns> <model> [options]");
            eprintln!("                                   speak into the open chat box");
            eprintln!("  ask <AddOns> <text>              one question, no voice");
            eprintln!("  api <AddOns> <out>               every callable in this build");
            eprintln!("  apidocs <AddOns> <out>           signatures, if the client has them");
            eprintln!("  context <AddOns> <out>           bars, bindings, macros, spellbook");
            eprintln!("  context <AddOns>                 what the agent and Whisper are given");
            eprintln!("  alive <AddOns> <out>             which documented reads answer (/wc alive)");
            eprintln!("    options: chat=home ask=minus mic=<name> cue=<name> volume=<0..1>");
            std::process::exit(2);
        }
    };
    if let Err(err) = result {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

/// The whole thing: controller, microphone, Whisper, the channel, and one
/// continuing conversation with the agent. Hold one button to dictate into the chat
/// box, the other to ask.
fn run(addons: &Path, model: &Path, options: &[String]) -> io::Result<()> {
    // run from a copy, so `cargo build` can replace the real one while we run
    if let Some(handed_over) = run_from_copy()? {
        return handed_over;
    }
    {
        let args: Vec<String> = env::args().skip(1).collect();
        thread::spawn(move || watch_for_restart(args));
    }
    // the in-game "companion" mark: beats while the voice loop can hear the player,
    // and stops when a restart hands over
    heartbeat::start(addons, || {
        voice::READY.load(Ordering::SeqCst) && !voice::SHUTDOWN.load(Ordering::SeqCst)
    });
    // the same conversation as before a restart: it remembers what you were doing
    let mut session = agent::Session::resumed();
    if let Some(chosen) = options.iter().find_map(|option| option.strip_prefix("agent=")) {
        session.model = chosen.to_string();
    }
    println!(
        "agent: claude -p --model {}",
        if session.model.is_empty() { agent::DEFAULT_MODEL } else { &session.model }
    );
    let game = addons.parent().and_then(Path::parent).unwrap_or(addons);
    session.setup = format!(
        "game: {}\nAddOns: {}\nthis project: {}\nhelper: {}",
        game.display(),
        addons.display(),
        home().display(),
        env::current_exe().map(|exe| exe.display().to_string()).unwrap_or_default()
    );
    // one conversation, reached from the voice loop and from the reload watcher
    let session = Arc::new(Mutex::new(session));
    // Some(session start) while the agent waits to look: the reload it asked for
    // is the next change to that timestamp
    let looking: Arc<Mutex<Option<Option<u128>>>> = Arc::new(Mutex::new(None));
    {
        let (addons, session, looking) = (addons.to_path_buf(), Arc::clone(&session), Arc::clone(&looking));
        thread::spawn(move || watch_for_looks(&addons, &session, &looking));
    }
    // Stop in the window: the game's commands, read off the data strip
    {
        let addons = addons.to_path_buf();
        thread::spawn(move || watch_commands(&addons));
    }
    // The voice loop never sends anything itself. A send waits for any other send
    // and then about two seconds for the game to hear it, and the voice loop is
    // what reads the pad: sending from it froze the buttons and the cues whenever
    // the agent was talking at the same time (measured: a request made while
    // another ran). One courier thread delivers in order instead.
    let courier = {
        let (post, mailbox) = std::sync::mpsc::channel::<String>();
        let addons = addons.to_path_buf();
        thread::spawn(move || {
            for inbox in mailbox {
                if let Err(err) = send_inbox(&addons, &inbox) {
                    eprintln!("  not delivered: {err}");
                }
            }
        });
        post
    };
    let deliver = |inbox: String| {
        courier.send(inbox).map_err(|_| io::Error::other("the courier thread has stopped"))
    };
    // One conversation per trigger slot (L1, L2, R1, R2), each its own thread,
    // made on first use; "" is the main one. Different slots run side by side.
    let slots: Arc<Mutex<std::collections::HashMap<String, Arc<Mutex<agent::Session>>>>> = {
        let mut map = std::collections::HashMap::new();
        map.insert(String::new(), Arc::clone(&session));
        Arc::new(Mutex::new(map))
    };
    // Copied now, while nothing holds the main session. Creating a conversation
    // used to lock the main one for these two fields, and the main one is held for
    // a whole request: the voice loop waited minutes, the pad went dead and the
    // rumble with it, until the request finished (2026-11-10).
    let (base_model, base_setup) = {
        let main = session.lock().unwrap();
        (main.model.clone(), main.setup.clone())
    };
    let slot_session = {
        let slots = Arc::clone(&slots);
        move |slot: &str| -> Arc<Mutex<agent::Session>> {
            let mut map = slots.lock().unwrap();
            if let Some(found) = map.get(slot) {
                return Arc::clone(found);
            }
            let mut fresh = agent::Session::resumed_slot(slot);
            fresh.model = base_model.clone();
            fresh.setup = base_setup.clone();
            let fresh = Arc::new(Mutex::new(fresh));
            map.insert(slot.to_string(), Arc::clone(&fresh));
            fresh
        }
    };
    // Typed requests (`wow-companion tell <slot> <text>`): a file per request in
    // %LOCALAPPDATA%\wow-companion\typed, taken as if spoken into that
    // conversation, so one can be asked from a terminal while the player is away.
    // The reply goes to the game as usual.
    {
        let (addons, find_session, looking, courier) =
            (addons.to_path_buf(), slot_session.clone(), Arc::clone(&looking), courier.clone());
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(2));
            let Some(dir) = typed_dir() else { continue };
            let mut waiting: Vec<_> = fs::read_dir(&dir).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "txt")).collect();
            waiting.sort();
            for path in waiting {
                let Ok(text) = fs::read_to_string(&path) else { continue };
                if fs::remove_file(&path).is_err() {
                    continue;
                }
                let Some((slot, text)) = text.split_once('\n') else { continue };
                let (slot, text) = (slot.trim().to_string(), text.trim().to_string());
                if text.is_empty() {
                    continue;
                }
                println!("typed ({}): {text}", if slot.is_empty() { "main" } else { &slot });
                let (addons, session, looking, courier) =
                    (addons.clone(), find_session(&slot), Arc::clone(&looking), courier.clone());
                thread::spawn(move || {
                    let text = if slot.is_empty() { text } else { format!("[{}] {}", slot.to_uppercase(), text) };
                    if slot.is_empty() {
                        *looking.lock().unwrap() = None;
                    }
                    let job = jobs::create(&slot, &text, jobs::State::Queued);
                    let (mut held, queued) = match session.try_lock() {
                        Ok(guard) => (guard, false),
                        Err(std::sync::TryLockError::Poisoned(poisoned)) => (poisoned.into_inner(), false),
                        Err(std::sync::TryLockError::WouldBlock) => {
                            let line = log_inbox_in(Some(&slot), "you", &text, None, None)
                                .replacen("{ kind = \"log\"", &format!("{{ kind = \"log\"{}", jobs::fields(job, jobs::state(job).unwrap_or(jobs::State::Queued))), 1);
                            let _ = courier.send(line);
                            (session.lock().unwrap_or_else(|poisoned| poisoned.into_inner()), true)
                        }
                    };
                    let text = if queued {
                        match run_queued(&addons, &slot, job) {
                            Some(all) => all,
                            None => return,
                        }
                    } else {
                        text
                    };
                    IN_FLIGHT.fetch_add(1, Ordering::SeqCst);
                    let _done = InFlight;
                    match ask(&addons, &mut held, &text, queued, Some(job)) {
                        Ok(true) if slot.is_empty() => *looking.lock().unwrap() = Some(session_began(&addons)),
                        Ok(_) => {}
                        Err(err) => {
                            eprintln!("  not delivered: {err}");
                            tell_failure(&addons, &err);
                        }
                    }
                });
            }
        });
    }
    voice::listen(
        model,
        options,
        || vocabulary(addons),
        |role, text| match role {
            // a tap of the ask button, too short to be speech: show the window
            // a tap opens the window: one slot, of 512. A bell of its own (no slot)
            // was tried and failed: the game holds a constantly polled bell open,
            // so it could never be rung (measured: locked for 10 s straight)
            "ask tap" => deliver("{ kind = \"show\" }".to_string()),
            // the voice loop's own news (a reconnected headset), for the window
            "notice" => deliver(log_inbox("error", text, None, None)),
            // a clip's own notice ("nothing was sent") goes to the conversation it
            // was for, not whichever one the window shows ("ask@r2 notice")
            r if r.ends_with(" notice") || r.ends_with(" unheard") => {
                let role = r.trim_end_matches(" notice").trim_end_matches(" unheard");
                let slot = match role {
                    "ask" => Some(""),
                    _ => role.strip_prefix("ask@").filter(|slot| *slot != "say"),
                };
                // a transcript that came back empty: its clip is back (a clip too
                // short for Whisper, " unheard", never left)
                if let (Some(slot), true) = (slot, r.ends_with(" notice")) {
                    jobs::words(slot, "");
                }
                deliver(log_inbox_in(slot, "error", text, None, None))
            }
            _ if role.ends_with(" tap") => Ok(()),
            r if r.starts_with("ask") && r.ends_with(" heard") => {
                *LAST_RELEASE.lock().unwrap() = Some(Instant::now());
                // the clip is a job from the moment it is let go (src/jobs.rs):
                // a cancel pressed while it is heard ends that job, and its words
                // are dropped when they come back; a clip let go while one is
                // still being gathered joins it
                let role = r.trim_end_matches(" heard");
                if role == "ask" || (role.starts_with("ask@") && role != "ask@say") {
                    jobs::hear(role.strip_prefix("ask@").unwrap_or(""));
                }
                // Not sent any more (2026-11-10): the addon hears minus come up
                // and shows "transcribing" itself, at once. Sending it held the
                // channel for the bell's 2 s just as the words arrived, so the
                // request's own line waited behind it (the player: "4 seconds
                // for a short transcription").
                Ok(())
            }
            _ if role.ends_with(" heard") => {
                *LAST_RELEASE.lock().unwrap() = Some(Instant::now());
                Ok(())
            }
            // L1+R1: dictation, no agent. Sent at once (no gathering): the line
            // goes into the chat box (or waits for it), on the channel it opens
            // with, else on the one picked on the chat wheel (the addon adds it)
            "ask@say" => {
                if discards(text) {
                    return deliver("{ kind = \"chat\", clear = true }".to_string());
                }
                let routed = channeled(text);
                *LAST_CHAT.lock().unwrap() = Some((routed.clone(), Instant::now()));
                println!("  dictated: {routed}");
                // no line in a conversation (the player: agents need not see
                // every dictation); the chat box itself shows it
                deliver(say_inbox(text, &routed))
            }
            r if r == "ask" || r.starts_with("ask@") => {
                let slot = r.strip_prefix("ask@").unwrap_or("").to_string();
                // Gathered, not sent at once: the player often lets go before they
                // are finished, and a second press within GATHER of the last clip
                // adds to the same request instead of starting another (the
                // player, 2026-11-10). The job collects the words (src/jobs.rs).
                let Some((job, first)) = jobs::words(&slot, text) else {
                    println!("  dropped: cancelled while being heard");
                    return Ok(());
                };
                if !first {
                    println!("  added to the request being gathered");
                    return Ok(());
                }
                // the session is found or made on the request's own thread: nothing
                // the voice loop does may wait on a lock a request can hold
                let (addons, find_session, looking, courier) =
                    (addons.to_path_buf(), slot_session.clone(), Arc::clone(&looking), courier.clone());
                thread::spawn(move || {
                    voice::mark("request thread up");
                    let session = find_session(&slot);
                    let text = loop {
                        thread::sleep(Duration::from_millis(100));
                        match jobs::gathered(job, GATHER, voice::HOLDING.load(Ordering::Relaxed)) {
                            None => continue,
                            Some(Ok(words)) => break words,
                            Some(Err(state)) => {
                                println!("  dropped: {} while being gathered", state.name());
                                return;
                            }
                        }
                    };
                    voice::mark("gathered");
                    // not a request for the agent (chat, clearing, starting over):
                    // the job just ends
                    let handled = || {
                        jobs::finish(job, jobs::State::Answered);
                    };
                    // One button for both: a line that opens with a channel ("party,
                    // pulling now", "whisper Sage, ...") is chat, not a request, and
                    // "scratch that" alone empties the box.
                    if discards(&text) {
                        println!("  clearing the chat box");
                        handled();
                        let _ = courier.send("{ kind = \"chat\", clear = true }".to_string());
                        // a line without `pending` also clears "got it, transcribing"
                        let _ = courier.send(log_inbox("you", &text, None, None));
                        return;
                    }
                    // "start over" / "new conversation" alone: this conversation
                    // begins fresh (the Home chords for it were dropped, 2026-11-10)
                    let plain: String = text.chars().filter(|c| c.is_alphanumeric() || c.is_whitespace()).collect::<String>().to_lowercase();
                    if matches!(plain.trim(), "start over" | "new conversation" | "fresh start" | "reset conversation") {
                        handled();
                        session.lock().map(|mut s| s.forget()).ok();
                        let _ = courier.send(log_inbox_in(Some(&slot), "you", "(started this conversation over)", None, None));
                        return;
                    }
                    let routed = channeled(&text);
                    if routed != text.trim() {
                        println!("  chat line: {routed}");
                        handled();
                        *LAST_CHAT.lock().unwrap() = Some((routed.clone(), Instant::now()));
                        let _ = courier.send(dictation_inbox(&text, &routed));
                        let _ = courier.send(log_inbox("you", &format!("(to chat) {routed}"), None, None));
                        return;
                    }
                    // "edit ..." / "change ..." soon after a chat line: the agent gets
                    // the line, rewrites it and sends it back to the chat box
                    let lowered = text.trim_start().to_lowercase();
                    let text = match LAST_CHAT.lock().unwrap().as_ref() {
                        Some((line, at)) if at.elapsed() < Duration::from_secs(300)
                            && (lowered.starts_with("edit") || lowered.starts_with("change")
                                || lowered.starts_with("reword") || lowered.starts_with("fix")) =>
                        {
                            format!("{text}

(Editing the last chat line: `{line}`. Rewrite it as asked, keep the slash command, and give it as a `send` step. It goes into the chat box if that is open and empty; else it waits for the next time they open chat, so if the old line is still in the box, tell them to clear it with circle and open chat again.)")
                        }
                        _ => text,
                    };
                    // a slot's request is marked with it, in the window and for the
                    // agent ("[L2] ..."), so both can tell the conversations apart
                    let text = if slot.is_empty() { text } else { format!("[{}] {}", slot.to_uppercase(), text) };
                    // a new request supersedes a look still waiting for its reload
                    *looking.lock().unwrap() = None;
                    // A request made while another runs is shown at once, as
                    // waiting: otherwise it appears only when it starts, and reads
                    // as dropped.
                    // Waiting means *this conversation's* lock is held: a request in
                    // another slot (counted in IN_FLIGHT) is no reason to wait, and
                    // marking R1 "waiting" for the main one sent that line after R1's
                    // reply, so it read as stuck (2026-11-10).
                    let (mut held, queued) = match session.try_lock() {
                        Ok(guard) => (guard, false),
                        Err(std::sync::TryLockError::Poisoned(poisoned)) => (poisoned.into_inner(), false),
                        Err(std::sync::TryLockError::WouldBlock) => {
                            // Shown in the transcript as queued, on the request's own
                            // line; the board and WORKING keep the running request's
                            // progress, which the waiting line used to overwrite
                            // (the player, 2026-11-10).
                            let line = log_inbox_in(Some(&slot), "you", &text, None, None)
                                .replacen("{ kind = \"log\"", &format!("{{ kind = \"log\"{}", jobs::fields(job, jobs::state(job).unwrap_or(jobs::State::Queued))), 1);
                            let _ = courier.send(line);
                            // waiting messages go together (the player, 2026-11-10:
                            // "it should send every queued message"): the first to get
                            // the conversation takes all of them (jobs::take_queued)
                            (session.lock().unwrap_or_else(|poisoned| poisoned.into_inner()), true)
                        }
                    };
                    let text = if queued {
                        match run_queued(&addons, &slot, job) {
                            Some(all) => all,
                            // another waiting request already took this one
                            None => return,
                        }
                    } else {
                        text
                    };
                    IN_FLIGHT.fetch_add(1, Ordering::SeqCst);
                    let _done = InFlight;
                    match ask(&addons, &mut held, &text, queued, Some(job)) {
                        // a look resumes the main conversation, so only the main one looks
                        Ok(true) if slot.is_empty() => *looking.lock().unwrap() = Some(session_began(&addons)),
                        Ok(true) => {}
                        Ok(false) => {}
                        Err(err) => {
                            eprintln!("  not delivered: {err}");
                            tell_failure(&addons, &err);
                        }
                    }
                });
                Ok(())
            }
            _ if discards(text) => {
                println!("  clearing the chat box");
                deliver("{ kind = \"chat\", clear = true }".to_string())
            }
            _ => {
                let routed = channeled(text);
                if routed != text {
                    println!("  as: {routed}");
                }
                deliver(dictation_inbox(text, &routed))
            }
        },
    )?;
    // a restart closed the voice loop; the restart thread starts the next copy and
    // exits this process, so do not let main return and end it first
    if voice::SHUTDOWN.load(Ordering::SeqCst) {
        loop {
            thread::park();
        }
    }
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target: PathBuf = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            // write only when the bytes differ: the addon's mtime is how we tell a
            // stale UI session from a current one, so a pointless copy would lie
            let source = fs::read(entry.path())?;
            if fs::read(&target).is_ok_and(|existing| existing == source) {
                continue;
            }
            fs::write(&target, &source)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::channeled;
    use super::*;
    use std::time::{Duration, Instant, SystemTime};

    /// A throwaway game folder: <root>/Interface/AddOns/WowCompanion and the
    /// account's SavedVariables, which is where the slot cursor's reset comes from.
    fn game(name: &str, slot_count: u32) -> (PathBuf, PathBuf) {
        let root = env::temp_dir().join(format!("wc-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let addons = root.join("Interface").join("AddOns");
        fs::create_dir_all(addons.join(ADDON)).unwrap();
        let saved_dir = root.join("WTF").join("Account").join("A").join("SavedVariables");
        fs::create_dir_all(&saved_dir).unwrap();
        let saved = saved_dir.join(format!("{ADDON}.lua"));
        fs::write(&saved, format!("WowCompanionDB = {{ [\"slotCount\"] = {slot_count}, }}")).unwrap();
        (addons, saved)
    }

    #[test]
    fn slots_count_up_and_start_over_when_the_game_saves() {
        let (addons, saved) = game("cursor", 100);
        assert_eq!(slots_used(&addons), 0);
        assert_eq!(next_slot(&addons).unwrap(), 1);
        assert_eq!(next_slot(&addons).unwrap(), 2);
        assert_eq!(slots_used(&addons), 2);
        // a /reload writes SavedVariables: the addon's cursor is back at slot 1
        let later = SystemTime::now() + Duration::from_secs(5);
        fs::File::options().write(true).open(&saved).unwrap().set_modified(later).unwrap();
        assert_eq!(slots_used(&addons), 0);
        assert_eq!(next_slot(&addons).unwrap(), 1);
    }

    #[test]
    fn sends_stop_at_the_slots_the_game_can_see() {
        let (addons, _) = game("limit", 2);
        assert_eq!(known_slots(&addons), 2);
        next_slot(&addons).unwrap();
        next_slot(&addons).unwrap();
        let err = next_slot(&addons).unwrap_err().to_string();
        assert!(err.contains("slots are spent"), "{err}");
    }

    #[test]
    fn bells_reuse_eight_names_in_turn() {
        assert_eq!(bell_name(1), "m1.wav");
        assert_eq!(bell_name(8), "m8.wav");
        assert_eq!(bell_name(9), "m1.wav");
        assert_eq!(catch_up_name(17), "c1.wav");
    }

    #[test]
    fn lua_strings_survive_quotes_backslashes_and_newlines() {
        assert_eq!(lua_string(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(lua_string(r"C:\x"), r#""C:\\x""#);
        assert_eq!(lua_string("a\nb"), r#""a\nb""#);
    }

    #[test]
    fn the_board_lists_every_working_conversation_and_every_recent_state() {
        let running = jobs::create("t-board", "hi", jobs::State::Running);
        jobs::set_doing(running, "reading \"main.rs\"");
        let ended = jobs::create("t-board2", "bye", jobs::State::Running);
        jobs::finish(ended, jobs::State::Answered);
        let inbox = board_inbox();
        // never opens with its kind, or the send would treat it as droppable
        assert!(inbox.starts_with("{ kind = \"board\", resync = true, working = {"), "{inbox}");
        assert!(inbox.contains("slot = \"t-board\", text = \"reading \\\"main.rs\\\"\""), "{inbox}");
        assert!(!inbox.contains("slot = \"t-board2\", text"), "an answered one is not working: {inbox}");
        assert!(inbox.contains(&format!("{{ job = {ended}, slot = \"t-board2\", state = \"answered\" }}")), "{inbox}");
    }

    #[test]
    fn spoken_channels_become_slash_commands() {
        assert_eq!(channeled("Party, on my way."), "/p on my way.");
        assert_eq!(channeled("To guild: anyone selling bags?"), "/g anyone selling bags?");
        assert_eq!(channeled("Slash P hello there"), "/p hello there");
        assert_eq!(channeled("Raid warning, stack on me"), "/rw stack on me");
        assert_eq!(channeled("raid pull in ten"), "/raid pull in ten");
        assert_eq!(channeled("Reply, sure thing"), "/r sure thing");
    }

    #[test]
    fn ordinary_sentences_are_left_alone() {
        assert_eq!(channeled("Hello everyone."), "Hello everyone.");
        assert_eq!(channeled("Partying is fun"), "Partying is fun");
        assert_eq!(channeled("my guild is great"), "my guild is great");
        assert_eq!(channeled("Party."), "Party.");
    }
}
