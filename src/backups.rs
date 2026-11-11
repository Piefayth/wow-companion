//! The game's save files for our addons, kept safe.
//!
//! WoW keeps one `.bak` of a save file. If a file ever fails to parse, the
//! addon starts empty, and at the next logout the game writes that empty state
//! over it: the player's history, settings and traces are gone. On 2026-11-11 an
//! edit of ours (a reply appended while the game was closed) broke the file's Lua
//! for a few minutes; a check caught it before the game read it. So:
//!
//! - every save the game writes is copied here (the last `KEEP` per file);
//! - our own edits are checked to still be sound Lua before they replace the
//!   file, with a copy taken first (`before_edit`);
//! - a save that looks reset (far fewer conversation lines than the one before)
//!   is reported in game, and `wow-companion restore-save` puts the newest good
//!   copy back with the game closed.

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
        if save.file_name().is_some_and(|name| name == "WowCompanion.lua") {
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

/// How many conversation lines a save holds (each log entry has one `who`).
fn lines(save: &str) -> usize {
    save.matches("[\"who\"] = ").count()
}

/// Why `now` looks like a reset of `before`, if it does: the conversation
/// lost most of its lines and the file most of its size, or the addon's table
/// is gone. A trimmed history (each conversation keeps its last 300) never
/// loses this much at once.
pub(crate) fn reset_suspected(before: &str, now: &str) -> Option<String> {
    if before.contains("WowCompanionDB = {") && !now.contains("WowCompanionDB = {") {
        return Some("the addon's table is missing".into());
    }
    let (was, is) = (lines(before), lines(now));
    if was >= 20 && is * 4 < was && now.len() * 3 < before.len() {
        return Some(format!("{was} conversation lines before, {is} now"));
    }
    None
}

/// Whether `text` is sound enough for the game to load: every string, comment
/// and long bracket closed, braces and parentheses balanced, blocks
/// (function/if/do/repeat against end/until) balanced. Not a parser; it
/// catches what a broken write does (the 2026-11-11 one left a string open).
pub(crate) fn lua_sound(text: &str) -> Result<(), String> {
    let bytes = text.as_bytes();
    let (mut at, mut line) = (0usize, 1usize);
    let (mut braces, mut parens, mut blocks) = (0i64, 0i64, 0i64);
    let long_open = |at: usize| -> Option<(usize, usize)> {
        // [[ or [=*[ : returns (level, length of the opener)
        if bytes.get(at) != Some(&b'[') {
            return None;
        }
        let mut level = 0;
        while bytes.get(at + 1 + level) == Some(&b'=') {
            level += 1;
        }
        (bytes.get(at + 1 + level) == Some(&b'[')).then_some((level, level + 2))
    };
    let long_close = |from: usize, level: usize| -> Option<usize> {
        let close = format!("]{}]", "=".repeat(level));
        text[from..].find(&close).map(|found| from + found + close.len())
    };
    while at < bytes.len() {
        let c = bytes[at];
        match c {
            b'\n' => {
                line += 1;
                at += 1;
            }
            b'-' if bytes.get(at + 1) == Some(&b'-') => {
                if let Some((level, opener)) = long_open(at + 2) {
                    let end = long_close(at + 2 + opener, level).ok_or(format!("line {line}: a long comment is not closed"))?;
                    line += text[at..end].matches('\n').count();
                    at = end;
                } else {
                    at = text[at..].find('\n').map_or(bytes.len(), |found| at + found);
                }
            }
            b'[' if long_open(at).is_some() => {
                let (level, opener) = long_open(at).unwrap_or_default();
                let end = long_close(at + opener, level).ok_or(format!("line {line}: a long string is not closed"))?;
                line += text[at..end].matches('\n').count();
                at = end;
            }
            b'"' | b'\'' => {
                at += 1;
                loop {
                    match bytes.get(at) {
                        None | Some(b'\n') => return Err(format!("line {line}: a string is not closed")),
                        Some(b'\\') => at += 2,
                        Some(quote) if *quote == c => {
                            at += 1;
                            break;
                        }
                        Some(_) => at += 1,
                    }
                }
            }
            b'{' => {
                braces += 1;
                at += 1;
            }
            b'}' => {
                braces -= 1;
                if braces < 0 {
                    return Err(format!("line {line}: a closing brace with none open"));
                }
                at += 1;
            }
            b'(' => {
                parens += 1;
                at += 1;
            }
            b')' => {
                parens -= 1;
                at += 1;
            }
            c if c.is_ascii_alphabetic() || c == b'_' => {
                let start = at;
                while at < bytes.len() && (bytes[at].is_ascii_alphanumeric() || bytes[at] == b'_') {
                    at += 1;
                }
                match &text[start..at] {
                    "function" | "if" | "do" | "repeat" => blocks += 1,
                    "end" | "until" => blocks -= 1,
                    _ => {}
                }
            }
            _ => at += 1,
        }
    }
    if braces != 0 {
        return Err(format!("{braces} brace(s) left open"));
    }
    if parens != 0 {
        return Err(format!("parentheses unbalanced by {parens}"));
    }
    if blocks != 0 {
        return Err(format!("blocks unbalanced by {blocks} (function/if/do/repeat against end/until)"));
    }
    Ok(())
}

/// Put the newest good copy of the main save back (`wow-companion restore-save
/// [copy]`), with the game closed. Good: sound Lua and not a reset of the
/// fullest copy kept. The current file is copied first, so this can be undone.
pub(crate) fn restore(addons: &Path, chosen: Option<&Path>) -> io::Result<()> {
    if crate::game_running()? {
        return Err(io::Error::other("close the game first: it would overwrite the restored file at logout"));
    }
    let save = crate::saved_variables(addons).ok_or_else(|| io::Error::other("no WowCompanion.lua save file found"))?;
    let folder = folder_for(&save);
    let pick = match chosen {
        Some(path) => path.to_path_buf(),
        None => {
            let kept = copies(&folder, |_| true);
            let texts: Vec<(PathBuf, String)> =
                kept.into_iter().filter_map(|path| fs::read_to_string(&path).ok().map(|text| (path, text))).collect();
            let fullest = texts.iter().map(|(_, text)| lines(text)).max().unwrap_or(0);
            texts
                .iter()
                .rev()
                .find(|(_, text)| lua_sound(text).is_ok() && lines(text) * 4 >= fullest)
                .map(|(path, _)| path.clone())
                .ok_or_else(|| io::Error::other(format!("no good copy in {}", folder.display())))?
        }
    };
    let text = fs::read_to_string(&pick)?;
    lua_sound(&text).map_err(|why| io::Error::other(format!("{} is not sound Lua: {why}", pick.display())))?;
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
    fn sound_lua_passes_and_each_kind_of_break_is_caught() {
        let good = "WowCompanionDB = {\n[\"log\"] = {\n{ [\"who\"] = \"claude\", [\"text\"] = \"a \\\"quoted\\\" (line) }\", },\n},\n}\n-- a comment with { and \"\n--[[ long\ncomment ]]\nlocal s = [==[ long ] string ]==]\nif type(WowCompanionDB) == \"table\" then\n  WowCompanionDB.x = { 1, 2 }\nend\n";
        assert_eq!(lua_sound(good), Ok(()));
        // the 2026-11-11 break: a raw newline inside a string
        assert!(lua_sound("x = { text = \"one\ntwo\" }\n").unwrap_err().contains("string is not closed"));
        assert!(lua_sound("x = { 1, 2\n").unwrap_err().contains("brace"));
        assert!(lua_sound("if x then\n y = 1\n").unwrap_err().contains("blocks"));
        assert!(lua_sound("--[[ never closed\n").unwrap_err().contains("long comment"));
    }

    #[test]
    fn a_reset_is_told_from_a_trim() {
        let entry = "{ [\"who\"] = \"claude\", [\"text\"] = \"some reply text that takes room\", },\n";
        let full = format!("WowCompanionDB = {{\n[\"log\"] = {{\n{}}},\n}}\n", entry.repeat(300));
        let trimmed = format!("WowCompanionDB = {{\n[\"log\"] = {{\n{}}},\n}}\n", entry.repeat(250));
        let reset = "WowCompanionDB = {\n[\"log\"] = {\n},\n}\n";
        assert_eq!(reset_suspected(&full, &trimmed), None);
        assert!(reset_suspected(&full, reset).unwrap().contains("300"));
        assert!(reset_suspected(&full, "").unwrap().contains("missing"));
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
            assert_eq!(lua_sound(&text), Ok(()), "{}", save.display());
            println!("sound: {} ({} bytes, {} lines)", save.display(), text.len(), lines(&text));
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
