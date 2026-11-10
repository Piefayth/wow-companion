//! A heartbeat the game can see, so the player knows whether the companion is
//! listening before they speak into it.
//!
//! The only thing an addon can learn from the PC is whether a sound file plays.
//! So while the companion is ready, exactly one of two silent bells exists, and
//! which one swaps every few seconds. The addon (Status.lua) checks both: a swap
//! seen recently means up; no swap for a while, or neither file, means down. A
//! crash freezes the swapping, so it reads as down within seconds; a clean exit
//! removes both at once.
//!
//! Files are created and deleted, never left empty: an empty bell polled all the
//! time is a small file, small sound files are cached, and a cached file is held
//! open, which is how the window bell came to be locked for good.

use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::Duration,
};

/// Seconds between swaps; Status.lua calls it down after three missed swaps.
const EVERY: Duration = Duration::from_secs(4);

/// Cleared to stop the heartbeat.
pub static BEATING: AtomicBool = AtomicBool::new(true);

fn bells(addons: &Path) -> [PathBuf; 2] {
    let signals = addons.join(crate::ADDON).join("Signals");
    [signals.join("pulse-a.wav"), signals.join("pulse-b.wav")]
}

/// A quarter second of silence at 192 kHz stereo: short, so the game closes the
/// file at once (the 10 s message bell kept it open as a stream, deletes failed,
/// both bells existed, and the mark flapped on and off), yet 192 KB, over the
/// 174,762 bytes below which the game caches a sound instead of rereading it.
fn short_bell() -> Vec<u8> {
    let (rate, channels, bits) = (192_000u32, 2u16, 16u16);
    let data = rate * u32::from(channels) * u32::from(bits / 8) / 4;
    let mut wav = Vec::with_capacity(44 + data as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&rate.to_le_bytes());
    wav.extend_from_slice(&(rate * u32::from(channels) * u32::from(bits / 8)).to_le_bytes());
    wav.extend_from_slice(&(channels * bits / 8).to_le_bytes());
    wav.extend_from_slice(&bits.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data.to_le_bytes());
    wav.resize(44 + data as usize, 0);
    wav
}

/// Beat while `ready()` says the companion can hear the player.
pub fn start(addons: &Path, ready: fn() -> bool) {
    let addons = addons.to_path_buf();
    thread::spawn(move || {
        let [a, b] = bells(&addons);
        let mut on_a = true;
        while BEATING.load(Ordering::SeqCst) {
            if ready() {
                let (show, hide) = if on_a { (&a, &b) } else { (&b, &a) };
                // the game may have the file open for its 0.15 s check; retry
                for _ in 0..40 {
                    if fs::write(show, short_bell()).is_ok() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(25));
                }
                // keep at it until gone (a few seconds at most): both bells at once
                // is what made the mark flap
                for _ in 0..140 {
                    if fs::remove_file(hide).is_ok() || !hide.exists() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(25));
                }
                on_a = !on_a;
            }
            thread::sleep(EVERY);
        }
    });
}
