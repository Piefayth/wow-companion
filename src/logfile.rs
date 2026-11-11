//! Everything the companion prints also goes to
//! `%LOCALAPPDATA%\wow-companion\companion.log`, so a player who started it
//! hidden (the watcher, `start`) still has a record when something goes wrong.
//! The console output is unchanged. The log rotates: past a few MB it becomes
//! `companion.1.log` and a fresh one starts, so two files at most.
//!
//! How: the process's stdout and stderr handles are swapped for pipes, and a
//! thread per pipe copies what arrives to the original handle and to the file.
//! Rust's println! looks the handle up on every write, so it follows the swap.
//! C code that captured the console at startup (Whisper's own prints) still
//! reaches the console only.

use super::*;
use std::io::Write;

const ROTATE_AT: u64 = 4 * 1024 * 1024;

struct LogFile {
    path: PathBuf,
    file: Option<fs::File>,
    len: u64,
}

impl LogFile {
    fn open(path: PathBuf) -> LogFile {
        let file = fs::OpenOptions::new().create(true).append(true).open(&path).ok();
        let len = file.as_ref().and_then(|f| f.metadata().ok()).map(|m| m.len()).unwrap_or(0);
        LogFile { path, file, len }
    }

    fn write(&mut self, bytes: &[u8]) {
        if self.len + bytes.len() as u64 > ROTATE_AT {
            self.file = None;
            let older = self.path.with_file_name("companion.1.log");
            let _ = fs::remove_file(&older);
            let _ = fs::rename(&self.path, &older);
            *self = LogFile::open(self.path.clone());
        }
        if let Some(file) = &mut self.file {
            if file.write_all(bytes).is_ok() {
                self.len += bytes.len() as u64;
            }
        }
    }
}

pub(crate) fn path() -> Option<PathBuf> {
    companion_dir().ok().map(|dir| dir.join("companion.log"))
}

/// Start copying stdout and stderr into the log. Once per process.
pub(crate) fn tee() {
    let Some(path) = path() else { return };
    let log = Arc::new(Mutex::new(LogFile::open(path)));
    {
        let mut log = log.lock().unwrap();
        let line = format!("\n---- companion {} started (pid {}) ----\n", crash::stamp(), std::process::id());
        log.write(line.as_bytes());
    }
    imp::swap(log);
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::ffi::c_void;

    const STD_OUTPUT_HANDLE: u32 = -11i32 as u32;
    const STD_ERROR_HANDLE: u32 = -12i32 as u32;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreatePipe(read: *mut isize, write: *mut isize, attributes: *const c_void, size: u32) -> i32;
        fn GetStdHandle(id: u32) -> isize;
        fn SetStdHandle(id: u32, handle: isize) -> i32;
        fn ReadFile(handle: isize, buffer: *mut u8, len: u32, read: *mut u32, overlapped: *mut c_void) -> i32;
        fn WriteFile(handle: isize, buffer: *const u8, len: u32, written: *mut u32, overlapped: *mut c_void) -> i32;
        fn GetConsoleMode(handle: isize, mode: *mut u32) -> i32;
        fn WriteConsoleW(handle: isize, buffer: *const u16, len: u32, written: *mut u32, reserved: *const c_void) -> i32;
    }

    pub(super) fn swap(log: Arc<Mutex<LogFile>>) {
        for id in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
            let (mut read, mut write) = (0isize, 0isize);
            // SAFETY: plain handle calls; the pipe's ends live for the process
            unsafe {
                let original = GetStdHandle(id);
                if CreatePipe(&mut read, &mut write, std::ptr::null(), 1 << 20) == 0 {
                    continue;
                }
                if SetStdHandle(id, write) == 0 {
                    continue;
                }
                let log = Arc::clone(&log);
                thread::spawn(move || copy(read, original, &log));
            }
        }
    }

    /// Copy what arrives on `read` to the console (or file) the process had,
    /// and to the log. Whole UTF-8 sequences only reach a console, which takes
    /// UTF-16.
    fn copy(read: isize, original: isize, log: &Mutex<LogFile>) {
        let mut buffer = vec![0u8; 64 * 1024];
        let mut pending: Vec<u8> = Vec::new();
        let mut mode = 0u32;
        // SAFETY: the original handle is only asked whether it is a console
        let console = original != 0 && original != -1 && unsafe { GetConsoleMode(original, &mut mode) } != 0;
        loop {
            let mut got = 0u32;
            // SAFETY: reads into a buffer of the length given
            let ok = unsafe { ReadFile(read, buffer.as_mut_ptr(), buffer.len() as u32, &mut got, std::ptr::null_mut()) };
            if ok == 0 || got == 0 {
                return;
            }
            let bytes = &buffer[..got as usize];
            log.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).write(bytes);
            if original == 0 || original == -1 {
                continue;
            }
            if console {
                pending.extend_from_slice(bytes);
                // all of it, unless it ends partway through a character (the
                // rest of which is in the next read); bytes that are simply not
                // UTF-8 are written as replacement characters
                let whole = match std::str::from_utf8(&pending) {
                    Err(err) if err.error_len().is_none() => err.valid_up_to(),
                    _ => pending.len(),
                };
                let text: Vec<u16> = String::from_utf8_lossy(&pending[..whole]).encode_utf16().collect();
                let mut written = 0u32;
                // SAFETY: writes the UTF-16 buffer of the length given
                unsafe { WriteConsoleW(original, text.as_ptr(), text.len() as u32, &mut written, std::ptr::null()) };
                pending.drain(..whole);
            } else {
                let mut written = 0u32;
                // SAFETY: writes the bytes just read to the handle the process had
                unsafe { WriteFile(original, bytes.as_ptr(), bytes.len() as u32, &mut written, std::ptr::null_mut()) };
            }
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::*;
    pub(super) fn swap(_log: Arc<Mutex<LogFile>>) {
        // not supported yet: the console output is all there is
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_log_rotates_into_one_older_file() {
        let dir = std::env::temp_dir().join(format!("wc-log-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("companion.log");
        let mut log = LogFile::open(path.clone());
        let chunk = vec![b'x'; 1024 * 1024];
        for _ in 0..9 {
            log.write(&chunk);
        }
        let now = fs::metadata(&path).unwrap().len();
        let older = fs::metadata(dir.join("companion.1.log")).unwrap().len();
        assert!(now <= ROTATE_AT && older <= ROTATE_AT, "{now} {older}");
        assert!(now > 0 && older > 0);
        let _ = fs::remove_dir_all(&dir);
    }
}
