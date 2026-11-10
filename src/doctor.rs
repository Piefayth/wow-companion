//! `wow-companion doctor <AddOns>`: every link of the chain checked in a few
//! seconds, so "is it broken?" is a check rather than a guess. Each line is OK or
//! a problem with what it means; nothing here changes the game.

use std::{
    fs,
    path::Path,
    process::Command,
    thread,
    time::{Duration, SystemTime},
};

fn running(image: &str) -> bool {
    Command::new("tasklist")
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).to_lowercase().contains(&image.to_lowercase()))
        .unwrap_or(false)
}

fn agent_busy() -> bool {
    Command::new("wmic")
        .args(["process", "where", "name='claude.exe'", "get", "CommandLine"])
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).contains("json-schema"))
        .unwrap_or(false)
}

fn line(ok: bool, what: &str, detail: &str) {
    println!("{} {what}: {detail}", if ok { "OK     " } else { "PROBLEM" });
}

pub fn run(addons: &Path) -> std::io::Result<()> {
    let signals = addons.join(crate::ADDON).join("Signals");

    line(running("wow.exe"), "game", if running("wow.exe") { "running" } else { "not running" });
    let companion = running("companion-");
    line(companion, "companion", if companion { "running" } else { "not running: start it with `run`" });
    let pending = crate::companion_dir().map(|dir| dir.join("restart.request").exists()).unwrap_or(false);
    line(!pending, "restart", if pending { "a restart is waiting for the companion to go idle" } else { "none pending" });
    line(true, "agent", if agent_busy() { "working on a request" } else { "idle" });

    // slots: how many this UI session has spent, of how many the game can see
    let used = crate::slots_used(addons);
    let known = crate::known_slots(addons);
    line(used + 16 < known, "slots", &format!("{used} of {known} used this session{}",
        if used + 16 >= known { ": nearly out, /reload refills them" } else { "" }));

    // bells: none should be empty (rule 3 in bells.rs), and at most a couple ring
    let mut ringing = Vec::new();
    let mut empty = Vec::new();
    if let Ok(entries) = fs::read_dir(&signals) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            // always.wav is the probe's control; a pulse bell is the heartbeat
            if !name.ends_with(".wav") || name == "always.wav" || name.starts_with("pulse-") {
                continue;
            }
            // message (m) and catch-up (c) bells and never.wav are empty when idle
            // by design (bells.rs, the 2026-11-09 protocol); only a ringing one counts
            let idle_empty = name == "never.wav"
                || (name.len() == 6 && (name.starts_with('m') || name.starts_with('c')));
            match entry.metadata().map(|meta| meta.len()) {
                Ok(0) if idle_empty => {}
                Ok(len) if len < 174_763 => empty.push(name),
                Ok(_) => ringing.push(name),
                _ => {}
            }
        }
    }
    line(empty.is_empty(), "small bells", &if empty.is_empty() {
        "none".to_string()
    } else {
        format!("{} (a small or empty bell gets cached and locked; reinstall, then /reload)", empty.join(", "))
    });
    // one message bell and one catch-up bell may ring at once
    line(ringing.len() <= 2, "bells present", &if ringing.is_empty() {
        "none ringing".to_string()
    } else {
        format!("{} (more than one ringing, or old names, means a stuck file)", ringing.join(", "))
    });

    // writable: ring and silence a bell nobody listens to
    let test = signals.join("doctor.wav");
    let writable = crate::bells::ring(&test).and_then(|()| crate::bells::silence(&test));
    line(writable.is_ok(), "bell files", &match &writable {
        Ok(()) => "can be rung and silenced".to_string(),
        Err(err) => err.to_string(),
    });

    // heartbeat: one pulse bell, swapping every 4 s
    let pulses = |at: &str| -> Option<SystemTime> {
        fs::metadata(signals.join(at)).and_then(|meta| meta.modified()).ok()
    };
    let before = (pulses("pulse-a.wav"), pulses("pulse-b.wav"));
    thread::sleep(Duration::from_secs(9));
    let after = (pulses("pulse-a.wav"), pulses("pulse-b.wav"));
    let both = after.0.is_some() && after.1.is_some();
    let swapped = before != after;
    line(swapped && !both, "heartbeat", &match (swapped, both) {
        (true, false) => "swapping: the in-game mark should be in colour".to_string(),
        (_, true) => "both pulse bells exist at once: the mark will flap".to_string(),
        (false, _) => "not swapping: the companion is down, loading, or handing over".to_string(),
    });

    // the mic: is audio actually arriving?
    println!("checking the mic for 2 s (say nothing, or anything)...");
    if let Err(err) = crate::voice::miccheck(Some("airpods"), None) {
        line(false, "mic", &err.to_string());
    }
    Ok(())
}
