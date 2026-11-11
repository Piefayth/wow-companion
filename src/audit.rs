//! The audit trail (the player, 2026-11-10: "how can we audit it?"): one line
//! per thing that happened to a request, in order, so a confusing moment in
//! the game can be read back exactly instead of guessed at. Every job state
//! change (from the ledger itself, src/jobs.rs), every clip's words, every
//! message sent to the game and every command the game drew are written to
//! `%LOCALAPPDATA%\wow-companion\audit.log`. `tools/audit.py` prints it merged
//! with the game's own record (WowCompanionDB.audit, after a reload).

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static FILE: Mutex<()> = Mutex::new(());

fn path() -> Option<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")?;
    Some(PathBuf::from(base).join("wow-companion").join("audit.log"))
}

/// `what` is a short word (job, words, send, cmd, hear); `detail` one line.
pub(crate) fn note(what: &str, slot: &str, detail: &str) {
    if cfg!(test) {
        return;
    }
    let Some(path) = path() else { return };
    let ms = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default();
    let slot = if slot.is_empty() { "main" } else { slot };
    let detail: String = detail.replace(['\n', '\r'], " ").chars().take(240).collect();
    let _held = FILE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "{ms} pc {slot} {what} {detail}");
    }
    // a week of a busy evening is a few MB; start over past 8 MB
    if std::fs::metadata(&path).map(|m| m.len() > 8 << 20).unwrap_or(false) {
        let _ = std::fs::rename(&path, path.with_extension("old.log"));
    }
}
