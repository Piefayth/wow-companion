//! What the companion needs from the operating system, in one place: named
//! locks that die with their process (one companion, one watcher), counting a
//! program's processes (is the game up, are two clients running), hiding a
//! child's window, opening a file, and starting with the user's session.
//!
//! Windows is implemented; anything else answers "not supported yet" (or none,
//! for questions) rather than scattering platform checks through the callers,
//! so a macOS version can fill this file in (the player wants the platforms WoW
//! runs on, Windows and macOS).

use std::{io, path::Path, process::Command};

/// A held lock: while this value lives, `lock_exists(name)` is true for every
/// process. The OS releases it when the process ends, crash included.
pub struct Lock {
    #[allow(dead_code)]
    handle: isize,
}

/// A running process, held open: whether it still runs and when it started are
/// asked of its handle, in microseconds, where finding it walks every process
/// on the machine (about 50 ms, measured 2026-11-11, twice per send until then).
pub struct Process {
    handle: isize,
    started: u64,
}

impl Process {
    /// The oldest running process with this image name (e.g. "Wow.exe").
    pub fn find(image: &str) -> Option<Process> {
        imp::find(image)
    }

    /// Whether it still runs.
    pub fn running(&self) -> bool {
        imp::running(self.handle)
    }

    /// When it started: an opaque, exact timestamp, equal for the same process
    /// and different for a new one.
    pub fn started(&self) -> u64 {
        self.started
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        imp::close(self.handle);
    }
}

#[cfg(windows)]
mod imp {
    use super::{Lock, Process};
    use std::{ffi::c_void, io, os::windows::process::CommandExt, path::Path, process::Command};

    const SYNCHRONIZE: u32 = 0x0010_0000;
    const WAIT_OBJECT_0: u32 = 0;
    const WAIT_TIMEOUT: u32 = 0x102;
    const WAIT_ABANDONED: u32 = 0x80;
    const INFINITE: u32 = u32::MAX;
    const TH32CS_SNAPPROCESS: u32 = 2;
    const NO_WINDOW: u32 = 0x0800_0000;
    const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
    const RUN_VALUE: &str = "WowCompanion";

    #[repr(C)]
    struct ProcessEntry {
        size: u32,
        usage: u32,
        pid: u32,
        heap: usize,
        module: u32,
        threads: u32,
        parent: u32,
        priority: i32,
        flags: u32,
        exe: [u16; 260],
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateMutexW(attributes: *const c_void, initial_owner: i32, name: *const u16) -> isize;
        fn OpenMutexW(access: u32, inherit: i32, name: *const u16) -> isize;
        fn WaitForSingleObject(handle: isize, millis: u32) -> u32;
        fn CloseHandle(handle: isize) -> i32;
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> isize;
        fn Process32FirstW(snapshot: isize, entry: *mut ProcessEntry) -> i32;
        fn Process32NextW(snapshot: isize, entry: *mut ProcessEntry) -> i32;
        fn OpenProcess(access: u32, inherit: i32, pid: u32) -> isize;
        fn GetProcessTimes(process: isize, creation: *mut u64, exit: *mut u64, kernel: *mut u64, user: *mut u64) -> i32;
    }

    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

    /// The ids of the running processes with this image name.
    fn pids(image: &str) -> Vec<u32> {
        let mut found = Vec::new();
        // SAFETY: a process snapshot walked with a sized entry, then closed
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot == -1 || snapshot == 0 {
                return found;
            }
            let mut entry: ProcessEntry = std::mem::zeroed();
            entry.size = std::mem::size_of::<ProcessEntry>() as u32;
            let mut more = Process32FirstW(snapshot, &mut entry) != 0;
            while more {
                let len = entry.exe.iter().position(|&c| c == 0).unwrap_or(entry.exe.len());
                if String::from_utf16_lossy(&entry.exe[..len]).eq_ignore_ascii_case(image) {
                    found.push(entry.pid);
                }
                more = Process32NextW(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
        }
        found
    }

    /// The started time is the creation FILETIME (100 ns since 1601).
    pub fn find(image: &str) -> Option<Process> {
        pids(image)
            .into_iter()
            .filter_map(|pid| {
                // SAFETY: the handle is owned by the Process made from it, or
                // closed here when its times cannot be read; the times are four u64s
                unsafe {
                    let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, 0, pid);
                    if handle == 0 {
                        return None;
                    }
                    let (mut creation, mut exit, mut kernel, mut user) = (0u64, 0u64, 0u64, 0u64);
                    if GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) == 0 {
                        CloseHandle(handle);
                        return None;
                    }
                    Some(Process { handle, started: creation })
                }
            })
            // the others are dropped, which closes them
            .min_by_key(Process::started)
    }

    pub fn running(handle: isize) -> bool {
        // SAFETY: a process handle opened with SYNCHRONIZE, still open
        unsafe { WaitForSingleObject(handle, 0) == WAIT_TIMEOUT }
    }

    pub fn close(handle: isize) {
        // SAFETY: the handle is closed once, by its Process's drop
        unsafe {
            CloseHandle(handle);
        }
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    fn local(name: &str) -> Vec<u16> {
        wide(&format!("Local\\{name}"))
    }

    pub fn lock_exists(name: &str) -> bool {
        let name = local(name);
        // SAFETY: a NUL-terminated name; the handle is closed at once
        unsafe {
            let handle = OpenMutexW(SYNCHRONIZE, 0, name.as_ptr());
            if handle == 0 {
                return false;
            }
            CloseHandle(handle);
            true
        }
    }

    pub fn take_lock(name: &str, wait: bool) -> Option<Lock> {
        let name = local(name);
        // SAFETY: a NUL-terminated name. The mutex belongs to the thread whose
        // wait succeeds; the handle stays open for the life of the Lock (and the
        // process), so the lock is held until the process ends.
        unsafe {
            let handle = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
            if handle == 0 {
                return None;
            }
            match WaitForSingleObject(handle, if wait { INFINITE } else { 0 }) {
                // abandoned: the holder ended without letting go (a crash); ours now
                WAIT_OBJECT_0 | WAIT_ABANDONED => Some(Lock { handle }),
                _ => {
                    CloseHandle(handle);
                    None
                }
            }
        }
    }

    pub fn process_count(image: &str) -> usize {
        pids(image).len()
    }

    #[link(name = "user32")]
    unsafe extern "system" {
        fn EnumWindows(callback: extern "system" fn(isize, isize) -> i32, param: isize) -> i32;
        fn GetWindowThreadProcessId(window: isize, pid: *mut u32) -> u32;
        fn IsWindowVisible(window: isize) -> i32;
        fn GetWindow(window: isize, command: u32) -> isize;
    }

    const GW_OWNER: u32 = 4;

    extern "system" fn note_window(window: isize, param: isize) -> i32 {
        // SAFETY: param is the &mut Vec<u32> windowed_count passed, alive for
        // the EnumWindows call that calls this
        unsafe {
            let owners = &mut *(param as *mut Vec<u32>);
            if IsWindowVisible(window) != 0 && GetWindow(window, GW_OWNER) == 0 {
                let mut pid = 0;
                GetWindowThreadProcessId(window, &mut pid);
                owners.push(pid);
            }
        }
        1
    }

    pub fn windowed_count(image: &str) -> usize {
        let mut owners: Vec<u32> = Vec::new();
        // SAFETY: the callback only pushes into `owners`, which outlives the call
        unsafe {
            EnumWindows(note_window, &mut owners as *mut Vec<u32> as isize);
        }
        pids(image).into_iter().filter(|pid| owners.contains(pid)).count()
    }

    pub fn hide_window(command: &mut Command) -> &mut Command {
        command.creation_flags(NO_WINDOW)
    }

    pub fn open(path: &Path) -> io::Result<()> {
        Command::new("explorer.exe").arg(path).creation_flags(NO_WINDOW).spawn().map(|_| ())
    }

    pub fn autostart() -> Option<String> {
        let out = Command::new("reg").args(["query", RUN_KEY, "/v", RUN_VALUE]).creation_flags(NO_WINDOW).output().ok()?;
        if !out.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        let line = text.lines().find(|line| line.trim_start().starts_with(RUN_VALUE))?;
        let at = line.find("REG_SZ")? + "REG_SZ".len();
        Some(line[at..].trim().to_string())
    }

    pub fn set_autostart(command: Option<&str>) -> io::Result<()> {
        let status = match command {
            Some(command) => Command::new("reg")
                .args(["add", RUN_KEY, "/v", RUN_VALUE, "/t", "REG_SZ", "/d", command, "/f"])
                .creation_flags(NO_WINDOW)
                .status()?,
            None if autostart().is_none() => return Ok(()),
            None => Command::new("reg").args(["delete", RUN_KEY, "/v", RUN_VALUE, "/f"]).creation_flags(NO_WINDOW).status()?,
        };
        if status.success() { Ok(()) } else { Err(io::Error::other("the registry refused the change")) }
    }

    pub fn autostart_place() -> String {
        format!(r"{RUN_KEY}\{RUN_VALUE}")
    }
}

#[cfg(not(windows))]
mod imp {
    use super::{Lock, Process};
    use std::{io, path::Path, process::Command};

    fn unsupported() -> io::Error {
        io::Error::new(io::ErrorKind::Unsupported, "not supported on this platform yet (Windows only for now)")
    }
    pub fn lock_exists(_name: &str) -> bool {
        false
    }
    pub fn take_lock(_name: &str, _wait: bool) -> Option<Lock> {
        Some(Lock { handle: 0 })
    }
    pub fn process_count(_image: &str) -> usize {
        0
    }
    pub fn windowed_count(_image: &str) -> usize {
        0
    }
    pub fn find(_image: &str) -> Option<Process> {
        None
    }
    pub fn running(_handle: isize) -> bool {
        false
    }
    pub fn close(_handle: isize) {}
    pub fn hide_window(command: &mut Command) -> &mut Command {
        command
    }
    pub fn open(_path: &Path) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn autostart() -> Option<String> {
        None
    }
    pub fn set_autostart(_command: Option<&str>) -> io::Result<()> {
        Err(unsupported())
    }
    pub fn autostart_place() -> String {
        String::new()
    }
}

/// Whether some process holds (or waits for) the lock `name`.
pub fn lock_exists(name: &str) -> bool {
    imp::lock_exists(name)
}

/// Take the lock `name`: at once or not at all, or (`wait`) whenever its holder
/// lets go. Hold the returned value for as long as the lock should be held, on
/// a thread that lives as long (the lock belongs to the thread that took it).
pub fn take_lock(name: &str, wait: bool) -> Option<Lock> {
    imp::take_lock(name, wait)
}

/// How many processes run the program `image` (e.g. "Wow.exe").
pub fn process_count(image: &str) -> usize {
    imp::process_count(image)
}

/// How many processes of `image` have a window open: a game that is closing
/// has dropped its window but still runs while it saves, and is not a client
/// any more (counted as two beside the new one at a restart, 2026-11-11).
pub fn windowed_count(image: &str) -> usize {
    imp::windowed_count(image)
}

/// Start `command` with no window of its own.
pub fn hide_window(command: &mut Command) -> &mut Command {
    imp::hide_window(command)
}

/// Open a file with the program the user has for it.
pub fn open(path: &Path) -> io::Result<()> {
    imp::open(path)
}

/// The command started with the user's session, if one is set.
pub fn autostart() -> Option<String> {
    imp::autostart()
}

/// Start `command` with the user's session, or (None) stop doing so.
pub fn set_autostart(command: Option<&str>) -> io::Result<()> {
    imp::set_autostart(command)
}

/// Where the autostart entry lives, for "what this put on your PC".
pub fn autostart_place() -> String {
    imp::autostart_place()
}

/// The lock the running companion holds.
pub const COMPANION_LOCK: &str = "WowCompanionRun";
/// The lock the watcher (`wow-companion start`) holds.
pub const WATCHER_LOCK: &str = "WowCompanionWatch";

/// What the watcher says it is doing (`%LOCALAPPDATA%\wow-companion\status.txt`):
/// waiting, starting, listening, paused, gave-up. None when no watcher runs.
pub fn watcher_status() -> Option<String> {
    if !lock_exists(WATCHER_LOCK) {
        return None;
    }
    let path = crate::changes::data_dir()?.join("status.txt");
    Some(std::fs::read_to_string(path).unwrap_or_default().trim().to_string())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn a_lock_is_seen_by_everyone_and_taken_once() {
        let name = format!("WowCompanionTest{}", std::process::id());
        assert!(!lock_exists(&name));
        let held = take_lock(&name, false).expect("free");
        assert!(lock_exists(&name));
        // another thread (as another process would) cannot take it
        let again = std::thread::spawn({
            let name = name.clone();
            move || take_lock(&name, false).is_some()
        });
        assert!(!again.join().unwrap());
        drop(held);
    }

    #[test]
    fn processes_are_counted_by_name() {
        let me = std::env::current_exe().unwrap();
        let image = me.file_name().unwrap().to_string_lossy().to_string();
        assert!(process_count(&image) >= 1);
        assert_eq!(process_count("surely-not-running-12345.exe"), 0);
        assert_eq!(windowed_count(&image), 0, "a test runs with no window: running, not open");
    }
}

#[cfg(test)]
mod live {
    /// Run with the game open (`--ignored`): it is found, held, and its start
    /// time is the same when found again, so the session stamp only changes
    /// with a new game.
    #[test]
    #[ignore]
    fn the_running_game_is_found_held_and_stable() {
        let game = super::Process::find("Wow.exe").expect("the game is running");
        assert!(game.running());
        assert_eq!(super::Process::find("Wow.exe").map(|again| again.started()), Some(game.started()));
        assert!(super::Process::find("NoSuchProcess.exe").is_none());
    }

    #[test]
    fn a_process_that_exited_is_seen_to_have_exited() {
        let mut child = std::process::Command::new("ping")
            .args(["-n", "2", "127.0.0.1"])
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let held = super::Process::find("PING.EXE").expect("ping is running");
        assert!(held.running());
        child.wait().unwrap();
        assert!(!held.running());
    }
}
