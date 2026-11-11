//! Install, and the probe and bridge tools.

use super::*;
use crate::message::Msg;

pub(crate) const PROBE_MESSAGES: u32 = 10;
pub(crate) const PROBE_SPACING: Duration = Duration::from_secs(3);
pub(crate) const PROBE_COUNTDOWN: Duration = Duration::from_secs(8);
// generous: the question is whether the client flushes chat to disk at all, and on
// what cadence, so give a slow flush room to show itself before calling it dead
pub(crate) const BRIDGE_PATIENCE: Duration = Duration::from_secs(20);

pub(crate) fn install(addons: &Path) -> io::Result<()> {
    let source = crate::home().join("addon").join(ADDON);
    // Modules.lua is built from modules/, never edited by hand
    modules::regenerate(None)?;
    let addon = addons.join(ADDON);
    copy_dir(&source, &addon)?;
    remove_stale(&source, &addon, generated(ADDON))?;
    // the ledger the setup window's uninstall works from
    let mut written = vec![addon.clone()];
    // the suite's other addons (Link, Agent, the extras), placed as they are
    for entry in fs::read_dir(source.parent().unwrap())? {
        let entry = entry?;
        let name = entry.file_name();
        if entry.file_type()?.is_dir() && name != ADDON {
            let installed = addons.join(&name);
            copy_dir(&entry.path(), &installed)?;
            remove_stale(&entry.path(), &installed, generated(&name.to_string_lossy()))?;
            written.push(installed);
            println!("installed {}", name.to_string_lossy());
        }
    }
    let signals = addons.join(LINK).join("Signals");
    fs::create_dir_all(&signals)?;
    // Install runs while the game plays (the agent installs its own changes), so it
    // only creates what is missing. Emptying every inbox and bell here wiped
    // messages the addon had not read yet: "Inbox.lua is empty", "slot 4 failed:
    // nil" (2026-11-10). Bells and inboxes belong to the sender alone.
    let missing = |path: &Path| !path.exists();
    for bell in (1..=BELLS).flat_map(|bell| [bell_name(bell), catch_up_name(bell), frame_bell_name(bell)]) {
        let path = signals.join(bell);
        if missing(&path) {
            bells::empty_message(&path)?;
        }
    }
    // the sound probe's controls: one that must play, one that must not
    if missing(&signals.join("always.wav")) {
        bells::ring_message(&signals.join("always.wav"))?;
    }
    if missing(&signals.join("never.wav")) {
        bells::empty_message(&signals.join("never.wav"))?;
    }
    for slot in 1..=SLOTS {
        let dir = addons.join(slot_name(slot));
        fs::create_dir_all(&dir)?;
        written.push(dir.clone());
        fs::write(dir.join(format!("{}.toc", slot_name(slot))), SLOT_TOC)?;
        fs::write(dir.join("Slot.xml"), SLOT_XML)?;
        // the client only knows files that exist at launch
        if missing(&dir.join("Inbox.lua")) {
            fs::write(dir.join("Inbox.lua"), "")?;
        }
    }
    // the mailbox the game takes at every load (src/ledger.rs), from the ledger
    // on disk; never the repo's (it has none: an install must not wipe lines)
    if let Err(err) = crate::ledger::write_mailbox(addons) {
        println!("warning: the mailbox could not be written: {err}");
    }
    if let Err(err) = wow_companion_settings::changes::record_folders(&written) {
        println!("warning: could not record what was installed, for uninstall: {err}");
    }
    println!("installed {ADDON} and {SLOTS} slots into {}", addons.display());
    println!("fully restart the game so it sees the new folders");
    Ok(())
}

/// What the PC writes into an installed addon folder, which the repo's copy
/// never has: kept when the folder is brought in line with the repo.
fn generated(addon: &str) -> &'static [&'static str] {
    match addon {
        LINK => &["Signals", "helper-state.txt"],
        ADDON => &["Probe"],
        "WowCompanion_Mailbox" => &["Mail.lua"],
        _ => &[],
    }
}

/// Delete what an installed addon folder holds that its repo folder does not
/// (a file moved to another addon, or deleted), except the PC's generated
/// files. A file the game holds open is reported, not hidden.
fn remove_stale(source: &Path, installed: &Path, keep: &[&str]) -> io::Result<()> {
    fn walk(source: &Path, installed: &Path, top: bool, keep: &[&str]) -> io::Result<()> {
        for entry in fs::read_dir(installed)? {
            let entry = entry?;
            let name = entry.file_name();
            if top && keep.iter().any(|kept| name == *kept) {
                continue;
            }
            let (from, at) = (source.join(&name), entry.path());
            if entry.file_type()?.is_dir() {
                if from.is_dir() {
                    walk(&from, &at, false, keep)?;
                } else if let Err(err) = fs::remove_dir_all(&at) {
                    println!("could not remove {} (the game may hold it): {err}", at.display());
                } else {
                    println!("removed {}", at.display());
                }
            } else if !from.exists() {
                match fs::remove_file(&at) {
                    Ok(()) => println!("removed {}", at.display()),
                    Err(err) => println!("could not remove {} (the game may hold it): {err}", at.display()),
                }
            }
        }
        Ok(())
    }
    walk(source, installed, true, keep)
}

pub(crate) fn probe(addons: &Path) -> io::Result<()> {
    let signals = addons.join(LINK).join("Signals");
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
        deliver(addons, slot, &Msg::new("probe").int("n", n).int("sent", sent))?;
        used.push(slot);
        println!("sent message {n} in slot {slot}");
        thread::sleep(PROBE_SPACING);
    }
    // the bells still ringing are the last few; earlier ones were silenced as we went
    for slot in used.iter().rev().take(BELL_LINGER as usize) {
        bells::empty_message(&signals.join(bell_name(*slot)))?;
    }
    if !game_running()? {
        println!("warning: the game closed partway through, so the run is incomplete");
    }
    println!("done: the game should have printed messages 1 to {PROBE_MESSAGES}");
    Ok(())
}

pub(crate) fn send_command(addons: &Path, args: &[String]) -> io::Result<()> {
    // conversation lines go through the running companion (`tell`): only it
    // numbers them (src/ledger.rs)
    let msg = match args {
        [kind, text] if kind == "chat" => chat_inbox(text),
        [kind, name, body] if kind == "macro" => Msg::new("macro").text("name", name).text("body", body),
        [kind] if kind == "reload" => Msg::new("reload"),
        // offer a secure button: the player presses it, so anything macro text can do
        [kind, label, text] if kind == "press" => Msg::new("press").text("label", label).text("macro", text),
        [kind, code] if kind == "lua" => Msg::new("lua").text("code", code),
        // spell|macro|item|empty, as the agent would send it
        [kind, slot, what, name] if kind == "bar" => Msg::new("bar")
            .int("slot", slot.parse::<u32>().map_err(|_| io::Error::other("slot must be a number"))?)
            .text("what", what)
            .text("name", name),
        // the PlaceAction taint test, delivered the way real bar edits would be
        [kind, variant] if kind == "place" => Msg::new("place").text("variant", variant),
        _ => {
            return Err(io::Error::other(
                "usage: send chat <text> | send macro <name> <body> | send reload | send bar <slot> <spell|macro|item|empty> <name> | send place <variant>",
            ));
        }
    };
    send(addons, &msg)?;
    // this process ends here: its one message goes out first
    crate::channel::flush();
    Ok(())
}

/// Round-trip probe: PC to game through the slot channel, game back to PC through
/// the client's own chat log. If this works there is a bidirectional bridge that
/// does not involve reading pixels off the screen.
pub(crate) fn bridge(addons: &Path) -> io::Result<()> {
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
    send(addons, &Msg::new("bridge").int("nonce", nonce as i128))?;
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
