//! Getting a Whisper model onto a new PC: which one suits it, and a download
//! that is checked before it is used.
//!
//! The files are whisper.cpp's own, from Hugging Face, pinned to one commit and
//! checked against the SHA-256 Hugging Face lists for them, so a moved or
//! changed file fails loudly instead of loading as something else. A download
//! is written to `<name>.part` and renamed only once it checks out, so a
//! cancelled or broken one never looks like a model; the next try resumes it.

use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
};

use sha2::{Digest, Sha256};

/// ggerganov/whisper.cpp on Hugging Face, the commit the hashes below are from.
const COMMIT: &str = "5359861c739e955e79d9a303bcbc70fb988958b1";

pub struct Model {
    pub file: &'static str,
    pub name: &'static str,
    pub about: &'static str,
    pub bytes: u64,
    sha256: &'static str,
}

pub const MODELS: &[Model] = &[
    Model {
        file: "ggml-large-v3-turbo.bin",
        name: "Large (turbo)",
        about: "the most accurate; for a graphics card with 4 GB or more",
        bytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    },
    Model {
        file: "ggml-large-v3-turbo-q5_0.bin",
        name: "Large (turbo, compressed)",
        about: "nearly as accurate, a third of the size; for a smaller graphics card",
        bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    },
    Model {
        file: "ggml-small.bin",
        name: "Small",
        about: "for the CPU: quick enough without a graphics card, less accurate",
        bytes: 487_601_967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    },
];

pub fn by_file(file: &str) -> Option<&'static Model> {
    MODELS.iter().find(|model| model.file == file)
}

/// The model to offer: the small one on the CPU, the compressed large one on a
/// card with under 4 GB, otherwise the full large one.
pub fn recommended(cpu: bool, video_memory: Option<u64>) -> &'static Model {
    if cpu {
        &MODELS[2]
    } else if video_memory.is_some_and(|bytes| bytes < 4 * 1024 * 1024 * 1024 - 64 * 1024 * 1024) {
        &MODELS[1]
    } else {
        &MODELS[0]
    }
}

/// The largest graphics card memory Windows reports, or None if it can't say.
/// Windows caps this figure at 4 GB, which is fine: it only has to tell a small
/// card from a big one.
pub fn video_memory() -> Option<u64> {
    use std::os::windows::process::CommandExt;
    let out = Command::new("powershell")
        .args(["-NoProfile", "-Command", "(Get-CimInstance Win32_VideoController).AdapterRAM"])
        .creation_flags(crate::NO_WINDOW)
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout).lines().filter_map(|line| line.trim().parse::<u64>().ok()).max()
}

/// Where downloads go: `models` beside this program, or under %LOCALAPPDATA% if
/// that folder can't be written (an install under Program Files).
pub fn folder() -> Option<PathBuf> {
    let beside = std::env::current_exe().ok()?.parent()?.join("models");
    if fs::create_dir_all(&beside).is_ok() && writable(&beside) {
        return Some(beside);
    }
    let local = PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join("wow-companion").join("models");
    fs::create_dir_all(&local).ok()?;
    Some(local)
}

fn writable(dir: &Path) -> bool {
    let probe = dir.join(".write-test");
    let ok = fs::write(&probe, b"").is_ok();
    let _ = fs::remove_file(probe);
    ok
}

#[derive(Clone, Default)]
pub enum Download {
    #[default]
    Idle,
    Running { file: &'static str, done: u64, total: u64 },
    Checking { file: &'static str },
    Done(PathBuf),
    Failed(String),
}

/// Download `model` on a thread, reporting into `state`; `cancel` stops it
/// (keeping the part for a resume).
pub fn start(model: &'static Model, state: Arc<Mutex<Download>>, cancel: Arc<AtomicBool>) {
    cancel.store(false, Ordering::Relaxed);
    *state.lock().unwrap() = Download::Running { file: model.file, done: 0, total: model.bytes };
    thread::spawn(move || {
        let result = fetch(model, &state, &cancel);
        *state.lock().unwrap() = match result {
            Ok(path) => Download::Done(path),
            Err(why) => Download::Failed(why),
        };
    });
}

fn fetch(model: &'static Model, state: &Mutex<Download>, cancel: &AtomicBool) -> Result<PathBuf, String> {
    let dir = folder().ok_or("No folder to save the model in.")?;
    let path = dir.join(model.file);
    let part = dir.join(format!("{}.part", model.file));
    let url = format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/{COMMIT}/{}", model.file);

    // resume what an earlier try left, hashing it again from the start
    let mut have = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if have > model.bytes {
        have = 0;
    }
    let mut request = ureq::get(&url);
    if have > 0 {
        request = request.header("Range", &format!("bytes={have}-"));
    }
    let response = request.call().map_err(|e| format!("Could not reach Hugging Face: {e}"))?;
    if response.status() != 206 {
        // the server sent the whole file: start over
        have = 0;
    }
    let mut hasher = Sha256::new();
    let mut out = if have > 0 {
        let mut existing = fs::File::open(&part).map_err(|e| e.to_string())?;
        let mut buffer = vec![0u8; 1 << 20];
        loop {
            let n = existing.read(&mut buffer).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            hasher.update(&buffer[..n]);
        }
        fs::OpenOptions::new().append(true).open(&part).map_err(|e| e.to_string())?
    } else {
        fs::File::create(&part).map_err(|e| format!("Could not write {}: {e}", part.display()))?
    };

    let mut reader = response.into_body().into_reader();
    let mut buffer = vec![0u8; 1 << 16];
    let mut done = have;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err("Cancelled. Download again to pick up where it stopped.".into());
        }
        let n = reader.read(&mut buffer).map_err(|e| format!("The download broke off: {e}. Try again to resume."))?;
        if n == 0 {
            break;
        }
        out.write_all(&buffer[..n]).map_err(|e| format!("Could not write the model: {e}"))?;
        hasher.update(&buffer[..n]);
        done += n as u64;
        *state.lock().unwrap() = Download::Running { file: model.file, done, total: model.bytes };
    }
    drop(out);

    *state.lock().unwrap() = Download::Checking { file: model.file };
    let digest = hex(&hasher.finalize());
    if done != model.bytes || digest != model.sha256 {
        let _ = fs::remove_file(&part);
        return Err(format!(
            "The downloaded file is not the expected model ({done} bytes, SHA-256 {digest}), so it was deleted. Try again."
        ));
    }
    fs::rename(&part, &path).map_err(|e| format!("Could not put the model in place: {e}"))?;
    Ok(path)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cpu_gets_small_and_a_small_card_the_compressed_large() {
        assert_eq!(recommended(true, None).file, "ggml-small.bin");
        assert_eq!(recommended(false, Some(2 * 1024 * 1024 * 1024)).file, "ggml-large-v3-turbo-q5_0.bin");
        // Windows reports a big card as 4 GB (0xFFF00000)
        assert_eq!(recommended(false, Some(0xFFF0_0000)).file, "ggml-large-v3-turbo.bin");
        assert_eq!(recommended(false, None).file, "ggml-large-v3-turbo.bin");
    }

    /// The real thing: start the small model, cancel it partway, resume, check.
    /// `cargo test -- --ignored download` (fetches 488 MB).
    #[test]
    #[ignore]
    fn download_cancels_resumes_and_checks() {
        let model = by_file("ggml-small.bin").unwrap();
        let state = Arc::new(Mutex::new(Download::Idle));
        let cancel = Arc::new(AtomicBool::new(false));
        let watcher = {
            let (state, cancel) = (Arc::clone(&state), Arc::clone(&cancel));
            thread::spawn(move || loop {
                if let Download::Running { done, .. } = *state.lock().unwrap() {
                    if done > 50_000_000 {
                        cancel.store(true, Ordering::Relaxed);
                        return;
                    }
                }
                thread::sleep(std::time::Duration::from_millis(20));
            })
        };
        let first = fetch(model, &state, &cancel);
        watcher.join().unwrap();
        assert!(first.unwrap_err().starts_with("Cancelled"));
        let part = folder().unwrap().join("ggml-small.bin.part");
        let kept = fs::metadata(&part).unwrap().len();
        assert!(kept > 50_000_000, "kept {kept}");
        cancel.store(false, Ordering::Relaxed);
        let path = fetch(model, &state, &cancel).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().len(), model.bytes);
        assert!(!part.exists());
        println!("resumed from {kept} bytes, saved {}", path.display());
    }

    #[test]
    fn hex_is_lowercase_and_padded() {
        assert_eq!(hex(&[0x0a, 0xff]), "0aff");
    }
}
