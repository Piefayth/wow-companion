//! The PC half of WoW Companion. `install` lays the addon and its slots into the
//! game's AddOns folder, `send` delivers one command through a slot and a bell,
//! and `probe` sends numbered messages so we can watch the channel work.

mod agent;

use wow_companion_pad as pad;
use wow_companion_voice as voice;

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
// how often the window hears what the agent is doing, and how many times per
// request at most: every update spends one of the session's 64 slots
// Measured: progress lines were 29 of a session's 64 slots, nearly half. The
// window's seconds count already shows the agent is alive, so two will do.
const PROGRESS_EVERY: Duration = Duration::from_secs(12);
const PROGRESS_LIMIT: u32 = 2;
// at this many slots used, offer the Reload button once, while slots remain
// Margins below the slots the game knows (see known_slots): offer Reload at 16
// left, stop progress lines at 14 left, and from 8 left every reply says so.
const SLOTS_OFFER_RELOAD: u32 = 16;
const PROGRESS_STOP: u32 = 14;
const SLOTS_LOW: u32 = 8;
// the UI session in which the Reload button was last offered for low slots
static RELOAD_OFFERED: Mutex<String> = Mutex::new(String::new());
// requests to the agent running right now; a restart waits for zero
static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

/// Counts a request out of IN_FLIGHT however its thread ends.
struct InFlight;

impl Drop for InFlight {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::SeqCst);
    }
}
// 512, not 64: a session spent all 64 (progress lines were nearly half) and every
// later reply was lost. New folders need one full game restart to be seen.
const SLOTS: u32 = 512;
const BELLS: u32 = 8;
// the addon only checks the next bell, so a rung bell stays rung for this many sends
const BELL_LINGER: u32 = 4;
const PROBE_MESSAGES: u32 = 10;
const PROBE_SPACING: Duration = Duration::from_secs(3);
const PROBE_COUNTDOWN: Duration = Duration::from_secs(8);
// long enough for the addon's 0.5 s poll to catch a bell several times over
const BELL_HEARD: Duration = Duration::from_secs(2);
// generous: the question is whether the client flushes chat to disk at all, and on
// what cadence, so give a slow flush room to show itself before calling it dead
const BRIDGE_PATIENCE: Duration = Duration::from_secs(20);

// bells must exceed the client's sound cache limit (174,762 bytes) so it rereads them every play
const BELL_SECONDS: u32 = 10;
const SAMPLE_RATE: u32 = 22_050;

// every slot is identical; Slot.xml pulls in Inbox.lua so addon managers see one fixed fingerprint
const SLOT_TOC: &str = "## Interface: 16001\n## Title: WoW Companion slot\n## LoadOnDemand: 1\n## Group: WowCompanion\n\nSlot.xml\n";
const SLOT_XML: &str = "<Ui xmlns=\"http://www.blizzard.com/wow/ui/\">\n\t<Script file=\"Inbox.lua\"></Script>\n</Ui>\n";

// where the helper remembers the addon's slot cursor; inert to the game, which only
// loads files a toc or xml points at
const STATE: &str = "helper-state.txt";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let result = match args.as_slice() {
        [command, addons] if command == "install" => install(Path::new(addons)),
        // ask the running companion to move onto the newest build once it is idle
        [command] if command == "restart" => request_restart(),
        [command, addons] if command == "probe" => probe(Path::new(addons)),
        [command, addons, rest @ ..] if command == "send" => send(Path::new(addons), rest),
        // the agent's answer, printed and never delivered: for trying the agent
        // without a game to send into
        [command, addons, spoken] if command == "think" => think(Path::new(addons), spoken),
        [command, addons, spoken] if command == "ask" => {
            ask(Path::new(addons), &mut agent::Session::default(), spoken, false).map(|_| ())
        }
        [command, addons, model, options @ ..] if command == "run" => {
            run(Path::new(addons), Path::new(model), options)
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
        [command] if command == "pads" => pad::list(),
        [command] if command == "buzz" => pad::buzz(),
        [command] if command == "reconnect" => voice::reconnect(),
        [command, id] if command == "pads" => pad::watch(id),
        [command] if command == "mics" => voice::microphones(),
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

fn install(addons: &Path) -> io::Result<()> {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("addon").join(ADDON);
    let addon = addons.join(ADDON);
    copy_dir(&source, &addon)?;
    // the suite's other addons (WowCompanion_Wheel...), placed as they are
    for entry in fs::read_dir(source.parent().unwrap())? {
        let entry = entry?;
        let name = entry.file_name();
        if entry.file_type()?.is_dir() && name != ADDON {
            copy_dir(&entry.path(), &addons.join(&name))?;
            println!("installed {}", name.to_string_lossy());
        }
    }
    let signals = addon.join("Signals");
    fs::create_dir_all(&signals)?;
    for bell in 1..=BELLS {
        fs::write(signals.join(format!("{bell}.wav")), [])?;
    }
    fs::write(signals.join("always.wav"), silent_wav())?;
    fs::write(signals.join("never.wav"), [])?;
    // the window's own bell (see ring_show_bell); silent until a tap rings it
    fs::write(signals.join("show.wav"), [])?;
    for slot in 1..=SLOTS {
        let dir = addons.join(slot_name(slot));
        fs::create_dir_all(&dir)?;
        fs::write(dir.join(format!("{}.toc", slot_name(slot))), SLOT_TOC)?;
        fs::write(dir.join("Slot.xml"), SLOT_XML)?;
        // the client only knows files that exist at launch
        fs::write(dir.join("Inbox.lua"), "")?;
    }
    println!("installed {ADDON} and {SLOTS} slots into {}", addons.display());
    println!("fully restart the game so it sees the new folders");
    Ok(())
}

fn probe(addons: &Path) -> io::Result<()> {
    let signals = addons.join(ADDON).join("Signals");
    // a closed client swallows a whole run in silence, which looks identical to a broken channel
    if !game_running()? {
        return Err(io::Error::other(
            "Wow.exe isn't running: log in first, or the probe writes into a dead client",
        ));
    }
    println!("log in to a character, game sound on and the window focused, then press Enter");
    if io::stdin().read_line(&mut String::new())? == 0 {
        // no console attached, so nobody can press Enter: leave time to focus the game
        println!("no stdin, starting in {:?}", PROBE_COUNTDOWN);
        thread::sleep(PROBE_COUNTDOWN);
    }
    // take slots from the shared cursor, so a second run works without a /reload
    // instead of rewriting slots the addon has already loaded and cached
    let mut used = Vec::new();
    for n in 1..=PROBE_MESSAGES {
        let sent = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let slot = next_slot(addons)?;
        deliver(addons, slot, &format!("{{ kind = \"probe\", n = {n}, sent = {sent} }}"))?;
        used.push(slot);
        println!("sent message {n} in slot {slot}");
        thread::sleep(PROBE_SPACING);
    }
    // the bells still ringing are the last few; earlier ones were silenced as we went
    for slot in used.iter().rev().take(BELL_LINGER as usize) {
        write_reporting(&signals.join(bell_name(*slot)), &[])?;
    }
    if !game_running()? {
        println!("warning: the game closed partway through, so the run is incomplete");
    }
    println!("done: the game should have printed messages 1 to {PROBE_MESSAGES}");
    Ok(())
}

#[cfg(windows)]
fn game_running() -> io::Result<bool> {
    let listed = std::process::Command::new("tasklist")
        .args(["/FI", "IMAGENAME eq Wow.exe", "/NH"])
        .output()?;
    Ok(String::from_utf8_lossy(&listed.stdout).contains("Wow.exe"))
}

#[cfg(not(windows))]
fn game_running() -> io::Result<bool> {
    Ok(true)
}

fn send(addons: &Path, args: &[String]) -> io::Result<()> {
    let inbox = match args {
        [kind, text] if kind == "chat" => chat_inbox(text),
        [kind, name, body] if kind == "macro" => format!(
            "{{ kind = \"macro\", name = {}, body = {} }}",
            lua_string(name),
            lua_string(body)
        ),
        [kind, text] if kind == "log" => {
            format!("{{ kind = \"log\", text = {} }}", lua_string(text))
        }
        [kind, who, text] if kind == "log" => format!(
            "{{ kind = \"log\", who = {}, text = {} }}",
            lua_string(who),
            lua_string(text)
        ),
        [kind] if kind == "reload" => "{ kind = \"reload\" }".to_string(),
        // offer a secure button: the player presses it, so anything macro text can do
        [kind, label, text] if kind == "press" => format!(
            "{{ kind = \"press\", label = {}, macro = {} }}",
            lua_string(label),
            lua_string(text)
        ),
        [kind, code] if kind == "lua" => format!("{{ kind = \"lua\", code = {} }}", lua_string(code)),
        // spell|macro|item|empty, as the agent would send it
        [kind, slot, what, name] if kind == "bar" => format!(
            "{{ kind = \"bar\", slot = {}, what = {}, name = {} }}",
            slot.parse::<u32>().map_err(|_| io::Error::other("slot must be a number"))?,
            lua_string(what),
            lua_string(name)
        ),
        // the PlaceAction taint test, delivered the way real bar edits would be
        [kind, variant] if kind == "place" => {
            format!("{{ kind = \"place\", variant = {} }}", lua_string(variant))
        }
        _ => {
            return Err(io::Error::other(
                "usage: send chat <text> | send macro <name> <body> | send reload | send bar <slot> <spell|macro|item|empty> <name> | send place <variant>",
            ));
        }
    };
    send_inbox(addons, &inbox)
}

/// Hand what was said to Claude, show its line in the companion window, and
/// deliver whatever command it chose. The line goes first, so the player sees the
/// reasoning before the game changes under them.
/// The other half of looking. The agent ran something and asked to see what it
/// did; the only way results reach disk is a reload, which the player was offered
/// as a button. When the save lands, hand the agent the refreshed context and let
/// it carry on, so one press is all the player does.
fn watch_for_looks(addons: &Path, session: &Mutex<agent::Session>, looking: &Mutex<Option<Option<u128>>>) {
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

/// Returns whether the agent wants to look at the results before it is done.
fn ask(addons: &Path, session: &mut agent::Session, spoken: &str, shown: bool) -> io::Result<bool> {
    println!("asking: {spoken}");
    // start the agent before announcing ourselves: the announcement costs a bell
    // wait, the agent costs several seconds, and they may as well run together
    let waiting = session.start(spoken, agent_context(addons))?;
    // a queued request already showed its words; now it only starts thinking
    if shown {
        send_inbox(addons, "{ kind = \"progress\", text = \"thinking\" }")?;
    } else {
        send_inbox(addons, &log_inbox("you", spoken, Some("thinking"), None))?;
    }
    let answer = {
        // Progress goes to the spinner, newest only, at most every few seconds: each
        // update costs a slot, and there are 64 per UI session. Its own thread, so
        // the agent never waits on the game.
        let (tell, heard) = std::sync::mpsc::channel::<String>();
        let courier = {
            let addons = addons.to_path_buf();
            thread::spawn(move || {
                let mut sent = 0;
                while let Ok(mut latest) = heard.recv() {
                    thread::sleep(PROGRESS_EVERY);
                    while let Ok(newer) = heard.try_recv() {
                        latest = newer;
                    }
                    if sent < PROGRESS_LIMIT {
                        let inbox = format!("{{ kind = \"progress\", text = {} }}", lua_string(&latest));
                        if send_inbox(&addons, &inbox).is_ok() {
                            sent += 1;
                        }
                    }
                }
            })
        };
        let answer = session.finish(waiting, |doing| {
            println!("  ... {doing}");
            let _ = tell.send(doing.to_string());
        });
        drop(tell);
        let _ = courier.join();
        answer?
    };
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
    send_inbox(addons, &log_inbox("claude", &say, None, answer.inbox.as_deref()))?;
    if answer.look {
        println!("  waiting for the reload to look at the results");
    }
    Ok(answer.look)
}

fn think(addons: &Path, spoken: &str) -> io::Result<()> {
    let mut session = agent::Session::default();
    let started = Instant::now();
    let waiting = session.start(spoken, agent_context(addons))?;
    let answer = session.finish(waiting, |doing| println!("  ... {doing}"))?;
    println!("({:.1}s) say: {}", started.elapsed().as_secs_f32(), answer.say);
    println!("would send: {}", answer.inbox.as_deref().unwrap_or("nothing"));
    Ok(())
}

/// Lift the API dump out of SavedVariables into a plain text file.
///
/// This build ships no API documentation tables, so there are no signatures to be
/// had locally — but the names are exact for 1.60.1, which is the half the agent
/// cannot get from training data. Knowing a function exists *here* is the question
/// it otherwise answers from retail and gets wrong.
fn pull(addons: &Path, key: &str, out: &Path) -> io::Result<()> {
    let body = saved_string(addons, key)?;
    let kept = body.lines().filter(|line| !line.starts_with("--")).count();
    fs::write(out, &body)?;
    println!("wrote {kept} lines ({} bytes) to {}", body.len(), out.display());
    Ok(())
}

/// One string-valued key out of SavedVariables, unescaped.
/// How many slots the running game knows. The game only sees addon folders that
/// existed when it launched, so slots installed since are invisible to it until a
/// full restart, and a message sent to one would be lost. The addon records the
/// count it sees in SavedVariables; until it has, assume the old 64.
fn known_slots(addons: &Path) -> u32 {
    let counted = saved_variables(addons)
        .and_then(|saved| fs::read_to_string(saved).ok())
        .and_then(|text| {
            let at = text.find("[\"slotCount\"] = ")? + "[\"slotCount\"] = ".len();
            text[at..].split(|c: char| !c.is_ascii_digit()).next()?.parse::<u32>().ok()
        });
    counted.unwrap_or(64).min(SLOTS)
}

fn saved_string(addons: &Path, key: &str) -> io::Result<String> {
    let saved = saved_variables(addons)
        .ok_or_else(|| io::Error::other("no SavedVariables yet: /reload in game first"))?;
    let text = fs::read_to_string(&saved)?;
    // the dump is one long Lua string, so find its opening quote and read to the
    // first unescaped closing one rather than trying to parse Lua
    let marker = format!("[\"{key}\"] = \"");
    let start = text
        .find(&marker)
        .map(|at| at + marker.len())
        .ok_or_else(|| io::Error::other(format!("no {key} in SavedVariables: dump it, then /reload")))?;
    let mut body = String::new();
    let mut escaped = false;
    for character in text[start..].chars() {
        match (escaped, character) {
            (true, 'n') => {
                body.push('\n');
                escaped = false;
            }
            (true, other) => {
                body.push(other);
                escaped = false;
            }
            (false, '\\') => escaped = true,
            (false, '"') => break,
            (false, other) => body.push(other),
        }
    }
    Ok(body)
}

/// The sections of the exported context the agent reasons with.
///
/// The export also carries every action-bound frame and every key binding, which is
/// 500 lines answering questions we asked while mapping the UI, not ones the agent
/// asks. Those stay in the file for us and out of the prompt.
const AGENT_SECTIONS: &[&str] =
    &["character", "action slots", "empty slots on screen", "controller", "macros", "spellbook", "reach", "modules", "code runs", "lua errors"];

fn sections<'a>(context: &'a str, wanted: &[&str]) -> Vec<(&'a str, Vec<&'a str>)> {
    let mut kept: Vec<(&str, Vec<&str>)> = Vec::new();
    let mut current: Option<&str> = None;
    for line in context.lines() {
        if let Some(name) = line.strip_prefix("== ").and_then(|rest| rest.strip_suffix(" ==")) {
            current = wanted.contains(&name).then_some(name);
            if let Some(name) = current {
                kept.push((name, Vec::new()));
            }
        } else if current.is_some() && !line.trim().is_empty() {
            if let Some((_, lines)) = kept.last_mut() {
                lines.push(line);
            }
        }
    }
    kept
}

fn agent_context(addons: &Path) -> Option<String> {
    let context = saved_string(addons, "context").ok()?;
    let stamp = context.lines().next().unwrap_or_default();
    let mut out = vec![stamp.to_string()];
    for (name, lines) in sections(&context, AGENT_SECTIONS) {
        out.push(format!("== {name} =="));
        out.extend(lines.iter().map(|line| line.to_string()));
    }
    Some(out.join("
"))
}

/// Spell and macro names, for Whisper's prompt: the words this player will say and
/// a general model will misspell. Unique, in spellbook order.
fn vocabulary(addons: &Path) -> Vec<String> {
    let Ok(context) = saved_string(addons, "context") else {
        return Vec::new();
    };
    let mut words: Vec<String> = Vec::new();
    for (name, lines) in sections(&context, &["spellbook", "macros"]) {
        for line in lines {
            if line.starts_with("--") || line.starts_with("    ") {
                continue;
            }
            // spellbook: "1 Healing Touch (5185)"; macros: "1: Ping"
            let word = match name {
                "spellbook" => line
                    .split_once(' ')
                    .map(|(_, rest)| rest.rsplit_once(" (").map_or(rest, |(word, _)| word)),
                _ => line.split_once(": ").map(|(_, word)| word),
            };
            if let Some(word) = word.map(str::trim).filter(|word| !word.is_empty()) {
                if !words.iter().any(|seen| seen == word) {
                    words.push(word.to_string());
                }
            }
        }
    }
    words
}

fn saved_variables(addons: &Path) -> Option<PathBuf> {
    let accounts = addons.parent()?.parent()?.join("WTF").join("Account");
    let mut newest: Option<(u128, PathBuf)> = None;
    for account in fs::read_dir(accounts).ok()?.flatten() {
        let saved = account.path().join("SavedVariables").join(format!("{ADDON}.lua"));
        if let Some(at) = modified_millis(&saved) {
            if newest.as_ref().is_none_or(|(best, _)| at > *best) {
                newest = Some((at, saved));
            }
        }
    }
    newest.map(|(_, path)| path)
}

/// Round-trip probe: PC to game through the slot channel, game back to PC through
/// the client's own chat log. If this works there is a bidirectional bridge that
/// does not involve reading pixels off the screen.
fn bridge(addons: &Path) -> io::Result<()> {
    let root = addons
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| io::Error::other("cannot find the client folder above AddOns"))?;
    let chat_log = root.join("Logs").join("WoWChatLog.txt");
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis();
    // only read what arrives after we ask, so an old marker cannot be mistaken for a new one
    let already = fs::metadata(&chat_log).map(|meta| meta.len()).unwrap_or(0);
    println!("chat log: {} ({already} bytes so far)", chat_log.display());

    let sent = Instant::now();
    send_inbox(addons, &format!("{{ kind = \"bridge\", nonce = {nonce} }}"))?;
    println!("waiting for {nonce} to reach the log");

    let nonce = nonce.to_string();
    while sent.elapsed() < BRIDGE_PATIENCE {
        if let Ok(tail) = fs::read(&chat_log) {
            if tail.len() as u64 > already {
                let fresh = String::from_utf8_lossy(&tail[already as usize..]);
                if let Some(line) = fresh.lines().find(|line| line.contains(&nonce)) {
                    println!(
                        "round trip in {:.1}s via: {}",
                        sent.elapsed().as_secs_f32(),
                        line.trim()
                    );
                    return Ok(());
                }
            }
        }
        thread::sleep(Duration::from_millis(200));
    }
    Err(io::Error::other(format!(
        "nothing carrying {nonce} reached {} within {BRIDGE_PATIENCE:?}; the log may only \
         keep server chat events, or may not flush until logout",
        chat_log.display()
    )))
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
        env!("CARGO_MANIFEST_DIR"),
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
    voice::listen(
        model,
        options,
        || vocabulary(addons),
        |role, text| match role {
            // a tap of the ask button, too short to be speech: show the window
            // a tap rings the window's own bell: no slot spent (taps were 12 of 64)
            "ask tap" => ring_show_bell(addons),
            // the voice loop's own news (a reconnected headset), for the window
            "notice" => deliver(log_inbox("error", text, None, None)),
            _ if role.ends_with(" tap") => Ok(()),
            "ask" => {
                // a new request supersedes a look still waiting for its reload
                *looking.lock().unwrap() = None;
                // A request made while another runs is shown at once, as waiting:
                // otherwise it appears only when it starts, and reads as dropped.
                let queued = IN_FLIGHT.load(Ordering::SeqCst) > 0;
                if queued {
                    let line = log_inbox("you", text, Some("waiting for the request before this one"), None);
                    deliver(line)?;
                }
                // Off the voice loop: real work takes minutes, and the pad must stay
                // read meanwhile. A second request waits on the session lock, so
                // the conversation still runs one request at a time.
                let (addons, session, looking, text) =
                    (addons.to_path_buf(), Arc::clone(&session), Arc::clone(&looking), text.to_string());
                IN_FLIGHT.fetch_add(1, Ordering::SeqCst);
                thread::spawn(move || {
                    let _done = InFlight;
                    match ask(&addons, &mut session.lock().unwrap(), &text, queued) {
                        Ok(true) => *looking.lock().unwrap() = Some(session_began(&addons)),
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

/// Built field by field rather than by patching a finished string: the first attempt
/// spliced `andThen` onto the end and dropped the comma, which the client reported as
/// a Lua syntax error from inside a slot.
fn log_inbox(who: &str, text: &str, pending: Option<&str>, also: Option<&str>) -> String {
    let mut fields = vec![
        "kind = \"log\"".to_string(),
        format!("who = {}", lua_string(who)),
        format!("text = {}", lua_string(text)),
    ];
    if let Some(label) = pending {
        fields.push(format!("pending = {}", lua_string(label)));
    }
    if let Some(inbox) = also {
        fields.push(format!("andThen = {inbox}"));
    }
    format!("{{ {} }}", fields.join(", "))
}

// Spoken channel names, and the slash command each stands for. Whisper will never
// write "/p", and a controller cannot type it, so a clip that opens with "party"
// (or "to party", or "slash p") becomes "/p ..." -- which the chat box routes when
// the player presses send, exactly as if they had typed it. Whispering a player is
// not here: names are first and last on this client and the spoken boundary of a
// name is a guess (ask the agent instead).
const CHANNELS: &[(&str, &str)] = &[
    ("party", "/p"),
    ("group", "/p"),
    ("guild", "/g"),
    ("officer", "/o"),
    ("raid", "/raid"),
    ("raid warning", "/rw"),
    ("instance", "/i"),
    ("say", "/s"),
    ("yell", "/y"),
    ("reply", "/r"),
    ("emote", "/e"),
];

/// The whole clip is a request to throw the line away. Whole clip only: "cancel
/// the pull" is a message.
fn discards(text: &str) -> bool {
    let plain: String = text
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    matches!(
        plain.trim(),
        "clear" | "clear chat" | "clear that" | "cancel" | "cancel that" | "never mind"
            | "nevermind" | "scratch that" | "delete that" | "erase that"
    )
}

/// "Party, on my way." -> "/p on my way." Only the opening words count, so a
/// sentence that merely mentions the guild goes out unchanged.
fn channeled(text: &str) -> String {
    let trimmed = text.trim();
    let lowered = trimmed.to_lowercase();
    let mut rest_at = 0;
    let mut spoken = lowered.as_str();
    for lead in ["to ", "in ", "on "] {
        if let Some(after) = spoken.strip_prefix(lead) {
            rest_at += lead.len();
            spoken = after;
            break;
        }
    }
    // "slash p hello" -> "/p hello"; Whisper spells the shortcut out when it is said
    let mut found: Option<(String, usize)> = None;
    if let Some(after) = spoken.strip_prefix("slash ") {
        let word: String = after.chars().take_while(|c| c.is_alphanumeric()).collect();
        if !word.is_empty() && word.len() <= 5 {
            found = Some((format!("/{word}"), "slash ".len() + word.len()));
        }
    }
    if found.is_none() {
        // longest first, so "raid warning" is not read as "raid"
        let mut channels: Vec<&(&str, &str)> = CHANNELS.iter().collect();
        channels.sort_by_key(|(word, _)| std::cmp::Reverse(word.len()));
        for (word, slash) in channels {
            if let Some(after) = spoken.strip_prefix(word) {
                // the word must end there: "partying" is not "party"
                if after.is_empty() || after.starts_with(|c: char| !c.is_alphanumeric()) {
                    found = Some((slash.to_string(), word.len()));
                    break;
                }
            }
        }
    }
    let Some((slash, used)) = found else {
        return trimmed.to_string();
    };
    let message = trimmed[rest_at + used..]
        .trim_start_matches(|c: char| c == ',' || c == ':' || c == '.' || c == '-' || c.is_whitespace());
    if message.is_empty() {
        // "party." alone is more likely a word than a command with nothing to say
        return trimmed.to_string();
    }
    format!("{slash} {message}")
}

/// A request that failed says so in the window, and stops the spinner: a console
/// line nobody is watching is how a stuck-looking agent happens.
fn tell_failure(addons: &Path, err: &io::Error) {
    let line = format!("That request failed: {err}");
    if let Err(also) = send_inbox(addons, &log_inbox("error", &line, None, None)) {
        eprintln!("  and telling the game failed too: {also}");
    }
}

/// Dictation: `text` as chat should get it (a channel turned into its slash
/// command), `raw` as it was said, for any other text box the player is in.
fn dictation_inbox(raw: &str, routed: &str) -> String {
    format!(
        "{{ kind = \"chat\", text = {}, raw = {} }}",
        lua_string(routed),
        lua_string(raw.trim())
    )
}

fn chat_inbox(text: &str) -> String {
    format!("{{ kind = \"chat\", text = {} }}", lua_string(text))
}

// One send at a time: each one silences every bell before ringing its own and
// takes the next slot, so progress updates and replies from different threads
// would otherwise step on each other.
static SENDING: Mutex<()> = Mutex::new(());

fn send_inbox(addons: &Path, inbox: &str) -> io::Result<()> {
    let sent = send_inbox_once(addons, inbox);
    if let Err(err) = &sent {
        if err.to_string().contains("slots are spent") {
            // nothing can reach the game to say so; the pad can
            voice::ALERT.store(true, Ordering::SeqCst);
        }
    }
    sent
}

/// The window's own bell, checked on every poll beside the slot bells: ringing it
/// opens the window, and spends no slot.
fn ring_show_bell(addons: &Path) -> io::Result<()> {
    // The game opens this bell every half second, so it is locked more often than
    // a slot's; a 2 s retry gave up (measured). Rung off the voice loop and kept at
    // for up to 10 s: a tap is not urgent, but it should not be lost.
    let bell = addons.join(ADDON).join("Signals").join("show.wav");
    thread::spawn(move || {
        let start = Instant::now();
        while fs::write(&bell, silent_wav()).is_err() {
            if start.elapsed() > Duration::from_secs(10) {
                eprintln!("  could not ring the window bell: it stayed locked");
                return;
            }
            thread::sleep(Duration::from_millis(30));
        }
        thread::sleep(BELL_HEARD);
        let start = Instant::now();
        while fs::write(&bell, []).is_err() && start.elapsed() < Duration::from_secs(10) {
            thread::sleep(Duration::from_millis(30));
        }
    });
    Ok(())
}

fn send_inbox_once(addons: &Path, inbox: &str) -> io::Result<()> {
    let _one_at_a_time = SENDING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if !game_running()? {
        return Err(io::Error::other("Wow.exe isn't running, so nothing would read this"));
    }
    // A reply or a progress line is read by handlers every version of the addon
    // has, so a stale UI can still take it. Blocking those is how a finished answer
    // sat undelivered behind "reload first" while the window spun "thinking".
    // A reload is the same: every version has it, and it is the cure for staleness.
    if inbox.starts_with("{ kind = \"progress\"") && slots_used(addons) + PROGRESS_STOP >= known_slots(addons) {
        // the last slots are for replies; a skipped progress line is no loss
        return Ok(());
    }
    let always_readable = ["log", "progress", "reload"]
        .iter()
        .any(|kind| inbox.starts_with(&format!("{{ kind = \"{kind}\"")));
    if !always_readable && addon_is_stale(addons)? {
        return Err(io::Error::other(
            "the addon on disk is newer than the running UI session: /reload in game first",
        ));
    }
    let slot = next_slot(addons)?;
    // A bell left ringing is a command that fires again on every /reload: the addon's
    // cursor goes back to slot 1, hears the old bell, and redelivers. So ring it only
    // long enough to be heard, then silence it. The addon polls every 0.5 s.
    let signals = addons.join(ADDON).join("Signals");
    for bell in 1..=BELLS {
        write_reporting(&signals.join(bell_name(bell)), &[])?;
    }
    deliver(addons, slot, inbox)?;
    println!("sent in slot {slot}: {inbox}");
    thread::sleep(BELL_HEARD);
    write_reporting(&signals.join(bell_name(slot)), &[])?;
    Ok(())
}

fn deliver(addons: &Path, slot: u32, inbox: &str) -> io::Result<()> {
    let signals = addons.join(ADDON).join("Signals");
    let lua = format!("WowCompanion_Inbox = {inbox}\n");
    // the inbox lands first: the bell is what tells the addon to go read it
    write_reporting(&addons.join(slot_name(slot)).join("Inbox.lua"), lua.as_bytes())?;
    write_reporting(&signals.join(bell_name(slot)), &silent_wav())?;
    // a bell is reused every BELLS sends, so silence it well before then or the
    // addon hears a stale ring and reads a slot we haven't written yet
    if slot > BELL_LINGER {
        write_reporting(&signals.join(bell_name(slot - BELL_LINGER)), &[])?;
    }
    Ok(())
}

// Slots load once per UI session, so the helper has to know where the addon's cursor
// is. It resets when the UI session does, and the game rewrites SavedVariables at
// exactly that moment, so that file's timestamp is the reset signal. No game → PC
// channel needed.
fn next_slot(addons: &Path) -> io::Result<u32> {
    let state = addons.join(ADDON).join(STATE);
    let stamp = saved_variables_stamp(addons).unwrap_or_default();
    let (mut cursor, seen) = fs::read_to_string(&state)
        .ok()
        .and_then(|text| {
            let mut lines = text.lines();
            let cursor = lines.next()?.trim().parse().ok()?;
            Some((cursor, lines.next().unwrap_or_default().trim().to_string()))
        })
        .unwrap_or((1, String::new()));
    if stamp != seen {
        cursor = 1;
    }
    if cursor > known_slots(addons) {
        return Err(io::Error::other(format!(
            "all {SLOTS} slots are spent this UI session: `send reload`, or /reload in game"
        )));
    }
    fs::write(&state, format!("{}\n{}\n", cursor + 1, stamp))?;
    Ok(cursor)
}

/// Slots spent in the running UI session (0 after a reload), without spending one.
fn slots_used(addons: &Path) -> u32 {
    let state = addons.join(ADDON).join(STATE);
    let stamp = saved_variables_stamp(addons).unwrap_or_default();
    let Ok(text) = fs::read_to_string(&state) else { return 0 };
    let mut lines = text.lines();
    let cursor: u32 = lines.next().and_then(|line| line.trim().parse().ok()).unwrap_or(1);
    if lines.next().unwrap_or_default().trim() != stamp {
        return 0;
    }
    cursor.saturating_sub(1)
}

// --- restarts that never cut a request off
//
// Windows will not let a running .exe be replaced, so `cargo build` failed while
// the companion ran, and the only way onto a new build was to kill it, losing any
// reply in flight. So `run` executes from a copy in %LOCALAPPDATA%, leaving the
// real one free to rebuild; `restart` leaves a request, and the running copy acts
// on it only when no request is in flight and no button is held: it starts the
// newest build (which copies itself in turn) and exits.

fn companion_dir() -> io::Result<PathBuf> {
    let base = env::var_os("LOCALAPPDATA").ok_or_else(|| io::Error::other("no LOCALAPPDATA"))?;
    let dir = PathBuf::from(base).join("wow-companion");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn restart_request() -> io::Result<PathBuf> {
    Ok(companion_dir()?.join("restart.request"))
}

fn request_restart() -> io::Result<()> {
    fs::write(restart_request()?, "")?;
    println!("asked the companion to restart onto the newest build once it is idle");
    Ok(())
}

// set on the copy, naming the build it came from
const SOURCE_EXE: &str = "WOW_COMPANION_SOURCE_EXE";

/// Started from the build itself: copy it aside, run the copy, and step away.
/// Returns Some when this process handed over and should exit.
fn run_from_copy() -> io::Result<Option<io::Result<()>>> {
    if env::var_os(SOURCE_EXE).is_some() {
        // a copy: the generations before it are done (each is 180 MB in debug);
        // a predecessor still exiting is locked and goes next time
        let me = env::current_exe().ok();
        if let Ok(entries) = fs::read_dir(companion_dir()?.join("bin")) {
            for entry in entries.flatten() {
                if Some(entry.path()) != me {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        return Ok(None);
    }
    let source = env::current_exe()?;
    let bin = companion_dir()?.join("bin");
    fs::create_dir_all(&bin)?;
    // earlier copies: whichever are not running can go
    if let Ok(entries) = fs::read_dir(&bin) {
        for entry in entries.flatten() {
            let _ = fs::remove_file(entry.path());
        }
    }
    let copy = bin.join(format!("companion-{}.exe", std::process::id()));
    fs::copy(&source, &copy)?;
    // Not waited on: a launcher that waited would itself be the running build,
    // holding the lock this exists to free. The copy inherits the console, so its
    // output still lands where the companion was started.
    std::process::Command::new(&copy)
        .args(env::args_os().skip(1))
        .env(SOURCE_EXE, &source)
        .spawn()?;
    println!("running as {} (the build itself stays free to rebuild)", copy.display());
    Ok(Some(Ok(())))
}

fn watch_for_restart(args: Vec<String>) {
    let (Ok(request), Some(source)) = (restart_request(), env::var_os(SOURCE_EXE)) else { return };
    loop {
        thread::sleep(Duration::from_secs(1));
        if !request.exists() || IN_FLIGHT.load(Ordering::SeqCst) > 0 || voice::HOLDING.load(Ordering::Relaxed) {
            continue;
        }
        // copy the new build now; if it is mid-build the copy fails, so try again
        let bin = match companion_dir() {
            Ok(dir) => dir.join("bin"),
            Err(_) => continue,
        };
        let next = bin.join(format!("companion-next-{}.exe", std::process::id()));
        if fs::copy(&source, &next).is_err() {
            continue;
        }
        let _ = fs::remove_file(&request);
        println!("restarting onto the new build");
        // close the mic properly first: the next copy must not open it while this
        // one holds it, and an abandoned hands-free stream can wedge the link
        voice::SHUTDOWN.store(true, Ordering::SeqCst);
        let asked = Instant::now();
        while !voice::STOPPED.load(Ordering::SeqCst) && asked.elapsed() < Duration::from_secs(3) {
            thread::sleep(Duration::from_millis(20));
        }
        // the next generation runs as a copy already, and owns the console from here
        match std::process::Command::new(&next).args(&args).env(SOURCE_EXE, &source).spawn() {
            Ok(_) => std::process::exit(0),
            Err(err) => eprintln!("  restart failed, still running the old build: {err}"),
        }
    }
}

fn saved_variables_stamp(addons: &Path) -> Option<String> {
    session_began(addons).map(|millis| millis.to_string())
}

/// When the running UI session started, near enough: a `/reload` writes SavedVariables
/// and *then* reloads, so that write marks the boundary between sessions.
fn session_began(addons: &Path) -> Option<u128> {
    // <client>/Interface/AddOns -> <client>/WTF/Account/<account>/SavedVariables
    let accounts = addons.parent()?.parent()?.join("WTF").join("Account");
    let mut newest = None;
    for account in fs::read_dir(accounts).ok()?.flatten() {
        let saved = account.path().join("SavedVariables").join(format!("{ADDON}.lua"));
        if let Some(millis) = modified_millis(&saved) {
            newest = Some(newest.map_or(millis, |best: u128| best.max(millis)));
        }
    }
    newest
}

/// Is the game running code we have already replaced?
///
/// A version number in SavedVariables cannot answer this: the game saves before it
/// reloads, so the recorded version always describes the *previous* session. The
/// timestamps can, because that same ordering makes the save mark where the current
/// session began. Addon newer than that means the session predates it.
///
/// Worth the check: twice this cost us a stuck chat box and a half-dead controller,
/// because a retired handler was still live and still opening the chat box.
fn addon_is_stale(addons: &Path) -> io::Result<bool> {
    let addon = modified_millis(&addons.join(ADDON).join("Companion.lua"));
    Ok(match (addon, session_began(addons)) {
        (Some(addon), Some(began)) => addon > began,
        // never saved, or no addon: nothing to compare, so do not block
        _ => false,
    })
}

fn modified_millis(path: &Path) -> Option<u128> {
    fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|since| since.as_millis())
}

// an agent will be writing these eventually, so quote defensively rather than trusting
// the text to be free of quotes, backslashes and newlines
fn lua_string(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\0' => quoted.push_str("\\0"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

// the game may hold a bell open while it plays, which Windows can refuse to overwrite;
// retry so we learn how long that lasts instead of failing
fn write_reporting(path: &Path, contents: &[u8]) -> io::Result<()> {
    let start = Instant::now();
    let mut attempts = 0;
    loop {
        attempts += 1;
        match fs::write(path, contents) {
            Ok(()) => {
                if attempts > 1 {
                    println!(
                        "  {} was locked; wrote it after {attempts} tries ({:?})",
                        path.display(),
                        start.elapsed()
                    );
                }
                return Ok(());
            }
            Err(err) if start.elapsed() < Duration::from_secs(2) => {
                if attempts == 1 {
                    println!("  {} write failed ({err}), retrying", path.display());
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(err) => return Err(err),
        }
    }
}

fn slot_name(slot: u32) -> String {
    format!("{ADDON}_S{slot:03}")
}

fn bell_name(n: u32) -> String {
    format!("{}.wav", (n - 1) % BELLS + 1)
}

// 16-bit mono PCM of pure silence
fn silent_wav() -> Vec<u8> {
    let data_len = BELL_SECONDS * SAMPLE_RATE * 2;
    let mut wav = Vec::with_capacity(44 + data_len as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.resize(44 + data_len as usize, 0);
    wav
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
