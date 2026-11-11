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
    pub(crate) slot: crate::Slot,
    pub(crate) clip: Vec<f32>,
    pub(crate) prompt: String,
    pub(crate) level: f32,
    pub(crate) seconds: f32,
}
pub(crate) struct Done {
    pub(crate) slot: crate::Slot,
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

/// `wow-companion transcribe <model> <clip.wav>`: Whisper on a recorded clip,
/// timed, with no mic, pad or game. How a build is checked on a new machine (the
/// setup window's self-test) and how backends are compared on the same clip:
/// ggml prints which device it loaded (a Vulkan or CUDA GPU, or the CPU).
pub fn transcribe_file(model: &std::path::Path, wav: &std::path::Path) -> io::Result<()> {
    let (samples, channels, rate) = read_wav(&std::fs::read(wav)?)?;
    let clip = crate::mic::to_whisper(&samples, channels, rate);
    let path = model.to_str().ok_or_else(|| io::Error::other("model path isn't UTF-8"))?;
    let loading = std::time::Instant::now();
    let whisper = WhisperContext::new_with_params(path, WhisperContextParameters::default())
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let loaded = loading.elapsed();
    let started = std::time::Instant::now();
    let text = transcribe(&whisper, &clip, &prompt(&[]))?;
    let took = started.elapsed();
    println!("model loaded in {:.2}s", loaded.as_secs_f32());
    let audio = clip.len() as f32 / WHISPER_RATE as f32;
    println!("{audio:.1}s of audio transcribed in {:.2}s", took.as_secs_f32());
    println!("text: {}", text.trim());
    // the last line, for the setup window: the result as JSON
    println!(
        "{}",
        serde_json::json!({ "engine": "whisper", "text": text.trim(), "audio_seconds": audio, "took_ms": took.as_millis() as u64, "device": whisper_device() })
    );
    Ok(())
}

/// The device Whisper runs on, as whisper.cpp chooses it (`use_gpu` on, device
/// 0): the first GPU ggml has registered, if it starts (whisper.cpp falls back
/// to the CPU when it does not). None is the CPU.
fn whisper_device() -> Option<String> {
    use std::ffi::CStr;
    use whisper_rs::whisper_rs_sys as ggml;
    // SAFETY: ggml's registry calls; every pointer is checked before it is read,
    // and the backend started here is freed before returning
    unsafe {
        let device = ggml::ggml_backend_dev_by_type(ggml::ggml_backend_dev_type_GGML_BACKEND_DEVICE_TYPE_GPU);
        if device.is_null() {
            return None;
        }
        let backend = ggml::ggml_backend_dev_init(device, std::ptr::null());
        if backend.is_null() {
            return None;
        }
        ggml::ggml_backend_free(backend);
        let text = |ptr: *const std::os::raw::c_char| if ptr.is_null() { String::new() } else { CStr::from_ptr(ptr).to_string_lossy().into_owned() };
        Some(format!("{} ({})", text(ggml::ggml_backend_dev_name(device)), text(ggml::ggml_backend_dev_description(device))))
    }
}

/// A WAV file's samples as f32, with its channel count and rate: 16-bit PCM or
/// 32-bit float, the two formats anything records.
pub(crate) fn read_wav(bytes: &[u8]) -> io::Result<(Vec<f32>, u16, u32)> {
    let bad = |why: &str| io::Error::other(format!("not a usable WAV: {why}"));
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(bad("no RIFF/WAVE header"));
    }
    let u16_at = |at: usize| u16::from_le_bytes([bytes[at], bytes[at + 1]]);
    let u32_at = |at: usize| u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]);
    let (mut format, mut channels, mut rate, mut bits, mut data) = (0, 0, 0, 0, None);
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let size = u32_at(at + 4) as usize;
        let body = at + 8;
        let end = (body + size).min(bytes.len());
        match &bytes[at..at + 4] {
            b"fmt " if size >= 16 => {
                format = u16_at(body);
                channels = u16_at(body + 2);
                rate = u32_at(body + 4);
                bits = u16_at(body + 14);
            }
            b"data" => data = Some(&bytes[body..end]),
            _ => {}
        }
        at = body + size + (size & 1);
    }
    let data = data.ok_or_else(|| bad("no data chunk"))?;
    let samples = match (format, bits) {
        (1, 16) => data.chunks_exact(2).map(|s| i16::from_le_bytes([s[0], s[1]]) as f32 / i16::MAX as f32).collect(),
        (3, 32) => data.chunks_exact(4).map(|s| f32::from_le_bytes([s[0], s[1], s[2], s[3]])).collect(),
        _ => return Err(bad(&format!("format {format} at {bits} bits (16-bit PCM or 32-bit float only)"))),
    };
    Ok((samples, channels.max(1), rate))
}
