//! The request ledger: the one record of every request, and the only truth about
//! where each one stands (the player, 2026-11-10: "the advanced distributed
//! systems solution to the cancelling / message order thing").
//!
//! A request moves one way: hearing -> queued -> running -> one end (answered,
//! cancelled or failed), and an end is final. Every change goes through this
//! table under one lock, so a cancel and a reply racing each other resolve to
//! exactly one of them, and the loser learns it from the table. Ids come from
//! the clock and only grow, so they never repeat across restarts.
//!
//! The game is told each change as (job, state) on the message that carries it.
//! It keeps, per job, the furthest state it has seen and ignores anything
//! behind it, so a late, repeated or reordered message can't undo a newer one,
//! and a resync is simply every recent state, safe to apply whenever it lands.
//! A cancel from the game names a job and is idempotent, so the game may repeat
//! it until it sees an end.

use std::collections::BTreeMap;

use super::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum State {
    /// Clips released, words still on their way from Whisper.
    Hearing,
    Queued,
    Running,
    Answered,
    Cancelled,
    Failed,
}

impl State {
    fn rank(self) -> u8 {
        match self {
            State::Hearing => 0,
            State::Queued => 1,
            State::Running => 2,
            State::Answered | State::Cancelled | State::Failed => 3,
        }
    }

    pub(crate) fn ended(self) -> bool {
        self.rank() == 3
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            State::Hearing => "hearing",
            State::Queued => "queued",
            State::Running => "running",
            State::Answered => "answered",
            State::Cancelled => "cancelled",
            State::Failed => "failed",
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct Job {
    pub(crate) id: u64,
    pub(crate) slot: String,
    pub(crate) state: State,
    /// Words heard so far (while hearing), then the request's text.
    pub(crate) text: String,
    /// Requests answered together share the first one's id: cancelling one
    /// that runs ends the agent run they share.
    pub(crate) group: u64,
    /// When the player let go of its first clip, wall clock (unix ms): a cancel
    /// pressed in the game is matched to the clip it was pressed for by this.
    released: u128,
    /// Clips released into it whose words have not come back yet.
    clips: u32,
    /// When its newest clip was let go: only a clip let go soon after joins.
    last_release: Instant,
    /// When words last arrived (gathering waits for a quiet moment).
    last_words: Instant,
    /// What the agent is doing, for the board.
    pub(crate) doing: String,
    pub(crate) since: Instant,
    changed: Instant,
    pid: Option<u32>,
}

static JOBS: Mutex<BTreeMap<u64, Job>> = Mutex::new(BTreeMap::new());
static LAST_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Ended jobs are kept this long, for resyncs and late cancels.
const KEEP: Duration = Duration::from_secs(30 * 60);
/// The game stamps a cancel with time(), to the second.
const PRESS_SLACK: u128 = 1000;

fn with<R>(f: impl FnOnce(&mut BTreeMap<u64, Job>) -> R) -> R {
    let mut jobs = JOBS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    // every state change, whichever function made it, goes to the audit trail
    let before: Vec<(u64, State)> = jobs.values().map(|job| (job.id, job.state)).collect();
    let out = f(&mut jobs);
    for job in jobs.values() {
        match before.iter().find(|(id, _)| *id == job.id) {
            Some((_, was)) if *was == job.state => {}
            Some((_, was)) => crate::audit::note("job", &job.slot, &format!("{} {} -> {}", job.id, was.name(), job.state.name())),
            None => crate::audit::note("job", &job.slot, &format!("{} new {}", job.id, job.state.name())),
        }
    }
    out
}

pub(crate) fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default()
}

/// Unique and growing across restarts: the clock in ms, or one past the last.
fn next_id() -> u64 {
    let now = now_ms() as u64;
    let mut last = LAST_ID.load(Ordering::SeqCst);
    loop {
        let id = now.max(last + 1);
        match LAST_ID.compare_exchange(last, id, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => return id,
            Err(seen) => last = seen,
        }
    }
}

fn insert(jobs: &mut BTreeMap<u64, Job>, slot: &str, state: State, text: &str, released: u128) -> u64 {
    jobs.retain(|_, job| !(job.state.ended() && job.changed.elapsed() > KEEP));
    let id = next_id();
    let now = Instant::now();
    jobs.insert(
        id,
        Job {
            id,
            slot: slot.to_string(),
            state,
            text: text.to_string(),
            group: id,
            released,
            clips: 0,
            last_release: now,
            last_words: now,
            doing: String::new(),
            since: now,
            changed: now,
            pid: None,
        },
    );
    id
}

/// A new request that skipped hearing (typed, or a resumed look).
pub(crate) fn create(slot: &str, text: &str, state: State) -> u64 {
    with(|jobs| insert(jobs, slot, state, text, now_ms()))
}

/// A clip was let go in this conversation. A clip let go within JOIN of the
/// one before, still being heard, joins it (you let go too early and went on);
/// otherwise a new job starts. Joining every clip while one was still heard
/// merged separate messages whenever Whisper was slow (the player, 2026-11-10:
/// an 11 s transcription swallowed the two messages after it).
pub(crate) const JOIN: Duration = Duration::from_millis(1500);
pub(crate) fn hear(slot: &str) -> u64 {
    with(|jobs| {
        let joinable = jobs
            .values()
            .find(|job| job.slot == slot && job.state == State::Hearing && job.last_release.elapsed() <= JOIN);
        let id = match joinable {
            Some(job) => job.id,
            None => insert(jobs, slot, State::Hearing, "", now_ms()),
        };
        let job = jobs.get_mut(&id).unwrap();
        job.clips += 1;
        job.last_release = Instant::now();
        crate::audit::note("hear", slot, &format!("{id} clip {}", job.clips));
        job.last_words = Instant::now();
        id
    })
}

/// A clip's words came back (empty when it held none). Returns the job they
/// joined and whether this was the first words in it (so its gatherer starts),
/// or None when the job was cancelled meanwhile and the words are dropped.
pub(crate) fn words(slot: &str, text: &str) -> Option<(u64, bool)> {
    with(|jobs| {
        let job = jobs.values_mut().filter(|job| job.slot == slot && job.clips > 0).min_by_key(|job| job.id)?;
        job.clips -= 1;
        crate::audit::note("words", slot, &format!("{} [{}] {}", job.id, job.state.name(), text.trim()));
        if job.state != State::Hearing {
            return None;
        }
        let first = job.text.is_empty() && !text.trim().is_empty();
        if !text.trim().is_empty() {
            if !job.text.is_empty() {
                job.text.push(' ');
            }
            job.text.push_str(text.trim());
            job.last_words = Instant::now();
        }
        // every clip came back empty: nothing to ask, it just ends
        if job.clips == 0 && job.text.is_empty() {
            job.state = State::Failed;
            job.changed = Instant::now();
            return None;
        }
        Some((job.id, first))
    })
}

/// Gathering: Some(Ok(words)) once no clip is out and none came for `quiet`
/// (the job then stops hearing and is the caller's to queue or run), None to
/// keep waiting, Some(Err) when it was cancelled.
pub(crate) fn gathered(id: u64, quiet: Duration, holding: bool) -> Option<Result<String, State>> {
    with(|jobs| {
        let job = jobs.get_mut(&id)?;
        if job.state != State::Hearing {
            return Some(Err(job.state));
        }
        if job.clips > 0 || holding || job.last_words.elapsed() < quiet {
            return None;
        }
        // out of hearing; queued until the caller says it runs
        job.state = State::Queued;
        job.changed = Instant::now();
        Some(Ok(job.text.clone()))
    })
}

/// Move a job forward. Ok(previous) when it moved; Err(current) when the move
/// would go backwards or the job had already ended (the race's loser).
pub(crate) fn advance(id: u64, to: State) -> Result<State, State> {
    with(|jobs| {
        let job = jobs.get_mut(&id).ok_or(State::Failed)?;
        if job.state.ended() || to.rank() < job.state.rank() {
            return Err(job.state);
        }
        let was = job.state;
        job.state = to;
        job.changed = Instant::now();
        if to == State::Running && was != State::Running {
            job.since = Instant::now();
        }
        Ok(was)
    })
}

/// End a running group: every member answered, or failed. False when a cancel
/// ended it first (then the reply or the error is dropped: the game already
/// shows it cancelled).
pub(crate) fn finish(group: u64, to: State) -> bool {
    with(|jobs| {
        let members: Vec<u64> = jobs.values().filter(|job| job.group == group).map(|job| job.id).collect();
        let mut finished = false;
        for id in members {
            let job = jobs.get_mut(&id).unwrap();
            if !job.state.ended() {
                job.state = to;
                job.changed = Instant::now();
                finished = true;
            }
        }
        finished
    })
}

pub(crate) fn state(id: u64) -> Option<State> {
    with(|jobs| jobs.get(&id).map(|job| job.state))
}

/// Take every queued job of this conversation as one run, in order, led by
/// `lead` (whose thread got the conversation). They become running together.
/// None when `lead` is no longer queued (another thread took it, or it was
/// cancelled) or nothing queued is left.
pub(crate) fn take_queued(slot: &str, lead: u64) -> Option<Vec<(u64, String)>> {
    with(|jobs| {
        if jobs.get(&lead).map(|job| job.state) != Some(State::Queued) {
            return None;
        }
        let taken: Vec<(u64, String)> = jobs
            .values()
            .filter(|job| job.slot == slot && job.state == State::Queued)
            .map(|job| (job.id, job.text.clone()))
            .collect();
        let now = Instant::now();
        for (id, _) in &taken {
            let job = jobs.get_mut(id).unwrap();
            job.state = State::Running;
            job.group = lead;
            job.since = now;
            job.changed = now;
        }
        Some(taken).filter(|taken| !taken.is_empty())
    })
}

/// The agent process now running this group. Returns false when the group was
/// cancelled before its process existed: then the caller ends it at once.
pub(crate) fn set_pid(group: u64, pid: u32) -> bool {
    with(|jobs| {
        let mut live = false;
        for job in jobs.values_mut().filter(|job| job.group == group) {
            job.pid = Some(pid);
            live |= !job.state.ended();
        }
        live
    })
}

pub(crate) fn set_doing(group: u64, doing: &str) {
    with(|jobs| {
        for job in jobs.values_mut().filter(|job| job.group == group && job.state == State::Running) {
            job.doing = doing.to_string();
        }
    })
}

/// What a cancel changed: the jobs it ended, and agent processes to end.
pub(crate) struct Cancelled {
    pub(crate) ended: Vec<Job>,
    pub(crate) pids: Vec<u32>,
}

/// Cancel these jobs. A running one takes its whole group with it (they share
/// one agent run). Jobs already ended are left as they are: cancelling is
/// idempotent, and "too late" is simply a job that had already ended.
pub(crate) fn cancel(ids: &[u64]) -> Cancelled {
    with(|jobs| {
        let mut targets: Vec<u64> = Vec::new();
        for id in ids {
            let Some(job) = jobs.get(id) else { continue };
            if job.state == State::Running {
                let group = job.group;
                targets.extend(jobs.values().filter(|j| j.group == group).map(|j| j.id));
            } else {
                targets.push(*id);
            }
        }
        let mut out = Cancelled { ended: Vec::new(), pids: Vec::new() };
        for id in targets {
            let job = jobs.get_mut(&id).unwrap();
            if job.state.ended() {
                continue;
            }
            if job.state == State::Running {
                if let Some(pid) = job.pid {
                    if !out.pids.contains(&pid) {
                        out.pids.push(pid);
                    }
                }
            }
            job.state = State::Cancelled;
            job.changed = Instant::now();
            out.ended.push(job.clone());
        }
        out
    })
}

/// Jobs of a conversation that have not ended, oldest first, optionally only
/// in one state.
pub(crate) fn live(slot: &str, only: Option<State>) -> Vec<u64> {
    with(|jobs| {
        jobs.values()
            .filter(|job| job.slot == slot && !job.state.ended() && only.is_none_or(|state| job.state == state))
            .map(|job| job.id)
            .collect()
    })
}

/// The job a cancel pressed at `press` (the game's clock, unix ms) on a
/// conversation's "hearing" line meant: the clip being heard if it was let go
/// by then, else the newest request made from a clip let go by then.
pub(crate) fn pressed_for(slot: &str, press: u128) -> Option<u64> {
    with(|jobs| {
        jobs.values()
            .filter(|job| job.slot == slot && job.released <= press + PRESS_SLACK && job.changed.elapsed() < Duration::from_secs(120))
            .max_by_key(|job| job.id)
            .map(|job| job.id)
    })
}

/// The job made from the clip let go at `release` (unix ms): its identity, as
/// the game names it (the game and the PC both see the release; the game's
/// clock is lined up to the ms). Nearest within RELEASE_MATCH, ended or not.
/// Clips let go closer together than JOIN are one job, so the match is never
/// ambiguous, unlike a press time, which named the newest clip and cancelled
/// the message after the one meant (the player, 2026-11-10).
pub(crate) const RELEASE_MATCH: u128 = 1200;
pub(crate) fn heard_at(slot: &str, release: u128) -> Option<u64> {
    with(|jobs| {
        jobs.values()
            .filter(|job| job.slot == slot && job.released.abs_diff(release) <= RELEASE_MATCH)
            .min_by_key(|job| job.released.abs_diff(release))
            .map(|job| job.id)
    })
}

pub(crate) fn get(ids: &[u64]) -> Vec<Job> {
    with(|jobs| ids.iter().filter_map(|id| jobs.get(id).cloned()).collect())
}

/// What each conversation's running request is doing, for the board.
pub(crate) fn working() -> Vec<(String, String, Instant)> {
    with(|jobs| {
        let mut out: Vec<(String, String, Instant)> = Vec::new();
        for job in jobs.values().filter(|job| job.state == State::Running) {
            if !out.iter().any(|(slot, _, _)| *slot == job.slot) {
                let doing = if job.doing.is_empty() { "thinking" } else { &job.doing };
                out.push((job.slot.clone(), doing.to_string(), job.since));
            }
        }
        out
    })
}

/// Every job a fresh UI session should know about: all that have not ended,
/// and those that ended in the last ten minutes.
pub(crate) fn recent() -> Vec<Job> {
    with(|jobs| {
        jobs.values()
            .filter(|job| job.state != State::Hearing && (!job.state.ended() || job.changed.elapsed() < Duration::from_secs(600)))
            .cloned()
            .collect()
    })
}

/// `{ job = 1, slot = "l1", state = "cancelled" }`, the entries of a `list`.
pub(crate) fn entries(jobs: &[Job]) -> String {
    jobs.iter()
        .map(|job| format!("{{ job = {}, slot = {}, state = \"{}\" }}", job.id, lua_string(&job.slot), job.state.name()))
        .collect::<Vec<_>>()
        .join(", ")
}

/// `, job = 7, state = "running"`: the fields every message about a job carries.
pub(crate) fn fields(id: u64, state: State) -> String {
    format!(", job = {id}, req = {id}, state = \"{}\"", state.name())
}

#[cfg(test)]
mod tests {
    use super::*;

    // the ledger is one static table, so each test uses its own conversation
    /// Two clips in flight, let go 1.6 s apart: separate jobs, each cancel
    /// names its own clip, and each clip's words go to its own job (the
    /// player, 2026-11-10: a cancel hit the message after the one meant, and
    /// a slow transcription swallowed the next message).
    #[test]
    fn two_clips_in_flight_stay_two_and_a_cancel_names_its_own() {
        let first = hear("t-two");
        assert_eq!(hear("t-two"), first, "a clip let go at once joins");
        std::thread::sleep(Duration::from_millis(1600));
        let second = hear("t-two");
        assert_ne!(first, second, "a clip let go later is its own message");
        // the game names a clip by its release, the PC matches the nearest
        assert_eq!(heard_at("t-two", first as u128 + 40), Some(first));
        assert_eq!(heard_at("t-two", second as u128 - 40), Some(second));
        assert_eq!(heard_at("t-two", second as u128 + 5000), None);
        // words come back in order: the first clip's (two clips) then the second's
        assert_eq!(words("t-two", "one"), Some((first, true)));
        assert_eq!(words("t-two", "more"), Some((first, false)));
        assert_eq!(words("t-two", "two"), Some((second, true)));
        // cancelling the first leaves the second alone
        cancel(&[first]);
        assert_eq!(state(first), Some(State::Cancelled));
        assert_eq!(state(second), Some(State::Hearing));
    }

    #[test]
    fn a_cancel_and_a_reply_racing_resolve_to_one() {
        let id = create("t-race", "hello", State::Running);
        assert!(set_pid(id, 4242));
        let cancelled = cancel(&[id]);
        assert_eq!(cancelled.pids, vec![4242]);
        // the reply lost: it is dropped, the game already shows cancelled
        assert!(!finish(id, State::Answered));
        assert_eq!(state(id), Some(State::Cancelled));
        // and a repeated cancel changes nothing
        assert!(cancel(&[id]).ended.is_empty());
    }

    #[test]
    fn too_late_is_a_job_that_already_ended() {
        let id = create("t-late", "hello", State::Running);
        assert!(finish(id, State::Answered));
        assert!(cancel(&[id]).ended.is_empty());
        assert_eq!(state(id), Some(State::Answered));
        assert_eq!(advance(id, State::Running), Err(State::Answered));
    }

    #[test]
    fn a_cancel_before_the_agent_started_ends_it_when_it_does() {
        let id = create("t-early", "hello", State::Running);
        assert!(cancel(&[id]).pids.is_empty());
        assert!(!set_pid(id, 7));
    }

    #[test]
    fn clips_gather_into_one_job_and_a_cancel_drops_late_words() {
        let id = hear("t-hear");
        assert_eq!(hear("t-hear"), id, "a second clip joins the first");
        assert_eq!(words("t-hear", "open my"), Some((id, true)));
        cancel(&[id]);
        assert_eq!(words("t-hear", "bags"), None);
        // the next clip is a new job
        assert_ne!(hear("t-hear"), id);
    }

    #[test]
    fn gathering_waits_for_every_clip_then_queues() {
        let id = hear("t-gather");
        hear("t-gather");
        words("t-gather", "one");
        assert!(gathered(id, Duration::ZERO, false).is_none(), "a clip is still out");
        words("t-gather", "two");
        assert_eq!(gathered(id, Duration::ZERO, false), Some(Ok("one two".to_string())));
        assert_eq!(state(id), Some(State::Queued));
    }

    #[test]
    fn a_clip_with_no_words_ends_its_job() {
        let id = hear("t-empty");
        assert_eq!(words("t-empty", "  "), None);
        assert_eq!(state(id), Some(State::Failed));
    }

    #[test]
    fn queued_jobs_run_together_and_a_cancel_of_one_ends_the_run() {
        let a = create("t-queue", "a", State::Queued);
        let b = create("t-queue", "b", State::Queued);
        let gone = create("t-queue", "c", State::Queued);
        cancel(&[gone]);
        let taken = take_queued("t-queue", b).unwrap();
        assert_eq!(taken.iter().map(|(id, _)| *id).collect::<Vec<_>>(), vec![a, b]);
        assert!(take_queued("t-queue", a).is_none(), "already taken");
        set_pid(b, 9);
        let cancelled = cancel(&[a]);
        assert_eq!(cancelled.ended.len(), 2);
        assert_eq!(cancelled.pids, vec![9]);
    }

    #[test]
    fn ids_only_grow() {
        let a = next_id();
        let b = next_id();
        assert!(b > a);
    }
}
