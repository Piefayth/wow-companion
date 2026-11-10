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
    [signals.join("alive-a.wav"), signals.join("alive-b.wav")]
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
                    if fs::write(show, crate::silent_wav()).is_ok() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(25));
                }
                for _ in 0..40 {
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
