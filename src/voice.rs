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

use crate::pad::{self, Pad, DEFAULT_PAD};

const WHISPER_RATE: u32 = 16_000;
const POLL: Duration = Duration::from_millis(16);
// below this there is no speech, just the click of the chord being released
const MINIMUM_CLIP: Duration = Duration::from_millis(250);

// Whisper has never heard of Hearthstone or Shadowstep and will cheerfully write
// "fire ball". Seeding the decoder with the vocabulary fixes most of it.
const VOCABULARY: &str = "World of Warcraft. Spell and ability names: Fireball, Frostbolt, \
    Shadowstep, Hearthstone, Bloodlust, Rejuvenation, Innervate, Starfall, Thunderstorm. \
    Commands: macro, action bar, slot, bind, chat, whisper, party, raid, guild.";

/// Hold the button, speak, release. `heard` gets each finished transcript: printing it
/// for a dry run, or handing it to the channel for real.
pub fn listen(
    model: &Path,
    options: &[String],
    mut heard: impl FnMut(&str) -> io::Result<()>,
) -> io::Result<()> {
    // Home by default: the one button WoW has no use for. We cannot consume the
    // input, so anything the game binds would fire twice.
    let button = pad::press(options.first().map_or("home", |name| name.as_str()))?;
    let (vid, pid) = DEFAULT_PAD;
    let mut controller = Pad::open(vid, pid)?;
    let microphone = Microphone::open(options.get(1).map(|name| name.as_str()))?;

    // loading the model is the slow part, so do it once and keep it resident
    let path = model.to_str().ok_or_else(|| io::Error::other("model path isn't UTF-8"))?;
    println!("loading {path}");
    let whisper = WhisperContext::new_with_params(path, WhisperContextParameters::default())
        .map_err(|err| io::Error::other(format!("{err:?}")))?;

    println!("ready: hold {button} and speak");
    let mut holding = false;
    loop {
        controller.refresh()?;
        let held = controller.held(&button);

        if held && !holding {
            microphone.start();
            println!("listening");
        } else if !held && holding {
            let clip = microphone.stop();
            let seconds = clip.len() as f32 / WHISPER_RATE as f32;
            if Duration::from_secs_f32(seconds) < MINIMUM_CLIP {
                println!("too short, ignored");
            } else {
                match transcribe(&whisper, &clip) {
                    Ok(text) if text.is_empty() => println!("heard nothing"),
                    Ok(text) => {
                        println!("heard ({seconds:.1}s): {text}");
                        // a failed delivery must not kill the loop: the game may be
                        // closed, or every slot spent until the next reload
                        if let Err(err) = heard(&text) {
                            eprintln!("  not delivered: {err}");
                        }
                    }
                    Err(err) => eprintln!("transcribe failed: {err}"),
                }
            }
        }
        holding = held;
        thread::sleep(POLL);
    }
}

fn transcribe(whisper: &WhisperContext, clip: &[f32]) -> io::Result<String> {
    let mut state = whisper
        .create_state()
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("en"));
    params.set_initial_prompt(VOCABULARY);
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
