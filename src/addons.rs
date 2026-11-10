//! Installing and removing other addons, from GitHub.
//!
//! Installing addons is miserable on a controller, so the agent does it. The
//! terms the player set: GitHub first, with checks on who maintains the code, and
//! nothing installs until they have heard the check and said yes. The research
//! (search, the maintainer, the .toc, the CurseForge page) is the agent's own,
//! with Claude Code's WebSearch and WebFetch: this module is only the part that
//! touches the disk, and the rules it enforces whatever the agent decided.
//!
//! The game sandboxes addon code (no files, no network), so the risk on this
//! machine lives here, in downloading and unpacking. Hence: plain `curl` and the
//! `tar` that ships with Windows rather than new dependencies, an allow-list of
//! file types an addon actually contains, unpacking into a staging folder before
//! anything touches `Interface\AddOns`, and a backup of whatever gets replaced.
//! GitHub is used without a login: 60 requests an hour is plenty, and no
//! credential sits anywhere near the agent.

use std::{
    fs, io,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{json, Value};

// generic, not identifying: GitHub asks for a User-Agent, not for who we are
const AGENT: &str = "wow-companion-addon-manager";
// what an addon folder holds. Anything else is refused, not skipped: an addon
// shipping an executable is a reason to stop, not to tidy up
const ALLOWED: &[&str] = &[
    "lua", "xml", "toc", "tga", "blp", "png", "jpg", "jpeg", "gif", "ogg", "mp3", "wav",
    "ttf", "otf", "txt", "md", "markdown", "json", "yml", "yaml", "m2", "skin", "anim", "bls",
];
// toc suffixes for other game flavours: Name_Mainline.toc still means folder "Name"
const TOC_FLAVOURS: &[&str] = &[
    "_mainline", "_classic", "_vanilla", "_tbc", "_bcc", "_wrath", "_wotlkc", "_cata",
    "_mists", "_standard", "_forever", "-classic", "-bcc", "-wrath", "-mainline",
];

fn get(url: &str) -> io::Result<Vec<u8>> {
    let out = Command::new("curl")
        .args(["-sSfL", "--max-time", "60", "-A", AGENT])
        .args(["-H", "Accept: application/vnd.github+json"])
        .arg(url)
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "fetching {url} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(out.stdout)
}

fn api(path: &str) -> io::Result<Value> {
    let body = get(&format!("https://api.github.com/{path}"))?;
    serde_json::from_slice(&body).map_err(|err| io::Error::other(format!("{path}: {err}")))
}

fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

/// Where an install would come from: a release zip the maintainer uploaded, or the
/// newest tag's source, or (flagged) the default branch.
struct Source {
    url: String,
    what: String,
}

fn source(repo: &str, owner: &str) -> io::Result<Source> {
    if let Ok(release) = api(&format!("repos/{repo}/releases/latest")) {
        let assets = release.get("assets").and_then(Value::as_array).cloned().unwrap_or_default();
        // prefer a zip uploaded by the owner; a release zip is what players get
        let zip = assets.iter().find(|asset| {
            text(asset, "name").to_lowercase().ends_with(".zip")
                && asset.pointer("/uploader/login").and_then(Value::as_str) == Some(owner)
        });
        if let Some(zip) = zip {
            return Ok(Source {
                url: text(zip, "browser_download_url"),
                what: format!("release {} asset {}", text(&release, "tag_name"), text(zip, "name")),
            });
        }
    }
    let tags = api(&format!("repos/{repo}/tags?per_page=1"))?;
    if let Some(tag) = tags.as_array().and_then(|tags| tags.first()) {
        let name = text(tag, "name");
        return Ok(Source {
            url: format!("https://api.github.com/repos/{repo}/zipball/{name}"),
            what: format!("source of tag {name}"),
        });
    }
    Ok(Source {
        url: format!("https://api.github.com/repos/{repo}/zipball"),
        what: "the default branch (no release or tag: unreleased code)".into(),
    })
}

fn data_dir() -> io::Result<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA").ok_or_else(|| io::Error::other("no LOCALAPPDATA"))?;
    let dir = PathBuf::from(base).join("wow-companion");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn ledger_path() -> io::Result<PathBuf> {
    Ok(data_dir()?.join("addons.json"))
}

fn ledger() -> io::Result<Vec<Value>> {
    match fs::read(ledger_path()?) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(err) => Err(err),
    }
}

fn save_ledger(entries: &[Value]) -> io::Result<()> {
    fs::write(ledger_path()?, serde_json::to_vec_pretty(entries)?)
}

fn stamp() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Every .toc under `root`, keyed by the addon folder name it implies.
fn find_tocs(root: &Path, found: &mut Vec<(PathBuf, String)>) -> io::Result<()> {
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            find_tocs(&path, found)?;
        } else if path.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref() == Some("toc") {
            let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
            let lowered = stem.to_lowercase();
            let name = TOC_FLAVOURS
                .iter()
                .find_map(|suffix| lowered.strip_suffix(suffix).map(|kept| stem[..kept.len()].to_string()))
                .unwrap_or(stem);
            found.push((path.parent().unwrap_or(root).to_path_buf(), name));
        }
    }
    Ok(())
}

fn package_like_a_release(dir: &Path) -> io::Result<()> {
    let ignored: Vec<String> = fs::read_to_string(dir.join(".pkgmeta"))
        .map(|meta| {
            let mut listing = false;
            let mut out = Vec::new();
            for line in meta.lines() {
                let trimmed = line.trim();
                let indented = line.starts_with(' ') || line.starts_with('\t') || line.starts_with('-');
                if !indented {
                    listing = trimmed == "ignore:";
                    continue;
                }
                if listing {
                    if let Some(item) = trimmed.strip_prefix("- ") {
                        out.push(item.trim().trim_matches(['"', '\'']).to_string());
                    }
                }
            }
            out
        })
        .unwrap_or_default();
    for item in ignored {
        // only paths inside this folder: an ignore entry is not a way out of it
        if item.contains("..") || item.starts_with(['/', '\\']) {
            continue;
        }
        let path = dir.join(&item);
        if path.is_dir() {
            fs::remove_dir_all(&path)?;
        } else if path.is_file() {
            fs::remove_file(&path)?;
        }
    }
    strip_dotfiles(dir)
}

fn strip_dotfiles(dir: &Path) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_name().to_string_lossy().starts_with('.') {
            if entry.file_type()?.is_dir() {
                fs::remove_dir_all(&path)?;
            } else {
                fs::remove_file(&path)?;
            }
        } else if entry.file_type()?.is_dir() {
            strip_dotfiles(&path)?;
        }
    }
    Ok(())
}

fn check_files(dir: &Path, bad: &mut Vec<String>) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            bad.push(format!("{} is a link", path.display()));
        } else if kind.is_dir() {
            check_files(&path, bad)?;
        } else {
            let name = entry.file_name().to_string_lossy().to_lowercase();
            let ext = path.extension().and_then(|e| e.to_str()).map(str::to_lowercase);
            let fine = match ext {
                Some(ext) => ALLOWED.contains(&ext.as_str()),
                // LICENSE, NOTICE, README: plain text without an extension
                None => !name.contains('.'),
            };
            if !fine {
                bad.push(path.display().to_string());
            }
        }
    }
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

/// Download, vet the files, back up what it replaces, and put it in AddOns.
/// Returns what happened, including whether the game needs a full restart.
pub fn install(addons: &Path, repo: &str) -> io::Result<String> {
    let info = api(&format!("repos/{repo}"))?;
    let owner = info.pointer("/owner/login").and_then(Value::as_str).unwrap_or("?").to_string();
    let from = source(repo, &owner)?;

    let staging = data_dir()?.join("staging").join(stamp().to_string());
    fs::create_dir_all(&staging)?;
    let zip = staging.join("download.zip");
    fs::write(&zip, get(&from.url)?)?;
    let unpacked = staging.join("unpacked");
    fs::create_dir_all(&unpacked)?;
    // Windows' bsdtar reads zips, and by default refuses absolute paths and ".."
    // entries, which is the classic way an archive writes outside its folder
    let status = Command::new("tar").arg("-xf").arg(&zip).arg("-C").arg(&unpacked).status()?;
    if !status.success() {
        return Err(io::Error::other("could not unpack the download"));
    }

    let mut tocs = Vec::new();
    find_tocs(&unpacked, &mut tocs)?;
    // the shallowest toc per folder is the addon; tocs inside it are its libraries
    tocs.sort_by_key(|(dir, _)| dir.components().count());
    let mut chosen: Vec<(PathBuf, String)> = Vec::new();
    for (dir, name) in tocs {
        if chosen.iter().any(|(kept, _)| dir.starts_with(kept)) {
            continue;
        }
        chosen.push((dir, name));
    }
    if chosen.is_empty() {
        return Err(io::Error::other("the download holds no .toc, so it is not an addon"));
    }
    // what the addon's own packager would leave out of a release: dotfiles, and
    // whatever .pkgmeta lists under ignore. A source install has to do the same
    for (dir, _) in &chosen {
        package_like_a_release(dir)?;
    }
    let mut bad = Vec::new();
    for (dir, _) in &chosen {
        check_files(dir, &mut bad)?;
    }
    if !bad.is_empty() {
        bad.truncate(8);
        return Err(io::Error::other(format!(
            "refused: files an addon has no reason to ship: {}",
            bad.join(", ")
        )));
    }

    let backups = data_dir()?.join("backups");
    let mut installed = Vec::new();
    let mut new_folders = false;
    for (dir, name) in &chosen {
        if name.is_empty() || name.contains(['/', '\\', '.']) || name.eq_ignore_ascii_case("WowCompanion") {
            return Err(io::Error::other(format!("refused: unusable addon name {name:?}")));
        }
        let target = addons.join(name);
        if target.exists() {
            let kept = backups.join(format!("{name}-{}", stamp()));
            fs::create_dir_all(&backups)?;
            fs::rename(&target, &kept)?;
        } else {
            new_folders = true;
        }
        copy_dir(dir, &target)?;
        installed.push(name.clone());
    }
    let _ = fs::remove_dir_all(&staging);

    let mut entries = ledger()?;
    entries.retain(|entry| entry.get("repo").and_then(Value::as_str) != Some(repo));
    entries.push(json!({
        "repo": repo,
        "from": from.what,
        "url": from.url,
        "folders": installed,
        "installed": stamp(),
    }));
    save_ledger(&entries)?;

    Ok(format!(
        "installed {} from {repo} ({}). {}",
        installed.join(", "),
        from.what,
        if new_folders {
            "New addon folders: the game only notices them after a full restart (exit and relaunch), not a /reload."
        } else {
            "Replaced existing folders: a /reload loads the new version."
        }
    ))
}

/// What the agent installed, from the ledger; addons installed by hand are not in it.
pub fn list() -> io::Result<String> {
    let entries = ledger()?;
    if entries.is_empty() {
        return Ok("nothing installed by the companion yet".into());
    }
    Ok(entries
        .iter()
        .map(|entry| {
            format!(
                "{} from {} ({})",
                entry.get("folders").map(|f| f.to_string()).unwrap_or_default(),
                text(entry, "repo"),
                text(entry, "from")
            )
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

/// Remove an addon the companion installed, by repository or folder name. Moved
/// to backups rather than deleted, so a removal can be undone.
pub fn remove(addons: &Path, which: &str) -> io::Result<String> {
    let mut entries = ledger()?;
    let index = entries
        .iter()
        .position(|entry| {
            text(entry, "repo").eq_ignore_ascii_case(which)
                || entry
                    .get("folders")
                    .and_then(Value::as_array)
                    .is_some_and(|folders| folders.iter().any(|f| f.as_str().is_some_and(|f| f.eq_ignore_ascii_case(which))))
        })
        .ok_or_else(|| io::Error::other(format!("{which:?} was not installed by the companion; refusing to touch it")))?;
    let entry = entries.remove(index);
    let backups = data_dir()?.join("backups");
    fs::create_dir_all(&backups)?;
    let mut moved = Vec::new();
    for folder in entry.get("folders").and_then(Value::as_array).into_iter().flatten() {
        let Some(name) = folder.as_str() else { continue };
        let target = addons.join(name);
        if target.exists() {
            fs::rename(&target, backups.join(format!("{name}-removed-{}", stamp())))?;
            moved.push(name.to_string());
        }
    }
    save_ledger(&entries)?;
    Ok(format!(
        "removed {} (kept in {}); a /reload or restart drops it from the game",
        moved.join(", "),
        backups.display()
    ))
}
