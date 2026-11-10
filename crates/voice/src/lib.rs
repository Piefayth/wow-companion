//! Push-to-talk voice capture. Hold a controller chord, speak, release: the whole
//! clip goes to Whisper at once, which reads better than streaming dictation
//! because the model gets to see the end of the sentence before committing to the
//! start of it. Stays on this machine, so a hot mic can't leak the room.

use std::{
    io,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use wow_companion_pad::{self as pad, Pad, DEFAULT_PAD};

const WHISPER_RATE: u32 = 16_000;
const POLL: Duration = Duration::from_millis(16);
// below this there is no speech, just the click of the chord being released
const MINIMUM_CLIP: Duration = Duration::from_millis(250);
/// A press released this quickly was a tap, not speech: it is reported as the
/// role with " tap" appended and no text, so a button can do something on a tap
/// (minus opens the Companion window) and still be push-to-talk when held.
const TAP: Duration = Duration::from_millis(350);
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
// A Bluetooth pad sleeps and a headset drops its hands-free link; either used to end
// the app. Now a lost device is reopened on this cadence until it comes back.
const RETRY: Duration = Duration::from_secs(2);
// Whisper fills silence with the endings of the videos it was trained on. These only
// count as heard when the clip had real sound in it.
const PHANTOMS: &[&str] = &["thank you", "thanks for watching", "you", "bye", "thank you for watching"];
// RMS of a clip with nobody talking; speech sits well above it. Printed with every
// clip, so it can be tuned from the log rather than guessed.
const SILENCE: f32 = 0.01;
// Below this a clip holds no sound at all (a dead or muted mic measured 0.0011;
// real speech here is 0.016 to 0.043), and Whisper fills it with its own prompt
// ("Commands: the first one."), which then went to the agent as a request. Such
// a clip is dropped whatever the transcript says.
const NOTHING: f32 = 0.004;

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
/// said (a quick tap arrives as "<role> tap" with no text), so one loop can serve dictation on one button and the agent on another.
///
/// Both default to buttons WoW ignores — Home and minus. We cannot consume the input,
/// so anything the game binds would fire twice: once for us, once in game.
///
/// `vocabulary` is asked afresh for every clip, so names learned at the last reload
/// are in the prompt without restarting.
/// True while a push-to-talk button is held: a restart waits for the release, so
/// no clip is cut off halfway.
pub static HOLDING: AtomicBool = AtomicBool::new(false);

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
    let wanted_mic = option(options, "mic");
    // Neither has to be there at startup: the model loads either way, and each device
    // is picked up when it appears. A mistyped `mic=` looks exactly like an unplugged
    // headset from here, so the wait names the inputs it can see; a typo shows up
    // as a name missing from that list.
    let mut controller = match Pad::open(vid, pid) {
        Ok(opened) => Some(opened),
        Err(err) => {
            println!("controller not found ({err}); will pick it up when it connects");
            None
        }
    };
    let mut microphone = match Microphone::open(wanted_mic) {
        Ok(opened) => Some(opened),
        Err(err) => {
            println!("{err}; will pick it up when it connects");
            println!("  inputs I can see now: {}", input_names().join(", "));
            None
        }
    };
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
    let mut pressed_at = Instant::now();
    let mut retry_pad = Instant::now();
    let mut retry_mic = Instant::now();
    loop {
        // a dead stream is replaced between presses, never during one
        if holding.is_none() && microphone.as_ref().is_some_and(Microphone::broken) {
            eprintln!("microphone lost; waiting for it to come back");
            microphone = None;
            retry_mic = Instant::now();
        }
        if microphone.is_none() && Instant::now() >= retry_mic {
            retry_mic = Instant::now() + RETRY;
            // open prints the device it found, which doubles as "it's back"
            if let Ok(opened) = Microphone::open(wanted_mic) {
                microphone = Some(opened);
            }
        }
        let Some(pad) = controller.as_mut() else {
            if Instant::now() >= retry_pad {
                retry_pad = Instant::now() + RETRY;
                if let Ok(opened) = Pad::open(vid, pid) {
                    println!("controller back");
                    controller = Some(opened);
                }
            }
            thread::sleep(POLL);
            continue;
        };
        if let Err(err) = pad.refresh() {
            eprintln!("controller lost ({err}); waiting for it to come back");
            controller = None;
            retry_pad = Instant::now() + RETRY;
            // a clip cut off by the pad vanishing is not a request
            if holding.take().is_some() {
                if let Some(mic) = &microphone {
                    mic.stop();
                }
                println!("  discarded the clip in progress");
            }
            continue;
        }
        // first match wins, so holding both does one thing rather than two
        let held = bindings
            .iter()
            .find(|(_, press)| pad.held(press))
            .map(|(role, _)| *role);
        let Some(mic) = &microphone else {
            if held.is_some() && holding.is_none() {
                println!("no microphone yet; still waiting for it");
            }
            holding = held;
        HOLDING.store(held.is_some(), Ordering::Relaxed);
            thread::sleep(POLL);
            continue;
        };

        match (held, holding) {
            (Some(role), None) => {
                pressed_at = Instant::now();
                mic.start();
                cue(cue_device.clone(), cue_volume, &CUE_OPEN);
                println!("listening for {role}");
            }
            (None, Some(role)) => {
                let clip = mic.stop();
                // falling fifth on release: rising means live, falling means it has it
                cue(cue_device.clone(), cue_volume, &CUE_SHUT);
                let seconds = clip.len() as f32 / WHISPER_RATE as f32;
                if pressed_at.elapsed() < TAP {
                    println!("tap: {role}");
                    if let Err(err) = heard(&format!("{role} tap"), "") {
                        eprintln!("  not delivered: {err}");
                    }
                } else if Duration::from_secs_f32(seconds) < MINIMUM_CLIP {
                    println!("too short, ignored");
                } else {
                    let level = loudness(&clip);
                    if level < NOTHING {
                        println!("no sound in that clip (level {level:.4}); is the mic muted or disconnected?");
                        holding = held;
                        HOLDING.store(held.is_some(), Ordering::Relaxed);
                        thread::sleep(POLL);
                        continue;
                    }
                    match transcribe(&whisper, &clip, &prompt(&vocabulary())) {
                        Ok(text) if text.is_empty() => println!("heard nothing (level {level:.4})"),
                        Ok(text) if level < SILENCE && phantom(&text) => {
                            println!("heard only silence (level {level:.4}); ignored {text:?}")
                        }
                        Ok(text) => {
                            println!("heard ({seconds:.1}s, {role}, level {level:.4}): {text}");
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
        HOLDING.store(held.is_some(), Ordering::Relaxed);
        thread::sleep(POLL);
    }
}

fn loudness(clip: &[f32]) -> f32 {
    if clip.is_empty() {
        return 0.0;
    }
    (clip.iter().map(|sample| sample * sample).sum::<f32>() / clip.len() as f32).sqrt()
}

fn phantom(text: &str) -> bool {
    let plain: String = text
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    PHANTOMS.contains(&plain.trim())
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
    // set from the stream's error callback when the device is gone, not merely late
    dead: Arc<AtomicBool>,
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
        let dead = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&dead);
        // An underrun is a hiccup and the stream carries on; anything else means the
        // device went away (a headset dropping hands-free reports DeviceNotAvailable)
        // and the stream will never deliver again.
        let fail = move |err: cpal::Error| {
            if !matches!(err.kind(), cpal::ErrorKind::Xrun | cpal::ErrorKind::DeviceChanged) {
                if !flag.swap(true, Ordering::Relaxed) {
                    eprintln!("microphone error: {err}");
                }
            }
        };
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

        Ok(Self { _stream: stream, capture, rate, channels, dead })
    }

    fn broken(&self) -> bool {
        self.dead.load(Ordering::Relaxed)
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

fn input_names() -> Vec<String> {
    let Ok(devices) = cpal::default_host().input_devices() else { return Vec::new() };
    devices
        .filter_map(|device| device.description().ok().map(|d| d.name().to_string()))
        .collect()
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
