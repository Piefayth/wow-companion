//! The game's save files for our addons, kept safe.
//!
//! WoW keeps one `.bak` of a save file. If a file ever fails to parse, the
//! addon starts empty, and at the next logout the game writes that empty state
//! over it: the player's history, settings and traces are gone. We never edit
//! the save (lines made while the game is closed go to the mailbox,
//! src/ledger.rs), so:
//!
//! - every save the game writes is copied here (the last `KEEP` per file);
//! - a save whose load count went down (the addon loaded empty) is reported in
//!   game, and `wow-companion restore-save` puts the newest good copy back with
//!   the game closed, checked to be sound Lua, the file it replaces copied first
//!   (`before_edit`).

use std::{
    fs, io,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

/// Copies kept per save file, and separately per kind (game saves, our edits).
const KEEP: usize = 10;

/// `%LOCALAPPDATA%\wow-companion\backups\saves`
pub(crate) fn dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("wow-companion").join("backups").join("saves")
}

/// Every save file of ours under WTF\Account: per account and per character
/// (WowCompanion.lua, WowCompanion_Wheel.lua...), not WoW's .bak copies.
pub(crate) fn saves(addons: &Path) -> Vec<PathBuf> {
    let Some(accounts) = addons.parent().and_then(Path::parent).map(|client| client.join("WTF").join("Account")) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    walk(&accounts, 0, &mut found);
    found.sort();
    found
}

fn walk(dir: &Path, depth: usize, found: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if depth < 4 {
                walk(&path, depth + 1, found);
            }
        } else if path.parent().and_then(Path::file_name).is_some_and(|name| name == "SavedVariables") {
            let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            if name.starts_with("WowCompanion") && name.ends_with(".lua") {
                found.push(path);
            }
        }
    }
}

/// Where one save file's copies go: its path under WTF\Account, flattened.
fn folder_for(save: &Path) -> PathBuf {
    let parts: Vec<String> = save
        .components()
        .rev()
        .take_while(|part| part.as_os_str() != "Account")
        .map(|part| part.as_os_str().to_string_lossy().into_owned())
        .collect();
    let name: Vec<String> = parts.into_iter().rev().filter(|part| part != "SavedVariables").collect();
    dir().join(name.join("__"))
}

fn modified_secs(path: &Path) -> Option<u64> {
    fs::metadata(path).ok()?.modified().ok()?.duration_since(UNIX_EPOCH).ok().map(|since| since.as_secs())
}

/// Copy every save file the game has written since the last look. Cheap when
/// nothing changed (one stat per file); called when a save lands.
pub(crate) fn snapshot(addons: &Path) -> Vec<String> {
    let mut notes = Vec::new();
    for save in saves(addons) {
        let Some(at) = modified_secs(&save) else { continue };
        let folder = folder_for(&save);
        let copy = folder.join(format!("{at}.lua"));
        if copy.exists() {
            continue;
        }
        let previous = newest(&folder, |name| !name.contains("-before-edit"));
        if let Err(err) = fs::create_dir_all(&folder).and_then(|()| fs::copy(&save, &copy).map(|_| ())) {
            notes.push(format!("save backup failed for {}: {err}", save.display()));
            continue;
        }
        prune(&folder, |name| !name.contains("-before-edit"));
        // the main save only: a reset there costs the player their history
        if save.file_name().is_some_and(|name| name == "WowCompanion_Link.lua") {
            if let (Some(previous), Ok(now)) = (previous, fs::read_to_string(&save)) {
                if let Ok(before) = fs::read_to_string(&previous) {
                    if let Some(why) = reset_suspected(&before, &now) {
                        notes.push(format!(
                            "Your companion's saved data looks reset by the last save ({why}). The last {KEEP} saves are kept in {}. With the game closed, run `wow-companion restore-save` (or ask an agent to) to put the newest good one back.",
                            folder.display()
                        ));
                    }
                }
            }
        }
    }
    notes
}

/// A copy of `save` taken just before we edit it ourselves.
pub(crate) fn before_edit(save: &Path) -> io::Result<PathBuf> {
    let folder = folder_for(save);
    fs::create_dir_all(&folder)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_millis()).unwrap_or_default();
    let copy = folder.join(format!("{now}-before-edit.lua"));
    fs::copy(save, &copy)?;
    prune(&folder, |name| name.contains("-before-edit"));
    Ok(copy)
}

fn copies(folder: &Path, kind: impl Fn(&str) -> bool) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = fs::read_dir(folder)
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "lua"))
                .filter(|path| path.file_name().is_some_and(|name| kind(&name.to_string_lossy())))
                .collect()
        })
        .unwrap_or_default();
    // names start with a timestamp; oldest first
    found.sort_by_key(|path| {
        path.file_stem()
            .map(|stem| stem.to_string_lossy().split('-').next().unwrap_or("0").parse::<u128>().unwrap_or(0))
            .unwrap_or(0)
    });
    found
}

fn newest(folder: &Path, kind: impl Fn(&str) -> bool) -> Option<PathBuf> {
    copies(folder, kind).pop()
}

fn prune(folder: &Path, kind: impl Fn(&str) -> bool) {
    let all = copies(folder, kind);
    if all.len() > KEEP {
        for old in &all[..all.len() - KEEP] {
            let _ = fs::remove_file(old);
        }
    }
}

/// `WowCompanionLinkDB.loads`: the addon adds one each time it loads its saved
/// table, and nothing else writes it, so it only ever grows unless the addon
/// loaded empty. Read at the table's top level only (the game writes nested
/// tables without indentation, so depth is counted, strings skipped).
pub(crate) fn loads(save: &str) -> Option<u64> {
    let start = save.find("WowCompanionLinkDB = {")? + "WowCompanionLinkDB = {".len();
    let bytes = save.as_bytes();
    let (mut at, mut depth) = (start, 1usize);
    while at < bytes.len() && depth > 0 {
        match bytes[at] {
            b'"' => {
                at += 1;
                while at < bytes.len() && bytes[at] != b'"' {
                    at += if bytes[at] == b'\\' { 2 } else { 1 };
                }
            }
            b'{' => depth += 1,
            b'}' => depth -= 1,
            b'[' if depth == 1 && save[at..].starts_with("[\"loads\"] = ") => {
                let digits = &save[at + "[\"loads\"] = ".len()..];
                return digits.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok();
            }
            _ => {}
        }
        at += 1;
    }
    None
}

/// Why `now` is a reset of `before`, if it is: the addon's load count went
/// down (it restarts at 1 when the addon loaded empty), or the table is gone.
/// Nothing is said for a save from before the counter existed.
pub(crate) fn reset_suspected(before: &str, now: &str) -> Option<String> {
    if before.contains("WowCompanionLinkDB = {") && !now.contains("WowCompanionLinkDB = {") {
        return Some("the addon's table is missing".into());
    }
    match (loads(before), loads(now)) {
        (Some(was), Some(is)) if is < was => Some(format!("the addon had loaded {was} times; this save counts {is}")),
        (Some(was), None) => Some(format!("the addon had loaded {was} times; this save has no count")),
        _ => None,
    }
}

/// Put the newest good copy of the main save back (`wow-companion restore-save
/// [copy]`), with the game closed. Without a named copy: the sound copy with
/// the highest load count, the last save before the count went down (newest
/// of equals). The current file is copied first, so this can be undone.
pub(crate) fn restore(addons: &Path, chosen: Option<&Path>) -> io::Result<()> {
    if crate::game_running() {
        return Err(io::Error::other("close the game first: it would overwrite the restored file at logout"));
    }
    let save = crate::saved_variables(addons, crate::LINK).ok_or_else(|| io::Error::other("no WowCompanion_Link.lua save file found"))?;
    let folder = folder_for(&save);
    let pick = match chosen {
        Some(path) => path.to_path_buf(),
        None => {
            let kept = copies(&folder, |_| true);
            let texts: Vec<(PathBuf, String)> =
                kept.into_iter().filter_map(|path| fs::read_to_string(&path).ok().map(|text| (path, text))).collect();
            // oldest first, so max_by_key keeps the newest of equal counts
            texts
                .iter()
                .filter(|(_, text)| crate::savedvars::globals(text).is_ok())
                .filter_map(|(path, text)| loads(text).map(|count| (count, path)))
                .max_by_key(|(count, _)| *count)
                .map(|(_, path)| path.clone())
                .ok_or_else(|| {
                    io::Error::other(format!(
                        "no copy in {} carries a load count to choose by: name the copy to restore",
                        folder.display()
                    ))
                })?
        }
    };
    let text = fs::read_to_string(&pick)?;
    crate::savedvars::globals(&text).map_err(|why| io::Error::other(format!("{} does not parse as a save: {why}", pick.display())))?;
    let undo = before_edit(&save)?;
    let temporary = save.with_extension("lua.companion");
    fs::write(&temporary, &text)?;
    fs::rename(&temporary, &save)?;
    println!("restored {} from {}", save.display(), pick.display());
    println!("the file it replaced is kept as {}", undo.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_save_parses_and_each_kind_of_break_is_caught() {
        let good = "\nWowCompanionDB = {\n[\"log\"] = {\n{\n[\"who\"] = \"claude\",\n[\"text\"] = \"a \\\"quoted\\\" (line) }\\n\",\n}, -- [1]\n},\n}\nOtherDB = nil\n";
        assert!(crate::savedvars::globals(good).is_ok());
        // the 2026-11-11 break: a raw newline inside a string
        assert!(crate::savedvars::globals("x = {\n[\"text\"] = \"one\ntwo\",\n}\n").unwrap_err().contains("string is not closed"));
        assert!(crate::savedvars::globals("x = {\n1, 2\n").unwrap_err().contains("table is not closed"));
        // a save holds assignments only
        assert!(crate::savedvars::globals("if x then\n y = 1\nend\n").is_err());
    }

    #[test]
    fn a_reset_is_the_load_count_going_down() {
        // nested tables are written without indentation: a nested "loads" and
        // one inside a string must not be read as the addon's
        let save = |count: u64| {
            format!(
                "WowCompanionLinkDB = {{\n[\"log\"] = {{\n{{\n[\"text\"] = \"[\\\"loads\\\"] = 999\",\n[\"loads\"] = 7,\n}},\n}},\n[\"loads\"] = {count},\n}}\n"
            )
        };
        assert_eq!(loads(&save(41)), Some(41));
        assert_eq!(reset_suspected(&save(41), &save(42)), None);
        assert!(reset_suspected(&save(41), &save(1)).unwrap().contains("41"));
        assert!(reset_suspected(&save(41), "").unwrap().contains("missing"));
        // a save from before the counter existed says nothing
        assert_eq!(reset_suspected("WowCompanionLinkDB = {\n}\n", &save(1)), None);
    }

    /// The check must pass what the game itself writes, or every closed-game
    /// line would be refused: run on this PC's real saves (`--ignored`).
    #[test]
    #[ignore]
    fn the_games_own_saves_are_sound() {
        let addons = wow_companion_settings::Settings::load().get("addons").map(PathBuf::from).expect("addons set");
        let found = saves(&addons);
        assert!(!found.is_empty());
        for save in found {
            let text = fs::read_to_string(&save).unwrap();
            assert!(crate::savedvars::globals(&text).is_ok(), "{}", save.display());
            println!("sound: {} ({} bytes, loads {:?})", save.display(), text.len(), loads(&text));
        }
    }

    #[test]
    fn copies_of_one_save_are_kept_apart_from_another() {
        let a = Path::new(r"S:\WoW\_forever_\WTF\Account\ACC\SavedVariables\WowCompanion.lua");
        let b = Path::new(r"S:\WoW\_forever_\WTF\Account\ACC\91\Char-Name\SavedVariables\WowCompanion_Wheel.lua");
        assert!(folder_for(a).ends_with("ACC__WowCompanion.lua"));
        assert!(folder_for(b).ends_with("ACC__91__Char-Name__WowCompanion_Wheel.lua"));
    }
}
