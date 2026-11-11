//! A heartbeat the game can see, so the player knows whether the companion is
//! listening before they speak into it.
//!
//! The only thing an addon can learn from the PC is whether a sound file plays.
//! So while the companion is ready, exactly one of two bells rings (the other is
//! the quiet bell), and which one swaps every few seconds. The addon (Status.lua) checks both: a swap
//! seen recently means up; no swap for a while, or neither file, means down. A
//! crash freezes the swapping, so it reads as down within seconds.
//!
//! The bells follow bells.rs: short, over the cache threshold, created to ring
//! and deleted to silence.

use std::{
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

/// Beat while `ready()` says the companion can hear the player.
pub fn start(addons: &Path, ready: fn() -> bool) {
    let addons = addons.to_path_buf();
    thread::spawn(move || {
        let [a, b] = bells(&addons);
        let mut on_a = true;
        let mut session = None;
        while BEATING.load(Ordering::SeqCst) {
            // a new UI session (the save file was just written): clear the catch-up
            // bells so the fresh addon is not pointed at the old session's slots
            let began = crate::session_began(&addons);
            if began != session {
                // not the first look: that is the companion starting, not a reload
                if session.is_some() {
                    crate::resync(&addons);
                }
                session = began;
                if let Err(err) = crate::clear_catch_up(&addons.join(crate::ADDON).join("Signals")) {
                    eprintln!("heartbeat: {err}");
                }
                // a save just landed (or the companion started): copy it, and say
                // so in game if it looks like the addon's data was reset
                for note in crate::backups::snapshot(&addons) {
                    println!("  {note}");
                    if note.starts_with("Your companion") {
                        let _ = crate::send_inbox(&addons, &crate::log_inbox("error", &note, None, None));
                    }
                }
            }
            if ready() {
                let (show, hide) = if on_a { (&a, &b) } else { (&b, &a) };
                // both bells at once is what made the mark flap: report, don't hide it
                if let Err(err) = crate::bells::ring(show).and_then(|()| crate::bells::silence(hide)) {
                    eprintln!("heartbeat: {err}");
                }
                on_a = !on_a;
            }
            thread::sleep(EVERY);
        }
    });
}
