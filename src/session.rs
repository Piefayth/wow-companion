//! The game's UI session, read once (docs/reviews/2026-11-11.md, finding 3).
//!
//! The channel must know the session exactly: the slot cursor starts again with
//! each one, and its bells are its set's. Until now the cursor took the session
//! from Core's save's time and the game's start, the bell set from Link's load
//! count, the slot count from a text search, and each of those read the save its
//! own way. `Session` is one reading of Link's save, through savedvars: its load
//! count, how many slots it saw, and when it was written, with when the game
//! started.
//!
//! On trial beside the channel (CLAUDE.md, "Changing the channel"): every send
//! compares it with the keys the channel uses today and writes any disagreement
//! to audit.log (`session`). It takes over only after it has agreed across
//! reloads and a relaunch.

use super::*;
use crate::savedvars::{self, Lua};

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Session {
    /// Link's count of its loads in the save: the session before this one (the
    /// addon adds its one at load, in memory)
    pub(crate) loads: u64,
    /// how many slot folders the game saw at its last load; None before Link has
    /// recorded it
    pub(crate) slots: Option<u32>,
    /// when the save was written, which a reload does before it loads again: when
    /// this session began
    pub(crate) began: u128,
    /// when the running Wow.exe started; None while the game is closed
    pub(crate) game: Option<u64>,
}

impl Session {
    /// None when there is no save yet, or it does not parse (the game is writing
    /// it): the caller asks again rather than guess.
    pub(crate) fn read(addons: &Path) -> Option<Session> {
        let path = saved_variables(addons, LINK)?;
        let began = modified_millis(&path)?;
        let db = savedvars::global(&fs::read_to_string(&path).ok()?, "WowCompanionLinkDB")?;
        let count = |key: &str| db.get(key).and_then(Lua::number).filter(|n| *n >= 0.0 && n.fract() == 0.0);
        Some(Session {
            loads: count("loads")? as u64,
            slots: count("slotCount").map(|n| (n as u32).min(SLOTS)),
            began,
            game: channel::game(),
        })
    }

    /// This session's set of slot bells.
    pub(crate) fn set(&self) -> u64 {
        (self.loads + 1) % SETS
    }

    /// What tells one session from the next: a reload changes the count, a
    /// relaunch (after a crash, the count unchanged) the game's start.
    pub(crate) fn key(&self) -> String {
        format!("{}|{}", self.loads, self.game.map(|at| at.to_string()).unwrap_or_default())
    }
}

/// The keys the channel used at its last send, and the session's, to see
/// whether both saw a new session at the same send.
static LAST: Mutex<Option<(String, String)>> = Mutex::new(None);

/// At every send: Session against what the channel decided with (its cursor's
/// stamp, its bell set, its slot count). A disagreement, or a save that did not
/// parse, goes to audit.log; so does every session change both saw, so the
/// trial's coverage shows.
pub(crate) fn shadow(addons: &Path, stamp: &str, set: u64, known: u32) {
    let Some(session) = Session::read(addons) else {
        crate::audit::note("session", "", &format!("unreadable save at a send (stamp {stamp}, set {set})"));
        return;
    };
    let mut problems = Vec::new();
    if session.set() != set {
        problems.push(format!("set {} against the channel's {set}", session.set()));
    }
    // the channel assumes 64 until Link has counted
    if session.slots.unwrap_or(64) != known {
        problems.push(format!("{:?} slots against the channel's {known}", session.slots));
    }
    let key = session.key();
    let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if last.is_none() {
        crate::audit::note("session", "", &format!("watching from {key} (stamp {stamp}, set {set}, {known} slots)"));
    }
    if let Some((old_stamp, old_key)) = last.as_ref() {
        match (old_stamp != stamp, *old_key != key) {
            (true, true) => crate::audit::note("session", "", &format!("new session, both agree: {key} (stamp {stamp})")),
            (true, false) => problems.push(format!("the channel saw a new session ({stamp}), Session did not ({key})")),
            (false, true) => problems.push(format!("Session saw a new session ({key}), the channel did not ({stamp})")),
            (false, false) => {}
        }
    }
    *last = Some((stamp.to_string(), key));
    for problem in problems {
        crate::audit::note("session", "", &format!("DISAGREE: {problem}"));
    }
}
