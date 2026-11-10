//! Whisper: the prompt, a clip's transcription, and its echoes and phantoms.

use super::*;

pub(crate) const WHISPER_RATE: u32 = 16_000;
// below this there is no speech, just the click of the chord being released
pub(crate) const MINIMUM_CLIP: Duration = Duration::from_millis(250);
// Whisper has never heard of Hearthstone or Shadowstep and will cheerfully write
// "fire ball". Seeding the decoder with the vocabulary fixes most of it.
pub(crate) const COMMANDS: &str = "Commands: macro, action bar, slot, bind, chat, whisper, party, raid, guild.";
// used until the game has exported a spellbook to take names from
pub(crate) const FALLBACK_SPELLS: &[&str] = &["Hearthstone", "Rejuvenation", "Moonfire", "Bear Form"];
// Whisper keeps only the last ~224 tokens of a prompt; stay well inside that, or
// the cut falls on the spell names, which are the point
pub(crate) const PROMPT_CHARS: usize = 700;
// Whisper fills silence with the endings of the videos it was trained on. These only
// count as heard when the clip had real sound in it.
pub(crate) const PHANTOMS: &[&str] = &["thank you", "thanks for watching", "you", "bye", "thank you for watching"];
pub(crate) fn prompt(spells: &[String]) -> String {
    let mut prompt = String::from("World of Warcraft. Spells and macros: ");
    let names: Vec<&str> = if spells.is_empty() {
        FALLBACK_SPELLS.to_vec()
    } else {
        spells.iter().map(String::as_str).collect()
    };
    let room = PROMPT_CHARS - COMMANDS.len();
    let mut first = true;
    for name in names {
        if prompt.len() + name.len() + 2 > room {
            break;
        }
        if !first {
            prompt.push_str(", ");
        }
        prompt.push_str(name);
        first = false;
    }
    prompt.push_str(". ");
    prompt.push_str(COMMANDS);
    prompt
}

pub(crate) fn without_echo(text: &str) -> String {
    let mut rest = text.trim();
    loop {
        let lowered = rest.to_lowercase();
        let cut = ["commands:", "world of warcraft.", "spells and macros:"]
            .iter()
            .find_map(|echo| lowered.starts_with(echo).then_some(echo.len()));
        match cut {
            Some(len) => rest = rest[len..].trim_start_matches(|c: char| c.is_whitespace() || c == ','),
            None => break,
        }
    }
    // an echo can carry the prompt's own spell list or command words after it
    if rest.to_lowercase().starts_with("macro, action bar, slot") {
        return String::new();
    }
    rest.trim().to_string()
}

pub(crate) fn phantom(text: &str) -> bool {
    let plain: String = text
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    PHANTOMS.contains(&plain.trim())
}

/// A clip for the Whisper thread, and what it made of one.
pub(crate) struct Job {
    pub(crate) role: String,
    pub(crate) clip: Vec<f32>,
    pub(crate) prompt: String,
    pub(crate) level: f32,
    pub(crate) seconds: f32,
}
pub(crate) struct Done {
    pub(crate) role: String,
    pub(crate) level: f32,
    pub(crate) seconds: f32,
    pub(crate) result: io::Result<String>,
}

pub(crate) fn transcribe(whisper: &WhisperContext, clip: &[f32], prompt: &str) -> io::Result<String> {
    let mut state = whisper
        .create_state()
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("en"));
    params.set_initial_prompt(prompt);
    params.set_translate(false);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    state
        .full(params, clip)
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let mut text = String::new();
    for segment in state.as_iter() {
        text.push_str(&segment.to_string());
    }
    Ok(text.trim().to_string())
}
