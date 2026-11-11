//! Modules live in git (the player, 2026-11-10).
//!
//! A module is Lua the agent wants run at every login. It used to live only in
//! the addon's SavedVariables, which the game writes at a reload or logout: no
//! history, lost in a crash, and invisible to the agents until the next export.
//! Now each one is `modules/<Name>.lua` in this repository, the source of truth.
//! Every change regenerates `addon/WowCompanion_Agent/Modules.lua` (listed in the .toc,
//! so a /reload rereads it; only a *new* file in a .toc needs a game restart) and
//! copies it into the installed addon. The `module` step is still sent too, so a
//! change runs at once without waiting for a reload.

use std::{
    fs, io,
    path::{Path, PathBuf},
};

/// `modules/` in this repository.
pub fn dir() -> PathBuf {
    crate::home().join("modules")
}

/// The generated file in the repository's copy of the addon.
fn generated_in_repo() -> PathBuf {
    crate::home().join("addon").join(crate::AGENT).join("Modules.lua")
}

/// A module name the addon accepts: letters, digits and underscores.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A `module` step from an answer: stored, or removed when `code` is None.
pub fn save(addons: &Path, name: &str, code: Option<&str>) -> io::Result<()> {
    if !valid_name(name) {
        return Err(io::Error::other(format!("{name:?} is not a module name")));
    }
    let dir = dir();
    fs::create_dir_all(&dir)?;
    let file = dir.join(format!("{name}.lua"));
    match code {
        Some(code) => fs::write(&file, format!("{}\n", code.trim_end_matches(['\n', '\r'])))?,
        None => match fs::remove_file(&file) {
            Err(err) if err.kind() != io::ErrorKind::NotFound => return Err(err),
            _ => {}
        },
    }
    regenerate(Some(addons))
}

/// Rebuild Modules.lua from `modules/`, in the repository and, given the AddOns
/// folder, in the installed addon.
pub fn regenerate(addons: Option<&Path>) -> io::Result<()> {
    let lua = render(&read_all(&dir())?);
    fs::write(generated_in_repo(), &lua)?;
    if let Some(addons) = addons {
        let installed = addons.join(crate::AGENT);
        if installed.is_dir() {
            fs::write(installed.join("Modules.lua"), &lua)?;
        }
    }
    Ok(())
}

/// Every module in a folder, sorted by name.
fn read_all(dir: &Path) -> io::Result<Vec<(String, String)>> {
    let mut all = Vec::new();
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(all),
        Err(err) => return Err(err),
    };
    for entry in entries {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_suffix(".lua")) else {
            continue;
        };
        if valid_name(name) {
            all.push((name.to_string(), fs::read_to_string(&path)?));
        }
    }
    all.sort();
    Ok(all)
}

/// The Lua the addon loads: a table of name to code, each in a long bracket of a
/// level its code never closes.
fn render(modules: &[(String, String)]) -> String {
    let mut lua = String::from(
        "-- Generated from modules/*.lua by the companion (src/modules.rs). Edit those, not this.\n\
         WowCompanion_DiskModules = {\n",
    );
    for (name, code) in modules {
        let level = (0..).find(|n| !code.contains(&format!("]{}]", "=".repeat(*n)))).unwrap_or(0);
        let eq = "=".repeat(level);
        // a newline straight after the opening bracket is dropped by Lua, so the
        // code's first line stays its first line
        lua.push_str(&format!("\t[\"{name}\"] = [{eq}[\n{code}]{eq}],\n"));
    }
    lua.push_str("}\n");
    lua
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_letters_digits_and_underscores() {
        assert!(valid_name("Bags"));
        assert!(valid_name("Make_Room2"));
        assert!(!valid_name(""));
        assert!(!valid_name("../evil"));
        assert!(!valid_name("a b"));
    }

    #[test]
    fn code_that_closes_a_long_bracket_gets_a_longer_one() {
        let lua = render(&[
            ("Plain".to_string(), "print('hi')\n".to_string()),
            ("Tricky".to_string(), "local s = [[x]] .. [=[y]=]\n".to_string()),
        ]);
        assert!(lua.contains("[\"Plain\"] = [[\nprint('hi')\n]],"), "{lua}");
        assert!(lua.contains("[\"Tricky\"] = [==[\nlocal s = [[x]] .. [=[y]=]\n]==],"), "{lua}");
    }

    #[test]
    fn a_folder_reads_sorted_and_skips_other_files() {
        let dir = std::env::temp_dir().join(format!("wc-modules-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("Zed.lua"), "z").unwrap();
        fs::write(dir.join("Alpha.lua"), "a").unwrap();
        fs::write(dir.join("notes.txt"), "n").unwrap();
        fs::write(dir.join("bad name.lua"), "b").unwrap();
        let names: Vec<String> = read_all(&dir).unwrap().into_iter().map(|(n, _)| n).collect();
        assert_eq!(names, ["Alpha", "Zed"]);
    }
}
