//! The message channel to the game: the sender, the slots and the bells. What
//! is sent goes into the one inbox (src/inbox.rs), which every slot reads.

use super::*;
use crate::message::{Line, Msg, Out};
use crate::session::Session;
use wow_companion_settings::platform::Process;

/// Progress lines stop this many bells before the session's last: those are
/// for replies.
pub(crate) const PROGRESS_STOP: u32 = 14;
/// Slots, and bells per set: a session has sent up to 100 batches
/// (2026-11-11..13), and a false ring spends a slot too. New folders need one
/// full game restart to be seen.
pub(crate) const SLOTS: u32 = 512;
/// A slot's .toc. Each slot is its own group in a category of its own, so the
/// AddOns list folds all of them under one collapsible line (Blizzard_AddOnList:
/// only categories collapse, and the game remembers which; a group's children
/// always show). Slot.xml loads the inbox.
pub(crate) fn slot_toc(slot: u32) -> String {
    format!(
        "## Interface: 16001\n## Title: WoW Companion message slot\n## LoadOnDemand: 1\n## Group: {}\n## Category: WoW Companion: message slots\n\nSlot.xml\n",
        slot_name(slot)
    )
}
/// Every slot loads the one inbox, outside its folder (a path from the game's
/// root is taken inside the slot's folder and fails).
pub(crate) const SLOT_XML: &str =
    "<Ui xmlns=\"http://www.blizzard.com/wow/ui/\">\n\t<Script file=\"..\\WowCompanion_Mailbox\\Mail.lua\"></Script>\n</Ui>\n";

/// The game, held while it runs: asking the held process costs microseconds,
/// where finding it walks every process (about 50 ms), so the walk happens only
/// when no game is held or it has exited.
static GAME: Mutex<Option<Process>> = Mutex::new(None);

/// When the running game started, or None when it does not run.
pub(crate) fn game() -> Option<u64> {
    let mut held = GAME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if !held.as_ref().is_some_and(Process::running) {
        *held = Process::find("Wow.exe");
    }
    held.as_ref().map(Process::started)
}

pub(crate) fn game_running() -> bool {
    game().is_some()
}


/// What waits for the next write, in the order it was posted: lines (numbered
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

    fn progress_of(&self) -> Option<i128> {
        match self {
            Pending::Now(msg) => progress_job(msg),
            Pending::Line(_) => None,
        }
    }
}

/// The request a progress line says what is doing now: a newer one for the
/// same request makes it worthless. A `started` one is not: it ends the queued
/// mark on its request's line.
pub(crate) fn progress_job(msg: &Msg) -> Option<i128> {
    (msg.kind() == Some("progress") && !msg.has("started")).then(|| msg.int_of("job")).flatten()
}

struct Queue {
    waiting: Vec<Pending>,
    /// A batch is being delivered (taken off `waiting`, its bell not yet silent).
    delivering: bool,
    sender: bool,
    /// This copy is leaving (lifecycle::wind_down): it sends nothing more, since
    /// the companion taking over may already be sending.
    closed: bool,
}

static QUEUE: Mutex<Queue> = Mutex::new(Queue { waiting: Vec::new(), delivering: false, sender: false, closed: false });
static MOVED: std::sync::Condvar = std::sync::Condvar::new();

fn queue() -> std::sync::MutexGuard<'static, Queue> {
    QUEUE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Everything goes through one sender thread (one per process), which takes
/// all that is waiting when it is free: one write and one bell per batch, not
/// per message.
fn enqueue(addons: &Path, item: Pending) {
    let mut queue = queue();
    if queue.closed {
        println!("  not sent (this companion is leaving): {}", item.msg().lua().chars().take(120).collect::<String>());
        return;
    }
    queue.waiting.push(item);
    if !queue.sender {
        queue.sender = true;
        let addons = addons.to_path_buf();
        let _ = thread::Builder::new().name("sender".into()).spawn(move || sender(&addons));
    }
    MOVED.notify_all();
}

/// A conversation line: numbered and kept by the ledger (src/ledger.rs), then
/// queued. A line that cannot go out live (the game closed, the bells spent)
/// is in the inbox, which the game takes at its next load. With no ledger
/// there is no conversation (the agents are off): the line is a notice, which
/// the Link addon shows on its own.
pub(crate) fn post(addons: &Path, line: Line) -> io::Result<()> {
    match crate::ledger::number(addons, line) {
        Ok(line) => enqueue(addons, Pending::Line(line)),
        Err(line) => enqueue(addons, Pending::Now(Msg::new("notice").text("text", &line.text))),
    }
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

/// Send nothing more from this copy (after `flush`, as it leaves).
pub(crate) fn close() {
    queue().closed = true;
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
/// not, and they never run later.
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
    // the last bells are for replies: what a request is doing can go unsaid
    if crate::inbox::sent(addons).is_some_and(|sent| sent + PROGRESS_STOP >= SLOTS) {
        batch.retain(|item| item.progress_of().is_none());
    }
    if batch.is_empty() {
        return;
    }
    // every message of the batch in order: the game applies each as if it came alone
    let messages: Vec<Msg> = batch.iter().map(Pending::msg).collect();
    for msg in &messages {
        crate::audit::note("send", "", &msg.lua().chars().take(200).collect::<String>());
    }
    voice::mark("send has the channel");
    match crate::inbox::send(addons, &messages) {
        Ok(n) => {
            println!("sent as write {n}: {}", messages.iter().map(Msg::lua).collect::<Vec<_>>().join(", "));
            voice::mark(&format!("bell rung, write {n}"));
        }
        Err(err) => set_aside(addons, batch, &err.to_string()),
    }
}

/// How many game clients are open (multiboxing: each reads every message).
pub(crate) fn game_clients() -> usize {
    wow_companion_settings::platform::windowed_count("Wow.exe")
}

/// The game's UI session (`Session::key`); None while its save does not parse.
pub(crate) fn session_key(addons: &Path) -> Option<String> {
    Session::now(addons).ok().map(|session| session.key())
}

/// When the running UI session began: a `/reload` writes SavedVariables and
/// *then* reloads, so that write marks the boundary (`Session::began`).
pub(crate) fn session_began(addons: &Path) -> Option<u128> {
    Session::now(addons).ok().map(|session| session.began)
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

pub(crate) fn slot_name(slot: u32) -> String {
    format!("{ADDON}_S{slot:03}")
}

// The bells (docs/proposals/reliable-channel.md): bell n of a set rings when
// write n of its session is in the inbox, and is never emptied while that
// session runs, so nothing has to change while the game holds it; a set per
// session, so a ring never outlives its session. The game asks the bell after
// the last write it applied every 0.1 s.
pub(crate) const SETS: u64 = 3;

pub(crate) fn bell_name(set: u64, n: u32) -> String {
    format!("g{set}-{n:03}.wav")
}

/// Empty each of the bells `names` in `signals` that is rung, saying `why`.
pub(crate) fn empty_rung(signals: &Path, names: impl IntoIterator<Item = String>, why: &str) -> io::Result<()> {
    for name in names {
        let path = signals.join(&name);
        if fs::metadata(&path).is_ok_and(|meta| meta.len() > 0) {
            crate::audit::note("bell", "", &format!("empty {name} ({why})"));
            bells::empty(&path)?;
        }
    }
    Ok(())
}

/// Empty the rung bells of every set but `keep` (none while the game is closed):
/// nothing polls those, so nothing holds them.
fn empty_idle_sets(signals: &Path, keep: Option<u64>) -> io::Result<()> {
    for set in (0..SETS).filter(|set| Some(*set) != keep) {
        empty_rung(signals, (1..=SLOTS).map(|n| bell_name(set, n)), "idle set")?;
    }
    Ok(())
}

/// For the running companion: four times a second, which set the game uses; at
/// every change (a reload, the game closing or starting, the companion
/// starting) the others are emptied, until that has worked.
pub(crate) fn tend_bells(addons: &Path) {
    let signals = addons.join(LINK).join("Signals");
    let mut tended: Option<Option<u64>> = None;
    loop {
        let set = match game_running().then(|| Session::read(addons)) {
            None => None,
            Some(Some(session)) => Some(session.set()),
            // the game is writing its save: asked again at the next look
            Some(None) => {
                thread::sleep(Duration::from_millis(250));
                continue;
            }
        };
        if tended != Some(set) {
            match empty_idle_sets(&signals, set) {
                Ok(()) => tended = Some(set),
                Err(err) => println!("slot bells: {err}"),
            }
        }
        thread::sleep(Duration::from_millis(250));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::State;

    #[test]
    fn every_write_has_its_own_bell_in_each_set() {
        assert_eq!(bell_name(0, 1), "g0-001.wav");
        assert_eq!(bell_name(2, 512), "g2-512.wav");
        let names: std::collections::HashSet<String> =
            (0..SETS).flat_map(|set| (1..=SLOTS).map(move |n| bell_name(set, n))).collect();
        assert_eq!(names.len(), (SETS * SLOTS as u64) as usize);
    }

    #[test]
    fn lua_strings_survive_quotes_backslashes_and_newlines() {
        assert_eq!(lua_string(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(lua_string(r"C:\x"), r#""C:\\x""#);
        assert_eq!(lua_string("a\nb"), r#""a\nb""#);
    }

    #[test]
    fn only_the_idle_sets_bells_are_emptied() {
        let signals = std::env::temp_dir().join(format!("wc-bells-{}", std::process::id()));
        fs::create_dir_all(&signals).unwrap();
        let rung = |set, n| signals.join(bell_name(set, n));
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
}
