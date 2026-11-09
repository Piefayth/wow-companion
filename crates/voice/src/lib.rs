//! Push-to-talk voice capture. Hold a controller chord, speak, release: the whole
//! clip goes to Whisper at once, which reads better than streaming dictation
//! because the model gets to see the end of the sentence before committing to the
//! start of it. Stays on this machine, so a hot mic can't leak the room.

use std::{
    io,
    path::Path,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use wow_companion_pad::{self as pad, Pad, DEFAULT_PAD};

const WHISPER_RATE: u32 = 16_000;
const POLL: Duration = Duration::from_millis(16);
// below this there is no speech, just the click of the chord being released
const MINIMUM_CLIP: Duration = Duration::from_millis(250);
// A sine wave at full scale is far louder than music at the same nominal level, and
// a headset in hands-free mode has its own gain on top. Start very quiet; `volume=`
// tunes it without a rebuild.
const CUE_VOLUME: f32 = 0.015;
// A rising fifth to open, the same fifth falling to close: two notes carry direction
// where one pitch only says "something happened".
const CUE_OPEN: [f32; 2] = [587.33, 880.00];
const CUE_SHUT: [f32; 2] = [880.00, 587.33];
const CUE_NOTE: u64 = 85;
// struck-and-decaying, like a glass or a marimba, rather than a held tone
const CUE_DECAY: f32 = 20.0;

// Whisper has never heard of Hearthstone or Shadowstep and will cheerfully write
// "fire ball". Seeding the decoder with the vocabulary fixes most of it.
const COMMANDS: &str = "Commands: macro, action bar, slot, bind, chat, whisper, party, raid, guild.";
// used until the game has exported a spellbook to take names from
const FALLBACK_SPELLS: &[&str] = &["Hearthstone", "Rejuvenation", "Moonfire", "Bear Form"];
// Whisper keeps only the last ~224 tokens of a prompt; stay well inside that, or
// the cut falls on the spell names, which are the point
const PROMPT_CHARS: usize = 700;

fn prompt(spells: &[String]) -> String {
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

/// Hold a button, speak, release. `heard` is given which binding fired and what was
/// said, so one loop can serve dictation on one button and the agent on another.
///
/// Both default to buttons WoW ignores — Home and minus. We cannot consume the input,
/// so anything the game binds would fire twice: once for us, once in game.
///
/// `vocabulary` is asked afresh for every clip, so names learned at the last reload
/// are in the prompt without restarting.
pub fn listen(
    model: &Path,
    options: &[String],
    vocabulary: impl Fn() -> Vec<String>,
    mut heard: impl FnMut(&str, &str) -> io::Result<()>,
) -> io::Result<()> {
    let bindings = [
        ("chat", option(options, "chat").or(option(options, "button")).unwrap_or("home")),
        ("ask", option(options, "ask").unwrap_or("minus")),
    ];
    let bindings: Vec<(&str, pad::Press)> = bindings
        .iter()
        .map(|(role, name)| pad::press(name).map(|press| (*role, press)))
        .collect::<io::Result<_>>()?;
    let (vid, pid) = DEFAULT_PAD;
    let mut controller = Pad::open(vid, pid)?;
    let microphone = Microphone::open(option(options, "mic"))?;
    // A Bluetooth headset holding HFP for the mic has its A2DP render endpoint
    // switched off, so the cue has to name the hands-free one or it plays into a
    // dead device. Nothing is audible and nothing errors.
    let cue_device = option(options, "cue").map(str::to_string);
    let cue_volume = option(options, "volume")
        .and_then(|given| given.parse().ok())
        .unwrap_or(CUE_VOLUME);

    // loading the model is the slow part, so do it once and keep it resident
    let path = model.to_str().ok_or_else(|| io::Error::other("model path isn't UTF-8"))?;
    println!("loading {path}");
    let whisper = WhisperContext::new_with_params(path, WhisperContextParameters::default())
        .map_err(|err| io::Error::other(format!("{err:?}")))?;

    for (role, press) in &bindings {
        println!("ready: hold {press} for {role}");
    }
    let mut holding: Option<&str> = None;
    loop {
        controller.refresh()?;
        // first match wins, so holding both does one thing rather than two
        let held = bindings
            .iter()
            .find(|(_, press)| controller.held(press))
            .map(|(role, _)| *role);

        match (held, holding) {
            (Some(role), None) => {
                microphone.start();
                cue(cue_device.clone(), cue_volume, &CUE_OPEN);
                println!("listening for {role}");
            }
            (None, Some(role)) => {
                let clip = microphone.stop();
                // falling fifth on release: rising means live, falling means it has it
                cue(cue_device.clone(), cue_volume, &CUE_SHUT);
                let seconds = clip.len() as f32 / WHISPER_RATE as f32;
                if Duration::from_secs_f32(seconds) < MINIMUM_CLIP {
                    println!("too short, ignored");
                } else {
                    match transcribe(&whisper, &clip, &prompt(&vocabulary())) {
                        Ok(text) if text.is_empty() => println!("heard nothing"),
                        Ok(text) => {
                            println!("heard ({seconds:.1}s, {role}): {text}");
                            // a failed delivery must not kill the loop: the game may
                            // be closed, or every slot spent until the next reload
                            if let Err(err) = heard(role, &text) {
                                eprintln!("  not delivered: {err}");
                            }
                        }
                        Err(err) => eprintln!("transcribe failed: {err}"),
                    }
                }
            }
            _ => {}
        }
        holding = held;
        thread::sleep(POLL);
    }
}

fn transcribe(whisper: &WhisperContext, clip: &[f32], prompt: &str) -> io::Result<String> {
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


struct Capture {
    recording: bool,
    samples: Vec<f32>,
}

struct Microphone {
    // held because dropping it closes the stream
    _stream: cpal::Stream,
    capture: Arc<Mutex<Capture>>,
    rate: u32,
    channels: u16,
}

impl Microphone {
    // One stream open for the whole session, gated by a flag. Opening a stream takes
    // long enough that doing it per press would clip the first word.
    fn open(wanted: Option<&str>) -> io::Result<Self> {
        let host = cpal::default_host();
        let device = match wanted {
            // match on a fragment: full device names are long and awkward to type
            Some(fragment) => {
                let lowered = fragment.to_ascii_lowercase();
                host.input_devices()
                    .map_err(|err| io::Error::other(err.to_string()))?
                    .find(|device| {
                        device.description().is_ok_and(|described| {
                            described.name().to_ascii_lowercase().contains(&lowered)
                        })
                    })
                    .ok_or_else(|| {
                        io::Error::other(format!("no input device matching {fragment:?}"))
                    })?
            }
            None => host
                .default_input_device()
                .ok_or_else(|| io::Error::other("no input device"))?,
        };
        let config = device
            .default_input_config()
            .map_err(|err| io::Error::other(err.to_string()))?;
        let rate = config.sample_rate();
        let channels = config.channels();
        let name = device
            .description()
            .map(|described| described.name().to_string())
            .unwrap_or_else(|_| "unknown".into());
        println!("microphone: {name} at {rate} Hz, {channels} channel(s)");
        // Whisper is trained on 16 kHz. Below that there is nothing to resample from:
        // Bluetooth hands-free runs at 8 kHz and costs real accuracy.
        if rate < WHISPER_RATE {
            println!("  warning: {rate} Hz is below Whisper's {WHISPER_RATE} Hz; expect misreadings");
        }

        let capture = Arc::new(Mutex::new(Capture {
            recording: false,
            samples: Vec::new(),
        }));
        let sink = Arc::clone(&capture);
        let fail = |err| eprintln!("microphone error: {err}");
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                config.config(),
                move |data: &[f32], _: &_| push(&sink, data.iter().copied()),
                fail,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                config.config(),
                move |data: &[i16], _: &_| {
                    push(&sink, data.iter().map(|s| *s as f32 / i16::MAX as f32))
                },
                fail,
                None,
            ),
            other => return Err(io::Error::other(format!("unsupported sample format {other:?}"))),
        }
        .map_err(|err| io::Error::other(err.to_string()))?;
        stream.play().map_err(|err| io::Error::other(err.to_string()))?;

        Ok(Self { _stream: stream, capture, rate, channels })
    }

    fn start(&self) {
        let mut capture = self.capture.lock().unwrap();
        capture.samples.clear();
        capture.recording = true;
    }

    fn stop(&self) -> Vec<f32> {
        let mut capture = self.capture.lock().unwrap();
        capture.recording = false;
        let raw = std::mem::take(&mut capture.samples);
        drop(capture);
        to_whisper(&raw, self.channels, self.rate)
    }
}

fn push(capture: &Arc<Mutex<Capture>>, samples: impl Iterator<Item = f32>) {
    let mut capture = capture.lock().unwrap();
    if capture.recording {
        capture.samples.extend(samples);
    }
}

/// A short tone to the default output, so you can hear that push-to-talk went live
/// rather than guessing from whether text eventually appears.
///
/// Spawned on its own thread: capture has to start now, not after the audio device
/// has finished opening.
fn cue(wanted: Option<String>, volume: f32, notes: &'static [f32]) {
    if volume <= 0.0 {
        return;
    }
    thread::spawn(move || {
        if let Err(err) = chime(wanted.as_deref(), volume, notes) {
            eprintln!("cue failed: {err}");
        }
    });
}

fn chime(wanted: Option<&str>, volume: f32, notes: &[f32]) -> io::Result<()> {
    let host = cpal::default_host();
    let device = match wanted {
        Some(fragment) => {
            let lowered = fragment.to_ascii_lowercase();
            host.output_devices()
                .map_err(|err| io::Error::other(err.to_string()))?
                .find(|device| {
                    device.description().is_ok_and(|described| {
                        described.name().to_ascii_lowercase().contains(&lowered)
                    })
                })
                .ok_or_else(|| io::Error::other(format!("no output matching {fragment:?}")))?
        }
        None => host
            .default_output_device()
            .ok_or_else(|| io::Error::other("no output device"))?,
    };
    let config = device
        .default_output_config()
        .map_err(|err| io::Error::other(err.to_string()))?;
    let rate = config.sample_rate() as f32;
    let channels = config.channels() as usize;
    let per_note = (rate * CUE_NOTE as f32 / 1000.0) as usize;
    let length = per_note * notes.len();
    // a few ms of attack, or the strike itself clicks
    let attack = (rate * 0.003).max(1.0) as usize;
    let count = notes.len() as u64;
    let notes: Vec<f32> = notes.to_vec();

    let mut index = 0usize;
    let mut next = move || {
        if index >= length {
            return 0.0;
        }
        let (note, step) = (index / per_note, index % per_note);
        let seconds = step as f32 / rate;
        let hz = notes[note];
        let phase = seconds * hz * std::f32::consts::TAU;
        // a quiet second harmonic gives it some body; the sine alone sounds like a test
        let wave = phase.sin() + 0.12 * (phase * 2.0).sin();
        let envelope = (step as f32 / attack as f32).min(1.0) * (-seconds * CUE_DECAY).exp();
        index += 1;
        wave * envelope * volume
    };

    let fail = |err| eprintln!("cue stream error: {err}");
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => device.build_output_stream(
            config.config(),
            move |buffer: &mut [f32], _: &_| {
                for frame in buffer.chunks_mut(channels) {
                    frame.fill(next());
                }
            },
            fail,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_output_stream(
            config.config(),
            move |buffer: &mut [i16], _: &_| {
                for frame in buffer.chunks_mut(channels) {
                    frame.fill((next() * i16::MAX as f32) as i16);
                }
            },
            fail,
            None,
        ),
        other => return Err(io::Error::other(format!("unsupported output format {other:?}"))),
    }
    .map_err(|err| io::Error::other(err.to_string()))?;
    stream.play().map_err(|err| io::Error::other(err.to_string()))?;
    // hold the stream open until the notes have actually come out
    thread::sleep(Duration::from_millis(CUE_NOTE * count + 80));
    Ok(())
}

fn option<'a>(options: &'a [String], key: &str) -> Option<&'a str> {
    options
        .iter()
        .filter_map(|option| option.split_once('='))
        .find(|(name, _)| *name == key)
        .map(|(_, value)| value)
}

pub fn speakers() -> io::Result<()> {
    let host = cpal::default_host();
    let default = host
        .default_output_device()
        .and_then(|device| device.description().ok())
        .map(|described| described.name().to_string());
    for device in host
        .output_devices()
        .map_err(|err| io::Error::other(err.to_string()))?
    {
        let Ok(described) = device.description() else { continue };
        let name = described.name();
        let marker = if Some(name.to_string()) == default { "*" } else { " " };
        println!("{marker} {name}");
    }
    println!("\n* is the current default. A Bluetooth headset held in hands-free mode for");
    println!("  its mic cannot play through its stereo endpoint: name the hands-free one.");
    Ok(())
}

pub fn microphones() -> io::Result<()> {
    let host = cpal::default_host();
    let default = host
        .default_input_device()
        .and_then(|device| device.description().ok())
        .map(|described| described.name().to_string());
    for device in host
        .input_devices()
        .map_err(|err| io::Error::other(err.to_string()))?
    {
        let Ok(described) = device.description() else { continue };
        let name = described.name();
        let rate = device.default_input_config().map(|config| config.sample_rate());
        let marker = if Some(name.to_string()) == default { "*" } else { " " };
        match rate {
            Ok(rate) => println!("{marker} {rate:>6} Hz  {name}"),
            Err(_) => println!("{marker}      ?  {name}"),
        }
    }
    println!("\n* is the current default; {WHISPER_RATE} Hz or better is what Whisper wants");
    Ok(())
}

// Whisper wants 16 kHz mono f32. Averaging each output sample over its whole input
// window both decimates and acts as a crude low-pass, which matters: plain
// nearest-sample decimation from 48 kHz aliases badly enough to cost accuracy.
fn to_whisper(samples: &[f32], channels: u16, rate: u32) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let channels = channels.max(1) as usize;
    let mono: Vec<f32> = samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect();
    if rate == WHISPER_RATE {
        return mono;
    }
    let step = rate as f64 / WHISPER_RATE as f64;
    let count = (mono.len() as f64 / step).floor() as usize;
    (0..count)
        .map(|index| {
            let start = (index as f64 * step) as usize;
            let end = (((index + 1) as f64 * step).ceil() as usize).clamp(start + 1, mono.len());
            let window = &mono[start..end];
            window.iter().sum::<f32>() / window.len() as f32
        })
        .collect()
}
