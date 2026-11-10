//! What the agent is given: the saved export, its sections, the player
//! profile and the integrations.

use super::*;

/// The addon's save file, as text.
pub(crate) fn saved_variables_text(addons: &Path) -> Option<String> {
    let accounts = addons.parent()?.parent()?.join("WTF").join("Account");
    let mut newest: Option<(u128, PathBuf)> = None;
    for account in fs::read_dir(accounts).ok()?.flatten() {
        let saved = account.path().join("SavedVariables").join(format!("{ADDON}.lua"));
        if let Some(millis) = modified_millis(&saved) {
            if newest.as_ref().is_none_or(|(best, _)| millis > *best) {
                newest = Some((millis, saved));
            }
        }
    }
    fs::read_to_string(newest?.1).ok()
}

/// Lift the API dump out of SavedVariables into a plain text file.
///
/// This build ships no API documentation tables, so there are no signatures to be
/// had locally — but the names are exact for 1.60.1, which is the half the agent
/// cannot get from training data. Knowing a function exists *here* is the question
/// it otherwise answers from retail and gets wrong.
pub(crate) fn pull(addons: &Path, key: &str, out: &Path) -> io::Result<()> {
    let body = saved_string(addons, key)?;
    let kept = body.lines().filter(|line| !line.starts_with("--")).count();
    fs::write(out, &body)?;
    println!("wrote {kept} lines ({} bytes) to {}", body.len(), out.display());
    Ok(())
}

pub(crate) fn saved_string(addons: &Path, key: &str) -> io::Result<String> {
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
pub(crate) const AGENT_SECTIONS: &[&str] =
    &["character", "equipped", "bags", "bag contents", "skills", "quest log", "action slots", "empty slots on screen", "controller", "macros", "spellbook", "reach", "modules", "capabilities", "code runs", "lua errors"];

pub(crate) fn sections<'a>(context: &'a str, wanted: &[&str]) -> Vec<(&'a str, Vec<&'a str>)> {
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

/// The quick conversation's export: what chat, links and buttons need, so the
/// prompt is a fraction of the size and the answer comes sooner.
pub(crate) const QUICK_SECTIONS: &[&str] = &["character", "bags", "bag contents", "skills", "macros", "capabilities", "lua errors"];

pub(crate) fn agent_context(addons: &Path) -> Option<String> {
    agent_context_for(addons, "")
}

pub(crate) fn agent_context_for(addons: &Path, slot: &str) -> Option<String> {
    let context = saved_string(addons, "context").ok()?;
    let stamp = context.lines().next().unwrap_or_default();
    let mut out = vec![stamp.to_string()];
    let wanted = if slot == agent::QUICK_SLOT { QUICK_SECTIONS } else { AGENT_SECTIONS };
    for (name, lines) in sections(&context, wanted) {
        out.push(format!("== {name} =="));
        out.extend(lines.iter().map(|line| line.to_string()));
    }
    out.push("== player profile ==".to_string());
    out.push(
        fs::read_to_string(profile())
            .unwrap_or_else(|_| "(none yet: player/profile.md does not exist)".to_string()),
    );
    out.push("== integrations ==".to_string());
    out.push(integrations(addons));
    Some(out.join("
"))
}

/// The notes in integrations/<folder>.md for each addon whose folder is in the
/// AddOns folder now (read from disk, so an install counts before any reload).
/// Other players have other addons: the agent is told only about the ones present.
pub(crate) fn integrations(addons: &Path) -> String {
    let notes = crate::home().join("integrations");
    let mut present = Vec::new();
    let mut absent = Vec::new();
    for entry in fs::read_dir(&notes).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|ext| ext != "md") {
            continue;
        }
        let folder = path.file_stem().unwrap_or_default().to_string_lossy().into_owned();
        if addons.join(&folder).join(format!("{folder}.toc")).exists() {
            present.push(fs::read_to_string(&path).unwrap_or_default());
        } else {
            absent.push(folder);
        }
    }
    if present.is_empty() {
        present.push("none installed".to_string());
    }
    if !absent.is_empty() {
        present.push(format!("Not installed: {} (do not call them).", absent.join(", ")));
    }
    present.join("\n")
}

/// Spell and macro names, for Whisper's prompt: the words this player will say and
/// a general model will misspell. Unique, in spellbook order.
pub(crate) fn vocabulary(addons: &Path) -> Vec<String> {
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

pub(crate) fn saved_variables(addons: &Path) -> Option<PathBuf> {
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

/// Whether a request is about chat or links, so it is worth a live look first.
pub(crate) fn wants_chat(spoken: &str) -> bool {
    let lower = spoken.to_lowercase();
    ["link", "chat", "trade", "general", "said", "says", "saying", "talking", "whisper", "posted", "channel", "guild"]
        .iter()
        .any(|word| lower.contains(word))
}

/// Recent chat and caught profession links, read live (the player, 2026-11-10):
/// the game draws them as the data strip (`WCChatStrip`, modules/LinkCatcher.lua)
/// and we read the corner. The chat log file is only written at logout, so this
/// is the one live way out. A few seconds at most; None when it cannot be read
/// (combat, no game), and the request goes ahead without it.
pub(crate) fn live_chat(addons: &Path) -> Option<String> {
    if !channel::game_running().unwrap_or(false) {
        return None;
    }
    let out = std::env::temp_dir().join(format!("wc_chat_{}.txt", std::process::id()));
    let _ = fs::remove_file(&out);
    channel::send_inbox(addons, "{ kind = \"lua\", code = \"if WCChatStrip then WCChatStrip() end\" }").ok()?;
    let status = std::process::Command::new("python")
        .args(["-I", &crate::home().join("tools").join("strip.py").to_string_lossy(), "--watch", "5"])
        .arg(&out)
        .status()
        .ok()?;
    let text = fs::read_to_string(&out).ok()?;
    let _ = fs::remove_file(&out);
    (status.success() && !text.starts_with("STRIP FAILED")).then_some(text)
}

/// The player's profile. A release ships only `profile.template.md`, so unzipping
/// an update over an install never overwrites what the agent wrote: the profile
/// is made from the template the first time it is wanted.
pub(crate) fn profile() -> PathBuf {
    let dir = crate::home().join("player");
    let path = dir.join("profile.md");
    if !path.exists() {
        let _ = fs::copy(dir.join("profile.template.md"), &path);
    }
    path
}
