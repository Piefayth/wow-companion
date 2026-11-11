//! Install, and `send`: one message to the game from another process.

use super::*;
use crate::message::Msg;

pub(crate) fn install(addons: &Path) -> io::Result<()> {
    let source = crate::home().join("addon").join(ADDON);
    // Modules.lua is built from modules/, never edited by hand
    modules::regenerate(None)?;
    let addon = addons.join(ADDON);
    // folders the running game cannot see until it is restarted
    let mut fresh: Vec<String> = Vec::new();
    let mut note_fresh = |dir: &Path| {
        if !dir.exists() {
            fresh.push(dir.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default());
        }
    };
    note_fresh(&addon);
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
            note_fresh(&installed);
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
    // every bell exists before the game can ask for it: one it asked for while
    // missing is never heard (bells.rs, rule 3)
    for bell in (0..SETS).flat_map(|set| (1..=SLOTS).map(move |slot| slot_bell_name(set, slot))) {
        let path = signals.join(bell);
        if missing(&path) {
            bells::empty(&path)?;
        }
    }
    // the sound probe's controls: one that must play, one that must not
    if missing(&signals.join("always.wav")) {
        bells::ring(&signals.join("always.wav"))?;
    }
    if missing(&signals.join("never.wav")) {
        bells::empty(&signals.join("never.wav"))?;
    }
    for slot in 1..=SLOTS {
        let dir = addons.join(slot_name(slot));
        note_fresh(&dir);
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
    match fresh.len() {
        0 => println!("no new folders: a /reload loads the changes"),
        n => println!(
            "{n} new folder(s) ({}{}): fully restart the game so it sees them",
            fresh.iter().take(3).cloned().collect::<Vec<_>>().join(", "),
            if n > 3 { ", ..." } else { "" }
        ),
    }
    Ok(())
}

/// What the PC writes into an installed addon folder, which the repo's copy
/// never has: kept when the folder is brought in line with the repo.
fn generated(addon: &str) -> &'static [&'static str] {
    match addon {
        LINK => &["Signals", "helper-state.txt"],
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
        // a channel test message: the game counts it (WowCompanionLinkDB.probe.received)
        [kind, n] if kind == "probe" => Msg::new("probe")
            .int("n", n.parse::<i128>().map_err(|_| io::Error::other("probe wants a number"))?)
            .int("sent", SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_secs() as i128).unwrap_or_default()),
        _ => {
            return Err(io::Error::other(
                "usage: send chat <text> | send macro <name> <body> | send reload | send bar <slot> <spell|macro|item|empty> <name> | send place <variant> | send probe <n>",
            ));
        }
    };
    send(addons, &msg)?;
    // this process ends here: its one message goes out first
    crate::channel::flush();
    Ok(())
}
