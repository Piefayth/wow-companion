//! What the agent is given: the saved export, its sections, the player
//! profile and the integrations.

use super::*;

/// The PC bridge's addon: its Signals (bells), the slot cursor, and its saved
/// table (`WowCompanionLinkDB`: slotCount, channel, loads).
pub(crate) const LINK: &str = "WowCompanion_Link";
/// The agent's addon: its saved table (`WowCompanionAgentDB`: the export,
/// lines, jobModel, links) and the generated Modules.lua.
pub(crate) const AGENT: &str = "WowCompanion_Agent";

/// An addon's save file, as text.
pub(crate) fn saved_variables_text(addons: &Path, addon: &str) -> Option<String> {
    fs::read_to_string(saved_variables(addons, addon)?).ok()
}

/// `context <AddOns> <out>`: one string of the Agent addon's save (the export,
/// `context`) into a plain text file.
pub(crate) fn pull(addons: &Path, key: &str, out: &Path) -> io::Result<()> {
    let body = saved_string(addons, key)?;
    let kept = body.lines().filter(|line| !line.starts_with("--")).count();
    fs::write(out, &body)?;
    println!("wrote {kept} lines ({} bytes) to {}", body.len(), out.display());
    Ok(())
}

pub(crate) fn saved_string(addons: &Path, key: &str) -> io::Result<String> {
    let saved = saved_variables(addons, AGENT)
        .ok_or_else(|| io::Error::other("no SavedVariables yet: /reload in game first"))?;
    let db = crate::savedvars::global(&fs::read_to_string(&saved)?, "WowCompanionAgentDB")
        .ok_or_else(|| io::Error::other(format!("{} does not parse (the game may be writing it)", saved.display())))?;
    match db.get(key) {
        Some(crate::savedvars::Lua::Text(text)) => Ok(text.clone()),
        _ => Err(io::Error::other(format!("no {key} in SavedVariables: /reload in game first"))),
    }
}

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
pub(crate) const QUICK_SECTIONS: &[&str] = &["character", "bags", "bag contents", "skills", "macros", "capabilities", "blocked"];

pub(crate) fn agent_context(addons: &Path) -> Option<String> {
    agent_context_for(addons, "")
}

pub(crate) fn agent_context_for(addons: &Path, slot: &str) -> Option<String> {
    let context = saved_string(addons, "context").ok()?;
    let stamp = context.lines().next().unwrap_or_default();
    let mut out = vec![stamp.to_string()];
    // every section the export writes is the agent's (Export.lua decides); the
    // quick conversation takes its few
    if slot == agent::QUICK_SLOT {
        for (name, lines) in sections(&context, QUICK_SECTIONS) {
            out.push(format!("== {name} =="));
            out.extend(lines.iter().map(|line| line.to_string()));
        }
    } else {
        out.extend(context.lines().skip(1).filter(|line| !line.trim().is_empty()).map(str::to_string));
    }
    out.push("== lua errors ==".to_string());
    out.push(lua_errors(addons));
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

/// Every Lua error since the game launched, from the game's own log: Blizzard's
/// error handler writes each one to `Logs\General.log` through `C_Log` as it
/// happens (Blizzard_ScriptErrors), and the game starts that file afresh at each
/// launch. So this is live, needs no reload, and holds errors no addon could
/// catch: those from save files and addons loaded before ours. Repeats are
/// counted, newest last.
pub(crate) fn lua_errors(addons: &Path) -> String {
    let log = addons.parent().and_then(Path::parent).map(|client| client.join("Logs").join("General.log"));
    let Some(text) = log.and_then(|log| fs::read(log).ok()) else {
        return r"(the game's log, Logs\General.log, could not be read)".to_string();
    };
    errors_in(&String::from_utf8_lossy(&text))
}

/// The error handler's lines of a General.log (`[E][Lua] Lua Error: `; other
/// `C_Log` lines share the tag), each message once
/// with its count and its last time, the newest ten.
fn errors_in(log: &str) -> String {
    let mut seen: Vec<(String, String, usize)> = Vec::new();
    for line in log.lines() {
        let Some((stamp, message)) = line.split_once("  [E][Lua] Lua Error: ") else { continue };
        let message = message.trim().to_string();
        match seen.iter().position(|(_, m, _)| *m == message) {
            Some(at) => {
                let (_, m, n) = seen.remove(at);
                seen.push((stamp.to_string(), m, n + 1));
            }
            None => seen.push((stamp.to_string(), message, 1)),
        }
    }
    if seen.is_empty() {
        return "none since the game launched".to_string();
    }
    let skip = seen.len().saturating_sub(10);
    seen[skip..].iter().map(|(stamp, message, n)| format!("{stamp} x{n}: {message}")).collect::<Vec<_>>().join("
")
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

/// An addon's account-wide save file (`<addon>.lua`), the newest across accounts.
pub(crate) fn saved_variables(addons: &Path, addon: &str) -> Option<PathBuf> {
    let accounts = addons.parent()?.parent()?.join("WTF").join("Account");
    let mut newest: Option<(u128, PathBuf)> = None;
    for account in fs::read_dir(accounts).ok()?.flatten() {
        let saved = account.path().join("SavedVariables").join(format!("{addon}.lua"));
        if let Some(at) = modified_millis(&saved) {
            if newest.as_ref().is_none_or(|(best, _)| at > *best) {
                newest = Some((at, saved));
            }
        }
    }
    newest.map(|(_, path)| path)
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

#[cfg(test)]
mod lua_error_tests {
    use super::errors_in;

    #[test]
    fn counts_repeats_and_keeps_only_lua_errors() {
        let log = "11/11 00:27:04.716  [N][AccountData] PreLoadGameCVars
11/11 00:27:11.222  [E][Lua] Lua Error: WowCompanion.lua:10924: attempt to call a nil value

11/11 00:29:00.000  [E][Lua] a line an addon logged, not an error
11/11 00:30:00.000  [E][Lua] Lua Error: Bags.lua:5: boom
11/11 00:31:00.000  [E][Lua] Lua Error: WowCompanion.lua:10924: attempt to call a nil value
";
        assert_eq!(
            errors_in(log),
            "11/11 00:30:00.000 x1: Bags.lua:5: boom
11/11 00:31:00.000 x2: WowCompanion.lua:10924: attempt to call a nil value"
        );
        assert_eq!(errors_in("11/11 00:00:00.000  [N][Lua] fine
"), "none since the game launched");
    }
}
