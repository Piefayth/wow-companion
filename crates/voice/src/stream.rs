//! The streaming engine, on trial against Whisper (docs/proposals/streaming-speech.md):
//! NVIDIA's Nemotron streaming 0.6B through sherpa-onnx, on the CPU, so it never
//! competes with the game for the GPU. Audio goes in while the button is held;
//! its partial text stays on the PC (each message to the game costs one of 512
//! slots); the final text at release goes the way Whisper's does.
//!
//! A trial the player asked for (2026-11-11), not a kept fallback: the setup
//! window offers both engines until the player has compared them in play, then
//! the losing engine is deleted.

use std::{
    fs, io,
    path::Path,
    sync::mpsc::{Receiver, Sender},
    time::Instant,
};

use sherpa_onnx::{OnlineRecognizer, OnlineRecognizerConfig, OnlineStream};

use wow_companion_settings::stream_model::{missing, BPE_VOCAB, FILES};

use crate::transcribe::{Done, COMMANDS};

/// How strongly the hotwords pull. Chosen on the benchmark's clips: 1.5 was too
/// weak ("ferry fire" survived), 4.5 too strong (spells appeared that were not
/// said); the player's own voice confirms or moves it.
pub const HOTWORDS_SCORE: f32 = 3.0;
/// Silence fed after the last of the audio, so the model's final chunk is
/// decoded (three of its 160 ms chunks).
const TAIL_SECONDS: f32 = 0.48;
const RATE: i32 = 16_000;
/// CPU threads for the recognizer: on four the benchmark decoded at 0.25-0.4x
/// real time, keeping pace with speech with room to spare.
pub(crate) const THREADS: i32 = 4;

/// What the voice loop sends the engine's thread.
pub(crate) enum Feed {
    /// The button went down: a new utterance, biased toward these words.
    Start { hotwords: String },
    /// Audio captured since the last piece, mono, at the mic's own rate.
    Audio { rate: u32, samples: Vec<f32> },
    /// The button came up on a real clip: finish and report it.
    Finish { role: String, level: f32, seconds: f32 },
    /// The press was a tap, too short, or cut off: forget it.
    Drop,
}

fn path(dir: &Path, file: &str) -> Option<String> {
    Some(dir.join(file).to_string_lossy().into_owned())
}

/// Load the recognizer: modified beam search, so hotwords apply; no endpoint
/// detection, since the button says when an utterance ends.
pub(crate) fn load(dir: &Path, threads: i32) -> io::Result<OnlineRecognizer> {
    let gone = missing(dir);
    if !gone.is_empty() {
        return Err(io::Error::other(format!(
            "the streaming model in {} is missing {}: download it again in the setup window",
            dir.display(),
            gone.join(", ")
        )));
    }
    let mut config = OnlineRecognizerConfig::default();
    config.model_config.transducer.encoder = path(dir, FILES[0]);
    config.model_config.transducer.decoder = path(dir, FILES[1]);
    config.model_config.transducer.joiner = path(dir, FILES[2]);
    config.model_config.tokens = path(dir, FILES[3]);
    config.model_config.num_threads = threads;
    config.model_config.modeling_unit = Some("bpe".into());
    config.model_config.bpe_vocab = path(dir, BPE_VOCAB);
    config.decoding_method = Some("modified_beam_search".into());
    config.max_active_paths = 4;
    config.hotwords_score = HOTWORDS_SCORE;
    config.enable_endpoint = false;
    OnlineRecognizer::create(&config)
        .ok_or_else(|| io::Error::other(format!("sherpa-onnx could not load the streaming model in {}", dir.display())))
}

/// The hotwords for one utterance, in sherpa-onnx's per-stream form (phrases
/// separated by "/"): the vocabulary Whisper's prompt carries (spell and macro
/// names) and its command words.
pub(crate) fn hotwords(vocabulary: &[String]) -> String {
    let commands = COMMANDS.trim_start_matches("Commands:").trim_end_matches('.');
    vocabulary
        .iter()
        .map(String::as_str)
        .chain(commands.split(','))
        .map(|word| word.replace([':', '/'], " ").split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join("/")
}

fn decode(recognizer: &OnlineRecognizer, stream: &OnlineStream) -> String {
    while recognizer.is_ready(stream) {
        recognizer.decode(stream);
    }
    recognizer.get_result(stream).map(|result| result.text.trim().to_string()).unwrap_or_default()
}

/// The engine's thread: feeds in, partials printed to the log as they change,
/// the final text out on `done` (where Whisper's results go).
pub(crate) fn run(recognizer: OnlineRecognizer, feed: Receiver<Feed>, done: Sender<Done>) {
    let mut stream: Option<OnlineStream> = None;
    let mut partial = String::new();
    for item in feed {
        match item {
            Feed::Start { hotwords } => {
                stream = Some(recognizer.create_stream_with_hotwords(&hotwords));
                partial.clear();
            }
            Feed::Audio { rate, samples } => {
                let Some(stream) = &stream else { continue };
                stream.accept_waveform(rate as i32, &samples);
                let text = decode(&recognizer, stream);
                if text != partial {
                    crate::mark(&format!("partial: {text}"));
                    partial = text;
                }
            }
            Feed::Finish { role, level, seconds } => {
                // every Finish is answered: its clip was announced to the player
                let result = match stream.take() {
                    Some(stream) => {
                        let since = Instant::now();
                        stream.accept_waveform(RATE, &vec![0.0; (TAIL_SECONDS * RATE as f32) as usize]);
                        stream.input_finished();
                        let text = decode(&recognizer, &stream);
                        crate::mark(&format!("streaming final in {} ms", since.elapsed().as_millis()));
                        Ok(text)
                    }
                    None => Err(io::Error::other("the streaming engine was told to finish a clip it never started")),
                };
                if done.send(Done { role, level, seconds, result }).is_err() {
                    break;
                }
            }
            Feed::Drop => stream = None,
        }
    }
}

/// `wow-companion transcribe-stream <model folder> <clip.wav>`: the streaming
/// engine on a recorded clip fed at the pace of speech (100 ms of audio every
/// 100 ms), as the voice loop feeds it: each partial with how far into the audio
/// it came, then the time from the end of the audio to the final text, the
/// number the trial compares with Whisper's.
pub fn transcribe_stream_file(dir: &Path, wav: &Path, vocabulary: &[String]) -> io::Result<()> {
    let (samples, channels, rate) = crate::transcribe::read_wav(&fs::read(wav)?)?;
    let mono: Vec<f32> = samples
        .chunks(channels as usize)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect();
    let loading = Instant::now();
    let recognizer = load(dir, THREADS)?;
    println!("model loaded in {:.2}s", loading.elapsed().as_secs_f32());
    let stream = recognizer.create_stream_with_hotwords(&hotwords(vocabulary));
    let piece = (rate / 10) as usize;
    let started = Instant::now();
    let mut partial = String::new();
    for (index, chunk) in mono.chunks(piece).enumerate() {
        // the pace of speech: this piece exists only once its 100 ms have passed
        let due = std::time::Duration::from_millis(100 * (index as u64 + 1));
        if let Some(wait) = due.checked_sub(started.elapsed()) {
            std::thread::sleep(wait);
        }
        stream.accept_waveform(rate as i32, chunk);
        let text = decode(&recognizer, &stream);
        if text != partial {
            println!("{:>6} ms of audio, {:>6} ms: {text}", (index + 1) * 100, started.elapsed().as_millis());
            partial = text;
        }
    }
    let released = Instant::now();
    stream.accept_waveform(RATE, &vec![0.0; (TAIL_SECONDS * RATE as f32) as usize]);
    stream.input_finished();
    let text = decode(&recognizer, &stream);
    println!(
        "{:.1}s of audio; final text {} ms after the audio ended",
        mono.len() as f32 / rate as f32,
        released.elapsed().as_millis()
    );
    println!("text: {text}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotwords_are_the_vocabulary_and_the_command_words() {
        let words = hotwords(&["Teleport: Moonglade".into(), "Faerie Fire".into()]);
        assert!(words.starts_with("Teleport Moonglade/Faerie Fire/macro/action bar/"));
        assert!(words.ends_with("/guild"));
        assert!(!words.contains("//"));
    }
}
