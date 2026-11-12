//! An agent run on disk, so a request outlives the companion copy that started
//! it (docs/PLAN.md, 2026-11-12).
//!
//! The agent (`claude -p`) starts with no pipes to this process: its prompt is
//! a file it reads as stdin, and its stream and its complaints go to files in
//! the job's folder, `runs\<job>\`. `run.json` there says which conversation it
//! is for and which process is writing the newest round. Any copy of the
//! companion can follow the stream to its answer: the one that started it, the
//! one a restart hands over to, or the one started after a crash. A restart
//! therefore never waits for an agent, and a reply is never lost with the copy
//! that asked for it.
//!
//! A round is followed until its process has exited and its file is read to the
//! end: the answer is delivered only then, as with the pipe before (a turn can
//! wake again after its first result, and that result stays the answer).

use std::{
    fs::{self, File},
    io::{self, Read},
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::Duration,
};

use serde_json::{json, Value};
use wow_companion_settings::platform::Process;

/// How often a quiet stream is looked at again.
const LOOK: Duration = Duration::from_millis(100);

/// One round of an agent run: the `round`th process of job `job`'s request
/// (a request that runs out of steps carries on in a new round).
#[derive(Clone, Debug)]
pub(crate) struct Run {
    pub(crate) job: u64,
    pub(crate) slot: String,
    pub(crate) round: u32,
    pub(crate) pid: u32,
    /// the process's start time (platform::Process::started): a later process
    /// given the same id is not this one
    started: u64,
}

/// How following a round ended.
pub(crate) enum Followed {
    /// its process exited and every line was read
    Ended,
    /// this copy is handing over: the run goes on, and the next copy follows it
    Left,
}

fn folder(job: u64) -> io::Result<PathBuf> {
    Ok(crate::restart::companion_dir()?.join("runs").join(job.to_string()))
}

fn stream(job: u64, round: u32) -> io::Result<PathBuf> {
    Ok(folder(job)?.join(format!("round-{round}.jsonl")))
}

/// Start `agent` as round `round` of job `job`, detached: `prompt` as its stdin,
/// its stream and complaints to files. It keeps a console of its own, hidden, so
/// the shells it starts open no window over the game.
pub(crate) fn start(job: u64, slot: &str, round: u32, mut agent: Command, prompt: &str) -> io::Result<Run> {
    let dir = folder(job)?;
    fs::create_dir_all(&dir)?;
    let asked = dir.join(format!("round-{round}.prompt"));
    fs::write(&asked, prompt)?;
    agent
        .stdin(Stdio::from(File::open(&asked)?))
        .stdout(Stdio::from(File::create(stream(job, round)?)?))
        .stderr(Stdio::from(File::create(dir.join(format!("round-{round}.err")))?));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
        agent.creation_flags(0x0800_0000 | 0x0000_0200);
    }
    let child = agent.spawn()?;
    let pid = child.id();
    // the process was just made: if it is gone already, started is 0 and the
    // follower finds it ended, which it is
    let started = Process::open(pid).map(|process| process.started()).unwrap_or_default();
    let run = Run { job, slot: slot.to_string(), round, pid, started };
    let record = json!({ "slot": slot, "round": round, "pid": pid, "started": started.to_string() });
    fs::write(dir.join("run.json"), record.to_string())?;
    Ok(run)
}

/// Every run a companion left going: its newest round, whether its agent still
/// runs or has finished.
pub(crate) fn left() -> Vec<Run> {
    let Ok(dir) = crate::restart::companion_dir().map(|dir| dir.join("runs")) else { return Vec::new() };
    let mut found = Vec::new();
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let Some(job) = entry.file_name().to_str().and_then(|name| name.parse::<u64>().ok()) else { continue };
        let Ok(text) = fs::read_to_string(entry.path().join("run.json")) else { continue };
        let Ok(record) = serde_json::from_str::<Value>(&text) else { continue };
        let number = |key: &str| record.get(key).and_then(Value::as_u64);
        let (Some(round), Some(pid)) = (number("round"), number("pid")) else { continue };
        let started = record.get("started").and_then(Value::as_str).and_then(|text| text.parse().ok()).unwrap_or_default();
        let slot = record.get("slot").and_then(Value::as_str).unwrap_or_default().to_string();
        found.push(Run { job, slot, round: round as u32, pid: pid as u32, started });
    }
    found.sort_by_key(|run| run.job);
    found
}

/// The job's run is over (answered, failed or cancelled): its folder goes.
pub(crate) fn finished(job: u64) {
    if let Ok(dir) = folder(job) {
        let _ = fs::remove_dir_all(dir);
    }
}

/// What the round's process wrote to stderr.
pub(crate) fn complaints(run: &Run) -> String {
    folder(run.job).and_then(|dir| fs::read_to_string(dir.join(format!("round-{}.err", run.round)))).unwrap_or_default()
}

/// Whether the round's process still runs (and is the one that started it).
fn running(process: &Option<Process>, run: &Run) -> bool {
    process.as_ref().is_some_and(|process| process.started() == run.started && process.running())
}

/// Hand each line of the round's stream to `line`, from the first, as it is
/// written, until the process has exited and the file is read to its end, or
/// `leave()` says this copy is handing over.
pub(crate) fn follow(run: &Run, leave: impl Fn() -> bool, mut line: impl FnMut(&str)) -> io::Result<Followed> {
    let mut file = File::open(stream(run.job, run.round)?)?;
    let process = Process::open(run.pid);
    let mut pending: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        if leave() {
            return Ok(Followed::Left);
        }
        // looked at before reading: an exit seen here means everything it wrote
        // is in the file, so a read that comes back empty after it is the end
        let alive = running(&process, run);
        let read = file.read(&mut chunk)?;
        if read > 0 {
            pending.extend_from_slice(&chunk[..read]);
            while let Some(end) = pending.iter().position(|byte| *byte == b'\n') {
                let whole: Vec<u8> = pending.drain(..=end).collect();
                line(String::from_utf8_lossy(&whole).trim_end());
            }
            continue;
        }
        if !alive {
            if !pending.is_empty() {
                line(String::from_utf8_lossy(&pending).trim_end());
            }
            return Ok(Followed::Ended);
        }
        thread::sleep(LOOK);
    }
}
