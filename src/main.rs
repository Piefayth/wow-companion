//! The PC half of WoW Companion. `install` lays the addon and its slots into the
//! game's AddOns folder, `send` delivers one command through a slot and a bell,
//! and `probe` sends numbered messages so we can watch the channel work.

mod pad;
#[cfg(feature = "voice")]
mod voice;

use std::{
    env, fs, io,
    path::{Path, PathBuf},
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
        [command, addons] if command == "probe" => probe(Path::new(addons)),
        [command, addons, rest @ ..] if command == "send" => send(Path::new(addons), rest),
        [command] if command == "pads" => pad::list(),
        [command, id] if command == "pads" => pad::watch(id),
        #[cfg(feature = "voice")]
        [command] if command == "mics" => voice::microphones(),
        #[cfg(feature = "voice")]
        [command, model, options @ ..] if command == "voice" => {
            voice::listen(Path::new(model), options)
        }
        [command, ..] if command == "voice" => Err(io::Error::other(
            "built without voice: cargo run --features voice -- voice <model>",
        )),
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
            eprintln!("  voice <model> [button] [mic]     hold the button and speak");
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
    if !game_running()? {
        return Err(io::Error::other("Wow.exe isn't running, so nothing would read this"));
    }
    let inbox = match args {
        [kind, text] if kind == "chat" => {
            format!("{{ kind = \"chat\", text = {} }}", lua_string(text))
        }
        [kind, name, body] if kind == "macro" => format!(
            "{{ kind = \"macro\", name = {}, body = {} }}",
            lua_string(name),
            lua_string(body)
        ),
        [kind] if kind == "reload" => "{ kind = \"reload\" }".to_string(),
        _ => {
            return Err(io::Error::other(
                "usage: send chat <text> | send macro <name> <body> | send reload",
            ));
        }
    };
    let slot = next_slot(addons)?;
    deliver(addons, slot, &inbox)?;
    println!("sent in slot {slot}: {inbox}");
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
    // <client>/Interface/AddOns -> <client>/WTF/Account/<account>/SavedVariables
    let accounts = addons.parent()?.parent()?.join("WTF").join("Account");
    let mut newest = None;
    for account in fs::read_dir(accounts).ok()?.flatten() {
        let saved = account.path().join("SavedVariables").join(format!("{ADDON}.lua"));
        let written = fs::metadata(&saved)
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|at| at.duration_since(UNIX_EPOCH).ok());
        if let Some(written) = written {
            let millis = written.as_millis();
            newest = Some(newest.map_or(millis, |best: u128| best.max(millis)));
        }
    }
    newest.map(|millis| millis.to_string())
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
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}
