//! Spoken chat lines: channel words, discards, the dictation inbox.

use crate::message::Msg;

// Spoken channel names, and the slash command each stands for. Whisper will never
// write "/p", and a controller cannot type it, so a clip that opens with "party"
// (or "to party", or "slash p") becomes "/p ..." -- which the chat box routes when
// the player presses send, exactly as if they had typed it. Whispering a player is
// not here: names are first and last on this client and the spoken boundary of a
// name is a guess (ask the agent instead).
pub(crate) const CHANNELS: &[(&str, &str)] = &[
    ("party", "/p"),
    ("group", "/p"),
    ("guild", "/g"),
    ("officer", "/o"),
    ("raid", "/raid"),
    ("raid warning", "/rw"),
    ("instance", "/i"),
    ("say", "/s"),
    ("yell", "/y"),
    ("reply", "/r"),
    ("emote", "/e"),
    // the numbered public channels, by the names they have in every zone
    ("general", "/1"),
    ("trade", "/2"),
    ("looking for group", "/4"),
    // the addon finds who the name means (friends, guild, group) and writes
    // it the way the game needs it, surname and all
    ("whisper", "/w"),
    ("tell", "/w"),
];

/// The whole clip is a request to throw the line away. Whole clip only: "cancel
/// the pull" is a message.
pub(crate) fn discards(text: &str) -> bool {
    let plain: String = text
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    matches!(
        plain.trim(),
        "clear" | "clear chat" | "clear that" | "cancel" | "cancel that" | "never mind"
            | "nevermind" | "scratch that" | "delete that" | "erase that"
    )
}

/// "Party, on my way." -> "/p on my way." Only the opening words count, so a
/// sentence that merely mentions the guild goes out unchanged.
pub(crate) fn channeled(text: &str) -> String {
    let trimmed = text.trim();
    let lowered = trimmed.to_lowercase();
    let mut rest_at = 0;
    let mut spoken = lowered.as_str();
    for lead in ["to ", "in ", "on "] {
        if let Some(after) = spoken.strip_prefix(lead) {
            rest_at += lead.len();
            spoken = after;
            break;
        }
    }
    // "slash p hello" -> "/p hello"; Whisper spells the shortcut out when it is said
    let mut found: Option<(String, usize)> = None;
    if let Some(after) = spoken.strip_prefix("slash ") {
        let word: String = after.chars().take_while(|c| c.is_alphanumeric()).collect();
        if !word.is_empty() && word.len() <= 5 {
            found = Some((format!("/{word}"), "slash ".len() + word.len()));
        }
    }
    if found.is_none() {
        // longest first, so "raid warning" is not read as "raid"
        let mut channels: Vec<&(&str, &str)> = CHANNELS.iter().collect();
        channels.sort_by_key(|(word, _)| std::cmp::Reverse(word.len()));
        for (word, slash) in channels {
            if let Some(after) = spoken.strip_prefix(word) {
                // the word must end there: "partying" is not "party"
                if after.is_empty() || after.starts_with(|c: char| !c.is_alphanumeric()) {
                    found = Some((slash.to_string(), word.len()));
                    break;
                }
            }
        }
    }
    let Some((slash, used)) = found else {
        return trimmed.to_string();
    };
    let message = trimmed[rest_at + used..]
        .trim_start_matches(|c: char| c == ',' || c == ':' || c == '.' || c == '-' || c.is_whitespace());
    if message.is_empty() {
        // "party." alone is more likely a word than a command with nothing to say
        return trimmed.to_string();
    }
    format!("{slash} {message}")
}

/// Dictation: `text` as chat should get it (a channel turned into its slash
/// command), `raw` as it was said, for any other text box the player is in.
pub(crate) fn dictation_inbox(raw: &str, routed: &str) -> Msg {
    Msg::new("chat").text("text", routed).text("raw", raw.trim())
}

/// Dictation from the L1+R1 chord: for the chat box, never the agent. `wheel`
/// asks the addon to put the chat wheel's channel on a line that names none.
pub(crate) fn say_inbox(raw: &str, routed: &str) -> Msg {
    Msg::new("chat").text("text", routed).text("raw", raw.trim()).flag("wheel", routed == raw.trim())
}

pub(crate) fn chat_inbox(text: &str) -> Msg {
    Msg::new("chat").text("text", text)
}
