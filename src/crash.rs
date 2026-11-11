//! When something in the companion panics, it says so and cleans up after it.
//!
//! The hook writes the panic (thread, message, place, backtrace) to
//! `%LOCALAPPDATA%\wow-companion\crash.log`. Then:
//! - A panic on a request's own thread kills only that request, and the job it
//!   ran (src/jobs.rs) would show "working" forever. The thread names its job
//!   while it runs (`working_on`), and the hook ends that job failed and tells
//!   the game, from a thread of its own: the panicking thread may hold the
//!   ledger's lock, so the hook itself takes no lock.
//! - A panic on the main thread (the voice loop) ends the process. The jobs it
//!   left in flight are on disk in the ledger (src/ledger.rs), which ends them
//!   at the next start with a line each.
//! - At every start, a crash recorded since the last start is said once in the
//!   window, so a companion that started again on its own is not a mystery.

use super::*;
use std::{cell::Cell, io::Write, sync::OnceLock};

thread_local! {
    static WORKING_ON: Cell<Option<u64>> = const { Cell::new(None) };
}
static ADDONS: OnceLock<PathBuf> = OnceLock::new();

/// While this lives, a panic on this thread ends `job` failed.
pub(crate) struct Working(Option<u64>);

pub(crate) fn working_on(job: u64) -> Working {
    Working(WORKING_ON.with(|working| working.replace(Some(job))))
}

impl Drop for Working {
    fn drop(&mut self) {
        WORKING_ON.with(|working| working.set(self.0));
    }
}

fn file(name: &str) -> Option<PathBuf> {
    companion_dir().ok().map(|dir| dir.join(name))
}

pub(crate) fn log_path() -> Option<PathBuf> {
    file("crash.log")
}

/// Now, as "2026-11-11 03:12:45 UTC" (no time zone database here).
pub(crate) fn stamp() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default() as i64;
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // days since 1970-01-01 to a civil date (Howard Hinnant's algorithm)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02} UTC", rest / 3600, rest % 3600 / 60, rest % 60)
}

/// Add a line to crash.log (the watcher uses it too).
pub(crate) fn note(text: &str) {
    let Some(path) = log_path() else { return };
    if let Ok(mut log) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(log, "{} {text}", stamp());
    }
}

/// Install the hook. Once, at the start of `run`.
pub(crate) fn install(addons: &Path) {
    let _ = ADDONS.set(addons.to_path_buf());
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        // the usual message on stderr (and so in companion.log) first
        default(info);
        let thread = thread::current();
        let name = thread.name().unwrap_or("unnamed").to_string();
        let job = WORKING_ON.with(|working| working.get());
        let backtrace = std::backtrace::Backtrace::force_capture();
        let on = job.map(|job| format!(", on job {job}")).unwrap_or_default();
        note(&format!("panic in thread '{name}' (pid {}){on}: {info}\n{backtrace}\n", std::process::id()));
        if let (false, Some(job)) = (name == "main", job) {
            thread::spawn(move || {
                // after the panicking thread has let go of whatever it held
                thread::sleep(Duration::from_millis(300));
                fail(job, "the companion hit an internal error while on it (crash.log has what happened). Ask again.");
            });
        }
    }));
}

fn fail(job: u64, why: &str) {
    let Some(addons) = ADDONS.get() else { return };
    let Some(found) = jobs::get(&[job]).into_iter().next() else { return };
    let _ = requests::failed(addons, &found.slot, found.group, io::Error::other(why.to_string()));
}

/// At a start: a crash recorded since the last start is said once (a line of
/// the main conversation: kept by the ledger, so it reaches the window even
/// with the game closed).
pub(crate) fn after_start(addons: &Path) {
    let (Some(crashes), Some(seen)) = (log_path(), file("crash.seen")) else { return };
    let size = fs::metadata(&crashes).map(|m| m.len()).unwrap_or(0);
    let known: u64 = fs::read_to_string(&seen).ok().and_then(|text| text.trim().parse().ok()).unwrap_or(0);
    if size > known {
        let text = format!(
            "The companion stopped unexpectedly and is running again. What happened is in {}.",
            crashes.display()
        );
        if post(addons, crate::message::Line::new("", "error", &text)).is_ok() {
            let _ = fs::write(&seen, size.to_string());
        }
    } else if size < known {
        let _ = fs::write(&seen, size.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stamp_reads_as_a_date() {
        let stamp = stamp();
        assert_eq!(stamp.len(), "2026-11-11 03:12:45 UTC".len(), "{stamp}");
        assert!(stamp.starts_with("20"), "{stamp}");
    }

    /// Writes to %LOCALAPPDATA%\wow-companion: run it alone with LOCALAPPDATA
    /// pointed at a scratch folder (it refuses otherwise).
    #[test]
    #[ignore]
    fn a_panic_on_a_request_thread_is_written_and_its_job_fails() {
        let base = env::var("LOCALAPPDATA").unwrap_or_default();
        assert!(base.to_lowercase().contains("scratch") || base.to_lowercase().contains("temp"), "point LOCALAPPDATA at a scratch folder: {base}");
        let addons = PathBuf::from(&base).join("AddOns");
        fs::create_dir_all(&addons).unwrap();
        install(&addons);
        let job = jobs::create("crashtest", "a request that panics", jobs::State::Running);
        let boom = thread::Builder::new()
            .name("boom".into())
            .spawn(move || {
                let _working = working_on(job);
                panic!("deliberate, for the test");
            })
            .unwrap();
        assert!(boom.join().is_err());
        thread::sleep(Duration::from_secs(2));
        let log = fs::read_to_string(log_path().unwrap()).unwrap();
        assert!(log.contains("panic in thread 'boom'") && log.contains(&format!("on job {job}")) && log.contains("deliberate, for the test"), "{log}");
        assert_eq!(jobs::state(job), Some(jobs::State::Failed));
    }

    #[test]
    fn a_thread_names_its_job_while_it_works() {
        assert_eq!(WORKING_ON.with(|w| w.get()), None);
        {
            let _working = working_on(7);
            assert_eq!(WORKING_ON.with(|w| w.get()), Some(7));
        }
        assert_eq!(WORKING_ON.with(|w| w.get()), None);
    }
}
