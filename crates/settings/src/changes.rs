//! What the companion put on this PC, so the setup window can show it and take it
//! all back out.
//!
//! `install` records each addon folder it writes in a ledger,
//! `%LOCALAPPDATA%\wow-companion\changes.txt`, one `folder<TAB><path>` line each.
//! Uninstall removes exactly:
//! - our addon folders: the ledger's, plus any `WowCompanion`/`WowCompanion_*`
//!   folder in the game's AddOns (ours by name, so an install from before the
//!   ledger is covered too). A ledger line naming anything else is ignored.
//! - our addon's saved data in the game's WTF folder (`WowCompanion*.lua`).
//! - addons the agent installed (`addons.json`), only when asked to.
//! - `%LOCALAPPDATA%\wow-companion`: settings, conversations, logs, backups.
//!
//! The program folder (the unzipped release, with any model in it) is left for
//! the player to delete: a program can't delete the folder it runs from.

use std::{
    fs, io,
    path::{Path, PathBuf},
};

/// `%LOCALAPPDATA%\wow-companion`.
pub fn data_dir() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join("wow-companion"))
}

fn ledger() -> Option<PathBuf> {
    Some(data_dir()?.join("changes.txt"))
}

/// Add these addon folders to the ledger (ones already in it are kept once).
pub fn record_folders(folders: &[PathBuf]) -> io::Result<()> {
    let path = ledger().ok_or_else(|| io::Error::other("LOCALAPPDATA is not set"))?;
    let mut text = fs::read_to_string(&path).unwrap_or_default();
    let mut added = false;
    for folder in folders {
        let line = format!("folder\t{}", folder.display());
        if !text.lines().any(|known| known == line) {
            text.push_str(&line);
            text.push('\n');
            added = true;
        }
    }
    if added {
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(&path, text)?;
    }
    Ok(())
}

/// An addon folder of ours: named so, directly inside an AddOns folder.
fn ours(path: &Path) -> bool {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    let in_addons = path.parent().and_then(Path::file_name).is_some_and(|parent| parent.eq_ignore_ascii_case("AddOns"));
    in_addons && (name == "WowCompanion" || name.starts_with("WowCompanion_"))
}

/// Everything uninstall would remove, found on disk now.
#[derive(Default, Debug)]
pub struct Changes {
    /// Our addon folders (the 512 message slots among them).
    pub folders: Vec<PathBuf>,
    /// Our addon's saved data in WTF.
    pub saved: Vec<PathBuf>,
    /// Addons the agent installed: name, and its folders that exist.
    pub agent_addons: Vec<(String, Vec<PathBuf>)>,
    /// `%LOCALAPPDATA%\wow-companion`, if it exists.
    pub data: Option<PathBuf>,
}

impl Changes {
    pub fn find(addons: Option<&Path>) -> Changes {
        let ledger = ledger().and_then(|path| fs::read_to_string(path).ok()).unwrap_or_default();
        let agent = data_dir().and_then(|dir| fs::read_to_string(dir.join("addons.json")).ok()).unwrap_or_default();
        Changes::find_in(addons, &ledger, &agent, data_dir())
    }

    /// `find` with the ledger, the agent's addons.json and the data folder given.
    fn find_in(addons: Option<&Path>, ledger: &str, agent: &str, data: Option<PathBuf>) -> Changes {
        let mut changes = Changes::default();
        let mut folders: Vec<PathBuf> = ledger
            .lines()
            .filter_map(|line| line.strip_prefix("folder\t"))
            .map(PathBuf::from)
            .collect();
        if let Some(addons) = addons {
            if let Ok(entries) = fs::read_dir(addons) {
                folders.extend(entries.flatten().map(|entry| entry.path()));
            }
            changes.saved = saved_data(addons);
            changes.agent_addons = agent_addons(addons, agent);
        }
        folders.retain(|folder| ours(folder) && folder.is_dir());
        folders.sort();
        folders.dedup();
        changes.folders = folders;
        changes.data = data.filter(|dir| dir.is_dir());
        changes
    }

    pub fn is_empty(&self) -> bool {
        self.folders.is_empty() && self.saved.is_empty() && self.agent_addons.is_empty() && self.data.is_none()
    }

    /// Remove it all (the agent's addons only if `agent_addons`). Returns what
    /// could not be removed; empty means everything went. Check that neither
    /// the game nor the companion is running first: both hold these files.
    pub fn remove(&self, agent_addons: bool) -> Vec<String> {
        let mut failed = Vec::new();
        let mut gone = |path: &Path, result: io::Result<()>| {
            if let Err(err) = result {
                if err.kind() != io::ErrorKind::NotFound {
                    failed.push(format!("{}: {err}", path.display()));
                }
            }
        };
        for folder in &self.folders {
            gone(folder, fs::remove_dir_all(folder));
        }
        for file in &self.saved {
            gone(file, fs::remove_file(file));
        }
        if agent_addons {
            for folder in self.agent_addons.iter().flat_map(|(_, folders)| folders) {
                gone(folder, fs::remove_dir_all(folder));
            }
        }
        if let Some(data) = &self.data {
            gone(data, fs::remove_dir_all(data));
        }
        failed
    }
}

/// `WowCompanion*.lua` (and the game's `.bak` copies) in every SavedVariables
/// folder of the install: per account, and per character.
fn saved_data(addons: &Path) -> Vec<PathBuf> {
    let Some(accounts) = addons.parent().and_then(Path::parent).map(|root| root.join("WTF").join("Account")) else {
        return Vec::new();
    };
    let mut folders = Vec::new();
    for account in children(&accounts) {
        folders.push(account.join("SavedVariables"));
        for realm in children(&account) {
            for character in children(&realm) {
                folders.push(character.join("SavedVariables"));
            }
        }
    }
    let mut files = Vec::new();
    for folder in folders {
        for file in fs::read_dir(&folder).into_iter().flatten().flatten() {
            let name = file.file_name().to_string_lossy().to_string();
            if name.starts_with("WowCompanion") && (name.ends_with(".lua") || name.ends_with(".lua.bak")) {
                files.push(file.path());
            }
        }
    }
    files
}

fn children(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir).into_iter().flatten().flatten().map(|entry| entry.path()).filter(|path| path.is_dir()).collect()
}

/// The addons the agent installed, from its `addons.json` (a list of objects
/// with `name` and `folders`), with the folders still in `addons`.
fn agent_addons(addons: &Path, text: &str) -> Vec<(String, Vec<PathBuf>)> {
    parse_agent_addons(text)
        .into_iter()
        .map(|(name, folders)| {
            let folders = folders
                .iter()
                // a plain folder name only: never a path out of AddOns
                .filter(|folder| !folder.is_empty() && !folder.contains(['/', '\\', ':']) && *folder != "." && *folder != "..")
                .map(|folder| addons.join(folder))
                .filter(|path| path.is_dir())
                .collect();
            (name, folders)
        })
        .filter(|(_, folders): &(String, Vec<PathBuf>)| !folders.is_empty())
        .collect()
}

/// Just enough JSON for `addons.json`: each `"name"` string and the strings of
/// the `"folders"` array after it.
fn parse_agent_addons(text: &str) -> Vec<(String, Vec<String>)> {
    let mut out: Vec<(String, Vec<String>)> = Vec::new();
    let mut rest = text;
    while let Some(at) = rest.find('"') {
        let Some((key, after)) = string(&rest[at..]) else { break };
        let after = after.trim_start().strip_prefix(':').map(str::trim_start);
        rest = after.unwrap_or(&rest[at + 1..]);
        let Some(after) = after else { continue };
        match key.as_str() {
            "name" => {
                if let Some((name, next)) = string(after) {
                    out.push((name, Vec::new()));
                    rest = next;
                }
            }
            "folders" => {
                let Some(list) = after.strip_prefix('[') else { continue };
                let end = list.find(']').unwrap_or(list.len());
                let mut items = &list[..end];
                while let Some(start) = items.find('"') {
                    let Some((folder, next)) = string(&items[start..]) else { break };
                    if let Some((_, folders)) = out.last_mut() {
                        folders.push(folder);
                    }
                    items = next;
                }
                rest = &list[end..];
            }
            _ => {}
        }
    }
    out
}

/// A JSON string at the start of `text`, and what follows it.
fn string(text: &str) -> Option<(String, &str)> {
    let body = text.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = body.char_indices();
    while let Some((at, ch)) = chars.next() {
        match ch {
            '"' => return Some((out, &body[at + 1..])),
            '\\' => match chars.next()?.1 {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                other => out.push(other),
            },
            ch => out.push(ch),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_addons_are_read_from_their_ledger() {
        let text = r#"[
  { "name": "Polestar", "version": "0.3.5", "folders": [ "Polestar", "Polestar_Nav" ] },
  { "name": "Auc \"tionator\"", "source": "x", "folders": ["Auctionator"] }
]"#;
        assert_eq!(
            parse_agent_addons(text),
            vec![
                ("Polestar".to_string(), vec!["Polestar".to_string(), "Polestar_Nav".to_string()]),
                ("Auc \"tionator\"".to_string(), vec!["Auctionator".to_string()]),
            ]
        );
    }

    #[test]
    fn only_our_names_in_an_addons_folder_count_as_ours() {
        assert!(ours(Path::new(r"C:\Game\Interface\AddOns\WowCompanion")));
        assert!(ours(Path::new(r"C:\Game\Interface\AddOns\WowCompanion_S001")));
        assert!(!ours(Path::new(r"C:\Game\Interface\AddOns\Polestar")));
        assert!(!ours(Path::new(r"C:\Windows\WowCompanion")));
        assert!(!ours(Path::new(r"C:\Game\Interface\AddOns\WowCompanionEvil\..")));
    }

    /// What uninstall would remove on this PC, listed and left alone.
    /// `cargo test -p wow-companion-settings -- --ignored --nocapture listed`
    #[test]
    #[ignore]
    fn listed_on_this_pc() {
        let settings = crate::Settings::load();
        let changes = Changes::find(settings.get("addons").map(Path::new));
        println!("{} folders, first {:?}", changes.folders.len(), changes.folders.first());
        println!("saved {:?}", changes.saved);
        println!("agent addons {:?}", changes.agent_addons.iter().map(|(name, f)| (name, f.len())).collect::<Vec<_>>());
        println!("data {:?}", changes.data);
    }

    #[test]
    fn a_whole_install_is_found_and_removed() {
        let root = std::env::temp_dir().join(format!("wc-changes-{}", std::process::id()));
        let addons = root.join("Interface").join("AddOns");
        for folder in ["WowCompanion", "WowCompanion_Wheel", "WowCompanion_S001", "SomeoneElses"] {
            fs::create_dir_all(addons.join(folder)).unwrap();
        }
        let saved = root.join("WTF").join("Account").join("ME").join("SavedVariables");
        let character = root.join("WTF").join("Account").join("ME").join("Realm").join("Hero").join("SavedVariables");
        fs::create_dir_all(&saved).unwrap();
        fs::create_dir_all(&character).unwrap();
        for file in [saved.join("WowCompanion.lua"), saved.join("WowCompanion.lua.bak"), saved.join("Other.lua"), character.join("WowCompanion_Wheel.lua")] {
            fs::write(file, "x").unwrap();
        }
        fs::create_dir_all(addons.join("Polestar")).unwrap();
        let data = root.join("data");
        fs::create_dir_all(&data).unwrap();
        // a ledger line for something not ours is ignored
        let ledger = format!("folder	{}
folder	{}
", addons.join("WowCompanion").display(), root.join("WTF").display());
        let changes = Changes::find_in(Some(&addons), &ledger, r#"[{"name": "Polestar", "folders": ["Polestar", "..\x"]}]"#, Some(data.clone()));
        assert_eq!(changes.folders.len(), 3);
        assert_eq!(changes.saved.len(), 3);
        assert_eq!(changes.agent_addons, vec![("Polestar".to_string(), vec![addons.join("Polestar")])]);
        assert!(changes.remove(false).is_empty());
        assert!(addons.join("Polestar").is_dir());
        assert!(!data.exists());
        assert!(changes.remove(true).is_empty());
        assert!(!addons.join("Polestar").exists());
        assert!(addons.join("SomeoneElses").is_dir());
        assert!(!addons.join("WowCompanion").exists());
        assert!(saved.join("Other.lua").exists());
        assert!(!saved.join("WowCompanion.lua").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
