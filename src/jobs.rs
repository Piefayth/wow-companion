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
//! behind it, so a late, repeated or reordered message can't undo a newer one.
//! A cancel from the game names a job and is idempotent, so the game may repeat
//! it until it sees an end.
//!
//! Every change is mirrored into the ledger (src/ledger.rs), which keeps the
//! states on disk and in the mailbox; a job leaves this table when a save shows
//! the game has its end (`forget`).

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

    pub(crate) fn from_name(name: &str) -> Option<State> {
        [State::Hearing, State::Queued, State::Running, State::Answered, State::Cancelled, State::Failed]
            .into_iter()
            .find(|state| state.name() == name)
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
    /// Clips released into it whose words have not come back yet.
    clips: u32,
    /// When its newest clip was let go: only a clip let go soon after joins.
    last_release: Instant,
    /// Cancelled while the agent had it: its words are in the conversation the
    /// agent keeps, so the next request tells it they were withdrawn. Cleared
    /// once told.
    withdraw: bool,
    /// Its run was interrupted by Send now: still running, it joins the next run
    /// with the queued messages (take_queued), never cancelled.
    interrupted: bool,
    /// When words last arrived (gathering waits for a quiet moment).
    last_words: Instant,
    pid: Option<u32>,
}

static JOBS: Mutex<BTreeMap<u64, Job>> = Mutex::new(BTreeMap::new());
static LAST_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn with<R>(f: impl FnOnce(&mut BTreeMap<u64, Job>) -> R) -> R {
    let mut jobs = JOBS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    // every state change, whichever function made it, goes to the audit trail
    // and the ledger
    let before: Vec<(u64, State)> = jobs.values().map(|job| (job.id, job.state)).collect();
    let out = f(&mut jobs);
    let mut changed = before.len() != jobs.len();
    for job in jobs.values() {
        match before.iter().find(|(id, _)| *id == job.id) {
            Some((_, was)) if *was == job.state => {}
            Some((_, was)) => {
                changed = true;
                crate::audit::note("job", &job.slot, &format!("{} {} -> {}", job.id, was.name(), job.state.name()))
            }
            None => {
                changed = true;
                crate::audit::note("job", &job.slot, &format!("{} new {}", job.id, job.state.name()))
            }
        }
    }
    if changed {
        crate::ledger::mirror(jobs.values().map(|job| (job.id, job.slot.clone(), job.state)).collect());
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

fn insert(jobs: &mut BTreeMap<u64, Job>, slot: &str, state: State, text: &str) -> u64 {
    let id = next_id();
    put(jobs, id, slot, state, text);
    id
}

fn put(jobs: &mut BTreeMap<u64, Job>, id: u64, slot: &str, state: State, text: &str) {
    let now = Instant::now();
    jobs.insert(
        id,
        Job {
            id,
            slot: slot.to_string(),
            state,
            text: text.to_string(),
            group: id,
            clips: 0,
            last_release: now,
            withdraw: false,
            interrupted: false,
            last_words: now,
            pid: None,
        },
    );
}

/// At a start: the jobs the ledger kept, as they stand (the ledger has already
/// ended the ones left running). Ids keep growing above them.
pub(crate) fn restore(kept: &[(u64, String, State)]) {
    with(|jobs| {
        for (id, slot, state) in kept {
            put(jobs, *id, slot, *state, "");
            LAST_ID.fetch_max(*id, Ordering::SeqCst);
        }
    })
}

/// Requests whose end the game has saved (the ledger's confirmation): gone.
pub(crate) fn forget(ids: &[u64]) {
    if ids.is_empty() {
        return;
    }
    with(|jobs| {
        for id in ids {
            if jobs.get(id).is_some_and(|job| job.state.ended()) {
                jobs.remove(id);
            }
        }
    })
}

/// A new request that skipped hearing (typed, or a resumed look).
pub(crate) fn create(slot: &str, text: &str, state: State) -> u64 {
    with(|jobs| insert(jobs, slot, state, text))
}

/// A clip was let go in this conversation. With `join`, a clip let go within
/// JOIN of the one before, still being heard, joins it (you let go too early and
/// went on); otherwise, and always for dictation (sent clip by clip), a new job
/// starts. Joining every clip while one was still heard
/// merged separate messages whenever Whisper was slow (the player, 2026-11-10:
/// an 11 s transcription swallowed the two messages after it).
/// Returns the job and whether it is new: a new job's first message to the
/// game is `heard`, which names it, so a cancel of the clip names its job (an
/// exact identity both sides share; docs/proposals/conversation-sync.md).
pub(crate) const JOIN: Duration = Duration::from_millis(1500);
pub(crate) fn hear(slot: &str, join: bool) -> (u64, bool) {
    with(|jobs| {
        let joinable = jobs
            .values()
            .find(|job| join && job.slot == slot && job.state == State::Hearing && job.last_release.elapsed() <= JOIN)
            .map(|job| job.id);
        let (id, new) = match joinable {
            Some(id) => (id, false),
            None => (insert(jobs, slot, State::Hearing, ""), true),
        };
        let job = jobs.get_mut(&id).unwrap();
        job.clips += 1;
        job.last_release = Instant::now();
        crate::audit::note("hear", slot, &format!("{id} clip {}", job.clips));
        job.last_words = Instant::now();
        (id, new)
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
            return None;
        }
        Some((job.id, first))
    })
}

/// A clip of `slot` came back with no words: Some(its job) when that ended the
/// job (every clip of it was empty), so the notice can name it to the game.
pub(crate) fn empty(slot: &str) -> Option<u64> {
    let id = with(|jobs| jobs.values().filter(|job| job.slot == slot && job.clips > 0).min_by_key(|job| job.id).map(|job| job.id))?;
    words(slot, "");
    (state(id) == Some(State::Failed)).then_some(id)
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
/// `lead` (whose thread got the conversation), and with it any interrupted by
/// Send now (marked true), which come first. They become running together.
/// None when `lead` is no longer queued (another thread took it, or it was
/// cancelled) or nothing queued is left.
pub(crate) fn take_queued(slot: &str, lead: u64) -> Option<Vec<(u64, String, bool)>> {
    with(|jobs| {
        if jobs.get(&lead).map(|job| job.state) != Some(State::Queued) {
            return None;
        }
        let taken: Vec<(u64, String, bool)> = jobs
            .values()
            .filter(|job| job.slot == slot && (job.state == State::Queued || (job.state == State::Running && job.interrupted)))
            .map(|job| (job.id, job.text.clone(), job.interrupted))
            .collect();
        for (id, _, _) in &taken {
            let job = jobs.get_mut(id).unwrap();
            job.state = State::Running;
            job.group = lead;
            job.interrupted = false;
        }
        Some(taken).filter(|taken| !taken.is_empty())
    })
}

/// Send now: the conversation's running jobs stop being worked on but stay
/// running, to join the next run (take_queued). Returns the agent processes to
/// end.
pub(crate) fn interrupt(slot: &str) -> Vec<u32> {
    with(|jobs| {
        let mut pids = Vec::new();
        for job in jobs.values_mut().filter(|job| job.slot == slot && job.state == State::Running) {
            job.interrupted = true;
            if let Some(pid) = job.pid.take() {
                if !pids.contains(&pid) {
                    pids.push(pid);
                }
            }
        }
        pids
    })
}

/// Whether the run led by `group` was interrupted (its jobs wait for, or have
/// joined, the next run): its thread ends without an answer or a failure.
pub(crate) fn interrupted(group: u64) -> bool {
    with(|jobs| jobs.values().any(|job| job.group == group && job.interrupted)
        || jobs.get(&group).is_some_and(|lead| lead.group != group))
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
                job.withdraw = true;
                if let Some(pid) = job.pid {
                    if !out.pids.contains(&pid) {
                        out.pids.push(pid);
                    }
                }
            }
            job.state = State::Cancelled;
            out.ended.push(job.clone());
        }
        out
    })
}

/// The words of requests in this conversation that the agent saw and you then
/// cancelled, not yet told to it; each is told once (the player, 2026-11-10:
/// a cancelled message was answered as if it had been said).
pub(crate) fn take_withdrawn(slot: &str) -> Vec<String> {
    with(|jobs| {
        jobs.values_mut()
            .filter(|job| job.slot == slot && job.withdraw)
            .map(|job| {
                job.withdraw = false;
                job.text.clone()
            })
            .filter(|text| !text.trim().is_empty())
            .collect()
    })
}

pub(crate) fn get(ids: &[u64]) -> Vec<Job> {
    with(|jobs| ids.iter().filter_map(|id| jobs.get(id).cloned()).collect())
}

/// Every request answered together with `group` (its members, the lead too),
/// each with its state: a reply or a failure says exactly which messages it
/// ended, so the game infers nothing (tools/test_jobs.py, invariant 1).
pub(crate) fn members(group: u64) -> Vec<(u64, String, State)> {
    with(|jobs| jobs.values().filter(|job| job.group == group).map(|job| (job.id, job.slot.clone(), job.state)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    // the ledger is one static table, so each test uses its own conversation
    /// A message cancelled while the agent had it is told to the agent once;
    /// one cancelled while still queued never reached it and is not.
    #[test]
    fn a_cancelled_message_the_agent_saw_is_withdrawn_once() {
        let seen = create("t-withdraw", "do the thing", State::Running);
        let unseen = create("t-withdraw", "and this", State::Queued);
        cancel(&[seen, unseen]);
        assert_eq!(take_withdrawn("t-withdraw"), vec!["do the thing".to_string()]);
        assert!(take_withdrawn("t-withdraw").is_empty());
    }

    /// Two clips in flight, let go 1.6 s apart: separate jobs, each new one
    /// says so (its `heard` names it, so its cancel names its job), and each
    /// clip's words go to its own job (the player, 2026-11-10: a cancel hit the
    /// message after the one meant, and a slow transcription swallowed the next).
    #[test]
    fn two_clips_in_flight_stay_two_and_a_cancel_names_its_own() {
        let (first, new) = hear("t-two", true);
        assert!(new);
        assert_eq!(hear("t-two", true), (first, false), "a clip let go at once joins");
        std::thread::sleep(Duration::from_millis(1600));
        let (second, new) = hear("t-two", true);
        assert!(new && first != second, "a clip let go later is its own message");
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
        let (id, _) = hear("t-hear", true);
        assert_eq!(hear("t-hear", true), (id, false), "a second clip joins the first");
        assert_eq!(words("t-hear", "open my"), Some((id, true)));
        cancel(&[id]);
        assert_eq!(words("t-hear", "bags"), None);
        // the next clip is a new job
        assert_ne!(hear("t-hear", true).0, id);
    }

    #[test]
    fn gathering_waits_for_every_clip_then_queues() {
        let (id, _) = hear("t-gather", true);
        hear("t-gather", true);
        words("t-gather", "one");
        assert!(gathered(id, Duration::ZERO, false).is_none(), "a clip is still out");
        words("t-gather", "two");
        assert_eq!(gathered(id, Duration::ZERO, false), Some(Ok("one two".to_string())));
        assert_eq!(state(id), Some(State::Queued));
    }

    #[test]
    fn a_clip_with_no_words_ends_its_job() {
        let (id, _) = hear("t-empty", true);
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
        assert_eq!(taken.iter().map(|(id, _, _)| *id).collect::<Vec<_>>(), vec![a, b]);
        assert!(take_queued("t-queue", a).is_none(), "already taken");
        set_pid(b, 9);
        let cancelled = cancel(&[a]);
        assert_eq!(cancelled.ended.len(), 2);
        assert_eq!(cancelled.pids, vec![9]);
    }

    #[test]
    fn restored_jobs_answer_and_new_ids_grow_above_them() {
        let far = next_id() + 1_000_000;
        restore(&[(far, "t-restore".to_string(), State::Failed)]);
        assert_eq!(state(far), Some(State::Failed));
        assert!(cancel(&[far]).ended.is_empty(), "an ended job stays ended");
        assert!(next_id() > far);
        forget(&[far]);
        assert_eq!(state(far), None);
    }

    #[test]
    fn a_job_still_running_is_not_forgotten() {
        let id = create("t-forget", "x", State::Running);
        forget(&[id]);
        assert_eq!(state(id), Some(State::Running));
    }

    #[test]
    fn ids_only_grow() {
        let a = next_id();
        let b = next_id();
        assert!(b > a);
    }

    #[test]
    fn send_now_joins_the_interrupted_message_to_the_queued_ones() {
        let running = create("t-now", "first", State::Running);
        set_pid(running, 7);
        let waiting = create("t-now", "second", State::Queued);
        assert_eq!(interrupt("t-now"), vec![7]);
        assert!(interrupted(running), "the run's thread ends quietly");
        assert_eq!(state(running), Some(State::Running), "never cancelled");
        let taken = take_queued("t-now", waiting).unwrap();
        assert_eq!(taken, vec![(running, "first".to_string(), true), (waiting, "second".to_string(), false)]);
        assert!(interrupted(running), "it now belongs to the new run");
        assert!(!interrupted(waiting));
        assert!(take_withdrawn("t-now").is_empty(), "nothing is withdrawn");
    }

    #[test]
    fn dictation_clips_never_join() {
        let (first, _) = hear("t-dictate", false);
        assert_eq!(words("t-dictate", "hello"), Some((first, true)));
        let (second, new) = hear("t-dictate", false);
        assert!(new && second != first, "each dictation clip is its own job");
    }
}


