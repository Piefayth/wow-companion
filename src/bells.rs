//! Every bell file, and the rules for them, in one place.
//!
//! A bell is the only signal the PC can give the game: the addon plays a sound
//! file and asks whether it is playing. The game's own handling of sound files
//! decides what works, and each of these rules was learned by breaking it:
//!
//! 1. **The game holds a sound file open while it plays it**, a long one for its
//!    whole length, streamed. A 10 s bell polled every second was never free:
//!    it could not be replaced or deleted again (the first heartbeat, 2026-11-09).
//!    So a bell is short: half a second.
//! 2. **Below 174,762 bytes the game caches a sound** and holds the cached file.
//!    An empty bell polled constantly was locked for good (the window bell). So a
//!    bell is never small: 192,044 bytes, at 96 kHz stereo.
//! 3. **Silence is a missing file, never an empty one.** A file that does not
//!    exist cannot be cached or held, and playing it just fails.
//! 4. **Every write and delete is retried and checked**, and a failure names the
//!    file. A retry that gave up quietly is how a stuck bell looked like nothing.
//!
//! Half a second is still long enough for the addon's check, which asks 0.15 s
//! after it starts the sound.

use std::{
    fs, io,
    path::Path,
    thread,
    time::{Duration, Instant},
};

const RATE: u32 = 96_000;
const CHANNELS: u16 = 2;
const MILLIS: u32 = 500;
// how long to keep at a locked bell before calling it stuck
const PATIENCE: Duration = Duration::from_secs(3);

/// The bell's bytes: half a second of silence, over the cache threshold.
pub fn bell() -> Vec<u8> {
    let bits = 16u16;
    let block = u32::from(CHANNELS) * u32::from(bits / 8);
    let data = RATE * block * MILLIS / 1000;
    let mut wav = Vec::with_capacity(44 + data as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&CHANNELS.to_le_bytes());
    wav.extend_from_slice(&RATE.to_le_bytes());
    wav.extend_from_slice(&(RATE * block).to_le_bytes());
    wav.extend_from_slice(&(block as u16).to_le_bytes());
    wav.extend_from_slice(&bits.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data.to_le_bytes());
    wav.resize(44 + data as usize, 0);
    wav
}

/// Ring: make the bell exist.
pub fn ring(path: &Path) -> io::Result<()> {
    patiently(path, "ring", || fs::write(path, bell()))
}

/// Silence: make the bell not exist. Already missing is already silent.
pub fn silence(path: &Path) -> io::Result<()> {
    patiently(path, "silence", || match fs::remove_file(path) {
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        done => done,
    })
}

fn patiently(path: &Path, what: &str, mut attempt: impl FnMut() -> io::Result<()>) -> io::Result<()> {
    let start = Instant::now();
    let mut tries = 0;
    loop {
        tries += 1;
        match attempt() {
            Ok(()) => {
                if tries > 1 {
                    println!("  {} was held; {what} after {tries} tries ({:?})", path.display(), start.elapsed());
                }
                return Ok(());
            }
            Err(err) if start.elapsed() < PATIENCE => {
                let _ = err;
                thread::sleep(Duration::from_millis(25));
            }
            Err(err) => {
                return Err(io::Error::other(format!(
                    "could not {what} {} for {:?}: {err} (the game is holding it)",
                    path.display(),
                    PATIENCE
                )));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::bell;

    #[test]
    fn a_bell_is_over_the_cache_threshold_and_short() {
        let wav = bell();
        assert!(wav.len() > 174_762, "{} bytes would be cached", wav.len());
        assert_eq!(wav.len(), 192_044);
        assert_eq!(&wav[..4], b"RIFF");
    }
}
