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
    time::{Duration, Instant},
};

/// Seconds between swaps; Status.lua calls it down after three missed swaps.
const EVERY: Duration = Duration::from_secs(4);
/// How soon a changed mic or setting is told (`status`): a quarter second, so
/// the settings page's "applying" ends about as soon as the change is taken.
const TICK: Duration = Duration::from_millis(250);

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
        let mut saved = None;
        // the UI session, mic state, settings and mics listed the game was last
        // told (`status`; the settings count up as the voice loop takes a
        // change). A session is the channel's: the last save and when Wow.exe
        // started, so a fresh launch, which saves nothing, is a new one too; told
        // while the game was closed, it is told again once the game runs
        let mut told: Option<(Option<String>, bool, usize, Vec<String>)> = None;
        // the session and the mics are looked up at each beat: finding a game
        // that is not running walks every process
        let mut stamp = None;
        let mut mics = Vec::new();
        let mut beat_at = Instant::now();
        while BEATING.load(Ordering::SeqCst) {
            // nothing until this copy has taken over (the ledger, the channel)
            // and nothing once it is leaving: the other copy has them then
            if !ready() {
                thread::sleep(TICK);
                continue;
            }
            let beat = Instant::now() >= beat_at;
            if beat {
                stamp = crate::saved_variables_stamp(&addons);
                mics = crate::voice::input_names();
            }
            let now = (stamp.clone(), crate::voice::MIC.load(Ordering::Relaxed), crate::voice::APPLIED.load(Ordering::SeqCst), mics.clone());
            if told.as_ref() != Some(&now) {
                if crate::send(&addons, &crate::settings_page::status(now.1, &now.3)).is_ok() {
                    told = Some(now);
                }
            }
            if !beat {
                thread::sleep(TICK);
                continue;
            }
            beat_at = Instant::now() + EVERY;
            let began = crate::session_began(&addons);
            let new_session = began != saved;
            if new_session {
                // a save landed (or the companion started): the ledger drops what
                // the game now holds
                crate::ledger::confirm(&addons);
                saved = began;
                // and copy the save, and say
                // so in game if it looks like the addon's data was reset
                for note in crate::backups::snapshot(&addons) {
                    println!("  {note}");
                    if note.starts_with("Your companion") {
                        let _ = crate::post(&addons, crate::message::Line::new("", "error", &note));
                    }
                }
            }
            let (show, hide) = if on_a { (&a, &b) } else { (&b, &a) };
            // both bells at once is what made the mark flap: report, don't hide it
            if let Err(err) = crate::bells::ring(show).and_then(|()| crate::bells::silence(hide)) {
                eprintln!("heartbeat: {err}");
            }
            on_a = !on_a;
            thread::sleep(TICK);
        }
    });
}
