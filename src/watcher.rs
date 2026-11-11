//! `wow-companion start`: the companion wakes with WoW.
//!
//! A small watcher, started with Windows (the setup window's checkbox) or by
//! hand, that does nothing until Wow.exe appears, then starts `run` hidden.
//! When the game closes the companion finishes what is in flight and exits
//! cleanly (src/lifecycle.rs), releasing the mic and the model's video memory,
//! and the watcher waits for the next Wow.exe. If the companion stops without a
//! clean exit (a crash) while the game runs, it is started again, at most 3
//! times in 10 minutes; then the watcher gives up until the game is restarted,
//! and says so in crash.log and on its icon. A restart's hand-over is not a
//! stop (the next copy holds the lock throughout), and neither is a clean exit.
//!
//! The watcher owns the tray icon (src/tray.rs) and writes what it is doing to
//! `status.txt` for the setup window. It runs from a copy in the companion's
//! bin folder, as `run` does, so the build stays free to rebuild.

use super::*;
use std::sync::mpsc;
use tray::{Choice, Look};
use wow_companion_settings::platform;

/// Set on the watcher process (the copy `start` launches).
const WATCHER: &str = "WOW_COMPANION_WATCHER";
/// The exe the watcher came from, which it starts `run` with.
const WATCH_SOURCE: &str = "WOW_COMPANION_WATCH_SOURCE";

fn file(name: &str) -> io::Result<PathBuf> {
    Ok(companion_dir()?.join(name))
}

pub(crate) fn start() -> io::Result<()> {
    if env::var_os(WATCHER).is_none() {
        if platform::lock_exists(platform::WATCHER_LOCK) {
            println!("already started: the watcher is running");
            return Ok(());
        }
        let source = env::current_exe()?;
        let bin = companion_dir()?.join("bin");
        fs::create_dir_all(&bin)?;
        let copy = bin.join(format!("watch-{}.exe", std::process::id()));
        fs::copy(&source, &copy)?;
        let mut command = std::process::Command::new(&copy);
        command.arg("start").env(WATCHER, "1").env(WATCH_SOURCE, &source);
        platform::hide_window(&mut command).spawn()?;
        println!("started: the companion wakes when WoW starts; its icon is in the notification area");
        return Ok(());
    }
    let Some(lock) = platform::take_lock(platform::WATCHER_LOCK, false) else {
        // another watcher won the race
        return Ok(());
    };
    std::mem::forget(lock);
    let _ = fs::remove_file(file("quit.request")?);
    let (choose, choices) = mpsc::channel();
    let worker = thread::spawn(move || watch(choices));
    match tray::run(choose) {
        // the icon ended with Quit; the worker has already finished
        Ok(()) => {}
        Err(err) => {
            eprintln!("no tray icon ({err}); watching without one");
            let _ = worker.join();
        }
    }
    Ok(())
}

fn source() -> PathBuf {
    env::var_os(WATCH_SOURCE).map(PathBuf::from).or_else(|| env::current_exe().ok()).unwrap_or_default()
}

fn setup_exe() -> Option<PathBuf> {
    let beside = source().with_file_name("wow-companion-setup.exe");
    let checkout = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("crates").join("setup").join("target");
    [beside, checkout.join("release").join("wow-companion-setup.exe"), checkout.join("debug").join("wow-companion-setup.exe")]
        .into_iter()
        .find(|exe| exe.exists())
}

fn launch() -> io::Result<()> {
    let mut command = std::process::Command::new(source());
    command.arg("run").env(lifecycle::WATCHED, "1");
    platform::hide_window(&mut command).spawn().map(|_| ())
}

fn say(look: Look, tip: &str, said: &mut Option<(Look, String)>) {
    if said.as_ref().is_some_and(|(was, text)| *was == look && text == tip) {
        return;
    }
    *said = Some((look, tip.to_string()));
    tray::show(look, &format!("WoW Companion: {tip}"));
    if let Ok(path) = file("status.txt") {
        let _ = fs::write(path, look.name());
    }
}

/// The watcher's loop, on its own thread (the icon has the main one).
fn watch(choices: mpsc::Receiver<Choice>) {
    let mut said = None;
    // when we last started it, or first saw it running (unix ms)
    let mut since: Option<u128> = None;
    let mut launched: Option<Instant> = None;
    let mut relaunches: Vec<Instant> = Vec::new();
    let mut was_running = false;
    let mut gave_up = false;
    // stopped on purpose (`stop`) while the game runs: not again until it restarts
    let mut quiet = false;
    let mut asked_to_stop = false;
    loop {
        while let Ok(choice) = choices.try_recv() {
            match choice {
                Choice::TogglePause => {
                    if let Ok(path) = lifecycle::pause_file() {
                        let _ = if path.exists() { fs::remove_file(&path) } else { fs::write(&path, "") };
                    }
                }
                Choice::OpenSetup => match setup_exe() {
                    Some(exe) => {
                        let _ = std::process::Command::new(exe).spawn();
                    }
                    None => crash::note("watcher: the setup window was not found next to the companion"),
                },
                Choice::ShowLog => {
                    if let Some(path) = logfile::path() {
                        let _ = platform::open(&path);
                    }
                }
                Choice::Quit => {
                    let _ = file("quit.request").and_then(|path| fs::write(path, ""));
                }
            }
        }
        let running = lifecycle::running();
        // Quit (the menu, or `wow-companion stop`): the companion first, cleanly
        if file("quit.request").map(|path| path.exists()).unwrap_or(false) {
            if running {
                if !asked_to_stop {
                    asked_to_stop = true;
                    let _ = lifecycle::stop_request().and_then(|path| fs::write(path, ""));
                }
                say(Look::Starting, "stopping once nothing is in flight", &mut said);
                thread::sleep(Duration::from_millis(500));
                continue;
            }
            let _ = file("quit.request").and_then(fs::remove_file);
            let _ = file("status.txt").and_then(fs::remove_file);
            tray::close();
            return;
        }
        let game = platform::process_count("Wow.exe") > 0;
        if !game {
            // a new game session gets a fresh start
            quiet = false;
            gave_up = false;
            relaunches.clear();
        }
        if running {
            if !was_running {
                since.get_or_insert_with(jobs::now_ms);
            }
            was_running = true;
            launched = None;
            let paused = lifecycle::pause_file().map(|path| path.exists()).unwrap_or(false);
            // what the ledger reports (src/ledger.rs: the mailbox not taken, a
            // file it could not write) is said on the icon too
            let ledger = crate::ledger::problems();
            let also = ledger.first().map(|problem| format!("; {problem}")).unwrap_or_default();
            if paused {
                say(Look::Paused, &format!("paused (the talk button does nothing){also}"), &mut said);
            } else {
                say(Look::Listening, &format!("listening{also}"), &mut said);
            }
            thread::sleep(Duration::from_secs(1));
            continue;
        }
        if was_running {
            // it was running and is not: how did it end?
            was_running = false;
            match lifecycle::last_exit(since.take().unwrap_or(0)) {
                Some(reason) if reason == "stopped" => quiet = true,
                Some(_) => {}
                None => {
                    crash::note("watcher: the companion stopped without a clean exit");
                    if game {
                        relaunch(&mut relaunches, &mut gave_up);
                    }
                }
            }
        }
        // started, but never took its lock: a failed start counts as a crash
        if let Some(at) = launched {
            if at.elapsed() < Duration::from_secs(60) {
                say(Look::Starting, "starting", &mut said);
                thread::sleep(Duration::from_secs(1));
                continue;
            }
            launched = None;
            crash::note("watcher: the companion did not come up within a minute of starting");
            relaunch(&mut relaunches, &mut gave_up);
        }
        if gave_up {
            say(Look::GaveUp, "stopped 3 times in 10 minutes; restart WoW to try again (crash.log)", &mut said);
        } else if !game {
            say(Look::Waiting, "waiting for WoW", &mut said);
        } else if quiet {
            say(Look::Waiting, "stopped; starts again with the next game", &mut said);
        } else {
            match launch() {
                Ok(()) => {
                    launched = Some(Instant::now());
                    since = Some(jobs::now_ms());
                    say(Look::Starting, "starting", &mut said);
                }
                Err(err) => {
                    crash::note(&format!("watcher: could not start the companion: {err}"));
                    relaunch(&mut relaunches, &mut gave_up);
                }
            }
        }
        thread::sleep(Duration::from_secs(2));
    }
}

/// Count a start after a crash; three in ten minutes and the watcher gives up.
fn relaunch(relaunches: &mut Vec<Instant>, gave_up: &mut bool) {
    relaunches.retain(|at| at.elapsed() < Duration::from_secs(600));
    if relaunches.len() >= 3 {
        if !*gave_up {
            crash::note("watcher: gave up: the companion stopped 3 times in 10 minutes; it starts again with the next game");
        }
        *gave_up = true;
        return;
    }
    relaunches.push(Instant::now());
}
