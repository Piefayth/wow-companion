//! `wow-companion doctor <AddOns>`: every link of the chain checked in a few
//! seconds, so "is it broken?" is a check rather than a guess. Each line is OK or
//! a problem with what it means; nothing here changes the game.

use std::{
    fs,
    path::Path,
    process::Command,
    thread,
    time::Duration,
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

    // bells: what each file holds, not its size. A ringing bell has its `data`
    // chunk right after the header; the heartbeat's quiet bell is the same size
    // but opens with `JUNK` (bells.rs), so size alone called it ringing.
    let mut ringing = Vec::new();
    let mut empty = Vec::new();
    let mut leftover = Vec::new();
    if let Ok(entries) = fs::read_dir(&signals) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".wav") {
                continue;
            }
            if !current_bell(&name) {
                leftover.push(name);
                continue;
            }
            // always.wav is the probe's control; the pulse bells are the heartbeat's
            if name == "always.wav" || name.starts_with("pulse-") {
                continue;
            }
            // message (m) and catch-up (c) bells and never.wav are empty when idle
            // by design (bells.rs, the 2026-11-09 protocol)
            let idle_empty = name != "doctor.wav";
            let path = entry.path();
            match entry.metadata().map(|meta| meta.len()) {
                Ok(0) if idle_empty => {}
                Ok(len) if len < 174_763 => empty.push(name),
                Ok(_) if rings(&path) => ringing.push(name),
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
    line(ringing.len() <= 2, "bells ringing", &if ringing.is_empty() {
        "none".to_string()
    } else {
        format!("{}{}", ringing.join(", "), if ringing.len() > 2 { " (more than two means a stuck file)" } else { "" })
    });
    line(true, "old bell files", &if leftover.is_empty() {
        "none".to_string()
    } else {
        format!("{} (names no longer used; nothing reads them, safe to delete)", leftover.join(", "))
    });

    // writable: ring and silence a bell nobody listens to
    let test = signals.join("doctor.wav");
    let writable = crate::bells::ring(&test).and_then(|()| crate::bells::silence(&test));
    line(writable.is_ok(), "bell files", &match &writable {
        Ok(()) => "can be rung and silenced".to_string(),
        Err(err) => err.to_string(),
    });

    // heartbeat: both pulse files always exist (one ringing, one the quiet bell)
    // and the ringing one swaps every 4 s (heartbeat.rs)
    let pulse = |at: &str| rings(&signals.join(at));
    // sampled twice a second for 9 s: two snapshots 9 s apart are two swaps
    // apart, and read the same as no swap at all
    let mut swaps = 0;
    let mut both = 0;
    let mut neither = 0;
    let mut last = (pulse("pulse-a.wav"), pulse("pulse-b.wav"));
    for _ in 0..18 {
        thread::sleep(Duration::from_millis(500));
        let now = (pulse("pulse-a.wav"), pulse("pulse-b.wav"));
        match now {
            (true, true) => both += 1,
            (false, false) => neither += 1,
            _ => {}
        }
        if now != last && now.0 != now.1 {
            swaps += 1;
        }
        last = now;
    }
    line(swaps >= 1 && both <= 2, "heartbeat", &if swaps == 0 {
        "not swapping: the companion is down, loading, or handing over".to_string()
    } else if both > 2 {
        format!("both pulse bells ringing in {both} of 18 samples: the mark will flap")
    } else {
        format!("{swaps} swaps in 9 s: the in-game mark should be in colour{}",
            if neither > 0 { format!(" ({neither} of 18 samples caught both quiet mid-swap)") } else { String::new() })
    });

    // the mic: is audio actually arriving?
    println!("checking the mic for 2 s (say nothing, or anything)...");
    if let Err(err) = crate::voice::miccheck(Some("airpods"), None) {
        line(false, "mic", &err.to_string());
    }
    Ok(())
}

/// A bell file that is ringing: a real sound right after the header. The quiet
/// bell (bells.rs) carries a `JUNK` chunk there instead, and an emptied one is 0 bytes.
fn rings(path: &std::path::Path) -> bool {
    let mut head = [0u8; 40];
    match fs::File::open(path) {
        Ok(mut file) => {
            use std::io::Read;
            file.read_exact(&mut head).is_ok() && &head[36..40] == b"data"
        }
        Err(_) => false,
    }
}

/// The bell names in use (bells.rs, main.rs, heartbeat.rs, Status.lua). Anything
/// else in Signals was left by an earlier design.
fn current_bell(name: &str) -> bool {
    let stem = name.trim_end_matches(".wav");
    matches!(stem, "always" | "never" | "doctor" | "pulse-a" | "pulse-b")
        || (stem.len() == 2
            && (stem.starts_with('m') || stem.starts_with('c'))
            && stem[1..].parse::<u32>().is_ok_and(|n| (1..=8).contains(&n)))
}
