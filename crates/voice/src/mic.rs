//! The microphone: opening it, capturing a clip, healing a stalled stream, and the device-listing tools.

use super::*;

// RMS of a clip with nobody talking; speech sits well above it. Printed with every
// clip, so it can be tuned from the log rather than guessed.
pub(crate) const SILENCE: f32 = 0.01;
// no buffers for this long and the mic stream is taken for dead
pub(crate) const STALL: Duration = Duration::from_millis(1500);
// at most one automatic reconnect this often, so an absent headset cannot loop
pub(crate) const HEAL_EVERY: Duration = Duration::from_secs(15);
pub(crate) fn loudness(clip: &[f32]) -> f32 {
    if clip.is_empty() {
        return 0.0;
    }
    (clip.iter().map(|sample| sample * sample).sum::<f32>() / clip.len() as f32).sqrt()
}

pub(crate) struct Capture {
    pub(crate) recording: bool,
    pub(crate) samples: Vec<f32>,
    // when start() was called, and when the first samples after it arrived: the
    // gap is how long the headset took to switch into hands-free and deliver
    pub(crate) started: Option<Instant>,
    pub(crate) first: Option<Instant>,
    // the last time the stream delivered anything, recording or not: a live
    // stream delivers every few milliseconds, so a gap means the link is dead
    pub(crate) last: Instant,
    // how many raw samples of this recording a streaming engine has taken so far
    pub(crate) taken: usize,
}

pub(crate) struct Microphone {
    // held because dropping it closes the stream
    pub(crate) _stream: cpal::Stream,
    pub(crate) capture: Arc<Mutex<Capture>>,
    pub(crate) rate: u32,
    pub(crate) channels: u16,
    // set from the stream's error callback when the device is gone, not merely late
    pub(crate) dead: Arc<AtomicBool>,
}

impl Microphone {
    // One stream open for the whole session, gated by a flag. Opening a stream takes
    // long enough that doing it per press would clip the first word.
    pub(crate) fn open(wanted: Option<&str>) -> io::Result<Self> {
        Self::open_quietly(wanted, false)
    }

    pub(crate) fn open_quietly(wanted: Option<&str>, quiet: bool) -> io::Result<Self> {
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
        if !quiet {
            println!("microphone: {name} at {rate} Hz, {channels} channel(s)");
        }
        // Whisper is trained on 16 kHz. Below that there is nothing to resample from:
        // Bluetooth hands-free runs at 8 kHz and costs real accuracy.
        if rate < WHISPER_RATE && !quiet {
            println!("  warning: {rate} Hz is below Whisper's {WHISPER_RATE} Hz; expect misreadings");
        }

        let capture = Arc::new(Mutex::new(Capture {
            recording: false,
            samples: Vec::new(),
            started: None,
            first: None,
            last: Instant::now(),
            taken: 0,
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

    pub(crate) fn broken(&self) -> bool {
        self.dead.load(Ordering::Relaxed)
    }

    pub(crate) fn start(&self) {
        let mut capture = self.capture.lock().unwrap();
        capture.samples.clear();
        capture.taken = 0;
        capture.recording = true;
        capture.started = Some(Instant::now());
        capture.first = None;
    }

    /// True when the stream has delivered nothing for `STALL`: the device is
    /// listed and the stream open, but no audio is coming (a wedged hands-free link).
    pub(crate) fn stalled(&self) -> bool {
        self.capture.lock().unwrap().last.elapsed() > STALL
    }

    /// How long after start() the first audio arrived, if it has.
    pub(crate) fn lag(&self) -> Option<Duration> {
        let capture = self.capture.lock().unwrap();
        Some(capture.first?.saturating_duration_since(capture.started?))
    }

    /// Stop taking in audio, keeping the recording for `take_new` and `stop`.
    pub(crate) fn end(&self) {
        self.capture.lock().unwrap().recording = false;
    }

    /// For a streaming engine: what this recording captured since the last call,
    /// mixed to mono, whole frames only, at the device's own rate (`rate`; the
    /// engine resamples). Called while the button is held and once more after
    /// `end`, so together the calls hand over every sample exactly once.
    pub(crate) fn take_new(&self) -> Vec<f32> {
        let mut capture = self.capture.lock().unwrap();
        let channels = self.channels.max(1) as usize;
        let whole = capture.samples.len() - capture.samples.len() % channels;
        let start = capture.taken.min(whole);
        let mono = capture.samples[start..whole]
            .chunks(channels)
            .map(|frame| frame.iter().sum::<f32>() / channels as f32)
            .collect();
        capture.taken = whole;
        mono
    }

    pub(crate) fn stop(&self) -> Vec<f32> {
        let mut capture = self.capture.lock().unwrap();
        capture.recording = false;
        let raw = std::mem::take(&mut capture.samples);
        drop(capture);
        to_whisper(&raw, self.channels, self.rate)
    }
}

pub(crate) fn push(capture: &Arc<Mutex<Capture>>, samples: impl Iterator<Item = f32>) {
    let mut capture = capture.lock().unwrap();
    capture.last = Instant::now();
    if capture.recording {
        let before = capture.samples.len();
        capture.samples.extend(samples);
        if capture.first.is_none() && capture.samples.len() > before {
            capture.first = Some(Instant::now());
        }
    }
}

pub(crate) fn input_names() -> Vec<String> {
    let Ok(devices) = cpal::default_host().input_devices() else { return Vec::new() };
    devices
        .filter_map(|device| device.description().ok().map(|d| d.name().to_string()))
        .collect()
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

/// Record two seconds from the mic and say how much arrived and how loud it was:
/// "is the headset actually sending audio" without a press or a transcription.
pub fn miccheck(wanted: Option<&str>, wake: Option<&str>) -> io::Result<()> {
    let mic = Microphone::open(wanted)?;
    // optionally play silence on an output meanwhile, to see whether that is what
    // starts a hands-free link's audio
    if let Some(output) = wake {
        let wake = output;
        let output = output.to_string();
        thread::spawn(move || {
            if let Err(err) = chime(Some(&output), 0.000_01, &[440.0; 24]) {
                eprintln!("wake output failed: {err}");
            }
        });
        println!("playing near-silence on the {wake:?} output during the check");
    }
    mic.start();
    thread::sleep(Duration::from_secs(2));
    let lag = mic.lag();
    let clip = mic.stop();
    println!(
        "{} samples at 16 kHz in 2 s ({:.2} s of audio), level {:.4}, first audio after {}",
        clip.len(),
        clip.len() as f32 / WHISPER_RATE as f32,
        loudness(&clip),
        lag.map_or("never".to_string(), |lag| format!("{} ms", lag.as_millis()))
    );
    Ok(())
}

/// Every format each device matching `fragment` accepts: for a Bluetooth headset
/// this says whether its hands-free link can do 16 kHz (wideband speech, mSBC)
/// or only 8 kHz (CVSD, which hisses).
pub fn formats(fragment: &str) -> io::Result<()> {
    let host = cpal::default_host();
    let lowered = fragment.to_ascii_lowercase();
    let named = |device: &cpal::Device| {
        device.description().map(|d| d.name().to_string()).unwrap_or_default()
    };
    for device in host.input_devices().map_err(|err| io::Error::other(err.to_string()))? {
        let name = named(&device);
        if !name.to_ascii_lowercase().contains(&lowered) {
            continue;
        }
        println!("input  {name}");
        if let Ok(configs) = device.supported_input_configs() {
            for config in configs {
                println!("    {:?} {} ch, {}..{} Hz", config.sample_format(), config.channels(),
                    config.min_sample_rate(), config.max_sample_rate());
            }
        }
    }
    for device in host.output_devices().map_err(|err| io::Error::other(err.to_string()))? {
        let name = named(&device);
        if !name.to_ascii_lowercase().contains(&lowered) {
            continue;
        }
        println!("output {name}");
        if let Ok(configs) = device.supported_output_configs() {
            for config in configs {
                println!("    {:?} {} ch, {}..{} Hz", config.sample_format(), config.channels(),
                    config.min_sample_rate(), config.max_sample_rate());
            }
        }
    }
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

/// The resampling filter's half width, in zero crossings of its sinc.
const ZEROS: f64 = 6.0;

/// Whisper wants 16 kHz mono f32. Resampled through a Hann-windowed sinc
/// low-pass at 99% of the lower Nyquist, six zero crossings wide: the filter
/// sherpa-onnx (Kaldi's resampler) applies to the streaming engine's input, so
/// both engines on trial hear the same audio. What it replaced doubled each
/// sample of an 8 kHz mic, mirroring the voice into 4-8 kHz, and let half of
/// what a 48 kHz mic heard above 8 kHz fold back into the voice.
pub(crate) fn to_whisper(samples: &[f32], channels: u16, rate: u32) -> Vec<f32> {
    let channels = channels.max(1) as usize;
    let mono: Vec<f32> = samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect();
    if rate == WHISPER_RATE || mono.is_empty() {
        return mono;
    }
    let (from, to) = (rate as usize, WHISPER_RATE as usize);
    let common = gcd(from, to);
    // every `phases` outputs advance `step` inputs, so one filter per phase serves all
    let (step, phases) = (from / common, to / common);
    // in cycles per input sample, and the filter's reach in input samples
    let cutoff = 0.99 * 0.5 * from.min(to) as f64 / from as f64;
    let reach = ZEROS / (2.0 * cutoff);
    let filters: Vec<(i64, Vec<f32>)> = (0..phases)
        .map(|phase| {
            let at = (phase * step) as f64 / phases as f64;
            let first = (at - reach).ceil() as i64;
            let weights = (first..=(at + reach).floor() as i64)
                .map(|input| {
                    let distance = at - input as f64;
                    let window = 0.5 * (1.0 + (std::f64::consts::PI * distance / reach).cos());
                    let x = std::f64::consts::PI * 2.0 * cutoff * distance;
                    let sinc = if x == 0.0 { 1.0 } else { x.sin() / x };
                    (2.0 * cutoff * sinc * window) as f32
                })
                .collect();
            (first, weights)
        })
        .collect();
    (0..mono.len() * to / from)
        .map(|output| {
            let (first, weights) = &filters[output % phases];
            let start = ((output / phases) * step) as i64 + first;
            weights
                .iter()
                .enumerate()
                .filter_map(|(tap, weight)| Some(mono.get(usize::try_from(start + tap as i64).ok()?)? * weight))
                .sum()
        })
        .collect()
}

fn gcd(a: usize, b: usize) -> usize {
    if b == 0 { a } else { gcd(b, a % b) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// How much of `tone` (Hz) a 16 kHz clip holds, as an amplitude.
    fn amplitude(clip: &[f32], tone: f32) -> f32 {
        let (mut re, mut im) = (0.0f64, 0.0f64);
        for (n, sample) in clip.iter().enumerate() {
            let phase = std::f64::consts::TAU * tone as f64 * n as f64 / WHISPER_RATE as f64;
            re += *sample as f64 * phase.cos();
            im -= *sample as f64 * phase.sin();
        }
        (2.0 * (re * re + im * im).sqrt() / clip.len() as f64) as f32
    }

    #[test]
    fn an_8_khz_voice_is_not_mirrored_above_4_khz() {
        let tone: Vec<f32> = (0..8000).map(|n| (std::f32::consts::TAU * 1000.0 * n as f32 / 8000.0).sin()).collect();
        let clip = to_whisper(&tone, 1, 8000);
        assert!((clip.len() as i32 - 16000).abs() < 32, "{} samples", clip.len());
        assert!(amplitude(&clip, 1000.0) > 0.9);
        // doubling each sample left this mirror at about 0.2 (cos 7π/16)
        assert!(amplitude(&clip, 7000.0) < 0.01, "{}", amplitude(&clip, 7000.0));
    }

    #[test]
    fn what_a_48_khz_mic_hears_above_8_khz_does_not_fold_into_the_voice() {
        let tone: Vec<f32> = (0..48000).map(|n| (std::f32::consts::TAU * 10_000.0 * n as f32 / 48000.0).sin()).collect();
        let clip = to_whisper(&tone, 1, 48000);
        assert_eq!(clip.len(), 16000);
        // a 10 kHz tone folds to 6 kHz; three-sample averaging let about 0.5 through
        assert!(amplitude(&clip, 6000.0) < 0.01, "{}", amplitude(&clip, 6000.0));
        let voice: Vec<f32> = (0..48000).map(|n| (std::f32::consts::TAU * 1000.0 * n as f32 / 48000.0).sin()).collect();
        assert!(amplitude(&to_whisper(&voice, 1, 48000), 1000.0) > 0.9);
    }
}
