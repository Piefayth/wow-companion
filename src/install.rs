//! Install: the addons, the slots and the bells laid down in the game's folder.

use super::*;

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
    // dictation only (the setup window's agent "off"): the addons that need the
    // agent are left out, and an earlier install's taken out
    let agents = wow_companion_settings::Settings::load().get("agent") != Some(wow_companion_settings::AGENT_OFF);
    // the suite's other addons (Link, Agent, the extras), placed as they are
    for entry in fs::read_dir(source.parent().unwrap())? {
        let entry = entry?;
        let name = entry.file_name();
        if entry.file_type()?.is_dir() && name != ADDON {
            let installed = addons.join(&name);
            if !agents && needs_agent(source.parent().unwrap(), &name.to_string_lossy()) {
                if installed.exists() {
                    fs::remove_dir_all(&installed)?;
                    println!("removed {} (the agents are off)", name.to_string_lossy());
                }
                continue;
            }
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
        fs::write(dir.join(format!("{}.toc", slot_name(slot))), slot_toc(slot))?;
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
/// Whether the addon `name` (a folder in `suite`, the repo's addon folder) is
/// the agent's or needs it, by the `## Dependencies:` of the .toc files.
fn needs_agent(suite: &Path, name: &str) -> bool {
    let toc = fs::read_to_string(suite.join(name).join(format!("{name}.toc"))).unwrap_or_default();
    name == AGENT
        || toc
            .lines()
            .filter_map(|line| line.strip_prefix("## Dependencies:"))
            .flat_map(|deps| deps.split(','))
            .map(str::trim)
            .any(|dep| !dep.is_empty() && dep != name && needs_agent(suite, dep))
}

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

pub(crate) fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
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
    use super::*;
    use wow_companion_settings::changes::Changes;

    /// The release script runs only when a release is made, so a mistake in it
    /// waits there unseen (a `"$Exe:"` stopped it parsing, 2026-11-11): parse it.
    #[cfg(windows)]
    #[test]
    fn the_release_script_parses() {
        let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("packaging").join("package.ps1");
        let check = format!(
            "$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('{}', [ref]$null, [ref]$e); \
             if ($e) {{ $e | ForEach-Object {{ $_.Message }}; exit 1 }}",
            script.display()
        );
        let out = std::process::Command::new("powershell").args(["-NoProfile", "-Command", &check]).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stdout));
    }

    #[test]
    fn dictation_only_leaves_out_the_agent_and_what_needs_it() {
        let suite = Path::new(env!("CARGO_MANIFEST_DIR")).join("addon");
        let mut needing: Vec<String> = fs::read_dir(&suite)
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| needs_agent(&suite, name))
            .collect();
        needing.sort();
        assert_eq!(needing, ["WowCompanion_Agent", "WowCompanion_Errands"]);
    }

    /// Every file under `dir`, relative to it, sorted.
    fn files(dir: &Path) -> Vec<String> {
        let mut found = Vec::new();
        let mut walk = vec![dir.to_path_buf()];
        while let Some(at) = walk.pop() {
            for entry in fs::read_dir(&at).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk.push(path);
                } else {
                    found.push(path.strip_prefix(dir).unwrap().to_string_lossy().into_owned());
                }
            }
        }
        found.sort();
        found
    }

    /// Run alone (`--ignored`: it points LOCALAPPDATA at a throwaway folder for
    /// the whole process). A real install into a throwaway game folder, then the
    /// setup window's uninstall: the game folder is as it was, someone else's
    /// addon and save untouched, and the companion's data folder gone.
    #[test]
    #[ignore]
    fn uninstall_takes_back_exactly_what_install_put_down() {
        let root = std::env::temp_dir().join(format!("wc-uninstall-{}", std::process::id()));
        let game = root.join("game");
        let addons = game.join("Interface").join("AddOns");
        let saved = game.join("WTF").join("Account").join("TEST").join("SavedVariables");
        fs::create_dir_all(addons.join("SomeoneElses")).unwrap();
        fs::write(addons.join("SomeoneElses").join("SomeoneElses.toc"), "## Title: theirs\n").unwrap();
        fs::create_dir_all(&saved).unwrap();
        fs::write(saved.join("SomeoneElses.lua"), "SomeoneElsesDB = {}\n").unwrap();
        let before = files(&game);
        // SAFETY: this test runs alone (ignored by default), so no other thread
        // reads the environment while it changes
        unsafe { std::env::set_var("LOCALAPPDATA", root.join("appdata")) };
        install(&addons).unwrap();
        // what the game writes for our addons once it has run
        fs::write(saved.join("WowCompanion_Link.lua"), "WowCompanionLinkDB = {}\n").unwrap();
        assert!(files(&game).len() > before.len() + 1500, "install put down the addons, slots and bells");
        let mut changes = Changes::find(Some(&addons));
        // the real "Start with Windows" entry is not this test's to remove
        changes.startup = None;
        assert_eq!(changes.remove(true), Vec::<String>::new());
        assert_eq!(files(&game), before);
        assert!(!root.join("appdata").join("wow-companion").exists());
        fs::remove_dir_all(&root).unwrap();
    }
}
