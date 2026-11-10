//! The audible cues (off by default: feedback is rumble).

use super::*;

// A sine wave at full scale is far louder than music at the same nominal level, and
// a headset in hands-free mode has its own gain on top. Start very quiet; `volume=`
// tunes it without a rebuild.
pub(crate) const CUE_VOLUME: f32 = 0.015;
// A rising fifth to open, the same fifth falling to close: two notes carry direction
// where one pitch only says "something happened".
pub(crate) const CUE_OPEN: [f32; 2] = [587.33, 880.00];
pub(crate) const CUE_SHUT: [f32; 2] = [880.00, 587.33];
pub(crate) const CUE_NOTE: u64 = 85;
// struck-and-decaying, like a glass or a marimba, rather than a held tone
pub(crate) const CUE_DECAY: f32 = 20.0;

/// A short tone to the default output, so you can hear that push-to-talk went live
/// rather than guessing from whether text eventually appears.
///
/// Spawned on its own thread: capture has to start now, not after the audio device
/// has finished opening.
pub(crate) fn cue(wanted: Option<String>, volume: f32, notes: &'static [f32]) {
    if volume <= 0.0 {
        return;
    }
    thread::spawn(move || {
        if let Err(err) = chime(wanted.as_deref(), volume, notes) {
            eprintln!("cue failed: {err}");
        }
    });
}

pub(crate) fn chime(wanted: Option<&str>, volume: f32, notes: &[f32]) -> io::Result<()> {
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
