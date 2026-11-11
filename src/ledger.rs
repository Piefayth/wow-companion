//! The ledger: every conversation line until the game has saved it, and every
//! request's state, on disk (docs/proposals/ledger.md).
//!
//! - A line is numbered in its conversation here (1, 2, 3..., no gaps) and kept
//!   until a save shows the game holds it (`WowCompanionDB.lines[conversation]`,
//!   the highest number it holds with none missing below).
//! - The jobs (src/jobs.rs) are mirrored here at every change, so their states
//!   survive the companion; a job not ended when the companion starts ended with
//!   the companion, and says so.
//! - The mailbox, `WowCompanion_Mailbox/Mail.lua`, an addon the game loads at
//!   every login and reload, holds every unconfirmed line and every job's state:
//!   lines made while the game was closed are in the window when it opens.
//!
//! Both files are written whole (a temporary file, then a rename) at every
//! change, so neither is ever half written. A failure is reported (the window,
//! `doctor`, the tray), never retried in the dark.

use std::collections::BTreeMap;

use super::*;
use crate::jobs::State;
use crate::message::{job_entry, Line, Msg};
use crate::savedvars::{self, Lua};
use serde_json::{json, Value};

/// The folder of the mailbox addon in AddOns.
pub(crate) const MAILBOX: &str = "WowCompanion_Mailbox";

/// What the ledger holds; pure, so its rules are tested without files.
#[derive(Default, Debug, PartialEq)]
pub(crate) struct Book {
    /// The next number per conversation.
    next: BTreeMap<String, u64>,
    /// Every line the game has not saved yet, in the order they were numbered.
    lines: Vec<Line>,
    /// Every request the game has not saved an end for, and its state.
    jobs: Vec<(u64, String, State)>,
    /// Per conversation, the highest number the mailbox held at the last
    /// confirmation: the game loaded it then, so its next save holds it.
    expected: BTreeMap<String, u64>,
}

/// What a save says the game holds.
#[derive(Default, Debug)]
pub(crate) struct Held {
    /// Per conversation, the highest number held with none missing below; None
    /// when the save records no lines at all (its addon predates the ledger).
    pub(crate) lines: Option<BTreeMap<String, u64>>,
    /// Requests whose end the save records.
    pub(crate) ended: Vec<u64>,
}

/// What a confirmation did.
#[derive(Default, Debug, PartialEq)]
pub(crate) struct Confirmed {
    /// Ended requests the game has saved: the jobs table forgets them.
    pub(crate) forget: Vec<u64>,
    /// Lines the mailbox held at the last load that the save still lacks, per
    /// conversation (first and last number).
    pub(crate) untaken: Vec<(String, u64, u64)>,
}

impl Book {
    /// Give `line` the next number in its conversation and keep it (its steps
    /// are never kept: they run live or not at all).
    pub(crate) fn number(&mut self, mut line: Line) -> Line {
        let next = self.next.entry(line.slot.clone()).or_insert(1);
        line.n = *next;
        *next += 1;
        let mut kept = line.clone();
        kept.steps = None;
        self.lines.push(kept);
        line
    }

    /// Numbers continue above what the game holds: a ledger lost or newer than
    /// the game's record never hands out a number the game already has.
    pub(crate) fn continue_above(&mut self, held: &BTreeMap<String, u64>) {
        for (slot, n) in held {
            let next = self.next.entry(slot.clone()).or_insert(1);
            *next = (*next).max(n + 1);
        }
    }

    /// A save landed: drop what it holds, and check that it holds what the
    /// mailbox held when the game last loaded.
    pub(crate) fn confirm(&mut self, held: &Held) -> Confirmed {
        let mut out = Confirmed::default();
        if let Some(lines) = &held.lines {
            self.continue_above(lines);
            for (slot, expected) in &self.expected {
                let have = lines.get(slot).copied().unwrap_or(0);
                if have < *expected {
                    out.untaken.push((slot.clone(), have + 1, *expected));
                }
            }
            self.lines.retain(|line| line.n > lines.get(&line.slot).copied().unwrap_or(0));
            self.expected = BTreeMap::new();
            for line in &self.lines {
                let max = self.expected.entry(line.slot.clone()).or_insert(0);
                *max = (*max).max(line.n);
            }
        }
        let ended: Vec<u64> = self
            .jobs
            .iter()
            .filter(|(id, _, state)| state.ended() && held.ended.contains(id))
            .map(|(id, _, _)| *id)
            .collect();
        self.jobs.retain(|(id, _, _)| !ended.contains(id));
        out.forget = ended;
        out
    }

    /// The jobs as they stand now (src/jobs.rs), mirrored.
    pub(crate) fn mirror(&mut self, jobs: Vec<(u64, String, State)>) {
        self.jobs = jobs;
    }

    /// At a start: every job not ended ended with the companion. Its line says
    /// so; the job itself becomes failed.
    pub(crate) fn recover(&mut self) -> Vec<Line> {
        let mut lines = Vec::new();
        for (id, slot, state) in self.jobs.iter_mut() {
            if state.ended() {
                continue;
            }
            let text = format!(
                "That request ended when the companion stopped, while it was {}. Ask again.",
                state.name()
            );
            *state = State::Failed;
            lines.push(Line::new(slot, "error", &text).job(*id, State::Failed).ended(vec![(*id, slot.clone(), State::Failed)]));
        }
        lines.into_iter().map(|line| self.number(line)).collect()
    }

    pub(crate) fn jobs(&self) -> &[(u64, String, State)] {
        &self.jobs
    }

    /// `WowCompanion_Mail = {...}`: what the game takes at its next load.
    pub(crate) fn mailbox_lua(&self) -> String {
        let written = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default();
        let mail = Msg::table()
            .int("written", written as i128)
            .list("lines", self.lines.iter().map(|line| line.msg(false)).collect())
            .list("jobs", self.jobs.iter().map(|(id, slot, state)| job_entry(*id, slot, *state)).collect());
        format!(
            "-- Written by the companion (src/ledger.rs) at every change: every conversation\n-- line the game has not saved yet, and every request's state. Do not edit.\nWowCompanion_Mail = {}\n",
            mail.lua()
        )
    }

    pub(crate) fn to_json(&self) -> Value {
        json!({
            "next": self.next,
            "lines": self.lines.iter().map(line_json).collect::<Vec<_>>(),
            "jobs": self.jobs.iter().map(|(id, slot, state)| json!([id, slot, state.name()])).collect::<Vec<_>>(),
            "expected": self.expected,
        })
    }

    pub(crate) fn from_json(value: &Value) -> Result<Book, String> {
        let counts = |key: &str| -> Result<BTreeMap<String, u64>, String> {
            value[key]
                .as_object()
                .ok_or(format!("no {key}"))?
                .iter()
                .map(|(slot, n)| n.as_u64().map(|n| (slot.clone(), n)).ok_or(format!("{key}[{slot}] is not a number")))
                .collect()
        };
        let lines = value["lines"].as_array().ok_or("no lines")?.iter().map(line_from_json).collect::<Result<Vec<_>, _>>()?;
        let jobs = value["jobs"]
            .as_array()
            .ok_or("no jobs")?
            .iter()
            .map(|job| {
                let id = job[0].as_u64().ok_or("a job without an id")?;
                let slot = job[1].as_str().ok_or("a job without a conversation")?.to_string();
                let state = State::from_name(job[2].as_str().unwrap_or_default()).ok_or("a job with no known state")?;
                Ok((id, slot, state))
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(Book { next: counts("next")?, lines, jobs, expected: counts("expected")? })
    }
}

fn line_json(line: &Line) -> Value {
    json!({
        "slot": line.slot,
        "n": line.n,
        "who": line.who,
        "text": line.text,
        "pending": line.pending,
        "job": line.job.map(|(id, state)| json!([id, state.name()])),
        "ended": line.ended.iter().map(|(id, slot, state)| json!([id, slot, state.name()])).collect::<Vec<_>>(),
        "queued": line.queued,
    })
}

fn line_from_json(value: &Value) -> Result<Line, String> {
    let text = |key: &str| value[key].as_str().map(str::to_string).ok_or(format!("a line without {key}"));
    let state = |value: &Value| State::from_name(value.as_str().unwrap_or_default()).ok_or("a line with no known state".to_string());
    let mut line = Line::new(&text("slot")?, &text("who")?, &text("text")?);
    line.n = value["n"].as_u64().ok_or("a line without a number")?;
    line.pending = value["pending"].as_str().map(str::to_string);
    if let Some(job) = value["job"].as_array() {
        line.job = Some((job[0].as_u64().ok_or("a line's job without an id")?, state(&job[1])?));
    }
    for entry in value["ended"].as_array().into_iter().flatten() {
        line.ended.push((entry[0].as_u64().ok_or("an ended job without an id")?, entry[1].as_str().unwrap_or_default().to_string(), state(&entry[2])?));
    }
    line.queued = value["queued"].as_bool().unwrap_or(false);
    Ok(line)
}

/// What a save holds, read from its text.
pub(crate) fn held_in(save: &str) -> Result<Held, String> {
    let db = savedvars::global(save, "WowCompanionDB").ok_or("no WowCompanionDB in the save")?;
    let lines = db.get("lines").map(|lines| {
        lines
            .entries()
            .iter()
            .filter_map(|(key, n)| match (key, n.number()) {
                (Some(Lua::Text(slot)), Some(n)) if n >= 0.0 => Some((slot.clone(), n as u64)),
                _ => None,
            })
            .collect()
    });
    let ended = db
        .get("jobModel")
        .and_then(|model| model.get("jobs"))
        .map(|jobs| {
            jobs.entries()
                .iter()
                .filter_map(|(key, job)| match key {
                    Some(Lua::Number(id)) if State::from_name(&job.text_of("state")).is_some_and(State::ended) => Some(*id as u64),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Held { lines, ended })
}

// ------------------------------------------------------------- the files

struct Store {
    book: Book,
    ledger: PathBuf,
    mailbox: PathBuf,
}

static LEDGER: Mutex<Option<Store>> = Mutex::new(None);
/// What is wrong now, by kind; written to `ledger-problems.txt` for `doctor`
/// and the tray. Empty when all is well.
static PROBLEMS: Mutex<BTreeMap<&'static str, String>> = Mutex::new(BTreeMap::new());

fn problems_path() -> Option<PathBuf> {
    companion_dir().ok().map(|dir| dir.join("ledger-problems.txt"))
}

/// What is wrong with the ledger now, one line each, as `doctor` and the
/// tray show it (read from the file: they run in other processes).
pub(crate) fn problems() -> Vec<String> {
    problems_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .map(|text| text.lines().filter(|line| !line.trim().is_empty()).map(str::to_string).collect())
        .unwrap_or_default()
}

/// Set (Some) or clear (None) one kind of problem. A new one is also said in
/// the window, once, unless it is about the window's own lines.
fn problem(kind: &'static str, text: Option<String>) -> Option<String> {
    let mut problems = PROBLEMS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let changed = match &text {
        Some(text) => problems.insert(kind, text.clone()).as_ref() != Some(text),
        None => problems.remove(kind).is_some(),
    };
    if changed {
        if let Some(path) = problems_path() {
            let all: String = problems.values().map(|text| format!("{text}\n")).collect();
            let _ = if all.is_empty() { fs::remove_file(path) } else { fs::write(path, all) };
        }
        if let Some(text) = &text {
            eprintln!("ledger: {text}");
        }
    }
    text.filter(|_| changed)
}

fn write_whole(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let part = path.with_extension("part");
    fs::write(&part, bytes)?;
    fs::rename(&part, path)
}

/// Write both files from the book; report what fails. Returns a problem new
/// since the last write, to say in the window (the caller does, outside the lock).
fn save(store: &Store) -> Vec<String> {
    let mut news = Vec::new();
    let ledger = serde_json::to_vec_pretty(&store.book.to_json()).map_err(io::Error::other).and_then(|bytes| write_whole(&store.ledger, &bytes));
    news.extend(problem(
        "ledger",
        ledger.err().map(|err| format!("the ledger ({}) could not be written: {err}. Lines are not safe while the game is closed.", store.ledger.display())),
    ));
    let mailbox = if store.mailbox.parent().is_some_and(Path::is_dir) {
        write_whole(&store.mailbox, store.book.mailbox_lua().as_bytes())
    } else {
        Err(io::Error::other(format!("the {MAILBOX} addon is not installed (`wow-companion install`)")))
    };
    news.extend(problem(
        "mailbox",
        mailbox.err().map(|err| {
            let mut held: BTreeMap<&str, (u64, u64)> = BTreeMap::new();
            for line in &store.book.lines {
                let range = held.entry(&line.slot).or_insert((line.n, line.n));
                range.0 = range.0.min(line.n);
                range.1 = range.1.max(line.n);
            }
            let named: Vec<String> = held.iter().map(|(slot, (a, b))| format!("{} {a}-{b}", conversation(slot))).collect();
            format!("the mailbox could not be written: {err}. It should hold lines {}.", if named.is_empty() { "(none yet)".into() } else { named.join(", ") })
        }),
    ));
    news
}

fn conversation(slot: &str) -> String {
    if slot.is_empty() { "main".into() } else { slot.to_uppercase() }
}

/// Say new problems in the window, as lines of the main conversation (a
/// ledger that cannot be written still numbers in memory, so the line goes
/// out; only one new since the last write is said, so this ends).
fn say(addons: &Path, news: Vec<String>) {
    for text in news {
        let _ = crate::channel::post(addons, Line::new("", "error", &format!("The companion's ledger: {text}")));
    }
}

/// At `run`'s start, before any request: load the ledger, number above what
/// the game holds, end the jobs the last companion left running, and put
/// every job back in the jobs table. Returns the lines that say which ended,
/// to send (they are in the mailbox already).
pub(crate) fn open(addons: &Path) -> Vec<Line> {
    let dir = companion_dir().unwrap_or_else(|_| env::temp_dir());
    let ledger_path = dir.join("ledger.json");
    let mut news = Vec::new();
    let mut book = match fs::read(&ledger_path) {
        Ok(bytes) => match serde_json::from_slice::<Value>(&bytes).map_err(|err| err.to_string()).and_then(|value| Book::from_json(&value)) {
            Ok(book) => book,
            Err(err) => {
                let kept = ledger_path.with_extension("json.unreadable");
                let _ = fs::rename(&ledger_path, &kept);
                news.extend(problem(
                    "read",
                    Some(format!("the ledger could not be read ({err}); it is kept as {} and a new one started: the lines it held are not in the mailbox.", kept.display())),
                ));
                Book::default()
            }
        },
        Err(_) => Book::default(),
    };
    if let Some(Ok(held)) = saved_variables_text(addons).map(|save| held_in(&save)) {
        if let Some(lines) = &held.lines {
            book.continue_above(lines);
        }
    }
    let recovered = book.recover();
    jobs::restore(book.jobs());
    let store = Store { book, ledger: ledger_path, mailbox: addons.join(MAILBOX).join("Mail.lua") };
    news.extend(save(&store));
    *LEDGER.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(store);
    say(addons, news);
    recovered
}

/// Number `line` and keep it (and write both files). Outside `run` (tests,
/// other commands) nothing is kept and the line goes out unnumbered.
pub(crate) fn number(addons: &Path, line: Line) -> Line {
    let mut guard = LEDGER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(store) = guard.as_mut() else { return line };
    let line = store.book.number(line);
    let news = save(store);
    drop(guard);
    say(addons, news);
    line
}

/// The jobs table changed (src/jobs.rs): mirror it and write both files.
pub(crate) fn mirror(jobs: Vec<(u64, String, State)>) {
    let mut guard = LEDGER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(store) = guard.as_mut() else { return };
    store.book.mirror(jobs);
    let _ = save(store);
}

/// A save landed (a reload, a logout) or the companion started: drop what the
/// game holds, report what it should hold and does not, forget the requests
/// whose end it saved.
pub(crate) fn confirm(addons: &Path) {
    let held = match saved_variables_text(addons).ok_or_else(|| "no save file found".to_string()).and_then(|save| held_in(&save)) {
        Ok(held) => held,
        Err(err) => {
            let news = problem("save", Some(format!("the save could not be read at a confirmation ({err}): nothing was dropped; the mailbox keeps every line.")));
            if let Some(text) = news {
                say(addons, vec![text]);
            }
            return;
        }
    };
    problem("save", None);
    problem(
        "unrecorded",
        held.lines.is_none().then(|| "the game's save records no conversation lines (its addon predates the ledger): nothing can be confirmed, so the ledger and the mailbox keep every line.".to_string()),
    );
    let mut guard = LEDGER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(store) = guard.as_mut() else { return };
    let confirmed = store.book.confirm(&held);
    let mut news = save(store);
    drop(guard);
    let untaken: Vec<String> = confirmed.untaken.iter().map(|(slot, a, b)| format!("{} {a}-{b}", conversation(slot))).collect();
    news.extend(problem(
        "untaken",
        (!untaken.is_empty()).then(|| format!("the game did not take its mailbox: its save lacks lines {} that the mailbox held when it loaded.", untaken.join(", "))),
    ));
    say(addons, news);
    // after the ledger's lock is let go: the jobs table calls back into it
    jobs::forget(&confirmed.forget);
}

/// `install`: the mailbox from the ledger on disk, so a fresh install has it
/// before the game's next launch (the running companion rewrites it anyway).
pub(crate) fn write_mailbox(addons: &Path) -> io::Result<()> {
    let path = companion_dir()?.join("ledger.json");
    let book = match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
            .map_err(io::Error::other)
            .and_then(|value| Book::from_json(&value).map_err(io::Error::other))?,
        Err(_) => Book::default(),
    };
    write_whole(&addons.join(MAILBOX).join("Mail.lua"), book.mailbox_lua().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(lines: &[(&str, u64)], ended: &[u64]) -> Held {
        Held { lines: Some(lines.iter().map(|(slot, n)| (slot.to_string(), *n)).collect()), ended: ended.to_vec() }
    }

    #[test]
    fn lines_are_numbered_per_conversation_without_gaps() {
        let mut book = Book::default();
        let numbers: Vec<(String, u64)> = ["", "l1", "", "", "l1"]
            .iter()
            .map(|slot| book.number(Line::new(slot, "you", "hi")))
            .map(|line| (line.slot, line.n))
            .collect();
        assert_eq!(numbers, vec![("".into(), 1), ("l1".into(), 1), ("".into(), 2), ("".into(), 3), ("l1".into(), 2)]);
    }

    #[test]
    fn a_save_drops_exactly_the_lines_it_holds() {
        let mut book = Book::default();
        for _ in 0..5 {
            book.number(Line::new("", "you", "x"));
        }
        book.number(Line::new("r1", "claude", "y"));
        // the game holds main 1-3 (4 and 5 not yet), and nothing of R1
        book.confirm(&held(&[("", 3)], &[]));
        let kept: Vec<(String, u64)> = book.lines.iter().map(|line| (line.slot.clone(), line.n)).collect();
        assert_eq!(kept, vec![("".into(), 4), ("".into(), 5), ("r1".into(), 1)]);
    }

    #[test]
    fn every_unconfirmed_line_is_in_the_mailbox_without_its_steps() {
        let mut book = Book::default();
        let sent = book.number(Line::new("l1", "claude", "Done \"it\"\nC:\\x").steps(Some(Msg::new("reload"))));
        assert!(sent.steps.is_some(), "the live line keeps its steps");
        book.number(Line::new("", "you", "second"));
        let mail = book.mailbox_lua();
        assert!(mail.contains(r#"{ kind = "log", slot = "l1", n = 1, who = "claude", text = "Done \"it\"\nC:\\x" }"#), "{mail}");
        assert!(mail.contains(r#"slot = "", n = 1, who = "you", text = "second""#), "{mail}");
        assert!(!mail.contains("andThen"), "{mail}");
        assert!(mail.contains("WowCompanion_Mail = { written = "), "{mail}");
        book.confirm(&held(&[("l1", 1), ("", 1)], &[]));
        assert!(!book.mailbox_lua().contains("kind = \"log\""), "confirmed lines leave the mailbox");
    }

    #[test]
    fn numbers_continue_above_what_the_game_holds() {
        // a ledger lost (or never written) must not hand out numbers the game has
        let mut book = Book::default();
        book.continue_above(&[("".to_string(), 41)].into_iter().collect());
        assert_eq!(book.number(Line::new("", "you", "x")).n, 42);
        assert_eq!(book.number(Line::new("l2", "you", "x")).n, 1);
    }

    #[test]
    fn a_mailbox_the_game_did_not_take_is_named() {
        let mut book = Book::default();
        for _ in 0..4 {
            book.number(Line::new("r2", "you", "x"));
        }
        // a save before any load: nothing was expected yet
        assert!(book.confirm(&held(&[("r2", 1)], &[])).untaken.is_empty());
        // the mailbox held 2-4 at that load; the next save still holds only 2
        let confirmed = book.confirm(&held(&[("r2", 2)], &[]));
        assert_eq!(confirmed.untaken, vec![("r2".to_string(), 3, 4)]);
        // the one after holds them all
        assert!(book.confirm(&held(&[("r2", 4)], &[])).untaken.is_empty());
    }

    #[test]
    fn a_save_without_lines_confirms_nothing() {
        let mut book = Book::default();
        book.number(Line::new("", "you", "x"));
        let confirmed = book.confirm(&Held { lines: None, ended: vec![] });
        assert!(confirmed.untaken.is_empty());
        assert_eq!(book.lines.len(), 1);
    }

    #[test]
    fn a_job_running_at_a_start_ended_with_the_companion() {
        let mut book = Book::default();
        book.mirror(vec![(7, "l1".into(), State::Running), (8, "".into(), State::Answered), (9, "".into(), State::Queued)]);
        let lines = book.recover();
        assert_eq!(lines.len(), 2);
        assert_eq!((lines[0].slot.as_str(), lines[0].job, lines[0].n), ("l1", Some((7, State::Failed)), 1));
        assert!(lines[0].text.contains("while it was running"), "{}", lines[0].text);
        assert!(lines[1].text.contains("while it was queued"), "{}", lines[1].text);
        assert_eq!(book.jobs(), &[(7, "l1".to_string(), State::Failed), (8, "".to_string(), State::Answered), (9, "".to_string(), State::Failed)]);
    }

    #[test]
    fn ended_jobs_leave_once_the_save_records_them() {
        let mut book = Book::default();
        book.mirror(vec![(1, "".into(), State::Answered), (2, "".into(), State::Running), (3, "l1".into(), State::Cancelled)]);
        let confirmed = book.confirm(&held(&[], &[1, 2]));
        // 2 is still running here: a save naming it ended changes nothing yet
        assert_eq!(confirmed.forget, vec![1]);
        assert_eq!(book.jobs().iter().map(|(id, _, _)| *id).collect::<Vec<_>>(), vec![2, 3]);
    }

    #[test]
    fn the_ledger_survives_a_round_trip_through_its_file() {
        let mut book = Book::default();
        book.number(Line::new("l1", "you", "a \"quoted\" line").job(5, State::Queued).queued().pending("thinking"));
        book.number(Line::new("l1", "claude", "done").job(5, State::Answered).ended(vec![(5, "l1".into(), State::Answered)]));
        book.mirror(vec![(5, "l1".into(), State::Answered)]);
        book.confirm(&held(&[], &[]));
        let text = serde_json::to_string(&book.to_json()).unwrap();
        let back = Book::from_json(&serde_json::from_str(&text).unwrap()).unwrap();
        assert_eq!(back, book);
    }

    #[test]
    fn the_save_says_what_it_holds() {
        let save = "WowCompanionDB = {\n[\"lines\"] = {\n[\"\"] = 12,\n[\"l1\"] = 3,\n},\n[\"jobModel\"] = {\n[\"jobs\"] = {\n[1794357313662] = {\n[\"state\"] = \"answered\",\n[\"slot\"] = \"r1\",\n},\n[1794357203688] = {\n[\"state\"] = \"running\",\n},\n},\n},\n}\n";
        let held = held_in(save).unwrap();
        assert_eq!(held.lines.unwrap(), [("".to_string(), 12), ("l1".to_string(), 3)].into_iter().collect());
        assert_eq!(held.ended, vec![1794357313662]);
        assert!(held_in("WowCompanionDB = {\n}\n").unwrap().lines.is_none());
    }

    #[test]
    fn a_file_is_replaced_whole() {
        let dir = env::temp_dir().join(format!("wc-ledger-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Mail.lua");
        fs::write(&path, "old").unwrap();
        write_whole(&path, b"new").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "new");
        assert!(!path.with_extension("part").exists(), "no temporary file left behind");
        let _ = fs::remove_dir_all(dir);
    }
}
