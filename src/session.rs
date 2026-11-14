//! The game's UI session, read once (docs/reviews/2026-11-11.md, finding 3).
//!
//! The inbox's writes start again with each session (src/inbox.rs), and their
//! bells are its set's. Both come from one reading of Link's save (`Session`):
//! its load count and when it was written, with when the game started. Read
//! from different files they came apart in the middle of a save
//! (docs/history.md, 2026-11-12): sends began a session in one set and went on
//! in the next, and the game waited a whole session on a bell that never rang.

use super::*;
use crate::savedvars::{self, Lua};

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Session {
    /// Link's count of its loads in the save: the session before this one (the
    /// addon adds its one at load, in memory)
    pub(crate) loads: u64,
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
            return Some(Session { loads: 0, began: 0, game });
        };
        let began = modified_millis(&path)?;
        let db = savedvars::global(&savedvars::read(&path).ok()?, "WowCompanionLinkDB")?;
        let loads = db.get("loads").and_then(Lua::number).filter(|n| *n >= 0.0 && n.fract() == 0.0);
        Some(Session { loads: loads.unwrap_or(0.0) as u64, began, game })
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

    /// This session's number: the game's own load count while it runs (the save
    /// holds the one before), which the inbox carries so the game can tell writes
    /// made for it from those of an earlier session.
    pub(crate) fn number(&self) -> u64 {
        self.loads + 1
    }

    /// This session's set of slot bells.
    pub(crate) fn set(&self) -> u64 {
        self.number() % SETS
    }

    /// What tells one session from the next: a reload changes the count, a
    /// relaunch (after a crash, the count unchanged) the game's start.
    pub(crate) fn key(&self) -> String {
        format!("{}|{}", self.loads, self.game.map(|at| at.to_string()).unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime};

    fn save(link: &Path, loads: u64) {
        fs::write(link, format!("WowCompanionLinkDB = {{ [\"loads\"] = {loads}, }}")).unwrap();
    }

    #[test]
    fn a_session_starts_with_a_save_of_link_and_no_other() {
        let root = env::temp_dir().join(format!("wc-session-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let addons = root.join("Interface").join("AddOns");
        fs::create_dir_all(addons.join(LINK)).unwrap();
        let saved = root.join("WTF").join("Account").join("A").join("SavedVariables");
        fs::create_dir_all(&saved).unwrap();
        let core = saved.join(format!("{ADDON}.lua"));
        fs::write(&core, "WowCompanionDB = { }").unwrap();
        let link = saved.join(format!("{LINK}.lua"));
        save(&link, 7);
        let first = Session::read(&addons).unwrap();
        assert_eq!((first.number(), first.set()), (8, 8 % SETS));
        // another addon's save landing first is no new session (2026-11-12: read
        // from Core's save, sends started over a set early)
        fs::File::options().write(true).open(&core).unwrap().set_modified(SystemTime::now() + Duration::from_secs(5)).unwrap();
        assert_eq!(Session::read(&addons).unwrap().key(), first.key());
        // a /reload's save of Link: the next session, in the next set
        save(&link, 8);
        let next = Session::read(&addons).unwrap();
        assert_ne!(next.key(), first.key());
        assert_eq!((next.number(), next.set()), (9, 9 % SETS));
        let _ = fs::remove_dir_all(&root);
    }
}
