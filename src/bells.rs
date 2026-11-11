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
//! 3. **Never delete a bell the game polls**: it remembers a missing sound, so a
//!    bell created later was never heard (223 polls, 0 heard, 2026-11-10).
//! 3b. **A valid sound the game polls constantly is held open constantly.** The
//!    quiet bell (10 ms of sound padded to size) could not be emptied again once
//!    the addon polled it. An *empty* file fails to play at once and holds
//!    nothing, which is why idle slot bells are empty.
//! 4. **Every write and delete is retried and checked**, and a failure names the
//!    file. A retry that gave up quietly is how a stuck bell looked like nothing.
//! 5. **A long sound is streamed, and not playing a frame after it starts**; the
//!    half-second `bell` plays 2 ms after (measured 2026-11-11). Asked every
//!    frame, the old ten-second message bell was never heard, so it was never let
//!    go and could never be emptied (the frame bell trial, docs/history.md).
//! 6. **Asked every frame, any bell makes the game hold its sound files**, an
//!    empty one too: the heartbeat's and the message bells were held for seconds
//!    (2026-11-11). At 10 asks a second they were not.
//!
//! What this means in practice: the slot bells (docs/proposals/slot-bells.md)
//! use `ring` / `empty`; the heartbeat's pulse bells `ring` / `silence`. See
//! CLAUDE.md, "Changing the channel", before touching either.

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

/// The silent bell: 10 ms of sound, finished long before the addon asks at
/// 0.15 s, padded with a `JUNK` chunk to the same size as a ringing bell so it is
/// never cached and never missing.
pub fn quiet() -> Vec<u8> {
    let bits = 16u16;
    let block = u32::from(CHANNELS) * u32::from(bits / 8);
    let data = RATE * block / 100;
    // RIFF header 12, fmt chunk 24, JUNK header 8 + padding, data header 8 + data
    let padding = 192_044u32.saturating_sub(12 + 24 + 8 + 8 + data) & !1;
    let mut wav = Vec::with_capacity(192_044);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(4 + 24 + 8 + padding + 8 + data).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&CHANNELS.to_le_bytes());
    wav.extend_from_slice(&RATE.to_le_bytes());
    wav.extend_from_slice(&(RATE * block).to_le_bytes());
    wav.extend_from_slice(&(block as u16).to_le_bytes());
    wav.extend_from_slice(&bits.to_le_bytes());
    wav.extend_from_slice(b"JUNK");
    wav.extend_from_slice(&padding.to_le_bytes());
    wav.resize(wav.len() + padding as usize, 0);
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data.to_le_bytes());
    wav.resize(wav.len() + data as usize, 0);
    wav
}

/// Empty a slot bell: its idle state (an empty file fails to play at once and
/// holds nothing).
pub fn empty(path: &Path) -> io::Result<()> {
    patiently(path, "silence", || fs::write(path, []))
}

/// Ring: half a second of sound, still playing when the addon checks.
pub fn ring(path: &Path) -> io::Result<()> {
    patiently(path, "ring", || fs::write(path, bell()))
}

/// Silence: the quiet bell, never a missing or empty file (rule 3).
pub fn silence(path: &Path) -> io::Result<()> {
    patiently(path, "silence", || fs::write(path, quiet()))
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
    fn the_quiet_bell_is_big_short_and_well_formed() {
        let wav = super::quiet();
        assert!(wav.len() > 174_762, "{} bytes would be cached", wav.len());
        assert_eq!(&wav[..4], b"RIFF");
        let riff = u32::from_le_bytes(wav[4..8].try_into().unwrap()) as usize;
        assert_eq!(riff + 8, wav.len(), "RIFF size must match the file");
        // 10 ms of 16-bit stereo at RATE, after its data header
        let data = (super::RATE * 2 * 2 / 100) as usize;
        assert_eq!(&wav[wav.len() - data - 8..wav.len() - data - 4], b"data");
    }

    #[test]
    fn a_bell_is_over_the_cache_threshold_and_short() {
        let wav = bell();
        assert!(wav.len() > 174_762, "{} bytes would be cached", wav.len());
        assert_eq!(wav.len(), 192_044);
        assert_eq!(&wav[..4], b"RIFF");
    }
}
