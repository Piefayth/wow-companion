//! The PC half of WoW Companion. `install` lays the addon and its slots into the
//! game's AddOns folder, `send` delivers one message through a slot and its bell,
//! `run` is the companion itself.

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
mod jobs;
mod ledger;
mod message;
mod savedvars;
mod session;
mod audit;
mod strip;
#[cfg(windows)]
mod duplication;
mod crash;
mod lifecycle;
mod logfile;
mod tray;
mod watcher;
mod backups;
use channel::*;
use requests::*;
use context::*;
use restart::*;
use chat::*;
use install::*;
use message::{Line, Msg, Out};

use wow_companion_pad as pad;
use wow_companion_voice as voice;
use voice::{Event, Slot};
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
/// Messages handed to the courier thread and not yet sent: an exit waits for none
/// (lifecycle::idle).
pub(crate) static COURIER: AtomicUsize = AtomicUsize::new(0);
/// The courier thread's mailbox; every message through it counts in COURIER
/// until it is delivered.
#[derive(Clone)]
struct Courier(std::sync::mpsc::Sender<Out>);

impl Courier {
    fn send(&self, message: Out) -> io::Result<()> {
        COURIER.fetch_add(1, Ordering::SeqCst);
        self.0.send(message).map_err(|_| {
            COURIER.fetch_sub(1, Ordering::SeqCst);
            io::Error::other("the courier thread has stopped")
        })
    }
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
        // the watcher: the companion wakes with WoW and sleeps without it, with a
        // tray icon (src/watcher.rs); `stop` ends companion and watcher cleanly
        [command] if command == "start" => watcher::start(),
        [command] if command == "stop" => lifecycle::stop(),
        // a request typed into a conversation (main, l1, l2, r1, r2, quick), for
        // the running companion to ask that conversation's agent
        [command, slot, words @ ..] if command == "tell" && !words.is_empty() => tell(slot, &words.join(" ")),
        // the agent's answer, printed and never delivered: for trying the agent
        // without a game to send into
        [command, addons, spoken] if command == "think" => think(Path::new(addons), spoken),
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
        [command] if command == "buzz" => match Settings::load().get("pad") {
            Some(id) => pad::buzz(id),
            None => Err(io::Error::other("no controller chosen: pick it in the setup window")),
        },
        [command] if command == "reconnect" => voice::reconnect(),
        // every link of the chain, checked: is it broken, and where
        [command, addons] if command == "doctor" => doctor::run(Path::new(addons)),
        [command] if command == "doctor" => match Settings::load().get("addons") {
            Some(addons) => doctor::run(Path::new(addons)),
            None => Err(io::Error::other("no AddOns folder set: run wow-companion-setup, or give `doctor <AddOns>`")),
        },
        // the newest good copy of the save file back, game closed (src/backups.rs)
        [command, rest @ ..] if command == "restore-save" && rest.len() <= 1 => match Settings::load().get("addons") {
            Some(addons) => backups::restore(Path::new(addons), rest.first().map(Path::new)),
            None => Err(io::Error::other("no AddOns folder set: run wow-companion-setup first")),
        },
        [command, id] if command == "pads" => pad::watch(id),
        [command] if command == "mics" => voice::microphones(),
        // Whisper alone on a recorded clip, timed: checks a build on a new machine
        [command, model, wav] if command == "transcribe" => voice::transcribe_file(Path::new(model), Path::new(wav)),
        // the streaming engine on a clip at the pace of speech, with this
        // character's vocabulary as its hotwords
        [command, folder, wav] if command == "transcribe-stream" => {
            let vocabulary = Settings::load().get("addons").map(|addons| context::vocabulary(Path::new(addons))).unwrap_or_default();
            voice::transcribe_stream_file(Path::new(folder), Path::new(wav), &vocabulary)
        }
        [command] if command == "speakers" => voice::speakers(),
        [command, fragment] if command == "formats" => voice::formats(fragment),
        [command, fragment] if command == "miccheck" => voice::miccheck(Some(fragment), None),
        [command, fragment, wake] if command == "miccheck" => voice::miccheck(Some(fragment), Some(wake)),
        [command, model, options @ ..] if command == "voice" => {
            voice::listen(Path::new(model), options, Vec::new, |_| Ok(()))
        }
        _ => {
            eprintln!("usage: wow-companion <command> [args]");
            eprintln!("  install <AddOns>                 lay down the addon and its slots");
            eprintln!("  tell <conversation> <text>       a typed request to the running companion");
            eprintln!("  pads                            list HID devices");
            eprintln!("  pads <vid:pid>                   watch one pad's raw reports");
            eprintln!("  mics                             list input devices");
            eprintln!("  speakers                         list output devices");
            eprintln!("  voice <model> [options]          hold the button and speak");
            eprintln!("  run <AddOns> <model> [options]   the whole thing");
            eprintln!("  start                            wake with WoW, hidden, with a tray icon");
            eprintln!("  stop                             end the companion (and the watcher) cleanly");
            eprintln!("  think <AddOns> <text>            the agent's answer, sent nowhere");
            eprintln!("  context <AddOns> <out>           bars, bindings, macros, spellbook");
            eprintln!("  context <AddOns>                 what the agent and Whisper are given");
            eprintln!("    options: ask=minus mic=<name> cue=<name> volume=<0..1>");
            std::process::exit(2);
        }
    };
    if let Err(err) = result {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

/// The whole thing: controller, microphone, speech, the channel, and the
/// conversations with the agent. One talk button: a trigger held with it picks the
/// conversation, L1+R1 dictates, and a line opening with a channel word is chat.
fn run(addons: &Path, model: &Path, options: &[String]) -> io::Result<()> {
    // one companion at a time (src/lifecycle.rs)
    lifecycle::refuse_second()?;
    // run from a copy, so `cargo build` can replace the real one while we run
    if let Some(handed_over) = run_from_copy()? {
        return handed_over;
    }
    // what it prints also goes to companion.log; a panic goes to crash.log
    logfile::tee();
    crash::install(addons);
    lifecycle::hold()?;
    lifecycle::watch(addons);
    // every line until the game has saved it, and every job's state, on disk
    // and in the mailbox the game reads at load (src/ledger.rs); jobs the last
    // companion left running end now, each with a line
    // dictation only (the setup window's agent "off"): no agent, so no conversation
    // and no ledger; what would be a line in one is said as a notice (channel::post)
    let agents = !options.iter().any(|option| option.strip_prefix("agent=") == Some(wow_companion_settings::AGENT_OFF));
    let recovered = ledger::open(addons, agents);
    {
        let addons = addons.to_path_buf();
        thread::spawn(move || {
            for line in recovered {
                let _ = send_line_now(&addons, line);
            }
            crash::after_start(&addons);
        });
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
    if agents {
        println!("agent: claude -p --model {}", if session.model.is_empty() { agent::DEFAULT_MODEL } else { &session.model });
    } else {
        println!("agents off: dictation only, everything said goes to the chat box");
    }
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
    // Cancel and Send now in the window: the game's commands, read off the data strip
    {
        let addons = addons.to_path_buf();
        thread::spawn(move || watch_commands(&addons));
    }
    // the slot bells of the sets no session uses, emptied (docs/proposals/slot-bells.md)
    {
        let addons = addons.to_path_buf();
        thread::spawn(move || tend_slot_bells(&addons));
    }
    // other processes' asks to read the game (an agent's `strip --chat`)
    strip::serve_asks(addons);
    // The voice loop never sends anything itself. A send waits for any other send,
    // and for a bell file the game may hold, and the voice loop is what reads
    // the pad: sending from it froze the buttons and the cues whenever
    // the agent was talking at the same time (measured: a request made while
    // another ran). One courier thread delivers in order instead.
    let courier = {
        let (out, waiting) = std::sync::mpsc::channel::<Out>();
        let addons = addons.to_path_buf();
        thread::spawn(move || {
            for message in waiting {
                if let Err(err) = send_out(&addons, message) {
                    eprintln!("  not delivered: {err}");
                }
                COURIER.fetch_sub(1, Ordering::SeqCst);
            }
        });
        Courier(out)
    };
    let deliver = |message: Out| courier.send(message);
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
    // %LOCALAPPDATA%\wow-companion\typed: a request to that conversation's agent
    // (the spoken shortcuts are for speech only), asked from a terminal.
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
                let job = jobs::create(&slot, &text, jobs::State::Queued);
                let (addons, session, looking, courier) =
                    (addons.clone(), find_session(&slot), Arc::clone(&looking), courier.clone());
                let in_flight = InFlight::start();
                thread::spawn(move || {
                    let _in_flight = in_flight;
                    request(&addons, &slot, text, job, &session, &looking, &courier);
                });
            }
        });
    }
    let dictation = Slot::Dictation.key();
    voice::listen(model, options, || vocabulary(addons), |event| {
        // dictation only: every clip is dictation's (its words to the chat box,
        // its notices as dictation's)
        let event = if agents { event } else { event.for_slot(Slot::Dictation) };
        match event {
            // the voice loop's own news (a reconnected headset), for the window
            Event::Notice(text) => deliver(Out::Line(Line::new("", "error", text))),
            // The clip is a job from the moment it is let go (src/jobs.rs): a cancel
            // pressed while it is heard ends that job, and its words are dropped when
            // they come back. A new clip's job is named to the game at once (its
            // hearing line carries the id). A clip let go while another of its
            // conversation is still being gathered joins it; dictation's never join,
            // each is sent as it comes back.
            Event::Released(slot) => match jobs::hear(slot.key(), slot != Slot::Dictation) {
                (id, true) => {
                    deliver(Out::Now(Msg::new("heard").int("job", id).text("slot", slot.key()).text("state", jobs::State::Hearing.name())))
                }
                (_, false) => Ok(()),
            },
            // dictation's clip came back empty: its job ends, said as dictation's
            // own notice (it is no conversation's), named so its wait ends
            Event::Empty(Slot::Dictation, why) => {
                let mut notice = Msg::new("notice").text("text", why);
                if let Some(job) = jobs::empty(dictation) {
                    notice = notice.int("job", job).text("slot", dictation).text("state", jobs::State::Failed.name());
                }
                deliver(Out::Now(notice))
            }
            // a clip that came back empty: its notice goes to the conversation it
            // was for, and ends the job its release made, so "hearing you" ends too
            Event::Empty(slot, why) => {
                let mut line = Line::new(slot.key(), "error", why);
                if let Some(job) = jobs::empty(slot.key()) {
                    line = line.job(job, jobs::State::Failed);
                }
                deliver(Out::Line(line))
            }
            // never released, so no job; dictation's is said in the main conversation
            Event::Unheard(slot, why) => {
                let conversation = if slot == Slot::Dictation { "" } else { slot.key() };
                deliver(Out::Line(Line::new(conversation, "error", why)))
            }
            // L1+R1: dictation, no agent. Sent at once (no gathering): the line
            // goes into the chat box (or waits for it), on the channel it opens
            // with, else on the one picked on the chat wheel (the addon adds it)
            Event::Words(Slot::Dictation, text) => {
                // its clip's job ends answered with the message that carries the words
                let Some((job, _)) = jobs::words(dictation, text) else {
                    println!("  dropped: dictation cancelled while being heard");
                    return Ok(());
                };
                let _ = jobs::advance(job, jobs::State::Answered);
                let ended = |msg: Msg| msg.int("job", job).text("slot", dictation).text("state", jobs::State::Answered.name());
                if discards(text) {
                    return deliver(Out::Now(ended(Msg::new("chat").flag("clear", true))));
                }
                let routed = channeled(text);
                println!("  dictated: {routed}");
                // no line in a conversation (agents need not see every
                // dictation); the chat box itself shows it
                deliver(Out::Now(ended(say_inbox(text, &routed))))
            }
            Event::Words(slot, text) => {
                let slot = slot.key().to_string();
                // Gathered, not sent at once: the player often lets go before they
                // are finished, and a second press within GATHER of the last clip
                // adds to the same request instead of starting another. The job
                // collects the words (src/jobs.rs).
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
                // counted from now, not from when the agent starts: gathering and
                // queueing are part of the request
                let in_flight = InFlight::start();
                thread::spawn(move || {
                    let _in_flight = in_flight;
                    voice::mark("request thread up");
                    let session = find_session(&slot);
                    let text = loop {
                        thread::sleep(Duration::from_millis(100));
                        match jobs::gathered(job, GATHER, voice::HOLDING.load(Ordering::Relaxed)) {
                            None => continue,
                            Some(Ok(words)) => break words,
                            Some(Err(state)) => {
                                println!("  dropped: {} while being gathered", state.name());
                                // cancelled while heard: what was said stays in the
                                // conversation, marked cancelled (the window draws
                                // only what the PC numbers, so this is its line)
                                if state == jobs::State::Cancelled {
                                    let said = jobs::get(&[job]).first().map(|j| j.text.trim().to_string()).unwrap_or_default();
                                    let said = if said.is_empty() { "(cancelled while it was still being heard)".to_string() } else { said };
                                    let _ = courier.send(Out::Line(Line::new(&slot, "you", &said).job(job, jobs::State::Cancelled)));
                                }
                                return;
                            }
                        }
                    };
                    voice::mark("gathered");
                    if !spoken_shortcut(&slot, &text, job, &session, &courier) {
                        request(&addons, &slot, text, job, &session, &looking, &courier);
                    }
                });
                Ok(())
            }
        }
    })?;
    // a restart closed the voice loop; the restart thread starts the next copy and
    // exits this process, so do not let main return and end it first
    if voice::SHUTDOWN.load(Ordering::SeqCst) {
        loop {
            thread::park();
        }
    }
    Ok(())
}

/// What speech cannot say any other way (Whisper never writes "/p", and a
/// controller cannot type it), done for a spoken clip `job` in conversation
/// `slot`: "scratch that" alone clears the chat box, "start over" alone begins
/// the conversation afresh, and a line opening with a channel word ("party,
/// pulling now") goes to the chat box. True when it was one of those; its job
/// then just ends. Typed requests never come here: typing can say all three.
fn spoken_shortcut(slot: &str, text: &str, job: u64, session: &Mutex<agent::Session>, courier: &Courier) -> bool {
    let handled = || {
        jobs::finish(job, jobs::State::Answered);
    };
    if discards(text) {
        println!("  clearing the chat box");
        handled();
        let _ = courier.send(Out::Now(Msg::new("chat").flag("clear", true)));
        let _ = courier.send(Out::Line(Line::new(slot, "you", text)));
        return true;
    }
    let plain: String = text.chars().filter(|c| c.is_alphanumeric() || c.is_whitespace()).collect::<String>().to_lowercase();
    if matches!(plain.trim(), "start over" | "new conversation" | "fresh start" | "reset conversation") {
        handled();
        session.lock().map(|mut s| s.forget()).ok();
        let _ = courier.send(Out::Line(Line::new(slot, "you", "(started this conversation over)")));
        return true;
    }
    let routed = channeled(text);
    if routed != text.trim() {
        println!("  chat line: {routed}");
        handled();
        let _ = courier.send(Out::Now(dictation_inbox(text, &routed)));
        let _ = courier.send(Out::Line(Line::new(slot, "you", &format!("(to chat) {routed}"))));
        return true;
    }
    false
}

/// A request to the agent in conversation `slot`, as its job `job`, on the
/// request's own thread: spoken or typed, shown as waiting while one runs in
/// the same conversation, its reply sent, a failure said.
fn request(
    addons: &Path,
    slot: &str,
    text: String,
    job: u64,
    session: &Mutex<agent::Session>,
    looking: &Mutex<Option<Option<u128>>>,
    courier: &Courier,
) {
    // a slot's request is marked with it, in the window and for the agent
    // ("[L2] ..."), so both can tell the conversations apart
    let text = if slot.is_empty() { text } else { format!("[{}] {}", slot.to_uppercase(), text) };
    // only the main conversation looks; a new request there supersedes a look
    // still waiting for its reload
    if slot.is_empty() {
        *looking.lock().unwrap() = None;
    }
    // Waiting means this conversation's lock is held (a request in another runs
    // beside it). Shown at once, as queued on its own line; the first to get the
    // conversation takes every queued one (jobs::take_queued).
    let (mut held, queued) = match session.try_lock() {
        Ok(guard) => (guard, false),
        Err(std::sync::TryLockError::Poisoned(poisoned)) => (poisoned.into_inner(), false),
        Err(std::sync::TryLockError::WouldBlock) => {
            let line = Line::new(slot, "you", &text).queued().job(job, jobs::state(job).unwrap_or(jobs::State::Queued));
            let _ = courier.send(Out::Line(line));
            (session.lock().unwrap_or_else(|poisoned| poisoned.into_inner()), true)
        }
    };
    let text = if queued {
        match run_queued(addons, slot, job) {
            Some(all) => all,
            // another waiting request already took this one
            None => return,
        }
    } else {
        text
    };
    match ask(addons, &mut held, &text, queued, Some(job)) {
        Ok(true) if slot.is_empty() => *looking.lock().unwrap() = Some(session_began(addons)),
        Ok(_) => {}
        Err(err) => {
            eprintln!("  not delivered: {err}");
            tell_failure(addons, slot, &err);
        }
    }
}

/// A line the ledger has numbered already (the ones it made at the start):
/// sent live if the game runs; it is in the mailbox either way.
fn send_line_now(addons: &Path, line: Line) -> io::Result<()> {
    if game_running() {
        send(addons, &line.msg(false))?;
    }
    Ok(())
}
