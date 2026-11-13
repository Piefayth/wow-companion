//! The game's UI session, read once (docs/reviews/2026-11-11.md, finding 3).
//!
//! The slot cursor starts again with each session, and its slot bells are its
//! set's. The cursor, the set and the slot count all come from one reading of
//! Link's save (`Session`): its load count, how many slots it saw, and when it
//! was written, with when the game started. Read from different files they came
//! apart in the middle of a save (docs/history.md, 2026-11-12): the cursor began
//! a session in one set and went on in the next, and the game waited a whole
//! session on a first slot that never rang.

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
    /// this session began (0 before the game has ever saved)
    pub(crate) began: u128,
    /// when the running Wow.exe started; None while the game is closed
    pub(crate) game: Option<u64>,
}

impl Session {
    /// None while the save does not parse (the game is writing it): the caller
    /// asks again rather than guess. Before the game has ever saved, the first
    /// session.
    pub(crate) fn read(addons: &Path) -> Option<Session> {
        let game = channel::game();
        let Some(path) = saved_variables(addons, LINK) else {
            return Some(Session { loads: 0, slots: None, began: 0, game });
        };
        let began = modified_millis(&path)?;
        let db = savedvars::global(&fs::read_to_string(&path).ok()?, "WowCompanionLinkDB")?;
        let count = |key: &str| db.get(key).and_then(Lua::number).filter(|n| *n >= 0.0 && n.fract() == 0.0);
        Some(Session {
            loads: count("loads").unwrap_or(0.0) as u64,
            slots: count("slotCount").map(|n| (n as u32).min(SLOTS)),
            began,
            game,
        })
    }

    /// The session now, read again until the save parses: the game writes it in
    /// a moment.
    pub(crate) fn now(addons: &Path) -> io::Result<Session> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if let Some(session) = Session::read(addons) {
                return Ok(session);
            }
            if std::time::Instant::now() >= deadline {
                return Err(io::Error::other(format!("the game's save ({LINK}.lua) has not parsed for 2 s")));
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
    }

    /// This session's set of slot bells.
    pub(crate) fn set(&self) -> u64 {
        (self.loads + 1) % SETS
    }

    /// How many slots the running game knows. The game only sees addon folders
    /// that existed when it launched, so slots installed since are invisible to
    /// it until a full restart, and a message sent to one would be lost. Link
    /// records the count it sees; until it has, the old 64.
    pub(crate) fn known_slots(&self) -> u32 {
        self.slots.unwrap_or(64).min(SLOTS)
    }

    /// What tells one session from the next: a reload changes the count, a
    /// relaunch (after a crash, the count unchanged) the game's start.
    pub(crate) fn key(&self) -> String {
        format!("{}|{}", self.loads, self.game.map(|at| at.to_string()).unwrap_or_default())
    }
}
