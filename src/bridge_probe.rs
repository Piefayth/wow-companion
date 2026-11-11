//! The bridge probe, PC side (docs/proposals/bridge-probe.md): measurements of
//! two possible new channels and of the strip, beside today's channel and
//! changing nothing in it. The game side is BridgeProbe.lua.
//!
//! 1. `C_Log` lines in `Logs\General.log`: each `WCPROBE` line's own timestamp
//!    against the PC's clock when it was read (the file is polled every
//!    `POLL`, so a delay is exact to within that).
//! 2. Fonts written after launch: from the session's first `WCPROBE` line (the
//!    exact sign the addon is in the world and polling), `Probe\f<n>.ttf` every
//!    `FONT_EVERY`, at most `FONTS`, each a copy of RobotoCondensed with 64
//!    letters' advance widths set to a pattern, the pattern in `f<n>.txt`.
//! 3. `strip::capture` times itself into `capture.tsv`.
//!
//! `wow-companion bridge-probe report` reads it all back with the game's
//! `WowCompanionDB.bridgeProbe`; `clean` deletes the probe's files.

use super::*;
use crate::savedvars::Lua;
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    sync::{atomic::AtomicBool, OnceLock},
};

const POLL: Duration = Duration::from_millis(10);
const FONT_EVERY: Duration = Duration::from_secs(15);
const FONTS: u32 = 5;
const FONT_SOURCE: &str = "RobotoCondensed.ttf";
/// The 64 letters whose widths a probe font carries.
pub(crate) const LETTERS: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn data_dir() -> io::Result<PathBuf> {
    let dir = companion_dir()?.join("bridge-probe");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn probe_dir(addons: &Path) -> PathBuf {
    addons.join(ADDON).join("Probe")
}

fn epoch_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_millis()).unwrap_or_default()
}

/// Append one line to a file of the probe's (made with `header` the first time).
fn append(name: &str, header: &str, line: &str) {
    let Ok(dir) = data_dir() else { return };
    let path = dir.join(name);
    let fresh = !path.exists();
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        if fresh {
            let _ = writeln!(file, "{header}");
        }
        let _ = writeln!(file, "{line}");
    }
}

// ---------------------------------------------------------------- the session

/// Watch for the game; for each run of Wow.exe, tail its log and write the
/// probe fonts until it exits.
pub(crate) fn start(addons: &Path) {
    let addons = addons.to_path_buf();
    thread::spawn(move || loop {
        while game_clients() == 0 {
            thread::sleep(Duration::from_secs(2));
        }
        let session = game_started().unwrap_or_else(|| epoch_ms().to_string());
        let begun = epoch_ms();
        append("sessions.tsv", "session\tstarted_ms", &format!("{session}\t{begun}"));
        // fonts left from an earlier session would load at once and measure nothing
        remove_fonts(&addons);
        let stop = Arc::new(AtomicBool::new(false));
        let in_world = Arc::new(AtomicBool::new(false));
        let log = addons.parent().and_then(Path::parent).map(|client| client.join("Logs").join("General.log"));
        let tailer = log.map(|log| {
            let (session, stop, in_world) = (session.clone(), Arc::clone(&stop), Arc::clone(&in_world));
            thread::spawn(move || tail(&log, &session, &stop, &in_world))
        });
        let fonts = {
            let (addons, session, stop, in_world) = (addons.clone(), session.clone(), Arc::clone(&stop), Arc::clone(&in_world));
            thread::spawn(move || write_fonts(&addons, &session, &stop, &in_world))
        };
        while game_clients() > 0 {
            thread::sleep(Duration::from_secs(2));
        }
        stop.store(true, Ordering::SeqCst);
        if let Some(tailer) = tailer {
            let _ = tailer.join();
        }
        let _ = fonts.join();
        println!("bridge probe: session {session} ended");
    });
}

// ---------------------------------------------------------- 1. C_Log tailing

/// Follow `log` from its end; a shorter file at the path than our offset, or
/// the path now holding another file than ours, starts again from 0 (the game
/// rewrites General.log at each launch).
fn tail(log: &Path, session: &str, stop: &AtomicBool, in_world: &AtomicBool) {
    let mut file: Option<File> = None;
    let mut offset = 0u64;
    let mut partial = Vec::new();
    let mut batch = 0u64;
    while !stop.load(Ordering::SeqCst) {
        thread::sleep(POLL);
        let Ok(at_path) = fs::metadata(log) else {
            file = None;
            continue;
        };
        if file.is_none() {
            match open_shared(log) {
                Ok(opened) => {
                    // the first open follows from the end; a reopen reads the new file whole
                    offset = if batch == 0 && offset == 0 { at_path.len() } else { 0 };
                    file = Some(opened);
                    partial.clear();
                }
                Err(_) => continue,
            }
        }
        let Some(handle) = file.as_mut() else { continue };
        let ours = handle.metadata().map(|meta| meta.len()).unwrap_or(0);
        if at_path.len() < offset || (at_path.len() != ours && at_path.len() < ours) {
            file = None;
            offset = 0;
            batch += 1;
            continue;
        }
        if ours <= offset {
            continue;
        }
        let mut read = Vec::with_capacity((ours - offset) as usize);
        if handle.seek(SeekFrom::Start(offset)).is_err() || handle.take(ours - offset).read_to_end(&mut read).is_err() {
            continue;
        }
        let read_at = local_now_ms();
        offset += read.len() as u64;
        partial.extend_from_slice(&read);
        let Some(last_newline) = partial.iter().rposition(|byte| *byte == b'\n') else { continue };
        let complete: Vec<u8> = partial.drain(..=last_newline).collect();
        batch += 1;
        let text = String::from_utf8_lossy(&complete);
        let probes: Vec<&str> = text.lines().filter(|line| line.contains("WCPROBE")).collect();
        for line in &probes {
            let found = probe_line(line, read_at);
            append(
                "log.tsv",
                "session\tread_local_ms\tdelay_ms\tlevel\tkind\tseq\tdeclared_len\tarrived_len\twhole\tbatch\tprobe_lines_in_batch",
                &format!(
                    "{session}\t{read_at}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{batch}\t{}",
                    found.delay_ms.map(|ms| ms.to_string()).unwrap_or_else(|| "?".into()),
                    found.level,
                    found.kind,
                    found.seq,
                    found.declared.map(|len| len.to_string()).unwrap_or_else(|| "?".into()),
                    found.arrived,
                    found.whole(),
                    probes.len()
                ),
            );
            println!(
                "bridge probe: WCPROBE {} {} ({} bytes{}) read {} ms after the game logged it, batch {batch} of {}",
                found.kind,
                found.seq,
                found.arrived,
                if found.whole() { ", whole" } else { ", NOT whole" },
                found.delay_ms.map(|ms| ms.to_string()).unwrap_or_else(|| "?".into()),
                probes.len()
            );
            in_world.store(true, Ordering::SeqCst);
        }
    }
}

#[cfg(windows)]
fn open_shared(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    // read, write and delete shared: the game keeps writing, and may replace it
    fs::OpenOptions::new().read(true).share_mode(0x1 | 0x2 | 0x4).open(path)
}

#[cfg(not(windows))]
fn open_shared(path: &Path) -> io::Result<File> {
    File::open(path)
}

/// One `WCPROBE` line as read: `MM/DD HH:MM:SS.mmm  [N][Lua] WCPROBE <kind> <seq> <len> <text>`.
#[derive(Debug, PartialEq)]
struct ProbeLine {
    delay_ms: Option<i128>,
    level: String,
    kind: String,
    seq: String,
    declared: Option<usize>,
    arrived: usize,
    /// every byte is the one BridgeProbe.lua wrote (`text_pattern`)
    exact: bool,
}

impl ProbeLine {
    fn whole(&self) -> bool {
        self.declared == Some(self.arrived) && self.exact
    }
}

/// The text BridgeProbe.lua logs for a length: byte i is letter
/// ((i - 1) % 62 + 1) of A-Z a-z 0-9.
fn text_pattern(len: usize) -> String {
    const ALNUM: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    (0..len).map(|i| ALNUM[i % ALNUM.len()] as char).collect()
}

fn probe_line(line: &str, read_at: i128) -> ProbeLine {
    let delay_ms = logged_at(line, read_at).map(|logged| read_at - logged);
    let level = line.find("][").and_then(|at| line[..at].rfind('[')).map(|at| line[at + 1..at + 2].to_string()).unwrap_or_else(|| "?".into());
    let rest = &line[line.find("WCPROBE").unwrap_or(0) + "WCPROBE".len()..];
    let mut fields = rest.trim_start().splitn(4, ' ');
    let kind = fields.next().unwrap_or("").to_string();
    let seq = fields.next().unwrap_or("").to_string();
    let declared = fields.next().and_then(|len| len.parse().ok());
    let text = fields.next().map(|text| text.trim_end_matches('\r')).unwrap_or("");
    let exact = declared.is_some_and(|len| text == text_pattern(len));
    ProbeLine { delay_ms, level, kind, seq, declared, arrived: text.len(), exact }
}

/// The game's timestamp at the start of a log line, as local milliseconds on
/// the same scale as `local_now_ms` (the year is the one `read_at` is in, or
/// the one before for a December line read in January).
fn logged_at(line: &str, read_at: i128) -> Option<i128> {
    let (date, rest) = line.split_once(' ')?;
    let time = rest.split_whitespace().next()?;
    let (month, day) = date.split_once('/')?;
    let (month, day): (i64, i64) = (month.parse().ok()?, day.parse().ok()?);
    let mut parts = time.split([':', '.']);
    let (hour, minute, second, milli): (i64, i64, i64, i64) =
        (parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.parse().ok()?);
    let (year_now, month_now) = civil_from_days(read_at.div_euclid(86_400_000) as i64);
    let year = if month > month_now { year_now - 1 } else { year_now };
    Some(days_from_civil(year, month, day) as i128 * 86_400_000 + ((hour * 3600 + minute * 60 + second) * 1000 + milli) as i128)
}

/// Days from 1970-01-01 to a date (Howard Hinnant's days_from_civil).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let of_era = year - era * 400;
    let of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let of_cycle = of_era * 365 + of_era / 4 - of_era / 100 + of_year;
    era * 146_097 + of_cycle - 719_468
}

/// (year, month) of a day count from 1970-01-01.
fn civil_from_days(days: i64) -> (i64, i64) {
    let (year, month, _) = civil_ymd(days);
    (year, month)
}

/// (year, month, day) of a day count from 1970-01-01 (civil_from_days).
fn civil_ymd(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let of_era = z - era * 146_097;
    let year_of_era = (of_era - of_era / 1460 + of_era / 36_524 - of_era / 146_096) / 365;
    let of_year = of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let mp = (5 * of_year + 2) / 153;
    let day = of_year - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (year_of_era + era * 400 + if month <= 2 { 1 } else { 0 }, month, day)
}

/// The PC's local wall clock in milliseconds, on the scale `logged_at` uses.
#[cfg(windows)]
fn local_now_ms() -> i128 {
    #[repr(C)]
    #[derive(Default)]
    struct SystemTimeParts {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        milliseconds: u16,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetLocalTime(time: *mut SystemTimeParts);
    }
    let mut now = SystemTimeParts::default();
    // SAFETY: GetLocalTime fills the struct it is given, nothing else.
    unsafe { GetLocalTime(&mut now) };
    days_from_civil(now.year as i64, now.month as i64, now.day as i64) as i128 * 86_400_000
        + ((now.hour as i64 * 3600 + now.minute as i64 * 60 + now.second as i64) * 1000 + now.milliseconds as i64) as i128
}

#[cfg(not(windows))]
fn local_now_ms() -> i128 {
    epoch_ms() as i128
}

// ------------------------------------------------------------ 2. probe fonts

/// The widths font `n` carries, one per letter of `LETTERS`, in font units:
/// all different within a font (37 is prime to 64) and different between fonts.
pub(crate) fn pattern(n: u32, index: usize) -> u16 {
    256 + 16 * ((index as u32 * 37 + n * 11) % 64) as u16
}

/// f1 at once, as the game starts (it answers "does a font made after launch
/// load" whether or not C_Log reaches the file); f2 on, every FONT_EVERY from
/// the session's first WCPROBE line, the exact sign the addon is polling.
fn write_fonts(addons: &Path, session: &str, stop: &AtomicBool, in_world: &AtomicBool) {
    let source = addons.join(ADDON).join("Fonts").join(FONT_SOURCE);
    let font = match fs::read(&source) {
        Ok(font) => font,
        Err(err) => return println!("bridge probe: cannot read {}: {err}", source.display()),
    };
    let dir = probe_dir(addons);
    for n in 1..=FONTS {
        if n == 2 {
            while !in_world.load(Ordering::SeqCst) {
                if stop.load(Ordering::SeqCst) {
                    println!("bridge probe: no WCPROBE line this session, so only f1 was written");
                    return;
                }
                thread::sleep(Duration::from_millis(200));
            }
        }
        if stop.load(Ordering::SeqCst) {
            return;
        }
        match write_font(&font, &dir, session, n) {
            Ok(()) => println!("bridge probe: wrote Probe\\f{n}.ttf"),
            Err(err) => println!("bridge probe: f{n}.ttf not written: {err}"),
        }
        // the font before the last: the game has had it, does it hold it open?
        if n >= 3 {
            let old = dir.join(format!("f{}.ttf", n - 2));
            let result = match fs::remove_file(&old) {
                Ok(()) => "deleted".to_string(),
                Err(err) => format!("refused: {err}"),
            };
            append("fonts.tsv", "session\tfont\tdelete", &format!("{session}\tf{}\t{result}", n - 2));
        }
        if n == 1 {
            continue;
        }
        let wake = Instant::now() + FONT_EVERY;
        while Instant::now() < wake {
            if stop.load(Ordering::SeqCst) {
                return;
            }
            thread::sleep(Duration::from_millis(200));
        }
    }
}

fn write_font(font: &[u8], dir: &Path, session: &str, n: u32) -> io::Result<()> {
    let widths: Vec<u16> = (0..LETTERS.len()).map(|index| pattern(n, index)).collect();
    let (patched, glyphs) = patch_widths(font, LETTERS, &widths).map_err(io::Error::other)?;
    fs::create_dir_all(dir)?;
    let temporary = dir.join(format!("f{n}.ttf.tmp"));
    fs::write(&temporary, &patched)?;
    fs::rename(&temporary, dir.join(format!("f{n}.ttf")))?;
    let mut record = format!(
        "session\t{session}\nn\t{n}\nunits_per_em\t{}\nwritten_local_ms\t{}\nletter\tglyph\toriginal\twritten\n",
        units_per_em(font).map_err(io::Error::other)?,
        local_now_ms()
    );
    for (letter, glyph) in LETTERS.chars().zip(&glyphs) {
        record.push_str(&format!("{letter}\t{}\t{}\t{}\n", glyph.id, glyph.original, glyph.written));
    }
    fs::write(data_dir()?.join(format!("f{n}.txt")), record)
}

fn remove_fonts(addons: &Path) {
    if let Ok(entries) = fs::read_dir(probe_dir(addons)) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('f') && (name.ends_with(".ttf") || name.ends_with(".tmp")) {
                if let Err(err) = fs::remove_file(entry.path()) {
                    println!("bridge probe: could not remove Probe\\{name}: {err}");
                }
            }
        }
    }
}

// ------------------------------------------------------------- TrueType tables

fn u16_at(data: &[u8], at: usize) -> Result<u16, String> {
    data.get(at..at + 2).map(|b| u16::from_be_bytes([b[0], b[1]])).ok_or_else(|| format!("the font ends before byte {at}"))
}

fn u32_at(data: &[u8], at: usize) -> Result<u32, String> {
    data.get(at..at + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]])).ok_or_else(|| format!("the font ends before byte {at}"))
}

/// (offset, length) of a table, from the font's table directory.
fn table(font: &[u8], tag: &[u8; 4]) -> Result<(usize, usize), String> {
    let count = u16_at(font, 4)? as usize;
    for record in 0..count {
        let at = 12 + record * 16;
        if font.get(at..at + 4) == Some(tag) {
            return Ok((u32_at(font, at + 8)? as usize, u32_at(font, at + 12)? as usize));
        }
    }
    Err(format!("the font has no {} table", String::from_utf8_lossy(tag)))
}

fn units_per_em(font: &[u8]) -> Result<u16, String> {
    let (head, _) = table(font, b"head")?;
    u16_at(font, head + 18)
}

/// The glyph a character maps to, through the font's format 4 cmap subtable
/// (Windows Unicode BMP, else Unicode).
fn glyph_for(font: &[u8], character: char) -> Result<u16, String> {
    let (cmap, _) = table(font, b"cmap")?;
    let code = character as u32;
    if code > 0xFFFF {
        return Err(format!("{character:?} is outside the BMP"));
    }
    let subtables = u16_at(font, cmap + 2)? as usize;
    let mut chosen = None;
    for index in 0..subtables {
        let at = cmap + 4 + index * 8;
        let (platform, encoding, offset) = (u16_at(font, at)?, u16_at(font, at + 2)?, u32_at(font, at + 4)? as usize);
        if u16_at(font, cmap + offset)? != 4 {
            continue;
        }
        if (platform, encoding) == (3, 1) {
            chosen = Some(cmap + offset);
            break;
        }
        if platform == 0 && chosen.is_none() {
            chosen = Some(cmap + offset);
        }
    }
    let sub = chosen.ok_or("the font has no format 4 cmap subtable")?;
    let segments = u16_at(font, sub + 6)? as usize / 2;
    let ends = sub + 14;
    let starts = ends + segments * 2 + 2;
    let deltas = starts + segments * 2;
    let ranges = deltas + segments * 2;
    for segment in 0..segments {
        let end = u16_at(font, ends + segment * 2)? as u32;
        if end < code {
            continue;
        }
        let start = u16_at(font, starts + segment * 2)? as u32;
        if start > code {
            break;
        }
        let delta = u16_at(font, deltas + segment * 2)? as u32;
        let range_at = ranges + segment * 2;
        let range = u16_at(font, range_at)? as usize;
        let glyph = if range == 0 {
            (code + delta) & 0xFFFF
        } else {
            let id = u16_at(font, range_at + range + 2 * (code - start) as usize)? as u32;
            if id == 0 { 0 } else { (id + delta) & 0xFFFF }
        };
        return if glyph == 0 { Err(format!("{character:?} has no glyph")) } else { Ok(glyph as u16) };
    }
    Err(format!("{character:?} has no glyph"))
}

pub(crate) struct Glyph {
    pub id: u16,
    pub original: u16,
    pub written: u16,
}

/// The font with each letter's advance width (hmtx) set to its width; every
/// other byte unchanged. A glyph past hhea's numberOfHMetrics shares the last
/// advance with every glyph after it, so it is refused, not guessed at.
fn patch_widths(font: &[u8], letters: &str, widths: &[u16]) -> Result<(Vec<u8>, Vec<Glyph>), String> {
    let (hhea, _) = table(font, b"hhea")?;
    let metrics = u16_at(font, hhea + 34)?;
    let (hmtx, length) = table(font, b"hmtx")?;
    let mut patched = font.to_vec();
    let mut glyphs = Vec::new();
    for (letter, width) in letters.chars().zip(widths) {
        let id = glyph_for(font, letter)?;
        if id >= metrics {
            return Err(format!(
                "{letter:?} is glyph {id}, past the font's {metrics} advance widths: it shares the last one, so it cannot carry its own"
            ));
        }
        let at = hmtx + id as usize * 4;
        if at + 2 > hmtx + length {
            return Err(format!("{letter:?}'s advance width lies outside the hmtx table"));
        }
        let original = u16_at(font, at)?;
        patched[at..at + 2].copy_from_slice(&width.to_be_bytes());
        glyphs.push(Glyph { id, original, written: *width });
    }
    Ok((patched, glyphs))
}

/// Advance widths as the font holds them, for each letter.
fn widths_of(font: &[u8], letters: &str) -> Result<Vec<u16>, String> {
    let (hmtx, _) = table(font, b"hmtx")?;
    letters.chars().map(|letter| u16_at(font, hmtx + glyph_for(font, letter)? as usize * 4)).collect()
}

// ---------------------------------------------------------- 3. capture timing

/// One `strip::capture` timed: when, how tall, how long. The path is worked out
/// once; each call costs one line.
pub(crate) fn note_capture(height: usize, took: Duration, ok: bool) {
    static PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
    let Some(path) = PATH.get_or_init(|| data_dir().ok().map(|dir| dir.join("capture.tsv"))) else { return };
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}\t{height}\t{}\t{ok}", epoch_ms(), took.as_micros());
    }
}

// ------------------------------------------------------------- the commands

pub(crate) fn command(args: &[String]) -> io::Result<()> {
    let addons = Settings::load().get("addons").map(PathBuf::from).ok_or_else(|| io::Error::other("no AddOns folder set: run wow-companion-setup first"))?;
    match args.first().map(String::as_str) {
        Some("report") => report(&addons),
        Some("clean") => clean(&addons),
        _ => Err(io::Error::other("bridge-probe report | clean")),
    }
}

fn clean(addons: &Path) -> io::Result<()> {
    remove_fonts(addons);
    let dir = companion_dir()?.join("bridge-probe");
    if dir.exists() {
        fs::remove_dir_all(&dir)?;
    }
    println!("removed the probe fonts in {} and {}", probe_dir(addons).display(), dir.display());
    Ok(())
}

fn read_tsv(name: &str) -> Vec<Vec<String>> {
    let Ok(dir) = data_dir() else { return Vec::new() };
    fs::read_to_string(dir.join(name))
        .map(|text| text.lines().skip(1).map(|line| line.split('\t').map(str::to_string).collect()).collect())
        .unwrap_or_default()
}

fn stats(mut values: Vec<f64>) -> String {
    if values.is_empty() {
        return "none".into();
    }
    values.sort_by(|a, b| a.total_cmp(b));
    format!("min {:.0}, median {:.0}, max {:.0} ({} values)", values[0], values[values.len() / 2], values[values.len() - 1], values.len())
}

fn report(addons: &Path) -> io::Result<()> {
    let sessions = read_tsv("sessions.tsv");
    let Some(latest) = sessions.last() else {
        println!("No probe session recorded yet: the probe runs while the game does.");
        return Ok(());
    };
    let (session, started) = (latest[0].clone(), latest.get(1).and_then(|v| v.parse::<u128>().ok()).unwrap_or(0));
    println!("Bridge probe, game session {session} ({} sessions recorded)\n", sessions.len());
    let saved = saved_variables_text(addons).unwrap_or_default();
    let game = saved
        .find("[\"bridgeProbe\"] = ")
        .map(|at| &saved[at + "[\"bridgeProbe\"] = ".len()..])
        .and_then(|from| Lua::parse(from).ok())
        .map(|(value, _)| value);

    // 1. C_Log
    println!("1. C_Log into Logs\\General.log (delay = the PC reading the line minus the game's own timestamp on it; polled every {} ms)", POLL.as_millis());
    let lines: Vec<Vec<String>> = read_tsv("log.tsv").into_iter().filter(|row| row.first() == Some(&session)).collect();
    if lines.is_empty() {
        println!("   No WCPROBE line reached the file this session.");
    } else {
        let delays: Vec<f64> = lines.iter().filter_map(|row| row.get(2)?.parse().ok()).collect();
        println!("   {} lines arrived; delay ms: {}", lines.len(), stats(delays));
        let batched = lines.iter().filter(|row| row.get(10).and_then(|n| n.parse::<usize>().ok()).unwrap_or(1) > 1).count();
        println!("   {batched} of them came in a read holding more than one WCPROBE line (batched flushing if most did)");
        let whole: Vec<usize> = lines.iter().filter(|row| row.get(8).map(String::as_str) == Some("true")).filter_map(|row| row.get(6)?.parse().ok()).collect();
        println!("   largest line that arrived whole: {} bytes", whole.iter().max().map(|n| n.to_string()).unwrap_or_else(|| "none".into()));
        for row in lines.iter().filter(|row| row.get(8).map(String::as_str) != Some("true")) {
            println!("   NOT whole: seq {} declared {} bytes, {} arrived", row[5], row[6], row[7]);
        }
        for (level, call) in [("N", "LogMessage"), ("W", "LogWarningMessage"), ("E", "LogErrorMessage")] {
            let count = lines.iter().filter(|row| row.get(3).map(String::as_str) == Some(level)).count();
            println!("   {call} ([{level}] lines): {count}");
        }
    }
    match game.as_ref().and_then(|game| game.get("log")) {
        Some(calls) => {
            let calls = calls.list();
            println!("   The game made {} C_Log calls (its record, kept to the last 60):", calls.len());
            for call in calls {
                if let Some(error) = call.get("error") {
                    println!("     {}", error.text());
                    continue;
                }
                let (via, seq, ok, result) =
                    (call.text_of("via"), call.text_of("seq"), call.text_of("ok"), call.text_of("result"));
                let arrived = lines.iter().any(|row| row.get(5) == Some(&seq));
                println!("     seq {seq} via {via}: call ok {ok}, returned {result}; {}", if arrived { "reached the file" } else { "NOT in the file" });
            }
        }
        None => println!("   The save holds no WowCompanionDB.bridgeProbe.log yet (the game writes it at a reload or logout)."),
    }

    // 2. fonts
    println!("\n2. Fonts written after launch (Probe\\f<n>.ttf)");
    let deletes: Vec<Vec<String>> = read_tsv("fonts.tsv").into_iter().filter(|row| row.first() == Some(&session)).collect();
    for n in 1..=FONTS {
        let Ok(record) = fs::read_to_string(data_dir()?.join(format!("f{n}.txt"))) else { continue };
        if !record.lines().next().is_some_and(|line| line == format!("session\t{session}")) {
            continue;
        }
        let written: Vec<(char, f64)> = record
            .lines()
            .skip(5)
            .filter_map(|line| {
                let mut fields = line.split('\t');
                Some((fields.next()?.chars().next()?, fields.nth(2)?.parse().ok()?))
            })
            .collect();
        let delete = deletes.iter().find(|row| row.get(1).map(String::as_str) == Some(&format!("f{n}"))).and_then(|row| row.get(2).cloned());
        println!("   f{n}: written ({} letters); delete afterwards: {}", written.len(), delete.unwrap_or_else(|| "not tried".into()));
        // the widths depend on n only, so the game's last record of f<n> answers for it
        let record = game.as_ref().and_then(|game| game.get("font")).and_then(|fonts| {
            fonts.list().into_iter().filter(|entry| entry.text_of("n") == n.to_string()).last()
        });
        match record {
            Some(entry) => {
                let chars = entry.text_of("chars");
                let widths: Vec<f64> = entry.get("widths").map(|w| w.list().iter().filter_map(|v| v.number()).collect()).unwrap_or_default();
                let measured: Vec<(char, f64)> = chars.chars().zip(widths).collect();
                println!(
                    "      loaded {} s after login, after {} tries; UI scale {}",
                    entry.text_of("sinceStart"),
                    entry.text_of("tries"),
                    entry.text_of("uiScale")
                );
                println!("      {}", compare_widths(&written, &measured));
            }
            None => println!("      the game's record has no load of f{n}"),
        }
    }

    // 3. strip
    println!("\n3. The strip");
    let captures: Vec<Vec<String>> = read_tsv("capture.tsv")
        .into_iter()
        .filter(|row| row.first().and_then(|at| at.parse::<u128>().ok()).is_some_and(|at| at >= started))
        .collect();
    for (height, what) in [("4", "the 1024x4 look (twice a second)"), ("256", "the full grab (a read)")] {
        let us: Vec<f64> = captures.iter().filter(|row| row.get(1).map(String::as_str) == Some(height)).filter_map(|row| row.get(2)?.parse().ok()).collect();
        println!("   PC capture, {what}, microseconds: {}", stats(us));
    }
    match game.as_ref().and_then(|game| game.get("strip")) {
        Some(sends) => {
            let sends = sends.list();
            println!("   The game drawing each strip (Strip.Send, entry to Show), its last {}:", sends.len());
            for send in sends {
                println!(
                    "     {} ms for {} cells ({} bytes) at {}",
                    send.text_of("ms"),
                    send.text_of("cells"),
                    send.text_of("bytes"),
                    send.text_of("at")
                );
            }
        }
        None => println!("   The game's record has no strip timings (none drawn, or not saved yet)."),
    }
    Ok(())
}

/// What the measured widths say about the written ones. Each ratio
/// measured/written is printed as numbers; "a constant scale" means every ratio
/// equals the first to within 0.1% (stated, so the reader sees the threshold),
/// and "decodes" counts letters whose written width is the nearest one to
/// measured / that scale.
fn compare_widths(written: &[(char, f64)], measured: &[(char, f64)]) -> String {
    let pairs: Vec<(f64, f64)> = written
        .iter()
        .filter_map(|(letter, width)| measured.iter().find(|(m, _)| m == letter).map(|(_, got)| (*width, *got)))
        .collect();
    if pairs.is_empty() {
        return "no letter measured".into();
    }
    let ratios: Vec<f64> = pairs.iter().map(|(w, m)| m / w).collect();
    let first = ratios[0];
    let spread = ratios.iter().map(|r| ((r - first) / first).abs()).fold(0.0, f64::max);
    let scale = ratios.iter().sum::<f64>() / ratios.len() as f64;
    let candidates: Vec<f64> = written.iter().map(|(_, w)| *w).collect();
    let decoded = pairs
        .iter()
        .filter(|(w, m)| {
            let want = m / scale;
            candidates.iter().copied().min_by(|a, b| (a - want).abs().total_cmp(&(b - want).abs())) == Some(*w)
        })
        .count();
    format!(
        "{} letters measured; measured/written ratio {:.6} to {:.6} (largest gap from the first {:.4}%): {}; {} of {} decode to the width written",
        pairs.len(),
        ratios.iter().copied().fold(f64::MAX, f64::min),
        ratios.iter().copied().fold(f64::MIN, f64::max),
        spread * 100.0,
        if spread <= 0.001 { "a constant scale (within 0.1%)" } else { "NOT a constant scale" },
        decoded,
        pairs.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roboto() -> Vec<u8> {
        fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("addon").join(ADDON).join("Fonts").join(FONT_SOURCE)).unwrap()
    }

    #[test]
    fn a_probe_font_carries_its_widths_and_changes_nothing_else() {
        let font = roboto();
        let widths: Vec<u16> = (0..LETTERS.len()).map(|index| pattern(3, index)).collect();
        let (patched, glyphs) = patch_widths(&font, LETTERS, &widths).unwrap();
        assert_eq!(glyphs.len(), 64);
        assert_eq!(widths_of(&patched, LETTERS).unwrap(), widths);
        let (hmtx, _) = table(&font, b"hmtx").unwrap();
        let changed: Vec<usize> = glyphs.iter().flat_map(|g| [hmtx + g.id as usize * 4, hmtx + g.id as usize * 4 + 1]).collect();
        for (at, (a, b)) in font.iter().zip(&patched).enumerate() {
            if !changed.contains(&at) {
                assert_eq!(a, b, "byte {at} changed");
            }
        }
        assert_eq!(font.len(), patched.len());
        // every width different within the font
        let mut sorted = widths.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), 64);
    }

    #[test]
    fn letters_map_to_distinct_glyphs() {
        let font = roboto();
        let mut ids: Vec<u16> = LETTERS.chars().map(|c| glyph_for(&font, c).unwrap()).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), 64);
    }

    #[test]
    fn a_wcprobe_line_is_read_with_its_delay_and_wholeness() {
        let read_at = days_from_civil(2026, 11, 11) as i128 * 86_400_000 + (21 * 3600 + 5 * 60 + 7) as i128 * 1000 + 250;
        let line = "11/11 21:05:07.200  [N][Lua] WCPROBE log 7 5 ABCDE";
        let found = probe_line(line, read_at);
        assert_eq!(
            found,
            ProbeLine { delay_ms: Some(50), level: "N".into(), kind: "log".into(), seq: "7".into(), declared: Some(5), arrived: 5, exact: true }
        );
        assert!(found.whole());
        let cut = probe_line("11/11 21:05:07.200  [E][Lua] WCPROBE log 8 4096 ABC", read_at);
        assert_eq!((cut.level.as_str(), cut.whole()), ("E", false));
        // a December line read on New Year's Day
        let january = days_from_civil(2027, 1, 1) as i128 * 86_400_000 + 1000;
        assert_eq!(probe_line("12/31 23:59:59.000  [N][Lua] WCPROBE log 1 1 a", january).delay_ms, Some(2000));
    }

    #[test]
    fn a_line_is_whole_only_when_every_byte_is_the_games() {
        let read_at = 0;
        let good = format!("11/11 21:05:07.200  [N][Lua] WCPROBE log 3 70 {}", text_pattern(70));
        assert!(probe_line(&good, read_at).whole());
        let mut changed = text_pattern(70);
        changed.replace_range(65..66, "!");
        let bad = format!("11/11 21:05:07.200  [N][Lua] WCPROBE log 3 70 {changed}");
        let found = probe_line(&bad, read_at);
        assert_eq!((found.arrived, found.whole()), (70, false));
        assert_eq!(&text_pattern(64)[60..64], "89AB");
    }

    /// The tailer on a stand-in General.log, with the probe's data in a scratch
    /// folder (LOCALAPPDATA pointed there): lines appended while it runs, then
    /// the file cut short as a new game session does. Run alone, `--ignored`.
    #[test]
    #[ignore]
    fn the_tailer_reads_appended_lines_and_follows_a_new_file() {
        let scratch = env::temp_dir().join(format!("wc-bridge-probe-{}", std::process::id()));
        fs::create_dir_all(&scratch).unwrap();
        // SAFETY: this ignored test runs alone (`--ignored`, one test); nothing else reads the environment meanwhile
        unsafe { env::set_var("LOCALAPPDATA", &scratch) };
        let log = scratch.join("General.log");
        fs::write(&log, "11/11 00:00:00.000  [N][Console] an old line, before the tailer starts\n").unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let in_world = Arc::new(AtomicBool::new(false));
        let tailer = {
            let (log, stop, in_world) = (log.clone(), Arc::clone(&stop), Arc::clone(&in_world));
            thread::spawn(move || tail(&log, "test", &stop, &in_world))
        };
        let stamp = || {
            let now = local_now_ms();
            let (_, month, day) = civil_ymd(now.div_euclid(86_400_000) as i64);
            let of_day = now.rem_euclid(86_400_000);
            format!("{month:02}/{day:02} {:02}:{:02}:{:02}.{:03}", of_day / 3_600_000, of_day / 60_000 % 60, of_day / 1000 % 60, of_day % 1000)
        };
        let line = |seq: u32, len: usize| format!("{}  [N][Lua] WCPROBE log {seq} {len} {}\n", stamp(), text_pattern(len));
        thread::sleep(Duration::from_millis(100));
        for (seq, len) in [(1, 16), (2, 16384)] {
            let mut file = fs::OpenOptions::new().append(true).open(&log).unwrap();
            file.write_all(line(seq, len).as_bytes()).unwrap();
            drop(file);
            thread::sleep(Duration::from_millis(200));
        }
        // a new session: the game starts the file again, shorter than before
        fs::write(&log, line(3, 256)).unwrap();
        thread::sleep(Duration::from_millis(300));
        stop.store(true, Ordering::SeqCst);
        tailer.join().unwrap();
        let rows = fs::read_to_string(scratch.join("wow-companion").join("bridge-probe").join("log.tsv")).unwrap();
        let rows: Vec<Vec<&str>> = rows.lines().skip(1).map(|row| row.split('\t').collect()).collect();
        assert_eq!(rows.iter().map(|row| row[5]).collect::<Vec<_>>(), vec!["1", "2", "3"], "{rows:?}");
        for row in &rows {
            assert_eq!(row[8], "true", "{row:?}");
            let delay: i128 = row[2].parse().unwrap();
            assert!((0..100).contains(&delay), "{row:?}");
        }
        assert!(in_world.load(Ordering::SeqCst));
        let _ = fs::remove_dir_all(&scratch);
    }

    #[test]
    fn dates_round_trip() {
        for (y, m, d) in [(1970, 1, 1), (2026, 11, 11), (2027, 2, 28), (2028, 2, 29)] {
            assert_eq!(civil_from_days(days_from_civil(y, m, d)), (y, m));
        }
    }

    #[test]
    fn widths_compare_by_a_constant_scale() {
        let written: Vec<(char, f64)> = LETTERS.chars().enumerate().map(|(i, c)| (c, pattern(1, i) as f64)).collect();
        let measured: Vec<(char, f64)> = written.iter().map(|(c, w)| (*c, w * 64.0 / 2048.0 * 0.71)).collect();
        let said = compare_widths(&written, &measured);
        assert!(said.contains("a constant scale"), "{said}");
        assert!(said.contains("64 of 64 decode"), "{said}");
    }
}
