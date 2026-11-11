//! The game's SavedVariables, read as values: the one reader of the save file
//! (the ledger's confirmations, the bridge probe's report).

/// The table assigned to `global` in a save file's text (`WowCompanionDB = {...}`).
pub(crate) fn global(text: &str, global: &str) -> Option<Lua> {
    let opener = format!("{global} = ");
    let at = text.find(&opener)? + opener.len();
    Lua::parse(&text[at..]).ok().map(|(value, _)| value)
}

/// A value as the game writes SavedVariables: strings, numbers, booleans, nil,
/// and tables of `["key"] = value`, `[n] = value` and bare list entries
/// (`value, -- [n]`).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Lua {
    Text(String),
    Number(f64),
    Bool(bool),
    Nil,
    Table(Vec<(Option<Lua>, Lua)>),
}

impl Lua {
    /// One value from the start of `text`, and what follows it.
    pub(crate) fn parse(text: &str) -> Result<(Lua, &str), String> {
        let text = skip(text);
        let mut chars = text.chars();
        match chars.next() {
            Some('{') => {
                let mut rest = skip(&text[1..]);
                let mut entries = Vec::new();
                while !rest.starts_with('}') {
                    if rest.is_empty() {
                        return Err("a table is not closed".into());
                    }
                    let (key, after_key) = if let Some(inner) = rest.strip_prefix('[') {
                        let (key, after) = Lua::parse(inner)?;
                        let after = skip(after).strip_prefix(']').ok_or("a key is not closed")?;
                        let after = skip(after).strip_prefix('=').ok_or("a key has no value")?;
                        (Some(key), after)
                    } else {
                        (None, rest)
                    };
                    let (value, after) = Lua::parse(after_key)?;
                    entries.push((key, value));
                    rest = skip(after);
                    if let Some(after_comma) = rest.strip_prefix(',').or_else(|| rest.strip_prefix(';')) {
                        rest = skip(after_comma);
                    }
                }
                Ok((Lua::Table(entries), &rest[1..]))
            }
            Some('"') => {
                let mut out = String::new();
                let mut iter = text[1..].char_indices();
                while let Some((at, c)) = iter.next() {
                    match c {
                        '"' => return Ok((Lua::Text(out), &text[1 + at + 1..])),
                        '\\' => match iter.next().map(|(_, c)| c) {
                            Some('n') => out.push('\n'),
                            Some('r') => out.push('\r'),
                            Some('t') => out.push('\t'),
                            Some(other) => out.push(other),
                            None => break,
                        },
                        other => out.push(other),
                    }
                }
                Err("a string is not closed".into())
            }
            _ => {
                let end = text.find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace()).unwrap_or(text.len());
                let word = &text[..end];
                let value = match word {
                    "true" => Lua::Bool(true),
                    "false" => Lua::Bool(false),
                    "nil" => Lua::Nil,
                    number => Lua::Number(number.parse().map_err(|_| format!("not a value: {number:?}"))?),
                };
                Ok((value, &text[end..]))
            }
        }
    }

    pub(crate) fn get(&self, key: &str) -> Option<&Lua> {
        match self {
            Lua::Table(entries) => entries.iter().find(|(k, _)| k.as_ref() == Some(&Lua::Text(key.into()))).map(|(_, v)| v),
            _ => None,
        }
    }

    /// Every `[key] = value` of a table (bare list entries have no key).
    pub(crate) fn entries(&self) -> &[(Option<Lua>, Lua)] {
        match self {
            Lua::Table(entries) => entries,
            _ => &[],
        }
    }

    pub(crate) fn number(&self) -> Option<f64> {
        if let Lua::Number(n) = self { Some(*n) } else { None }
    }

    pub(crate) fn text(&self) -> String {
        match self {
            Lua::Text(text) => text.clone(),
            Lua::Number(n) if n.fract() == 0.0 && n.abs() < 1e15 => format!("{}", *n as i64),
            Lua::Number(n) => format!("{n:.3}"),
            Lua::Bool(b) => b.to_string(),
            Lua::Nil => "nil".into(),
            Lua::Table(_) => "{...}".into(),
        }
    }

    pub(crate) fn text_of(&self, key: &str) -> String {
        self.get(key).map(Lua::text).unwrap_or_else(|| "?".into())
    }
}

/// Whitespace and `--` comments skipped.
pub(crate) fn skip(mut text: &str) -> &str {
    loop {
        text = text.trim_start();
        if let Some(comment) = text.strip_prefix("--") {
            text = comment.find('\n').map_or("", |at| &comment[at..]);
        } else {
            return text;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_games_saved_table_is_read() {
        let saved = "{\n[\"log\"] = {\n{\n[\"seq\"] = 1,\n[\"ok\"] = true,\n[\"via\"] = \"LogMessage\",\n[\"result\"] = \"nil\",\n}, -- [1]\n},\n[\"font\"] = {\n{\n[\"n\"] = 2,\n[\"widths\"] = {\n12.5, -- [1]\n-3, -- [2]\n1e-05, -- [3]\n},\n[\"chars\"] = \"AB\\\"C\",\n},\n},\n[1794357313662] = {\n},\n}\n";
        let (value, rest) = Lua::parse(saved).unwrap();
        assert_eq!(rest.trim(), "");
        // bare list entries have no key
        let first = |table: &Lua| table.entries().iter().find(|(key, _)| key.is_none()).map(|(_, value)| value.clone()).unwrap();
        let log = first(value.get("log").unwrap());
        assert_eq!((log.text_of("seq"), log.text_of("ok"), log.text_of("via")), ("1".into(), "true".into(), "LogMessage".into()));
        let font = first(value.get("font").unwrap());
        assert_eq!(font.text_of("chars"), "AB\"C");
        let widths: Vec<f64> = font.get("widths").unwrap().entries().iter().filter_map(|(_, v)| v.number()).collect();
        assert_eq!(widths, vec![12.5, -3.0, 1e-05]);
    }

    #[test]
    fn a_global_is_found_in_the_file() {
        let save = "\nWowCompanionDB = {\n[\"lines\"] = {\n[\"\"] = 4,\n[\"l1\"] = 2,\n},\n}\nOtherDB = nil\n";
        let db = global(save, "WowCompanionDB").unwrap();
        let lines = db.get("lines").unwrap();
        assert_eq!(lines.get("").and_then(Lua::number), Some(4.0));
        assert_eq!(lines.get("l1").and_then(Lua::number), Some(2.0));
        assert!(global(save, "Missing").is_none());
    }
}
