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
    let signals = addons.join(crate::LINK).join("Signals");
    [signals.join("pulse-a.wav"), signals.join("pulse-b.wav")]
}

/// Beat while `ready()` says the companion can hear the player.
pub fn start(addons: &Path, ready: fn() -> bool) {
    let addons = addons.to_path_buf();
    thread::spawn(move || {
        let [a, b] = bells(&addons);
        let mut on_a = true;
        let mut session = None;
        // the mic state the game was last told; it forgets at a reload, where it
        // assumes a mic, so a missing one is told again
        let mut told_mic: Option<bool> = None;
        while BEATING.load(Ordering::SeqCst) {
            let began = crate::session_began(&addons);
            let new_session = began != session;
            let mic = crate::voice::MIC.load(Ordering::Relaxed);
            if ready() && (told_mic != Some(mic) || (new_session && !mic)) {
                let status = crate::message::Msg::new("status").flag("mic", mic);
                if crate::send(&addons, &status).is_ok() {
                    told_mic = Some(mic);
                }
            }
            if new_session {
                // a save landed (or the companion started): the ledger drops what
                // the game now holds
                crate::ledger::confirm(&addons);
                session = began;
                // and copy the save, and say
                // so in game if it looks like the addon's data was reset
                for note in crate::backups::snapshot(&addons) {
                    println!("  {note}");
                    if note.starts_with("Your companion") {
                        let _ = crate::post(&addons, crate::message::Line::new("", "error", &note));
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
