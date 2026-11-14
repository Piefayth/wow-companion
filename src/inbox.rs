//! The inbox on trial (docs/proposals/reliable-channel.md): one file that every
//! trial slot reads, run beside the channel on files of its own. The game counts
//! what it reads there and applies nothing (`Trial.lua` in Link).
//!
//! Every batch the channel sends is also write n of this session here. The
//! inbox holds every write of the session, numbered, with a progress line kept
//! only until a newer one for its request comes. It is replaced whole (written
//! beside, renamed over), so the game never opens half of it, and then trial
//! bell n rings. A ring the game hears falsely reads the inbox as it stands and
//! finds nothing newer: a trial slot spent, nothing lost.
//!
//! The writes are kept in `inbox.json` in the companion's folder, so a companion
//! that takes over goes on numbering where the last one stopped.

use super::*;
use crate::message::Msg;
use crate::session::Session;
use serde_json::{json, Value};

/// Trial slots (`WowCompanion_T001`...), and trial bells per set: a session has
/// sent up to 100 batches (2026-11-11..13), and a false ring spends a slot too.
pub(crate) const TRIAL_SLOTS: u32 = 256;
/// The inbox, in Link's folder. Every trial slot's Slot.xml names it.
pub(crate) const FILE: &str = "Inbox.lua";
/// What install puts there before the PC has written anything: never an empty
/// file, which the game reports as a Lua error, opening its error window.
pub(crate) const UNWRITTEN: &str = "WowCompanion_Trial = { session = 0, bell = 0, writes = { } }\n";
pub(crate) const TRIAL_XML: &str =
    "<Ui xmlns=\"http://www.blizzard.com/wow/ui/\">\n\t<Script file=\"..\\WowCompanion_Link\\Inbox.lua\"></Script>\n</Ui>\n";

pub(crate) fn trial_slot_name(slot: u32) -> String {
    format!("{ADDON}_T{slot:03}")
}

/// A trial slot's .toc, in the slots' category, so the AddOns list folds both.
pub(crate) fn trial_toc(slot: u32) -> String {
    format!(
        "## Interface: 16001\n## Title: WoW Companion trial slot\n## LoadOnDemand: 1\n## Group: {}\n## Category: WoW Companion: message slots\n\nSlot.xml\n",
        trial_slot_name(slot)
    )
}

/// Trial bell n of `set`: rung when write n is in the inbox, empty until then,
/// a set per session as the slot bells are.
pub(crate) fn trial_bell_name(set: u64, n: u32) -> String {
    format!("t{set}-{n:03}.wav")
}

/// This session's writes; pure, so its rules are tested without files.
#[derive(Debug, Default, PartialEq)]
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

    /// `WowCompanion_Trial = {...}`: the session, the last write, and every write.
    fn lua(&self) -> String {
        let writes: Vec<String> = self
            .writes
            .iter()
            .enumerate()
            .map(|(at, write)| {
                let messages: Vec<&str> = write.iter().map(|(_, lua)| lua.as_str()).collect();
                let list = if messages.is_empty() { "{ }".to_string() } else { format!("{{ {} }}", messages.join(", ")) };
                format!("{{ n = {}, messages = {list} }}", at + 1)
            })
            .collect();
        format!(
            "WowCompanion_Trial = {{ session = {}, bell = {}, writes = {{ {} }} }}\n",
            self.number,
            self.writes.len(),
            writes.join(", ")
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

/// After the channel has sent `messages` (into `slot`, or not at all): the same
/// batch as the trial's next write. A failure is reported and never touches the
/// channel.
pub(crate) fn trial(addons: &Path, messages: &[Msg], slot: Option<u32>) {
    if let Err(err) = write(addons, messages, slot) {
        println!("inbox trial: {err}");
        crate::audit::note("trial", "", &format!("failed: {err}"));
    }
}

fn write(addons: &Path, messages: &[Msg], slot: Option<u32>) -> io::Result<()> {
    let link = addons.join(LINK);
    let inbox = link.join(FILE);
    // not installed: no trial
    if !inbox.exists() {
        return Ok(());
    }
    let session = Session::now(addons)?;
    let state = companion_dir()?.join("inbox.json");
    let kept = fs::read(&state).ok().and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok()).and_then(|value| Writes::from_json(&value));
    let mut writes = match kept {
        Some(writes) if writes.session == session.key() => writes,
        _ => {
            // a new session: its set's trial bells start empty, as the slot
            // bells do (channel::next_slot)
            let set = session.set();
            channel::empty_rung(&link.join("Signals"), (1..=TRIAL_SLOTS).map(|n| trial_bell_name(set, n)), "left rung at the session's start")?;
            Writes { session: session.key(), number: session.number(), writes: Vec::new() }
        }
    };
    // every trial bell of the set rung: the trial is over for this session
    if writes.writes.len() as u32 >= TRIAL_SLOTS {
        return Ok(());
    }
    let n = writes.add(messages);
    let lua = writes.lua();
    replace(&state, &serde_json::to_vec(&writes.to_json()).map_err(io::Error::other)?)?;
    replace(&inbox, lua.as_bytes())?;
    bells::ring(&link.join("Signals").join(trial_bell_name(session.set(), n)))?;
    crate::audit::note(
        "trial",
        "",
        &format!(
            "write {n} session={} slot={} messages={} bytes={}",
            writes.number,
            slot.map_or("none".to_string(), |slot| slot.to_string()),
            messages.len(),
            lua.len()
        ),
    );
    Ok(())
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

    #[test]
    fn writes_are_numbered_and_a_progress_line_leaves_the_earlier_writes() {
        let mut writes = Writes { session: "7|1".into(), number: 8, writes: Vec::new() };
        assert_eq!(writes.add(&[progress(1, "reading"), Msg::new("heard").int("job", 2)]), 1);
        assert_eq!(writes.add(&[Msg::new("progress").flag("started", true).int("job", 1)]), 2);
        assert_eq!(writes.add(&[progress(1, "writing")]), 3);
        assert_eq!(
            writes.lua(),
            "WowCompanion_Trial = { session = 8, bell = 3, writes = { \
             { n = 1, messages = { { kind = \"heard\", job = 2 } } }, \
             { n = 2, messages = { { kind = \"progress\", started = true, job = 1 } } }, \
             { n = 3, messages = { { kind = \"progress\", text = \"writing\", job = 1 } } } } }\n"
        );
        // a write left with nothing still says its number, so a gap is a loss
        writes.add(&[progress(1, "done")]);
        assert!(writes.lua().contains("{ n = 3, messages = { } }"), "{}", writes.lua());
    }

    #[test]
    fn the_writes_survive_a_round_trip_through_their_file() {
        let mut writes = Writes { session: "7|1".into(), number: 8, writes: Vec::new() };
        writes.add(&[progress(1794631367206, "a \"quoted\"\nline"), Msg::new("stopped")]);
        writes.add(&[]);
        let back = Writes::from_json(&serde_json::from_slice(&serde_json::to_vec(&writes.to_json()).unwrap()).unwrap()).unwrap();
        assert_eq!(back, writes);
    }
}
