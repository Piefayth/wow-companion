//! The message channel to the game: slots, the cursor, bells, sending.

use super::*;
use crate::message::{Line, Msg, Out};
use wow_companion_settings::platform::Process;

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

/// The game, held while it runs: asking the held process costs microseconds,
/// where finding it walks every process (about 50 ms, twice per send until
/// 2026-11-11), so the walk happens only when no game is held or it has exited.
static GAME: Mutex<Option<Process>> = Mutex::new(None);

/// When the running game started, or None when it does not run.
fn game() -> Option<u64> {
    let mut held = GAME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if !held.as_ref().is_some_and(Process::running) {
        *held = Process::find("Wow.exe");
    }
    held.as_ref().map(Process::started)
}

pub(crate) fn game_running() -> bool {
    game().is_some()
}

/// One string-valued key out of SavedVariables, unescaped.
/// How many slots the running game knows. The game only sees addon folders that
/// existed when it launched, so slots installed since are invisible to it until a
/// full restart, and a message sent to one would be lost. The addon records the
/// count it sees in SavedVariables; until it has, assume the old 64.
pub(crate) fn known_slots(addons: &Path) -> u32 {
    let counted = saved_variables(addons, LINK)
        .and_then(|saved| fs::read_to_string(saved).ok())
        .and_then(|text| {
            let at = text.find("[\"slotCount\"] = ")? + "[\"slotCount\"] = ".len();
            text[at..].split(|c: char| !c.is_ascii_digit()).next()?.parse::<u32>().ok()
        });
    counted.unwrap_or(64).min(SLOTS)
}

/// What waits for the next slot, in the order it was posted: lines (numbered
/// and kept by the ledger first) and messages about now.
enum Pending {
    Line(Line),
    Now(Msg),
}

impl Pending {
    fn msg(&self) -> Msg {
        match self {
            Pending::Line(line) => line.msg(true),
            Pending::Now(msg) => msg.clone(),
        }
    }

    /// A progress line that only says what a request is doing now: a newer one
    /// for the same request makes it worthless. A `started` one is not: it ends
    /// the queued mark on its request's line.
    fn progress_of(&self) -> Option<i128> {
        match self {
            Pending::Now(msg) if msg.kind() == Some("progress") && !msg.has("started") => msg.int_of("job"),
            _ => None,
        }
    }
}

struct Queue {
    waiting: Vec<Pending>,
    /// A batch is being delivered (taken off `waiting`, its bell not yet silent).
    delivering: bool,
    sender: bool,
}

static QUEUE: Mutex<Queue> = Mutex::new(Queue { waiting: Vec::new(), delivering: false, sender: false });
static MOVED: std::sync::Condvar = std::sync::Condvar::new();

fn queue() -> std::sync::MutexGuard<'static, Queue> {
    QUEUE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Everything goes through one sender thread (one per process), which takes
/// all that is waiting when it is free: one slot and one bell per batch, not
/// per message (the player, 2026-11-11: "the messaging performance is
/// important to me").
fn enqueue(addons: &Path, item: Pending) {
    let mut queue = queue();
    queue.waiting.push(item);
    if !queue.sender {
        queue.sender = true;
        let addons = addons.to_path_buf();
        let _ = thread::Builder::new().name("sender".into()).spawn(move || sender(&addons));
    }
    MOVED.notify_all();
}

/// A conversation line: numbered and kept by the ledger (src/ledger.rs), then
/// queued. A line that cannot go out live (the game closed, the slots spent)
/// is in the mailbox, which the game takes at its next load.
pub(crate) fn post(addons: &Path, line: Line) -> io::Result<()> {
    let line = crate::ledger::number(addons, line);
    enqueue(addons, Pending::Line(line));
    Ok(())
}

/// A message about now (progress, a stop's answer, steps of chat): lost when
/// the game is closed, since nothing would read it.
pub(crate) fn send(addons: &Path, msg: &Msg) -> io::Result<()> {
    enqueue(addons, Pending::Now(msg.clone()));
    Ok(())
}

/// What the courier carries, queued in order.
pub(crate) fn send_out(addons: &Path, out: Out) -> io::Result<()> {
    match out {
        Out::Line(line) => post(addons, line),
        Out::Now(msg) => send(addons, &msg),
    }
}

/// Wait until everything queued so far is delivered or set aside (before a
/// process exits, and for the `send` command).
pub(crate) fn flush() {
    let mut queue = queue();
    while !queue.waiting.is_empty() || queue.delivering {
        queue = MOVED.wait(queue).unwrap_or_else(|poisoned| poisoned.into_inner());
    }
}

fn sender(addons: &Path) {
    loop {
        let batch = {
            let mut queue = queue();
            while queue.waiting.is_empty() {
                queue = MOVED.wait(queue).unwrap_or_else(|poisoned| poisoned.into_inner());
            }
            queue.delivering = true;
            std::mem::take(&mut queue.waiting)
        };
        deliver_batch(addons, batch);
        queue().delivering = false;
        MOVED.notify_all();
    }
}

/// The batch without what it supersedes, exactly: of the progress lines about
/// one request, only the newest stays. Order is kept.
fn supersede(batch: Vec<Pending>) -> Vec<Pending> {
    let mut newest: std::collections::HashMap<i128, usize> = std::collections::HashMap::new();
    for (at, item) in batch.iter().enumerate() {
        if let Some(job) = item.progress_of() {
            newest.insert(job, at);
        }
    }
    batch
        .into_iter()
        .enumerate()
        .filter(|(at, item)| item.progress_of().is_none_or(|job| newest.get(&job) == Some(at)))
        .map(|(_, item)| item)
        .collect()
}

/// What could not go out: a line is in the mailbox already; the changes a
/// reply carried run only as it arrives live, so an error line says they did
/// not (the player, 2026-11-11), and they never run later.
fn set_aside(addons: &Path, items: Vec<Pending>, why: &str) {
    for item in items {
        match item {
            Pending::Line(line) => {
                println!("  line {} of [{}] waits in the mailbox for the next load ({why})", line.n, if line.slot.is_empty() { "main" } else { &line.slot });
                if line.steps.is_some() {
                    let text = format!("The changes that reply carried (macros, bars, code) did not run: {why}. Ask again to apply them.");
                    let _ = post(addons, Line::new(&line.slot, "error", &text));
                }
            }
            Pending::Now(msg) => println!("  not sent ({why}): {}", msg.lua().chars().take(120).collect::<String>()),
        }
    }
}

fn deliver_batch(addons: &Path, batch: Vec<Pending>) {
    let mut batch = supersede(batch);
    if !game_running() {
        return set_aside(addons, batch, "the game is closed");
    }
    // the last slots are for replies: what a request is doing can go unsaid
    if slots_used(addons) + PROGRESS_STOP >= known_slots(addons) {
        batch.retain(|item| item.progress_of().is_none());
    }
    // A line, a progress line, a reload, a show: read by handlers every version
    // of the addon has, so a stale UI can still take them. Blocking those is how a
    // finished answer sat undelivered behind "reload first" while the window spun
    // "thinking". A reload is the cure for staleness itself.
    match addon_is_stale(addons) {
        Ok(true) => {
            let (keep, stale): (Vec<Pending>, Vec<Pending>) = batch
                .into_iter()
                .partition(|item| matches!(item.msg().kind(), Some("log" | "progress" | "reload" | "show")));
            set_aside(addons, stale, "the addon on disk is newer than the running UI session: /reload in game first");
            batch = keep;
        }
        Ok(false) => {}
        Err(err) => return set_aside(addons, batch, &err.to_string()),
    }
    if batch.is_empty() {
        return;
    }
    let list = slot_message(&batch);
    if let Err(err) = ring(addons, &list) {
        if err.to_string().contains("slots are spent") {
            // nothing can reach the game to say so; the pad can
            voice::ALERT.store(true, Ordering::SeqCst);
        }
        set_aside(addons, batch, &err.to_string());
    }
}

/// What one slot holds: `{ kind = "list", messages = { ... } }`, every message
/// of the batch in order (the game applies each as if it came alone).
fn slot_message(batch: &[Pending]) -> Msg {
    let messages: Vec<Msg> = batch.iter().map(Pending::msg).collect();
    for msg in &messages {
        crate::audit::note("send", "", &msg.lua().chars().take(200).collect::<String>());
    }
    Msg::new("list").list("messages", messages)
}

/// One slot and one bell: the 2026-11-09 protocol (CLAUDE.md, "Changing the
/// channel"), unchanged.
fn ring(addons: &Path, msg: &Msg) -> io::Result<()> {
    voice::mark("send has the channel");
    let slot = next_slot(addons)?;
    // A bell left ringing is a command that fires again on every /reload: the addon's
    // cursor goes back to slot 1, hears the old bell, and redelivers. So ring it only
    // long enough to be heard, then silence it. The addon polls every 0.5 s.
    let signals = addons.join(LINK).join("Signals");
    for bell in 1..=BELLS {
        bells::empty(&signals.join(bell_name(bell)))?;
    }
    deliver(addons, slot, msg)?;
    println!("sent in slot {slot}: {}", msg.lua());
    ring_catch_up(&signals, slot);
    voice::mark(&format!("bell rung, slot {slot}"));
    thread::sleep(BELL_HEARD);
    bells::empty(&signals.join(bell_name(slot)))?;
    Ok(())
}

/// How many game clients are running (multiboxing: each reads every message).
pub(crate) fn game_clients() -> usize {
    wow_companion_settings::platform::process_count("Wow.exe")
}

pub(crate) fn deliver(addons: &Path, slot: u32, msg: &Msg) -> io::Result<()> {
    let signals = addons.join(LINK).join("Signals");
    // when it was written, so a catch-up load can tell this session's message from
    // one left in the slot by an earlier session
    let sent = SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_secs()).unwrap_or_default();
    let lua = format!("WowCompanion_Inbox = {}\nWowCompanion_Sent = {sent}\n", msg.lua());
    // the inbox lands first: the bell is what tells the addon to go read it
    write_reporting(&addons.join(slot_name(slot)).join("Inbox.lua"), lua.as_bytes())?;
    // the slot bell, on trial: reported, never a failed send
    if let Err(err) = bells::ring(&signals.join(slot_bell_name(current_set(addons), slot))) {
        println!("slot bell for slot {slot}: {err}");
    }
    bells::ring_message(&signals.join(bell_name(slot)))?;
    // a bell is reused every BELLS sends, so silence it well before then or the
    // addon hears a stale ring and reads a slot we haven't written yet
    if slot > BELL_LINGER {
        bells::empty(&signals.join(bell_name(slot - BELL_LINGER)))?;
    }
    Ok(())
}

// Slots load once per UI session, so the helper has to know where the addon's cursor
// is. It resets when the UI session does, and the game rewrites SavedVariables at
// exactly that moment, so that file's timestamp is the reset signal. No game → PC
// channel needed.
pub(crate) fn next_slot(addons: &Path) -> io::Result<u32> {
    let state = addons.join(LINK).join(STATE);
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
    let state = addons.join(LINK).join(STATE);
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
    game().map(|started| started.to_string())
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
    let addon = modified_millis(&addons.join(LINK).join("Link.lua"));
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
        bells::empty(&signals.join(catch_up_name(bell)))?;
    }
    Ok(())
}

// The slot bells (docs/proposals/slot-bells.md), on trial beside the message
// bells since 2026-11-11, the game only watching them: a bell per slot, never
// emptied while its session runs, so a ring means that slot and nothing has to
// change while the game holds it; a set per session, so a ring never outlives
// its session. The game asks the next slot's every frame.
pub(crate) const SETS: u64 = 3;

pub(crate) fn slot_bell_name(set: u64, slot: u32) -> String {
    format!("g{set}-{slot:03}.wav")
}

/// This session's set: the Link addon's count of its loads, which the save holds
/// for the session before, plus one (the game adds its one at load), modulo SETS.
/// The next session's while the game is closed: it loads the same save.
pub(crate) fn current_set(addons: &Path) -> u64 {
    let loads = saved_variables(addons, LINK)
        .and_then(|save| fs::read_to_string(save).ok())
        .and_then(|save| crate::backups::loads(&save))
        .unwrap_or(0);
    (loads + 1) % SETS
}

/// Empty the rung bells of every set but `keep` (none while the game is closed):
/// nothing polls those, so nothing holds them.
fn empty_idle_sets(signals: &Path, keep: Option<u64>) -> io::Result<()> {
    for set in (0..SETS).filter(|set| Some(*set) != keep) {
        for slot in 1..=SLOTS {
            let path = signals.join(slot_bell_name(set, slot));
            if fs::metadata(&path).is_ok_and(|meta| meta.len() > 0) {
                bells::empty(&path)?;
            }
        }
    }
    Ok(())
}

/// For the running companion: four times a second, which set the game uses; at
/// every change (a reload, the game closing or starting, the companion
/// starting) the others are emptied, until that has worked.
pub(crate) fn tend_slot_bells(addons: &Path) {
    let signals = addons.join(LINK).join("Signals");
    let mut tended: Option<Option<u64>> = None;
    loop {
        let set = game_running().then(|| current_set(addons));
        if tended != Some(set) {
            match empty_idle_sets(&signals, set) {
                Ok(()) => tended = Some(set),
                Err(err) => println!("slot bells: {err}"),
            }
        }
        thread::sleep(Duration::from_millis(250));
    }
}

/// Ring `slot`'s catch-up bell, only once every other one is silent: two ringing
/// would point the addon at two different places.
pub(crate) fn ring_catch_up(signals: &Path, slot: u32) {
    for bell in (1..=BELLS).filter(|bell| *bell != (slot - 1) % BELLS + 1) {
        if let Err(err) = bells::empty(&signals.join(catch_up_name(bell))) {
            println!("catch-up bell not rung for slot {slot}: {err}");
            return;
        }
    }
    if let Err(err) = bells::ring(&signals.join(catch_up_name(slot))) {
        println!("catch-up bell not rung for slot {slot}: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::State;

    #[test]
    fn only_the_idle_sets_slot_bells_are_emptied() {
        let signals = std::env::temp_dir().join(format!("wc-slot-bells-{}", std::process::id()));
        fs::create_dir_all(&signals).unwrap();
        let rung = |set, slot| signals.join(slot_bell_name(set, slot));
        for set in 0..SETS {
            fs::write(rung(set, 7), bells::bell()).unwrap();
        }
        empty_idle_sets(&signals, Some(1)).unwrap();
        let size = |set| fs::metadata(rung(set, 7)).unwrap().len();
        assert_eq!((size(0), size(2)), (0, 0));
        assert!(size(1) > 0, "the running session's ring stays");
        // the game closed: every set
        empty_idle_sets(&signals, None).unwrap();
        assert_eq!(size(1), 0);
        fs::remove_dir_all(&signals).unwrap();
    }

    fn progress(job: u64, text: &str) -> Pending {
        Pending::Now(Msg::new("progress").text("text", text).int("job", job))
    }

    #[test]
    fn a_batch_keeps_only_the_newest_progress_per_request_and_everything_else() {
        let batch = vec![
            progress(1, "reading a"),
            Pending::Line(Line::new("l1", "you", "hi").job(2, State::Running)),
            progress(2, "thinking"),
            progress(1, "reading b"),
            Pending::Now(Msg::new("progress").flag("started", true).text("text", "thinking").int("job", 3)),
            Pending::Now(Msg::new("progress").flag("started", true).text("text", "thinking").int("job", 3)),
            progress(2, "writing"),
            Pending::Now(Msg::new("stopped").text("slot", "")),
        ];
        let kept: Vec<String> = supersede(batch).iter().map(|item| item.msg().lua()).collect();
        assert_eq!(kept.len(), 6, "{kept:#?}");
        assert!(kept[0].contains("who = \"you\""), "a line stays, in its place: {kept:#?}");
        assert!(kept[1].contains("reading b"), "job 1's newest only: {kept:#?}");
        assert!(kept[2].contains("started = true") && kept[3].contains("started = true"), "a started one is never superseded");
        assert!(kept[4].contains("writing"), "job 2's newest only: {kept:#?}");
        assert!(kept[5].contains("stopped"));
        assert!(!kept.iter().any(|lua| lua.contains("reading a") || lua.contains("\"thinking\", job = 2")));
    }

    #[test]
    fn one_slot_holds_the_whole_batch_as_a_list_in_order() {
        let mut line = Line::new("", "claude", "done").steps(Some(Msg::new("reload")));
        line.n = 4;
        let batch = vec![Pending::Now(Msg::new("heard").int("job", 9).text("slot", "r1").text("state", "hearing")), Pending::Line(line)];
        assert_eq!(
            slot_message(&batch).lua(),
            r#"{ kind = "list", messages = { { kind = "heard", job = 9, slot = "r1", state = "hearing" }, { kind = "log", slot = "", n = 4, who = "claude", text = "done", andThen = { kind = "reload" } } } }"#
        );
    }
}
