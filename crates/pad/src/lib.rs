//! The controller, read as raw HID.
//!
//! Windows.Gaming.Input never enumerated this pad (a Switch controller behind
//! switch2connect, presenting itself as a DualSense through the Virtual HID
//! Framework), and WGI omits the PS/Home button from its gamepad button set even for
//! pads it does see. gilrs on Windows offers only WGI or XInput, so neither reaches
//! this pad. HID does, and it needs no window focus, which push-to-talk during a game
//! very much does.
//!
//! Measured against this setup: 64-byte reports, id 0x01, standard DualSense layout.

use std::{
    fmt, io, thread,
    time::{Duration, Instant},
};

use hidapi::{HidApi, HidDevice};

// the pad as switch2connect presents it; `pads` lists what is actually attached
pub const DEFAULT_PAD: (u16, u16) = (0x054c, 0x0ce6);

const REPORT: usize = 128;
const POLL: Duration = Duration::from_millis(4);
// `watch`: hands off this long, and a byte that moves this often while untouched
// is an axis, a counter or a timestamp
const CALIBRATE: Duration = Duration::from_secs(3);
const RESTLESS: u32 = 3;
// learning a button: how long every byte is watched before a press counts, how
// long a byte must have been still before one, and the shortest real press
const WARM_UP: Duration = Duration::from_millis(400);
const QUIET: Duration = Duration::from_millis(400);
const HOLD_MIN: Duration = Duration::from_millis(40);

/// One button, as the bit it occupies in the input report.
#[derive(PartialEq)]
pub struct Press {
    pub byte: usize,
    pub mask: u8,
}

impl Press {
    /// As `press` reads it back: `byte:mask`, like `9:0x10`.
    pub fn spec(&self) -> String {
        format!("{}:{:#04x}", self.byte, self.mask)
    }
}

impl Press {
    /// The button's name on this kind of controller, as Windows sees it (by
    /// vendor id), or None when we don't know that layout. Only Sony's report
    /// layout is known; a pad behind an adapter is named as the adapter presents it.
    pub fn name(&self, vid: u16) -> Option<&'static str> {
        let known: &[(&str, usize, u8)] = match vid {
            0x054c => &[
                ("PS", 10, 0x01), ("touchpad", 10, 0x02), ("L1", 9, 0x01), ("R1", 9, 0x02),
                ("L2", 9, 0x04), ("R2", 9, 0x08), ("Create", 9, 0x10), ("Options", 9, 0x20),
                ("L3", 9, 0x40), ("R3", 9, 0x80),
                ("Square", 8, 0x10), ("Cross", 8, 0x20), ("Circle", 8, 0x40), ("Triangle", 8, 0x80),
            ],
            _ => &[],
        };
        known.iter().find(|(_, byte, mask)| *byte == self.byte && *mask == self.mask).map(|(name, ..)| *name)
    }
}

impl fmt::Display for Press {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "byte {} mask {:#04x}", self.byte, self.mask)
    }
}

// Named for this pad's measured layout. Anything else can be given as byte:mask,
// since these offsets belong to one adapter's report, not to HID in general.
pub fn press(name: &str) -> io::Result<Press> {
    let (byte, mask) = match name.to_ascii_lowercase().as_str() {
        // the one button WoW ignores, which is the whole reason for this module
        "home" | "ps" => (10, 0x01),
        "capture" | "touchpad" => (10, 0x02),
        "l1" | "lb" => (9, 0x01),
        "r1" | "rb" => (9, 0x02),
        // the DualSense layout of byte 9, which L1, R1 and minus all match here;
        // the triggers' digital bits, for talk-button slots
        "l2" | "lt" => (9, 0x04),
        "r2" | "rt" => (9, 0x08),
        // measured: Switch minus and plus arrive as the DualSense Create and Options
        // buttons. WoW binds plus to the game menu, so minus is the free one.
        "minus" | "create" | "share" => (9, 0x10),
        "plus" | "options" => (9, 0x20),
        other => match other.split_once(':') {
            Some((byte, mask)) => (
                byte.parse().map_err(|_| io::Error::other(format!("{byte:?} isn't a byte index")))?,
                hex8(mask)?,
            ),
            None => {
                return Err(io::Error::other(format!(
                    "unknown button {name:?}: try home, capture, l1, r1, or byte:mask like 10:0x01"
                )));
            }
        },
    };
    Ok(Press { byte, mask })
}

pub struct Pad {
    device: HidDevice,
    latest: Vec<u8>,
}

impl Pad {
    pub fn open(vid: u16, pid: u16) -> io::Result<Self> {
        Ok(Self { device: open(vid, pid)?, latest: Vec::new() })
    }

    /// Drain every report waiting on the device, keeping the newest. The pad streams
    /// at a few hundred hertz, so without draining we would read stale state.
    pub fn refresh(&mut self) -> io::Result<()> {
        let mut buffer = [0u8; REPORT];
        loop {
            let read = self
                .device
                .read_timeout(&mut buffer, 0)
                .map_err(|err| io::Error::other(err.to_string()))?;
            if read == 0 {
                return Ok(());
            }
            self.latest.clear();
            self.latest.extend_from_slice(&buffer[..read]);
        }
    }

    pub fn held(&self, press: &Press) -> bool {
        self.latest.get(press.byte).is_some_and(|byte| byte & press.mask != 0)
    }

    /// Set the two rumble motors (0 stops them). The DualSense's USB output
    /// report: id 0x02, then flags 0x03 ("compatible vibration": the classic
    /// two-motor rumble rather than haptic audio), then the right (small) and left
    /// (large) motor strengths. Whether the adapter passes it on to the pad behind
    /// it is what `buzz` tests.
    pub fn rumble(&self, small: u8, large: u8) -> io::Result<()> {
        let mut report = [0u8; 48];
        report[0] = 0x02;
        report[1] = 0x03;
        report[3] = small;
        report[4] = large;
        self.device
            .write(&report)
            .map(|_| ())
            .map_err(|err| io::Error::other(err.to_string()))
    }
}

/// Rumble patterns on a handle of their own, played on their own thread, so a
/// pattern keeps its timing while the caller is busy (transcribing, say). The
/// handle is opened when first needed and again after a failed write, which is
/// what a pad that went away and came back looks like.
pub struct Rumbler {
    pad: (u16, u16),
    device: std::sync::Arc<std::sync::Mutex<Option<HidDevice>>>,
}

impl Rumbler {
    pub fn new(vid: u16, pid: u16) -> Self {
        Rumbler { pad: (vid, pid), device: Default::default() }
    }

    /// Play `steps` of (milliseconds from now, small motor, large motor), in
    /// order, ending with the motors off whatever the steps say.
    pub fn play(&self, steps: &[(u64, u8, u8)]) {
        let (vid, pid) = self.pad;
        let device = std::sync::Arc::clone(&self.device);
        let steps = steps.to_vec();
        thread::spawn(move || {
            let mut handle = device.lock().unwrap();
            let start = Instant::now();
            for &(at, small, large) in steps.iter().chain([(steps.last().map_or(0, |s| s.0), 0, 0)].iter()) {
                let due = start + Duration::from_millis(at);
                if let Some(wait) = due.checked_duration_since(Instant::now()) {
                    thread::sleep(wait);
                }
                if handle.is_none() {
                    *handle = open(vid, pid).ok();
                }
                let mut report = [0u8; 48];
                report[0] = 0x02;
                report[1] = 0x03;
                report[3] = small;
                report[4] = large;
                if let Some(pad) = handle.as_ref() {
                    if pad.write(&report).is_err() {
                        *handle = None;
                    }
                }
            }
        });
    }
}

/// One short pulse on the pad, to see whether rumble reaches it at all.
pub fn buzz() -> io::Result<()> {
    let (vid, pid) = DEFAULT_PAD;
    let pad = Pad::open(vid, pid)?;
    pad.rumble(0xc0, 0xc0)?;
    thread::sleep(Duration::from_millis(250));
    pad.rumble(0, 0)?;
    println!("sent a 250 ms rumble; did the controller buzz?");
    Ok(())
}

pub fn list() -> io::Result<()> {
    let api = HidApi::new().map_err(|err| io::Error::other(err.to_string()))?;
    println!("{:>9}  {:>11}  {:<28} {}", "vid:pid", "usage", "product", "path");
    for device in api.device_list() {
        println!(
            "{:04x}:{:04x}  {:#06x}/{:#04x}  {:<28} {}",
            device.vendor_id(),
            device.product_id(),
            device.usage_page(),
            device.usage(),
            device.product_string().unwrap_or("?"),
            device.path().to_string_lossy(),
        );
    }
    println!("\ngame controllers report usage 0x0001/0x04 (joystick) or 0x05 (gamepad)");
    Ok(())
}

/// Reports a button as the bit it actually is.
///
/// A pad streams whether or not you touch it: a sequence counter, a timestamp and six
/// axes of IMU, all moving constantly. So spend a moment learning which bytes are
/// never still and mask those out. Counting changes rather than collecting flipped
/// bits matters: three seconds only catches some bits of a 16-bit gyro value, and
/// masking bit by bit lets the rest through forever after.
pub fn watch(id: &str) -> io::Result<()> {
    let (vid, pid) = split(id)?;
    let device = open(vid, pid)?;
    println!("watching {vid:04x}:{pid:04x}");
    println!("hands off the pad for {CALIBRATE:?} while I learn what moves on its own");

    let mut churn = [0u32; REPORT];
    let mut previous: Option<Vec<u8>> = None;
    let mut buffer = [0u8; REPORT];
    let mut learning = true;
    let since = Instant::now();
    loop {
        let read = device
            .read_timeout(&mut buffer, 100)
            .map_err(|err| io::Error::other(err.to_string()))?;
        if read == 0 {
            continue;
        }
        let current = &buffer[..read];
        match &previous {
            None => println!("report is {read} bytes, id {:#04x}", current[0]),
            Some(last) => {
                for (index, (before, after)) in last.iter().zip(current).enumerate() {
                    let flipped = before ^ after;
                    if flipped == 0 {
                        continue;
                    }
                    if learning {
                        churn[index] += 1;
                        continue;
                    }
                    if churn[index] >= RESTLESS {
                        continue;
                    }
                    for bit in 0..8 {
                        let mask = 1u8 << bit;
                        if flipped & mask != 0 {
                            let state = if after & mask != 0 { "down" } else { "up" };
                            println!("byte {index} bit {bit} {state}  (mask {mask:#04x})");
                        }
                    }
                }
            }
        }
        previous = Some(current.to_vec());
        if learning && since.elapsed() > CALIBRATE {
            learning = false;
            let noisy: Vec<String> = churn
                .iter()
                .enumerate()
                .filter(|(_, seen)| **seen >= RESTLESS)
                .map(|(index, seen)| format!("{index}({seen})"))
                .collect();
            println!("ignoring restless bytes: {}", noisy.join(" "));
            println!("now press one button at a time");
        }
        thread::sleep(POLL);
    }
}

/// The game controllers attached now (HID usage joystick or gamepad): vid, pid,
/// product name. One entry per pad, though a pad may expose several interfaces.
pub fn gamepads() -> io::Result<Vec<(u16, u16, String)>> {
    let api = HidApi::new().map_err(|err| io::Error::other(err.to_string()))?;
    let mut found: Vec<(u16, u16, String)> = Vec::new();
    for device in api.device_list() {
        if device.usage_page() == 1 && matches!(device.usage(), 4 | 5) {
            let entry = (device.vendor_id(), device.product_id(), device.product_string().unwrap_or("?").to_string());
            if !found.iter().any(|(vid, pid, _)| (*vid, *pid) == (entry.0, entry.1)) {
                found.push(entry);
            }
        }
    }
    Ok(found)
}

/// The button the player presses next, read from the raw report with no setup
/// step: a bit that goes down, is held at least `HOLD_MIN` and comes back up,
/// in a byte that was quiet before it. Axes, counters and timestamps flip all
/// the time, so a byte that moved within `QUIET` of the press, or moves while
/// the bit is held, is not a button. So nobody has to keep their hands off
/// first; the press counts when the button is let go.
pub fn learn(vid: u16, pid: u16, wait: Duration, status: impl Fn(&str)) -> io::Result<Press> {
    let device = open(vid, pid)?;
    status("press the button you want to talk with");
    // when each byte last changed, and how often it changed during a hold
    let mut moved: [Option<Instant>; REPORT] = [None; REPORT];
    let mut previous: Option<Vec<u8>> = None;
    let mut buffer = [0u8; REPORT];
    // the bit going down, when, and how many times its byte changed since
    let mut down: Option<(Press, Instant, u32)> = None;
    let since = Instant::now();
    loop {
        if since.elapsed() > wait {
            return Err(io::Error::other("no button press seen"));
        }
        let read = device
            .read_timeout(&mut buffer, 100)
            .map_err(|err| io::Error::other(err.to_string()))?;
        if read == 0 {
            continue;
        }
        let current = buffer[..read].to_vec();
        let now = Instant::now();
        if let Some(last) = &previous {
            let mut fresh = None;
            for (index, (before, after)) in last.iter().zip(&current).enumerate() {
                let flipped = before ^ after;
                if flipped == 0 {
                    continue;
                }
                let quiet = moved[index].is_none_or(|at| now - at >= QUIET);
                moved[index] = Some(now);
                if let Some((press, _, changes)) = &mut down {
                    if press.byte == index {
                        *changes += 1;
                    }
                    continue;
                }
                // a button going down: the lowest bit that turned on, in a byte
                // that had been still (a warm-up first, so every byte has a past)
                let pressed = flipped & after;
                if pressed != 0 && quiet && since.elapsed() >= WARM_UP && fresh.is_none() {
                    fresh = Some(Press { byte: index, mask: pressed & pressed.wrapping_neg() });
                }
            }
            if let Some(press) = fresh {
                down = Some((press, now, 0));
            }
            if let Some((press, at, changes)) = &down {
                if current.get(press.byte).is_some_and(|byte| byte & press.mask == 0) {
                    let held = now - *at;
                    // the release itself is one change; anything more moved under it
                    if changes <= &1 && held >= HOLD_MIN {
                        return Ok(Press { byte: press.byte, mask: press.mask });
                    }
                    down = None;
                }
            }
        }
        previous = Some(current);
        thread::sleep(POLL);
    }
}

/// `vid:pid` as numbers, like `054c:0ce6`.
pub fn split(id: &str) -> io::Result<(u16, u16)> {
    let (vid, pid) = id
        .split_once(':')
        .ok_or_else(|| io::Error::other("expected vid:pid, like 054c:0ce6"))?;
    Ok((hex(vid)?, hex(pid)?))
}

fn hex(text: &str) -> io::Result<u16> {
    u16::from_str_radix(text.trim_start_matches("0x"), 16)
        .map_err(|_| io::Error::other(format!("{text:?} isn't hex")))
}

fn hex8(text: &str) -> io::Result<u8> {
    u8::from_str_radix(text.trim_start_matches("0x"), 16)
        .map_err(|_| io::Error::other(format!("{text:?} isn't a hex byte")))
}

fn open(vid: u16, pid: u16) -> io::Result<HidDevice> {
    let api = HidApi::new().map_err(|err| io::Error::other(err.to_string()))?;
    // by path, not vid/pid: a pad exposes several HID interfaces and more than one
    // Sony device may be paired, so the first match is not reliably the right one
    let candidates: Vec<_> = api
        .device_list()
        .filter(|device| device.vendor_id() == vid && device.product_id() == pid)
        .collect();
    let chosen = candidates
        .iter()
        .find(|device| device.usage_page() == 1 && matches!(device.usage(), 4 | 5))
        .or_else(|| candidates.first())
        .ok_or_else(|| io::Error::other(format!("no HID device {vid:04x}:{pid:04x}")))?;
    if candidates.len() > 1 {
        println!("{} interfaces matched, using {}", candidates.len(), chosen.path().to_string_lossy());
    }
    chosen
        .open_device(&api)
        .map_err(|err| io::Error::other(format!("{err} (is something holding it exclusively?)")))
}
