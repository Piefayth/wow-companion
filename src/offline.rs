//! Conversation lines made while the game is closed (a `tell`, a request that
//! finished after logout) go straight into the addon's save file, so they are in
//! the window at the next login. The channel can't carry them: nothing reads a
//! slot with the game closed, and a login writes no save file, so the companion
//! can't tell when a fresh session starts to send them again (L1's reply was
//! lost exactly so, 2026-11-11).
//!
//! The save file is Lua the game runs at login, so a line is appended as a
//! statement after the game's own `WowCompanionDB = {...}`: it adds a `log`
//! entry and marks its conversation unread. The game rewrites the whole file in
//! its own form at the next save. Only done while Wow.exe is not running (the
//! game would overwrite it, and must not read a half-written file).

use super::*;

/// Keep a `log` message for the next login. Ok(false) when it is not a
/// conversation line (progress, board, show...), which can wait for nothing.
pub(crate) fn keep(addons: &Path, inbox: &str) -> io::Result<bool> {
    let Some(line) = Line::parse(inbox) else {
        return Ok(false);
    };
    let saved = context::saved_variables(addons).ok_or_else(|| io::Error::other("no save file to keep it in"))?;
    let mut text = fs::read_to_string(&saved)?;
    if !text.contains("WowCompanionDB") {
        return Err(io::Error::other("the save file holds no WowCompanionDB"));
    }
    if !text.ends_with('\n') {
        text.push('\n');
    }
    let at = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default();
    text.push_str(&line.statement(at));
    // whole or not at all: a half-written save would cost the player every setting
    let temporary = saved.with_extension("lua.companion");
    fs::write(&temporary, text)?;
    fs::rename(&temporary, &saved)?;
    println!("  the game is closed: kept in its save for the next login ({} line)", line.who);
    Ok(true)
}

struct Line {
    who: String,
    text: String,
    slot: Option<String>,
    /// steps came with it, which can't run with the game closed
    steps: bool,
}

impl Line {
    /// The fields of a `log` message, in any order: the job ledger puts `job`,
    /// `state` and `list` before `who` (a fixed order here dropped every job's
    /// lines, its reply too, while the game was closed, 2026-11-11).
    fn parse(inbox: &str) -> Option<Line> {
        let mut rest = inbox.strip_prefix("{ kind = \"log\"")?;
        let (mut who, mut text, mut slot, mut steps) = (None, None, None, false);
        while let Some(field) = rest.strip_prefix(", ") {
            let (key, value) = field.split_once(" = ")?;
            if !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                return None;
            }
            let after = if value.starts_with('"') {
                let (string, after) = lua_unquote(value)?;
                match key {
                    "who" => who = Some(string),
                    "text" => text = Some(string),
                    "slot" => slot = Some(string),
                    _ => {}
                }
                after
            } else {
                let end = value_end(value)?;
                &value[end..]
            };
            steps |= key == "andThen";
            rest = after;
        }
        rest.trim_start().starts_with('}').then_some(())?;
        Some(Line { who: who?, text: text?, slot, steps })
    }

    fn statement(&self, at: u64) -> String {
        let mut text = self.text.clone();
        if self.steps {
            text.push_str("\n\n(This arrived while the game was closed, so the changes it carried did not run. Ask again to apply them.)");
        }
        let slot = self.slot.as_deref().filter(|slot| !slot.is_empty());
        let mut entry = format!("at = {at}, who = {}, text = {}", lua_string(&self.who), lua_string(&text));
        if let Some(slot) = slot {
            entry.push_str(&format!(", slot = {}", lua_string(slot)));
        }
        let unread = if self.who == "you" {
            String::new()
        } else {
            format!(
                "\n  WowCompanionDB.unread = WowCompanionDB.unread or {{}}\n  WowCompanionDB.unread[{}] = true",
                lua_string(slot.unwrap_or(""))
            )
        };
        format!(
            "-- added by the companion while the game was closed\nif type(WowCompanionDB) == \"table\" then\n  WowCompanionDB.log = WowCompanionDB.log or {{}}\n  WowCompanionDB.log[#WowCompanionDB.log + 1] = {{ {entry} }}{unread}\nend\n"
        )
    }
}

/// Where a value that is not a string ends: a number, `true`, a `{ ... }` table
/// (strings inside it skipped whole), up to the `, ` or ` }` after it.
fn value_end(value: &str) -> Option<usize> {
    let bytes = value.as_bytes();
    let (mut depth, mut at) = (0usize, 0usize);
    while at < bytes.len() {
        match bytes[at] {
            b'"' => {
                let (_, after) = lua_unquote(&value[at..])?;
                at = value.len() - after.len();
                continue;
            }
            b'{' => depth += 1,
            b'}' if depth == 0 => return Some(value[..at].trim_end().len()),
            b'}' => depth -= 1,
            b',' if depth == 0 => return Some(at),
            _ => {}
        }
        at += 1;
    }
    None
}

/// A string `lua_string` wrote, and what follows it.
fn lua_unquote(text: &str) -> Option<(String, &str)> {
    let mut chars = text.strip_prefix('"')?.char_indices();
    let mut out = String::new();
    while let Some((at, character)) = chars.next() {
        match character {
            '"' => return Some((out, &text[at + 2..])),
            '\\' => match chars.next()?.1 {
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                '0' => out.push('\0'),
                other => out.push(other),
            },
            other => out.push(other),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_becomes_a_log_entry_and_marks_its_conversation_unread() {
        let inbox = requests::log_inbox_in(Some("l1"), "claude", "Built \"it\"\nC:\\x", None, Some("{ kind = \"reload\" }"));
        let line = Line::parse(&inbox).unwrap();
        assert_eq!((line.who.as_str(), line.text.as_str(), line.slot.as_deref(), line.steps), ("claude", "Built \"it\"\nC:\\x", Some("l1"), true));
        let statement = line.statement(1_700_000_000);
        assert!(statement.contains("WowCompanionDB.log[#WowCompanionDB.log + 1] = { at = 1700000000, who = \"claude\", text = \"Built \\\"it\\\"\\nC:\\\\x"));
        assert!(statement.contains("did not run"));
        assert!(statement.contains("WowCompanionDB.unread[\"l1\"] = true"));
    }

    #[test]
    fn the_main_conversation_and_what_you_said() {
        let line = Line::parse(&requests::log_inbox_in(None, "you", "hello", None, None)).unwrap();
        let statement = line.statement(1);
        assert!(!statement.contains("slot ="));
        assert!(!statement.contains("unread"));
    }

    #[test]
    fn a_job_line_is_kept_whatever_comes_before_who() {
        let reply = requests::log_inbox_in(Some("l1"), "claude", "Done, reload", None, None).replacen(
            "{ kind = \"log\"",
            "{ kind = \"log\", job = 1794363312223, req = 1794363312223, state = \"answered\", list = { { job = 1794363312223, slot = \"l1\", state = \"answered\" } }",
            1,
        );
        let line = Line::parse(&reply).unwrap();
        assert_eq!((line.who.as_str(), line.text.as_str(), line.slot.as_deref()), ("claude", "Done, reload", Some("l1")));
        let queued = requests::log_inbox_in(Some("l1"), "you", "a, \"b\" = c }", None, None)
            .replacen("{ kind = \"log\"", "{ kind = \"log\", queued = true, job = 7, state = \"queued\"", 1);
        let line = Line::parse(&queued).unwrap();
        assert_eq!((line.who.as_str(), line.text.as_str()), ("you", "a, \"b\" = c }"));
    }

    #[test]
    fn status_messages_are_not_kept() {
        assert!(Line::parse("{ kind = \"progress\", text = \"x\" }").is_none());
        assert!(Line::parse("{ kind = \"board\", resync = true, working = {  } }").is_none());
    }
}
