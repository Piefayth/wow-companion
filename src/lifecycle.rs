//! The companion's life: one at a time, and clean exits.
//!
//! - One companion: `run` holds a lock (crates/settings/src/platform.rs) that
//!   dies with its process. A second `run` refuses to start. The copy `restart`
//!   launches to take over (src/restart.rs) waits for the lock on a thread of
//!   its own, so the overlap the hand-over needs still happens.
//! - Clean exits, each written to `exit.txt` (reason and pid) so the watcher
//!   (src/watcher.rs) can tell them from a crash: `stop` (a request file, acted
//!   on when no request is in flight and no button is held, as a restart is),
//!   the game closing (only when the watcher started us: the companion wakes
//!   with WoW and sleeps without it, releasing the mic and the model's video
//!   memory), and a restart's hand-over.
//! - Pause: the tray's "Pause listening" is a file; while it exists the talk
//!   button does nothing (voice::PAUSED).
//! - Two game clients at once (multiboxing): said once in the window.

use super::*;
use wow_companion_settings::platform;

/// Set by the watcher on the `run` it starts.
pub(crate) const WATCHED: &str = "WOW_COMPANION_WATCHED";

fn file(name: &str) -> io::Result<PathBuf> {
    Ok(companion_dir()?.join(name))
}

pub(crate) fn stop_request() -> io::Result<PathBuf> {
    file("stop.request")
}

pub(crate) fn pause_file() -> io::Result<PathBuf> {
    file("paused")
}

fn pid_file() -> io::Result<PathBuf> {
    file("companion.pid")
}

/// Whether a companion is running (holds or waits for the lock).
pub(crate) fn running() -> bool {
    platform::lock_exists(platform::COMPANION_LOCK)
}

/// Before `run` does anything: refuse when a companion already runs.
pub(crate) fn refuse_second() -> io::Result<()> {
    // the copy restart starts is meant to overlap the one it replaces
    if env::var_os("WOW_COMPANION_READY_FILE").is_some() || !running() {
        return Ok(());
    }
    let pid = fs::read_to_string(pid_file()?).unwrap_or_default();
    Err(io::Error::other(format!(
        "the companion is already running (PID {}); stop it first, or `wow-companion restart` to move it onto a new build",
        pid.trim()
    )))
}

/// In the copy that runs: take the lock for the life of the process. The
/// copy a restart started waits for the old one to let go, on its own thread.
pub(crate) fn hold() -> io::Result<()> {
    if env::var_os("WOW_COMPANION_READY_FILE").is_some() {
        // the lock exists from now (this thread's handle), so nothing sees a gap
        thread::spawn(|| {
            let lock = platform::take_lock(platform::COMPANION_LOCK, true);
            let _ = fs::write(pid_file().unwrap_or_default(), std::process::id().to_string());
            // the lock belongs to this thread: it lives as long as the process
            loop {
                thread::park();
                let _ = &lock;
            }
        });
        // give that thread its moment to create the lock before anything looks
        thread::sleep(Duration::from_millis(50));
        return Ok(());
    }
    match platform::take_lock(platform::COMPANION_LOCK, false) {
        Some(lock) => {
            // held by the main thread, which runs the voice loop until we exit
            std::mem::forget(lock);
            let _ = fs::write(pid_file()?, std::process::id().to_string());
            // a stale request from before must not stop this start at once
            let _ = fs::remove_file(stop_request()?);
            Ok(())
        }
        None => Err(io::Error::other(format!(
            "the companion is already running (PID {})",
            fs::read_to_string(pid_file()?).unwrap_or_default().trim()
        ))),
    }
}

/// A clean exit, for the watcher: why, and who.
pub(crate) fn exited(reason: &str) {
    if let Ok(path) = file("exit.txt") {
        let _ = fs::write(path, format!("{} {reason}", std::process::id()));
    }
}

/// The reason in `exit.txt`, if written since `since` (unix ms).
pub(crate) fn last_exit(since: u128) -> Option<String> {
    let path = file("exit.txt").ok()?;
    let written = modified_millis(&path)?;
    if written < since {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    Some(text.split_once(' ').map(|(_, reason)| reason.trim().to_string()).unwrap_or_default())
}

fn idle() -> bool {
    IN_FLIGHT.load(Ordering::SeqCst) == 0 && !voice::HOLDING.load(Ordering::Relaxed) && !recently_released()
}

/// Close the mic properly and exit (the same order a restart uses).
fn leave(reason: &str) -> ! {
    voice::DEAF.store(true, Ordering::SeqCst);
    while IN_FLIGHT.load(Ordering::SeqCst) > 0 {
        thread::sleep(Duration::from_millis(100));
    }
    voice::SHUTDOWN.store(true, Ordering::SeqCst);
    let asked = Instant::now();
    while !voice::STOPPED.load(Ordering::SeqCst) && asked.elapsed() < Duration::from_secs(3) {
        thread::sleep(Duration::from_millis(20));
    }
    exited(reason);
    println!("exiting: {reason}");
    std::process::exit(0);
}

/// `wow-companion stop`: the companion (and the watcher, if one runs) end
/// cleanly once nothing is in flight. Waits until they have.
pub(crate) fn stop() -> io::Result<()> {
    let watcher = platform::lock_exists(platform::WATCHER_LOCK);
    if !running() && !watcher {
        println!("the companion is not running");
        let _ = fs::remove_file(stop_request()?);
        return Ok(());
    }
    if watcher {
        fs::write(file("quit.request")?, "")?;
    }
    if running() {
        fs::write(stop_request()?, "")?;
        println!("asked the companion to stop once no request is in flight and no button is held");
    }
    let since = Instant::now();
    while (running() || platform::lock_exists(platform::WATCHER_LOCK)) && since.elapsed() < Duration::from_secs(600) {
        thread::sleep(Duration::from_millis(250));
    }
    if running() {
        return Err(io::Error::other("still running after 10 minutes (a request in flight?); ask again later"));
    }
    println!("stopped");
    Ok(())
}

/// The companion's own watchers: a stop asked for, the game closing (when the
/// watcher started it), a pause, two clients.
pub(crate) fn watch(addons: &Path) {
    let watched = env::var_os(WATCHED).is_some();
    let addons = addons.to_path_buf();
    thread::spawn(move || {
        let mut game_seen = false;
        let mut told_clients = false;
        let mut last_clients_check = Instant::now() - Duration::from_secs(60);
        loop {
            thread::sleep(Duration::from_millis(500));
            let paused = pause_file().map(|path| path.exists()).unwrap_or(false);
            if voice::PAUSED.swap(paused, Ordering::SeqCst) != paused {
                println!("{}", if paused { "paused: the talk button does nothing until resumed" } else { "listening again" });
            }
            if stop_request().map(|path| path.exists()).unwrap_or(false) && idle() {
                let _ = fs::remove_file(stop_request().unwrap_or_default());
                leave("stopped");
            }
            if last_clients_check.elapsed() < Duration::from_secs(5) {
                continue;
            }
            last_clients_check = Instant::now();
            let clients = game_clients();
            if clients > 1 && !told_clients {
                told_clients = true;
                let text = format!(
                    "{clients} game clients are running: every message goes to all of them. One client per install for now."
                );
                println!("{text}");
                let _ = send_inbox(&addons, &log_inbox_in(None, "error", &text, None, None));
            } else if clients <= 1 {
                told_clients = false;
            }
            if !watched {
                continue;
            }
            if clients > 0 {
                game_seen = true;
            } else if game_seen && idle() {
                // the game closed and nothing is in flight (a request still
                // running finishes first: its reply is kept for the next login);
                // the watcher wakes the companion again with the game
                leave("game closed");
            }
        }
    });
}
