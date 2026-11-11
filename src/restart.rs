//! Restarts that never cut a request off: run from a copy, hand over.
//!
//! Windows will not let a running .exe be replaced, so `cargo build` failed while
//! the companion ran, and the only way onto a new build was to kill it, losing any
//! reply in flight. So `run` executes from a copy in %LOCALAPPDATA%, leaving the
//! real one free to rebuild; `restart` leaves a request, and the running copy acts
//! on it only when no request is in flight and no button is held: it starts the
//! newest build (which copies itself in turn) and exits.

use super::*;

pub(crate) fn companion_dir() -> io::Result<PathBuf> {
    let base = env::var_os("LOCALAPPDATA").ok_or_else(|| io::Error::other("no LOCALAPPDATA"))?;
    let dir = PathBuf::from(base).join("wow-companion");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

pub(crate) fn restart_request() -> io::Result<PathBuf> {
    Ok(companion_dir()?.join("restart.request"))
}

pub(crate) fn request_restart() -> io::Result<()> {
    fs::write(restart_request()?, "")?;
    println!("asked the companion to restart onto the newest build once it is idle");
    Ok(())
}

// set on the copy, naming the build it came from
pub(crate) const SOURCE_EXE: &str = "WOW_COMPANION_SOURCE_EXE";

/// Copy the build aside into `bin\<name>\`: the exe as `<name>.exe` and every DLL
/// beside it (the streaming engine's sherpa-onnx and ONNX Runtime). A folder per
/// copy, because Windows locks a loaded DLL: during a restart's overlap the old
/// copy holds its own while the new one loads its own.
pub(crate) fn copy_aside(source: &Path, name: &str) -> io::Result<PathBuf> {
    let folder = companion_dir()?.join("bin").join(name);
    fs::create_dir_all(&folder)?;
    let exe = folder.join(format!("{name}.exe"));
    fs::copy(source, &exe)?;
    if let Some(beside) = source.parent() {
        for entry in fs::read_dir(beside)?.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("dll")) {
                fs::copy(&path, folder.join(entry.file_name()))?;
            }
        }
    }
    Ok(exe)
}

/// Remove the copies in `bin` that are not running, keeping `keep`'s folder. A
/// copy's folder goes only once its exe could be deleted (a running exe cannot
/// be), so a running copy never loses a DLL it has not loaded yet.
fn clear_bin(keep: Option<&Path>) -> io::Result<()> {
    let Ok(entries) = fs::read_dir(companion_dir()?.join("bin")) else { return Ok(()) };
    for entry in entries.flatten() {
        let path = entry.path();
        if keep.is_some_and(|keep| keep.starts_with(&path)) {
            continue;
        }
        if path.is_dir() {
            let exes: Vec<PathBuf> = fs::read_dir(&path)
                .map(|inside| inside.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|ext| ext == "exe")).collect())
                .unwrap_or_default();
            if exes.iter().all(|exe| fs::remove_file(exe).is_ok()) {
                let _ = fs::remove_dir_all(&path);
            }
        } else {
            let _ = fs::remove_file(&path);
        }
    }
    Ok(())
}

/// Started from the build itself: copy it aside, run the copy, and step away.
/// Returns Some when this process handed over and should exit.
pub(crate) fn run_from_copy() -> io::Result<Option<io::Result<()>>> {
    if env::var_os(SOURCE_EXE).is_some() {
        // a copy: the generations before it are done (each is 180 MB in debug);
        // a predecessor still exiting is locked and goes next time
        clear_bin(env::current_exe().ok().as_deref())?;
        return Ok(None);
    }
    let source = env::current_exe()?;
    // earlier copies: whichever are not running can go
    clear_bin(None)?;
    let copy = copy_aside(&source, &format!("companion-{}", std::process::id()))?;
    // Not waited on: a launcher that waited would itself be the running build,
    // holding the lock this exists to free. The copy inherits the console, so its
    // output still lands where the companion was started.
    std::process::Command::new(&copy)
        .args(env::args_os().skip(1))
        .env(SOURCE_EXE, &source)
        .spawn()?;
    println!("running as {} (the build itself stays free to rebuild)", copy.display());
    Ok(Some(Ok(())))
}

pub(crate) fn watch_for_restart(args: Vec<String>) {
    let (Ok(request), Some(source)) = (restart_request(), env::var_os(SOURCE_EXE)) else { return };
    loop {
        thread::sleep(Duration::from_secs(1));
        if !request.exists() || !lifecycle::idle() {
            continue;
        }
        // copy the new build now; if it is mid-build the copy fails, so try again
        let Ok(next) = copy_aside(Path::new(&source), &format!("companion-next-{}", std::process::id())) else {
            continue;
        };
        let _ = fs::remove_file(&request);
        println!("restarting onto the new build");
        // Overlap, never a gap. Closing the mic before the next copy opened its own
        // left the headset's hands-free link with no stream, Windows dropped it, and
        // the first press after every restart recorded silence (measured twice). So
        // the next copy starts while this one keeps working, opens its mic, loads,
        // and raises a flag; only then does this one close its mic properly (an
        // abandoned stream can wedge the link), lower the flag, and exit.
        let Ok(dir) = companion_dir() else { continue };
        let flag = dir.join(format!("ready-{}.flag", std::process::id()));
        let _ = fs::remove_file(&flag);
        if let Err(err) = std::process::Command::new(&next)
            .args(&args)
            .env(SOURCE_EXE, &source)
            .env("WOW_COMPANION_READY_FILE", &flag)
            .spawn()
        {
            eprintln!("  restart failed, still running the old build: {err}");
            continue;
        }
        let since = Instant::now();
        while !flag.exists() {
            if since.elapsed() > Duration::from_secs(120) {
                eprintln!("  the new build never came up; still running this one");
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        if !flag.exists() {
            continue;
        }
        // not mid-press, then deaf: the new copy takes the pad from here (it stops
        // waiting for this one after 15 s), and this one only finishes its work.
        // Both reading the pad answered one clip twice (measured 2026-11-10).
        while voice::HOLDING.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(100));
        }
        lifecycle::wind_down();
        let _ = fs::remove_file(&flag);
        println!("handed over to the new build");
        lifecycle::exited("handover");
        std::process::exit(0);
    }
}
