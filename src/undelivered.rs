//! A conversation line that could neither be delivered nor kept in the save
//! file (the slots spent, a bell that would not ring, a save file that could
//! not be written) is not dropped: it goes to
//! `%LOCALAPPDATA%\wow-companion\undelivered.txt`, with the game session it
//! failed in, and is sent again once a new session has started (a reload, a
//! restart of the game) and the addon has had a moment to load.

use super::*;
use std::io::Write;

fn path() -> Option<PathBuf> {
    companion_dir().ok().map(|dir| dir.join("undelivered.txt"))
}

/// Keep `inbox` for the next session. Only conversation lines: status
/// messages are only ever about now.
pub(crate) fn keep(addons: &Path, inbox: &str, why: &io::Error) {
    if !inbox.starts_with("{ kind = \"log\"") || inbox.contains('\n') {
        return;
    }
    let Some(path) = path() else { return };
    let stamp = saved_variables_stamp(addons).unwrap_or_default();
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        if writeln!(file, "{stamp}\t{inbox}").is_ok() {
            println!("  kept for the next game session ({why}): {}", path.display());
        }
    }
}

/// Lines kept in an earlier session, once the session has changed and held
/// still for a few seconds.
pub(crate) fn watch(addons: &Path) {
    let addons = addons.to_path_buf();
    thread::spawn(move || {
        let mut last: Option<(String, Instant)> = None;
        loop {
            thread::sleep(Duration::from_secs(3));
            let Some(path) = path() else { continue };
            let Ok(text) = fs::read_to_string(&path) else { continue };
            if text.trim().is_empty() || !game_running().unwrap_or(false) {
                continue;
            }
            let now = saved_variables_stamp(&addons).unwrap_or_default();
            match &last {
                Some((seen, since)) if *seen == now && since.elapsed() >= Duration::from_secs(10) => {}
                Some((seen, _)) if *seen == now => continue,
                _ => {
                    last = Some((now, Instant::now()));
                    continue;
                }
            }
            let mut still = String::new();
            for line in text.lines() {
                let Some((stamp, inbox)) = line.split_once('\t') else { continue };
                if stamp == now {
                    // kept in this very session: it waits for the next one
                    still.push_str(line);
                    still.push('\n');
                    continue;
                }
                // send_inbox_once: a failure here must not keep it a second time
                match send_inbox_once(&addons, inbox) {
                    Ok(()) => println!("undelivered line sent in the new session"),
                    Err(err) => {
                        eprintln!("  an undelivered line failed again ({err}); kept");
                        still.push_str(&format!("{now}\t{inbox}\n"));
                    }
                }
            }
            let _ = if still.is_empty() { fs::remove_file(&path) } else { fs::write(&path, still) };
        }
    });
}
