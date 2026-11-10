//! The PC half of WoW Companion. `install` lays the addon and its slots into the
//! game's AddOns folder, `send` delivers one command through a slot and a bell,
//! and `probe` sends numbered messages so we can watch the channel work.

mod addons;
mod agent;

use wow_companion_pad as pad;
use wow_companion_voice as voice;

use std::{
    env, fs, io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const ADDON: &str = "WowCompanion";
const SLOTS: u32 = 64;
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
        // other people's addons, from GitHub: install, list, remove
        [command, verb, rest @ ..] if command == "addon" => addon_command(verb, rest),
        [command, addons] if command == "probe" => probe(Path::new(addons)),
        [command, addons, rest @ ..] if command == "send" => send(Path::new(addons), rest),
        // the agent's answer, printed and never delivered: for trying the agent
        // without a game to send into
        [command, addons, spoken] if command == "think" => think(Path::new(addons), spoken),
        [command, addons, spoken] if command == "ask" => {
            ask(Path::new(addons), &mut agent::Session::default(), spoken).map(|_| ())
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
        [command, id] if command == "pads" => pad::watch(id),
        [command] if command == "mics" => voice::microphones(),
        [command] if command == "speakers" => voice::speakers(),
        [command, model, options @ ..] if command == "voice" => {
            voice::listen(Path::new(model), options, Vec::new, |_, _| Ok(()))
        }
        [command, addons, model, options @ ..] if command == "dictate" => {
            let addons = Path::new(addons);
            voice::listen(Path::new(model), options, || vocabulary(addons), |_, text| {
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
    let signals = addon.join("Signals");
    fs::create_dir_all(&signals)?;
    for bell in 1..=BELLS {
        fs::write(signals.join(format!("{bell}.wav")), [])?;
    }
    fs::write(signals.join("always.wav"), silent_wav())?;
    fs::write(signals.join("never.wav"), [])?;
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
        match ask(addons, &mut session.lock().unwrap(), note) {
            Ok(true) => *looking.lock().unwrap() = Some(session_began(addons)),
            Ok(false) => {}
            Err(err) => eprintln!("  looking again failed: {err}"),
        }
    }
}

/// Returns whether the agent wants to look at the results before it is done.
fn ask(addons: &Path, session: &mut agent::Session, spoken: &str) -> io::Result<bool> {
    println!("asking: {spoken}");
    // start the agent before announcing ourselves: the announcement costs a bell
    // wait, the agent costs several seconds, and they may as well run together
    let waiting = session.start(spoken, agent_context(addons))?;
    send_inbox(addons, &log_inbox("you", spoken, Some("thinking"), None))?;
    let answer = session.finish(waiting)?;
    println!("claude: {}", answer.say);
    // One message, not two: the reply and the action it describes arrive together,
    // so there is no second bell and no two-second gap between reading the answer
    // and being offered the button. This one carries no `pending`, which stops the
    // spinner.
    send_inbox(addons, &log_inbox("claude", &answer.say, None, answer.inbox.as_deref()))?;
    // installs and removals happen here, not in game; the player sees the outcome
    // in the window and the agent hears it with their next request
    if !answer.addons.is_empty() {
        let mut results = Vec::new();
        for (action, target) in &answer.addons {
            println!("  addon {action} {target}");
            let outcome = match action.as_str() {
                "install" => addons::install(addons, target),
                "remove" => addons::remove(addons, target),
                "list" => addons::list(),
                other => Err(io::Error::other(format!("unknown addon action {other:?}"))),
            };
            let line = match outcome {
                Ok(done) => done,
                Err(err) => format!("{action} {target} failed: {err}"),
            };
            println!("  {line}");
            results.push(line);
        }
        let all = results.join("\n");
        send_inbox(addons, &log_inbox("addons", &all, None, None))?;
        session.note = Some(all);
    }
    if answer.look {
        println!("  waiting for the reload to look at the results");
    }
    Ok(answer.look)
}

fn think(addons: &Path, spoken: &str) -> io::Result<()> {
    let mut session = agent::Session::default();
    let started = Instant::now();
    let waiting = session.start(spoken, agent_context(addons))?;
    let answer = session.finish(waiting)?;
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
    &["character", "action slots", "empty slots on screen", "controller", "macros", "spellbook", "modules", "code runs"];

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
    let mut session = agent::Session::default();
    if let Some(chosen) = options.iter().find_map(|option| option.strip_prefix("agent=")) {
        session.model = chosen.to_string();
    }
    println!(
        "agent: claude -p --model {}",
        if session.model.is_empty() { agent::DEFAULT_MODEL } else { &session.model }
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
    voice::listen(
        model,
        options,
        || vocabulary(addons),
        |role, text| match role {
            "ask" => {
                // a new request supersedes a look still waiting for its reload
                *looking.lock().unwrap() = None;
                let look = ask(addons, &mut session.lock().unwrap(), text)?;
                if look {
                    *looking.lock().unwrap() = Some(session_began(addons));
                }
                Ok(())
            }
            _ if discards(text) => {
                println!("  clearing the chat box");
                send_inbox(addons, "{ kind = \"chat\", clear = true }")
            }
            _ => {
                let routed = channeled(text);
                if routed != text {
                    println!("  as: {routed}");
                }
                send_inbox(addons, &chat_inbox(&routed))
            }
        },
    )
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

fn addon_command(verb: &str, rest: &[String]) -> io::Result<()> {
    let report = match (verb, rest) {
        ("install", [folder, repo]) => addons::install(Path::new(folder), repo)?,
        ("remove", [folder, which]) => addons::remove(Path::new(folder), which)?,
        ("list", []) => addons::list()?,
        _ => {
            return Err(io::Error::other(
                "addon install <AddOns> <owner/repo> | remove <AddOns> <name> | list",
            ))
        }
    };
    println!("{report}");
    Ok(())
}

fn chat_inbox(text: &str) -> String {
    format!("{{ kind = \"chat\", text = {} }}", lua_string(text))
}

fn send_inbox(addons: &Path, inbox: &str) -> io::Result<()> {
    if !game_running()? {
        return Err(io::Error::other("Wow.exe isn't running, so nothing would read this"));
    }
    if addon_is_stale(addons)? {
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
    if cursor > SLOTS {
        return Err(io::Error::other(format!(
            "all {SLOTS} slots are spent this UI session: `send reload`, or /reload in game"
        )));
    }
    fs::write(&state, format!("{}\n{}\n", cursor + 1, stamp))?;
    Ok(cursor)
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
