//! The controller, read as raw HID.
//!
//! Windows.Gaming.Input never enumerated this pad (a Switch controller behind
//! switch2connect, presenting itself as a DualSense through the Virtual HID
//! Framework), and WGI omits the PS/Home button from its gamepad button set even for
//! pads it does see. gilrs on Windows offers only WGI or XInput, so neither reaches
//! this pad. HID does, and it needs no window focus, which push-to-talk during a game
//! very much does.
//!
//! Which bits are buttons comes from the pad, never from a guess: Sony's fixed
//! layout (the USB report 0x01; the Bluetooth report 0x31 is turned into it), the
//! XInput button word (xinput.rs), and for any other pad its own HID report
//! descriptor (descriptor.rs). Buttons have no names here: the companion's keys
//! are set by pressing them in the game, which names them, and stored as the bit
//! plus WoW's name (`Bound`; docs/proposals/settings-in-game.md).

use std::{
    fmt, io, thread,
    time::{Duration, Instant},
};

use hidapi::{HidApi, HidDevice};

mod descriptor;
mod xinput;

/// The id the setup window and `pad=` use for an Xbox (XInput) controller,
/// which has no HID face worth reading. Also accepted as `pad=xinput`.
pub const XINPUT: (u16, u16) = (0xffff, 0x0001);
const SONY: u16 = 0x054c;
const EDGE: u16 = 0x0df2;

const REPORT: usize = 128;
const POLL: Duration = Duration::from_millis(4);

/// One button, as the bit it occupies in the input report.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Press {
    pub byte: usize,
    pub mask: u8,
}

impl Press {
    /// `byte:mask`, like `9:0x10`.
    pub fn spec(&self) -> String {
        format!("{}:{:#04x}", self.byte, self.mask)
    }

    pub fn parse(spec: &str) -> io::Result<Press> {
        let (byte, mask) = spec.split_once(':').ok_or_else(|| io::Error::other(format!("{spec:?} isn't byte:mask")))?;
        Ok(Press {
            byte: byte.parse().map_err(|_| io::Error::other(format!("{byte:?} isn't a byte index")))?,
            mask: u8::from_str_radix(mask.trim_start_matches("0x"), 16)
                .map_err(|_| io::Error::other(format!("{mask:?} isn't a hex byte")))?,
        })
    }
}

impl fmt::Display for Press {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "byte {} mask {:#04x}", self.byte, self.mask)
    }
}

/// The companion's keys: the talk button and the four conversation triggers
/// (L2+R2 is Quick, L1+R1 dictation).
pub const KEYS: [&str; 5] = ["talk", "l1", "l2", "r1", "r2"];

/// A key's button: its bit here and its name in WoW, captured from one press
/// on the game's settings page. Written `9:0x10 PADSOCIAL`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bound {
    pub press: Press,
    pub name: String,
}

impl Bound {
    pub fn spec(&self) -> String {
        format!("{} {}", self.press.spec(), self.name)
    }

    pub fn parse(text: &str) -> io::Result<Bound> {
        let (press, name) = text.trim().split_once(' ').ok_or_else(|| io::Error::other(format!("{text:?} isn't \"byte:mask NAME\"")))?;
        Ok(Bound { press: Press::parse(press)?, name: name.trim().to_string() })
    }
}

/// `key`'s button on the pad `vid:pid`: as set (`set`, the settings file's
/// value), else where the two layouts we know put it; None on another pad
/// until it is pressed in the game.
pub fn bound(key: &str, set: Option<&str>, vid: u16, pid: u16) -> io::Result<Option<Bound>> {
    if let Some(text) = set {
        return Bound::parse(text).map(Some);
    }
    let defaults = match (vid, pid) {
        XINPUT => xinput::KEYS,
        (SONY, _) => SONY_KEYS,
        _ => &[],
    };
    Ok(defaults.iter().find(|(each, ..)| *each == key).map(|(_, press, name)| Bound { press: *press, name: name.to_string() }))
}

/// Sony's buttons in the USB report 0x01: square, cross, circle, triangle (byte
/// 8's high half), L1 R1 L2 R2 Create Options L3 R3 (byte 9), PS, touchpad, mute
/// (byte 10); the Edge adds its Fn and back buttons above them (SDL's PS5 driver).
const SONY_BUTTONS: [Press; 19] = [
    Press { byte: 8, mask: 0x10 },
    Press { byte: 8, mask: 0x20 },
    Press { byte: 8, mask: 0x40 },
    Press { byte: 8, mask: 0x80 },
    Press { byte: 9, mask: 0x01 },
    Press { byte: 9, mask: 0x02 },
    Press { byte: 9, mask: 0x04 },
    Press { byte: 9, mask: 0x08 },
    Press { byte: 9, mask: 0x10 },
    Press { byte: 9, mask: 0x20 },
    Press { byte: 9, mask: 0x40 },
    Press { byte: 9, mask: 0x80 },
    Press { byte: 10, mask: 0x01 },
    Press { byte: 10, mask: 0x02 },
    Press { byte: 10, mask: 0x04 },
    Press { byte: 10, mask: 0x10 },
    Press { byte: 10, mask: 0x20 },
    Press { byte: 10, mask: 0x40 },
    Press { byte: 10, mask: 0x80 },
];

/// The keys on a Sony pad: minus (Create; WoW ignores it) and the shoulders.
const SONY_KEYS: &[(&str, Press, &str)] = &[
    ("talk", Press { byte: 9, mask: 0x10 }, "PADSOCIAL"),
    ("l1", Press { byte: 9, mask: 0x01 }, "PADLSHOULDER"),
    ("r1", Press { byte: 9, mask: 0x02 }, "PADRSHOULDER"),
    ("l2", Press { byte: 9, mask: 0x04 }, "PADLTRIGGER"),
    ("r2", Press { byte: 9, mask: 0x08 }, "PADRTRIGGER"),
];

pub struct Pad {
    device: Device,
    sony: bool,
    /// the report that carries the buttons, when the pad numbers its reports
    report: Option<u8>,
    buttons: Vec<Press>,
    latest: Vec<u8>,
}

impl Pad {
    pub fn open(vid: u16, pid: u16) -> io::Result<Self> {
        let device = open(vid, pid)?;
        let (report, buttons) = match (&device, vid) {
            (Device::XInput(_), _) => (None, xinput::BUTTONS.to_vec()),
            (Device::Hid(_), SONY) => (Some(0x01), SONY_BUTTONS[..if pid == EDGE { 19 } else { 15 }].to_vec()),
            (Device::Hid(hid), _) => {
                let mut raw = [0u8; 4096];
                match hid.get_report_descriptor(&mut raw) {
                    Ok(length) => descriptor::buttons(&raw[..length]),
                    Err(err) => {
                        eprintln!("the controller's report descriptor could not be read ({err}): no button can be set on it");
                        (None, Vec::new())
                    }
                }
            }
        };
        Ok(Self { device, sony: vid == SONY, report, buttons, latest: Vec::new() })
    }

    /// Drain every report waiting on the device, keeping the newest that carries
    /// the buttons. The pad streams at a few hundred hertz, so without draining
    /// we would read stale state.
    pub fn refresh(&mut self) -> io::Result<()> {
        let mut buffer = [0u8; REPORT];
        loop {
            let read = self.device.read(&mut buffer, 0)?;
            if read == 0 {
                return Ok(());
            }
            let mut report = buffer[..read].to_vec();
            // Sony over Bluetooth (SDL's PS5 driver; not measured here): the full
            // report 0x31 has one byte more before the USB layout, and the short
            // 0x01 (10 bytes, until a program turns the full one on) is another
            // layout, skipped
            if self.sony && report[0] == 0x31 && report.len() > 2 {
                report.remove(1);
                report[0] = 0x01;
            }
            if self.report.is_some_and(|id| report[0] != id) || (self.sony && report.len() <= 10) {
                continue;
            }
            self.latest = report;
        }
    }

    pub fn held(&self, press: &Press) -> bool {
        self.latest.get(press.byte).is_some_and(|byte| byte & press.mask != 0)
    }

    /// The buttons held now.
    pub fn down(&self) -> Vec<Press> {
        self.buttons.iter().filter(|press| self.held(press)).copied().collect()
    }

    /// Set the two rumble motors (0 stops them). The DualSense's USB output
    /// report: id 0x02, then flags 0x03 ("compatible vibration": the classic
    /// two-motor rumble rather than haptic audio), then the right (small) and left
    /// (large) motor strengths. Whether the adapter passes it on to the pad behind
    /// it is what `buzz` tests.
    pub fn rumble(&self, small: u8, large: u8) -> io::Result<()> {
        self.device.rumble(small, large)
    }
}

/// Rumble patterns on a handle of their own, played on their own thread, so a
/// pattern keeps its timing while the caller is busy (transcribing, say). The
/// handle is opened when first needed and again after a failed write, which is
/// what a pad that went away and came back looks like.
pub struct Rumbler {
    pad: (u16, u16),
    device: std::sync::Arc<std::sync::Mutex<Option<Device>>>,
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
                if let Some(pad) = handle.as_ref() {
                    if pad.rumble(small, large).is_err() {
                        *handle = None;
                    }
                }
            }
        });
    }
}

/// One short pulse on the pad `id` (`vid:pid` or `xinput`), to see whether
/// rumble reaches it at all.
pub fn buzz(id: &str) -> io::Result<()> {
    let (vid, pid) = split(id)?;
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

/// `wow-companion pads <id>`: every button of that pad going down and up, by its
/// bit, to see what the pad says its buttons are.
pub fn watch(id: &str) -> io::Result<()> {
    let (vid, pid) = split(id)?;
    let mut pad = Pad::open(vid, pid)?;
    let report = pad.report.map(|id| format!(" in report {id:#04x}")).unwrap_or_default();
    println!("{} buttons on {vid:04x}:{pid:04x}{report}; press them", pad.buttons.len());
    let mut before: Vec<Press> = Vec::new();
    loop {
        pad.refresh()?;
        let now = pad.down();
        for press in now.iter().filter(|press| !before.contains(press)) {
            println!("{press} down");
        }
        for press in before.iter().filter(|press| !now.contains(press)) {
            println!("{press} up");
        }
        before = now;
        thread::sleep(POLL);
    }
}

/// The game controllers attached now (HID usage joystick or gamepad): vid, pid,
/// product name. One entry per pad, though a pad may expose several interfaces.
pub fn gamepads() -> io::Result<Vec<(u16, u16, String)>> {
    let api = HidApi::new().map_err(|err| io::Error::other(err.to_string()))?;
    let mut found: Vec<(u16, u16, String)> = Vec::new();
    for device in api.device_list() {
        // an Xbox pad's HID face (no Guide, triggers merged): it is read by XInput
        let shim = device.path().to_string_lossy().to_ascii_uppercase().contains("&IG_");
        if device.usage_page() == 1 && matches!(device.usage(), 4 | 5) && !shim {
            let entry = (device.vendor_id(), device.product_id(), device.product_string().unwrap_or("?").to_string());
            if !found.iter().any(|(vid, pid, _)| (*vid, *pid) == (entry.0, entry.1)) {
                found.push(entry);
            }
        }
    }
    if xinput::connected().is_some() {
        found.push((XINPUT.0, XINPUT.1, "Xbox controller (XInput)".to_string()));
    }
    Ok(found)
}

/// `vid:pid` as numbers, like `054c:0ce6`.
pub fn split(id: &str) -> io::Result<(u16, u16)> {
    if id.eq_ignore_ascii_case("xinput") {
        return Ok(XINPUT);
    }
    let (vid, pid) = id
        .split_once(':')
        .ok_or_else(|| io::Error::other("expected vid:pid, like 054c:0ce6"))?;
    Ok((hex(vid)?, hex(pid)?))
}

fn hex(text: &str) -> io::Result<u16> {
    u16::from_str_radix(text.trim_start_matches("0x"), 16)
        .map_err(|_| io::Error::other(format!("{text:?} isn't hex")))
}

/// A controller to read: raw HID, or XInput turned into a small report.
enum Device {
    Hid(HidDevice),
    XInput(xinput::Reader),
}

impl Device {
    fn read(&mut self, buffer: &mut [u8], timeout_ms: i32) -> io::Result<usize> {
        match self {
            Device::Hid(device) => device.read_timeout(buffer, timeout_ms).map_err(|err| io::Error::other(err.to_string())),
            Device::XInput(reader) => reader.read(buffer, timeout_ms),
        }
    }

    /// The DualSense's USB output report for HID: id 0x02, then flags 0x03
    /// ("compatible vibration": the classic two-motor rumble rather than haptic
    /// audio), then the right (small) and left (large) motor strengths.
    fn rumble(&self, small: u8, large: u8) -> io::Result<()> {
        match self {
            Device::Hid(device) => {
                let mut report = [0u8; 48];
                report[0] = 0x02;
                report[1] = 0x03;
                report[3] = small;
                report[4] = large;
                device.write(&report).map(|_| ()).map_err(|err| io::Error::other(err.to_string()))
            }
            Device::XInput(reader) => reader.rumble(small, large),
        }
    }
}

fn open(vid: u16, pid: u16) -> io::Result<Device> {
    if (vid, pid) == XINPUT {
        return xinput::Reader::open().map(Device::XInput);
    }
    open_hid(vid, pid).map(Device::Hid)
}

fn open_hid(vid: u16, pid: u16) -> io::Result<HidDevice> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_is_its_setting_or_the_layouts_default() {
        let set = bound("talk", Some("10:0x20 PADPADDLE2"), 0x054c, EDGE).unwrap().unwrap();
        assert_eq!(set, Bound { press: Press { byte: 10, mask: 0x20 }, name: "PADPADDLE2".into() });
        assert_eq!(Bound::parse(&set.spec()).unwrap(), set);
        let minus = bound("talk", None, 0x054c, 0x0ce6).unwrap().unwrap();
        assert_eq!(minus.spec(), "9:0x10 PADSOCIAL");
        let (vid, pid) = XINPUT;
        assert_eq!(bound("talk", None, vid, pid).unwrap().unwrap().spec(), "1:0x04 PADSYSTEM");
        assert_eq!(bound("r2", None, vid, pid).unwrap().unwrap().spec(), "3:0x01 PADRTRIGGER");
        // another pad has none until they are pressed in the game
        assert_eq!(bound("talk", None, 0x2dc8, 0x3106).unwrap(), None);
        assert_eq!(split("xinput").unwrap(), XINPUT);
        assert_eq!(split("ffff:0001").unwrap(), XINPUT);
    }

    #[test]
    fn every_default_is_a_button_of_its_layout() {
        for (_, press, _) in SONY_KEYS {
            assert!(SONY_BUTTONS.contains(press));
        }
        for (_, press, _) in xinput::KEYS {
            assert!(xinput::BUTTONS.contains(press));
        }
    }
}
