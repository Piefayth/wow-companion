//! The inbox (docs/proposals/reliable-channel.md): one file, the mailbox's
//! `Mail.lua`, which the game reads at every load and every slot reads during a
//! session (each slot's Slot.xml names it).
//!
//! It holds all the game may not have applied: every batch sent this session as
//! a numbered write, steps included (a progress line only until a newer one for
//! its request), and every conversation line the game has not saved and every
//! request's state (the ledger, src/ledger.rs). It is replaced whole (written
//! beside, renamed over) at every send and every change of the ledger, so the
//! game never opens half of it and never finds it empty: an empty Lua file is a
//! Lua error in game, which opens its error window. A send then rings bell n of
//! the session's set.
//!
//! The game asks the bell after the last write it applied; a ring loads its next
//! slot, which reads the inbox and applies every write newer than that. A false
//! ring (the game reads an empty bell as playing at a busy moment) finds none
//! newer: a slot spent, nothing lost.
//!
//! The session's writes are kept in `inbox.json` in the companion's folder, so a
//! companion that takes over goes on numbering where the last one stopped.

use super::*;
use crate::message::Msg;
use crate::session::Session;
use serde_json::{json, Value};

/// The mailbox addon's folder in AddOns; the inbox is its `Mail.lua`.
pub(crate) const MAILBOX: &str = "WowCompanion_Mailbox";

pub(crate) fn path(addons: &Path) -> PathBuf {
    addons.join(MAILBOX).join("Mail.lua")
}

/// Sends and ledger changes write the inbox one at a time. Taken before the
/// ledger's lock, never while holding it.
static WRITING: Mutex<()> = Mutex::new(());

/// This session's writes; pure, so its rules are tested without files.
#[derive(Clone, Debug, Default, PartialEq)]
struct Writes {
    /// The session they are for (`Session::key`).
    session: String,
    /// Its number, which the game checks (`Session::number`).
    number: u64,
    /// Write n is `writes[n - 1]`: each message as Lua, with the request it
    /// says the progress of (`channel::progress_job`).
    writes: Vec<Vec<(Option<i128>, String)>>,
}

impl Writes {
    /// Add a batch as the next write, and return its number. A progress line
    /// leaves every earlier write: the newer one says all it said.
    fn add(&mut self, messages: &[Msg]) -> u32 {
        for job in messages.iter().filter_map(channel::progress_job) {
            for write in &mut self.writes {
                write.retain(|(of, _)| *of != Some(job));
            }
        }
        self.writes.push(messages.iter().map(|msg| (channel::progress_job(msg), msg.lua())).collect());
        self.writes.len() as u32
    }

    /// The whole file: the session, its last write and every write (a write
    /// left with nothing still says its number), then the ledger's `lines` and
    /// `jobs`.
    fn lua(&self, lines: &[Msg], jobs: &[Msg]) -> String {
        let list = |items: Vec<String>| if items.is_empty() { "{ }".to_string() } else { format!("{{ {} }}", items.join(", ")) };
        let writes: Vec<String> = self
            .writes
            .iter()
            .enumerate()
            .map(|(at, write)| format!("{{ n = {}, messages = {} }}", at + 1, list(write.iter().map(|(_, lua)| lua.clone()).collect())))
            .collect();
        let written = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default();
        format!(
            "-- Written by the companion (src/inbox.rs) at every send and every change of\n\
             -- the ledger: this session's writes, every conversation line the game has\n\
             -- not saved yet, and every request's state. Do not edit.\n\
             WowCompanion_Mail = {{ written = {written}, session = {}, bell = {}, writes = {}, lines = {}, jobs = {} }}\n",
            self.number,
            self.writes.len(),
            list(writes),
            list(lines.iter().map(Msg::lua).collect()),
            list(jobs.iter().map(Msg::lua).collect()),
        )
    }

    fn to_json(&self) -> Value {
        json!({
            "session": self.session,
            "number": self.number,
            "writes": self.writes.iter().map(|write| write.iter().map(|(job, lua)| json!([job.map(|job| job as i64), lua])).collect::<Vec<_>>()).collect::<Vec<_>>(),
        })
    }

    fn from_json(value: &Value) -> Option<Writes> {
        let writes = value["writes"]
            .as_array()?
            .iter()
            .map(|write| {
                write.as_array()?.iter().map(|message| Some((message[0].as_i64().map(i128::from), message[1].as_str()?.to_string()))).collect()
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Writes { session: value["session"].as_str()?.to_string(), number: value["number"].as_u64()?, writes })
    }
}

fn state() -> io::Result<PathBuf> {
    Ok(companion_dir()?.join("inbox.json"))
}

/// The writes kept on disk, whichever session they are for.
fn kept() -> Option<Writes> {
    let bytes = fs::read(state().ok()?).ok()?;
    Writes::from_json(&serde_json::from_slice::<Value>(&bytes).ok()?)
}

fn keep(writes: &Writes) -> io::Result<()> {
    replace(&state()?, &serde_json::to_vec(&writes.to_json()).map_err(io::Error::other)?)
}

/// Send `messages` as the session's next write and ring its bell; returns its
/// number. Every bell up to it is rung after, so one that could not be rung at
/// its own send rings with the next and the game, asking it, goes on.
pub(crate) fn send(addons: &Path, messages: &[Msg]) -> io::Result<u32> {
    let _one = WRITING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let session = Session::now(addons)?;
    let signals = addons.join(LINK).join("Signals");
    let set = session.set();
    let mut writes = match kept() {
        Some(writes) if writes.session == session.key() => writes,
        _ => {
            // a new session, and nothing sent in it yet: its set starts empty. A
            // ring left there by a send across a reload would be heard as a write.
            channel::empty_rung(&signals, (1..=SLOTS).map(|n| channel::bell_name(set, n)), "left rung at the session's start")?;
            Writes { session: session.key(), number: session.number(), writes: Vec::new() }
        }
    };
    if writes.writes.len() as u32 >= SLOTS {
        // nothing can reach the game to say so; the pad can
        voice::ALERT.store(true, Ordering::SeqCst);
        return Err(io::Error::other(format!("all {SLOTS} bells of this UI session are rung: `send reload`, or Reload in game")));
    }
    let before = writes.clone();
    let n = writes.add(messages);
    let (lines, jobs) = crate::ledger::running_mail();
    keep(&writes)?;
    // the inbox never got this write: neither has the record of it
    if let Err(err) = publish(addons, &writes, &lines, &jobs) {
        return Err(match keep(&before) {
            Ok(()) => err,
            Err(undo) => io::Error::other(format!("{err}; and inbox.json could not be put back: {undo}")),
        });
    }
    for bell in 1..=n {
        let path = signals.join(channel::bell_name(set, bell));
        if bell == n || fs::metadata(&path).is_ok_and(|meta| meta.len() == 0) {
            if let Err(err) = bells::ring(&path) {
                // the write is in the inbox: it is read at the next ring
                println!("  {err}: it rings with the next send");
                crate::audit::note("bell", "", &format!("could not ring {}: {err}", channel::bell_name(set, bell)));
            }
        }
    }
    crate::audit::note("bell", "", &format!("ring {} (write {n})", channel::bell_name(set, n)));
    Ok(n)
}

/// The ledger changed: the inbox rewritten with its lines and jobs (`mail`,
/// asked once this holds the inbox, so a send between cannot be undone by an
/// older ledger) and this session's writes as they stand; no bell (the game
/// reads it at its next ring or load).
pub(crate) fn rewrite(addons: &Path, mail: impl FnOnce() -> (Vec<Msg>, Vec<Msg>)) -> io::Result<()> {
    let _one = WRITING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let (lines, jobs) = mail();
    publish(addons, &kept().unwrap_or_default(), &lines, &jobs)
}

/// How many writes this UI session has had; None while the game's save does
/// not read.
pub(crate) fn sent(addons: &Path) -> Option<u32> {
    let session = Session::now(addons).ok()?;
    Some(kept().filter(|writes| writes.session == session.key()).map_or(0, |writes| writes.writes.len() as u32))
}

fn publish(addons: &Path, writes: &Writes, lines: &[Msg], jobs: &[Msg]) -> io::Result<()> {
    let at = path(addons);
    if !at.parent().is_some_and(Path::is_dir) {
        return Err(io::Error::other(format!("the {MAILBOX} addon is not installed (`wow-companion install`)")));
    }
    replace(&at, writes.lua(lines, jobs).as_bytes())
}

/// Written beside and renamed over, retried while the game's read is in the way.
fn replace(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let part = path.with_extension("part");
    fs::write(&part, bytes)?;
    bells::patiently(path, "replace", || fs::rename(&part, path))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn progress(job: u64, text: &str) -> Msg {
        Msg::new("progress").text("text", text).int("job", job)
    }

    /// The file without its `written` time.
    fn body(writes: &Writes, lines: &[Msg], jobs: &[Msg]) -> String {
        let lua = writes.lua(lines, jobs);
        let start = lua.find("session = ").unwrap();
        lua[start..].to_string()
    }

    #[test]
    fn writes_are_numbered_and_a_progress_line_leaves_the_earlier_writes() {
        let mut writes = Writes { session: "7|1".into(), number: 8, writes: Vec::new() };
        assert_eq!(writes.add(&[progress(1, "reading"), Msg::new("heard").int("job", 2)]), 1);
        assert_eq!(writes.add(&[Msg::new("progress").flag("started", true).int("job", 1)]), 2);
        assert_eq!(writes.add(&[progress(1, "writing")]), 3);
        assert_eq!(
            body(&writes, &[], &[]),
            "session = 8, bell = 3, writes = { \
             { n = 1, messages = { { kind = \"heard\", job = 2 } } }, \
             { n = 2, messages = { { kind = \"progress\", started = true, job = 1 } } }, \
             { n = 3, messages = { { kind = \"progress\", text = \"writing\", job = 1 } } } }, lines = { }, jobs = { } }\n"
        );
        // a write left with nothing still says its number, so a gap is a loss
        writes.add(&[progress(1, "done")]);
        assert!(writes.lua(&[], &[]).contains("{ n = 3, messages = { } }"));
    }

    #[test]
    fn the_inbox_carries_the_ledgers_lines_and_jobs_and_is_never_empty() {
        let line = crate::message::Line::new("l1", "you", "hi").msg(false);
        let job = crate::message::job_entry(5, "l1", crate::jobs::State::Running);
        assert_eq!(
            body(&Writes::default(), &[line], &[job]),
            "session = 0, bell = 0, writes = { }, lines = { { kind = \"log\", slot = \"l1\", n = 0, who = \"you\", text = \"hi\" } }, \
             jobs = { { job = 5, slot = \"l1\", state = \"running\" } } }\n"
        );
        assert!(Writes::default().lua(&[], &[]).contains("WowCompanion_Mail = { written = "));
    }

    #[test]
    fn the_writes_survive_a_round_trip_through_their_file() {
        let mut writes = Writes { session: "7|1".into(), number: 8, writes: Vec::new() };
        writes.add(&[progress(1794631367206, "a \"quoted\"\nline"), Msg::new("stopped")]);
        writes.add(&[]);
        let back = Writes::from_json(&serde_json::from_slice(&serde_json::to_vec(&writes.to_json()).unwrap()).unwrap()).unwrap();
        assert_eq!(back, writes);
    }

    #[test]
    fn a_file_is_replaced_whole() {
        let dir = env::temp_dir().join(format!("wc-inbox-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Mail.lua");
        fs::write(&path, "old").unwrap();
        replace(&path, b"new").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "new");
        assert!(!path.with_extension("part").exists(), "no temporary file left behind");
        let _ = fs::remove_dir_all(dir);
    }
}
