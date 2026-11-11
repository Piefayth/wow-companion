//! The message channel to the game: slots, the cursor, bells, sending.

use super::*;

pub(crate) const PROGRESS_STOP: u32 = 14;
// 512, not 64: a session spent all 64 (progress lines were nearly half) and every
// later reply was lost. New folders need one full game restart to be seen.
pub(crate) const SLOTS: u32 = 512;
pub(crate) const BELLS: u32 = 8;
// the addon only checks the next bell, so a rung bell stays rung for this many sends
pub(crate) const BELL_LINGER: u32 = 4;
// long enough for the addon's 0.5 s poll to catch a bell several times over
pub(crate) const BELL_HEARD: Duration = Duration::from_secs(2);
// every slot is identical; Slot.xml pulls in Inbox.lua so addon managers see one fixed fingerprint
pub(crate) const SLOT_TOC: &str = "## Interface: 16001\n## Title: WoW Companion slot\n## LoadOnDemand: 1\n## Group: WowCompanion\n\nSlot.xml\n";
pub(crate) const SLOT_XML: &str = "<Ui xmlns=\"http://www.blizzard.com/wow/ui/\">\n\t<Script file=\"Inbox.lua\"></Script>\n</Ui>\n";

// where the helper remembers the addon's slot cursor; inert to the game, which only
// loads files a toc or xml points at
pub(crate) const STATE: &str = "helper-state.txt";

#[cfg(windows)]
pub(crate) fn game_running() -> io::Result<bool> {
    let listed = std::process::Command::new("tasklist")
        .args(["/FI", "IMAGENAME eq Wow.exe", "/NH"])
        .output()?;
    Ok(String::from_utf8_lossy(&listed.stdout).contains("Wow.exe"))
}

#[cfg(not(windows))]
pub(crate) fn game_running() -> io::Result<bool> {
    Ok(true)
}

/// One string-valued key out of SavedVariables, unescaped.
/// How many slots the running game knows. The game only sees addon folders that
/// existed when it launched, so slots installed since are invisible to it until a
/// full restart, and a message sent to one would be lost. The addon records the
/// count it sees in SavedVariables; until it has, assume the old 64.
pub(crate) fn known_slots(addons: &Path) -> u32 {
    let counted = saved_variables(addons)
        .and_then(|saved| fs::read_to_string(saved).ok())
        .and_then(|text| {
            let at = text.find("[\"slotCount\"] = ")? + "[\"slotCount\"] = ".len();
            text[at..].split(|c: char| !c.is_ascii_digit()).next()?.parse::<u32>().ok()
        });
    counted.unwrap_or(64).min(SLOTS)
}

// One send at a time: each one silences every bell before ringing its own and
// takes the next slot, so progress updates and replies from different threads
// would otherwise step on each other.
pub(crate) static SENDING: Mutex<()> = Mutex::new(());

pub(crate) fn send_inbox(addons: &Path, inbox: &str) -> io::Result<()> {
    let sent = send_inbox_once(addons, inbox);
    if let Err(err) = &sent {
        if err.to_string().contains("slots are spent") {
            // nothing can reach the game to say so; the pad can
            voice::ALERT.store(true, Ordering::SeqCst);
        }
    }
    sent
}

pub(crate) fn send_inbox_once(addons: &Path, inbox: &str) -> io::Result<()> {
    voice::mark(&format!("send asked: {}", inbox.chars().take(50).collect::<String>()));
    crate::audit::note("send", "", &inbox.chars().take(200).collect::<String>());
    // Status updates (progress, "transcribing") are advisory: they go out only when
    // the channel is free, and are dropped when it is busy, since a newer one or
    // the reply itself follows. Every send holds the channel for the bell's 2 s,
    // and status updates were 40 of 66 sends, so replies queued behind half a
    // minute of them (measured 2026-11-10).
    let advisory = inbox.starts_with("{ kind = \"progress\"") || inbox.starts_with("{ kind = \"transcribing\"");
    let _one_at_a_time = if advisory {
        match SENDING.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return Ok(()),
        }
    } else {
        SENDING.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    };
    // the board is read now, with the channel held: nothing finishing while we
    // waited for it can be undone by an older list
    let board;
    let inbox = if inbox == BOARD_NOW {
        board = board_inbox();
        board.as_str()
    } else {
        inbox
    };
    if !game_running()? {
        // a conversation line waits in the save file for the next login
        if crate::offline::keep(addons, inbox)? {
            return Ok(());
        }
        return Err(io::Error::other("Wow.exe isn't running, so nothing would read this"));
    }
    // A reply or a progress line is read by handlers every version of the addon
    // has, so a stale UI can still take it. Blocking those is how a finished answer
    // sat undelivered behind "reload first" while the window spun "thinking".
    // A reload is the same: every version has it, and it is the cure for staleness.
    if (inbox.starts_with("{ kind = \"progress\"") || inbox.starts_with("{ kind = \"transcribing\""))
        && slots_used(addons) + PROGRESS_STOP >= known_slots(addons)
    {
        // the last slots are for replies; a skipped progress line is no loss
        return Ok(());
    }
    let always_readable = ["log", "progress", "reload", "board", "transcribing", "show"]
        .iter()
        .any(|kind| inbox.starts_with(&format!("{{ kind = \"{kind}\"")))
        // a status line made non-advisory by a leading flag is still one the
        // oldest addon reads
        || inbox.starts_with("{ started = true, kind = \"progress\"")
        || inbox.starts_with("{ resync = true, kind = \"progress\"");
    if !always_readable && addon_is_stale(addons)? {
        return Err(io::Error::other(
            "the addon on disk is newer than the running UI session: /reload in game first",
        ));
    }
    voice::mark("send has the channel");
    let slot = next_slot(addons)?;
    // A bell left ringing is a command that fires again on every /reload: the addon's
    // cursor goes back to slot 1, hears the old bell, and redelivers. So ring it only
    // long enough to be heard, then silence it. The addon polls every 0.5 s.
    let signals = addons.join(ADDON).join("Signals");
    for bell in 1..=BELLS {
        bells::empty_message(&signals.join(bell_name(bell)))?;
    }
    deliver(addons, slot, inbox)?;
    println!("sent in slot {slot}: {inbox}");
    ring_catch_up(&signals, slot);
    voice::mark(&format!("bell rung, slot {slot}"));
    thread::sleep(BELL_HEARD);
    bells::empty_message(&signals.join(bell_name(slot)))?;
    Ok(())
}

pub(crate) fn deliver(addons: &Path, slot: u32, inbox: &str) -> io::Result<()> {
    let signals = addons.join(ADDON).join("Signals");
    // when it was written, so a catch-up load can tell this session's message from
    // one left in the slot by an earlier session
    let sent = SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_secs()).unwrap_or_default();
    let lua = format!("WowCompanion_Inbox = {inbox}\nWowCompanion_Sent = {sent}\n");
    // the inbox lands first: the bell is what tells the addon to go read it
    write_reporting(&addons.join(slot_name(slot)).join("Inbox.lua"), lua.as_bytes())?;
    bells::ring_message(&signals.join(bell_name(slot)))?;
    // a bell is reused every BELLS sends, so silence it well before then or the
    // addon hears a stale ring and reads a slot we haven't written yet
    if slot > BELL_LINGER {
        bells::empty_message(&signals.join(bell_name(slot - BELL_LINGER)))?;
    }
    Ok(())
}

// Slots load once per UI session, so the helper has to know where the addon's cursor
// is. It resets when the UI session does, and the game rewrites SavedVariables at
// exactly that moment, so that file's timestamp is the reset signal. No game → PC
// channel needed.
pub(crate) fn next_slot(addons: &Path) -> io::Result<u32> {
    let state = addons.join(ADDON).join(STATE);
    let stamp = saved_variables_stamp(addons).unwrap_or_default();
    let (mut cursor, seen) = fs::read_to_string(&state)
        .ok()
        .and_then(|text| {
            let mut lines = text.lines();
            let cursor = lines.next()?.trim().parse().ok()?;
            Some((cursor, lines.next().unwrap_or_default().trim().to_string()))
        })
        .unwrap_or((1, String::new()));
    if stamp != seen {
        cursor = 1;
    }
    if cursor > known_slots(addons) {
        return Err(io::Error::other(format!(
            "all {SLOTS} slots are spent this UI session: `send reload`, or /reload in game"
        )));
    }
    fs::write(&state, format!("{}\n{}\n", cursor + 1, stamp))?;
    Ok(cursor)
}

/// Slots spent in the running UI session (0 after a reload), without spending one.
pub(crate) fn slots_used(addons: &Path) -> u32 {
    let state = addons.join(ADDON).join(STATE);
    let stamp = saved_variables_stamp(addons).unwrap_or_default();
    let Ok(text) = fs::read_to_string(&state) else { return 0 };
    let mut lines = text.lines();
    let cursor: u32 = lines.next().and_then(|line| line.trim().parse().ok()).unwrap_or(1);
    if lines.next().unwrap_or_default().trim() != stamp {
        return 0;
    }
    cursor.saturating_sub(1)
}

/// What identifies the game's UI session for the slot cursor: the last save
/// (written at every /reload and logout) and when the running Wow.exe started.
/// The second matters: a freshly launched game starts its own cursor at 1 before
/// it has saved anything, and messages counted against the old session sent the
/// fresh addon waiting on a slot that had already rung (2026-11-10).
pub(crate) fn saved_variables_stamp(addons: &Path) -> Option<String> {
    let saved = session_began(addons).map(|millis| millis.to_string())?;
    Some(format!("{saved}|{}", game_started().unwrap_or_default()))
}

/// When the running Wow.exe started, as Windows reports it; None if not running.
pub(crate) fn game_started() -> Option<String> {
    let out = std::process::Command::new("wmic")
        .args(["process", "where", "name='Wow.exe'", "get", "CreationDate"])
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .find(|line| line.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .map(str::to_string)
}

/// When the running UI session started, near enough: a `/reload` writes SavedVariables
/// and *then* reloads, so that write marks the boundary between sessions.
pub(crate) fn session_began(addons: &Path) -> Option<u128> {
    // <client>/Interface/AddOns -> <client>/WTF/Account/<account>/SavedVariables
    let accounts = addons.parent()?.parent()?.join("WTF").join("Account");
    let mut newest = None;
    for account in fs::read_dir(accounts).ok()?.flatten() {
        let saved = account.path().join("SavedVariables").join(format!("{ADDON}.lua"));
        if let Some(millis) = modified_millis(&saved) {
            newest = Some(newest.map_or(millis, |best: u128| best.max(millis)));
        }
    }
    newest
}

/// Is the game running code we have already replaced?
///
/// A version number in SavedVariables cannot answer this: the game saves before it
/// reloads, so the recorded version always describes the *previous* session. The
/// timestamps can, because that same ordering makes the save mark where the current
/// session began. Addon newer than that means the session predates it.
///
/// Worth the check: twice this cost us a stuck chat box and a half-dead controller,
/// because a retired handler was still live and still opening the chat box.
pub(crate) fn addon_is_stale(addons: &Path) -> io::Result<bool> {
    let addon = modified_millis(&addons.join(ADDON).join("Companion.lua"));
    Ok(match (addon, session_began(addons)) {
        (Some(addon), Some(began)) => addon > began,
        // never saved, or no addon: nothing to compare, so do not block
        _ => false,
    })
}

pub(crate) fn modified_millis(path: &Path) -> Option<u128> {
    fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|since| since.as_millis())
}

// an agent will be writing these eventually, so quote defensively rather than trusting
// the text to be free of quotes, backslashes and newlines
pub(crate) fn lua_string(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\0' => quoted.push_str("\\0"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

// the game may hold a bell open while it plays, which Windows can refuse to overwrite;
// retry so we learn how long that lasts instead of failing
pub(crate) fn write_reporting(path: &Path, contents: &[u8]) -> io::Result<()> {
    let start = Instant::now();
    let mut attempts = 0;
    loop {
        attempts += 1;
        match fs::write(path, contents) {
            Ok(()) => {
                if attempts > 1 {
                    println!(
                        "  {} was locked; wrote it after {attempts} tries ({:?})",
                        path.display(),
                        start.elapsed()
                    );
                }
                return Ok(());
            }
            Err(err) if start.elapsed() < Duration::from_secs(2) => {
                if attempts == 1 {
                    println!("  {} write failed ({err}), retrying", path.display());
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(err) => return Err(err),
        }
    }
}

pub(crate) fn slot_name(slot: u32) -> String {
    format!("{ADDON}_S{slot:03}")
}

// "m" names since 2026-11-10: the plain 1.wav to 8.wav were left as valid
// sounds by a failed experiment, which the polling game then held open for good;
// fresh names the game has never opened start the channel clean
pub(crate) fn bell_name(n: u32) -> String {
    format!("m{}.wav", (n - 1) % BELLS + 1)
}

// The catch-up bells, beside the message bells (CLAUDE.md, "Changing the channel").
// A message bell rings for 2 s; a loading screen or a hitch longer than that and
// the addon never hears it, and since it waits on that slot, every later message
// was lost until a /reload. So the newest slot also rings its catch-up bell
// `c<n>.wav` until the next send. The addon, once it has heard one message this
// session, checks one catch-up bell per poll, in turn over the next 7 slots: one
// ringing means the companion has written up to there, and it takes the slots in
// order. The idle state is an empty file, as for the message bells. Failures here
// are reported and never stop a send: the message bell is still the channel.
pub(crate) fn catch_up_name(n: u32) -> String {
    format!("c{}.wav", (n - 1) % BELLS + 1)
}

/// Silence every catch-up bell (a new UI session starts its cursor at 1, and a
/// catch-up bell left from the old one would point it at stale slots).
pub(crate) fn clear_catch_up(signals: &Path) -> io::Result<()> {
    for bell in 1..=BELLS {
        bells::empty_message(&signals.join(catch_up_name(bell)))?;
    }
    Ok(())
}

/// Ring `slot`'s catch-up bell, only once every other one is silent: two ringing
/// would point the addon at two different places.
pub(crate) fn ring_catch_up(signals: &Path, slot: u32) {
    for bell in (1..=BELLS).filter(|bell| *bell != (slot - 1) % BELLS + 1) {
        if let Err(err) = bells::empty_message(&signals.join(catch_up_name(bell))) {
            println!("catch-up bell not rung for slot {slot}: {err}");
            return;
        }
    }
    if let Err(err) = bells::ring(&signals.join(catch_up_name(slot))) {
        println!("catch-up bell not rung for slot {slot}: {err}");
    }
}
