//! Xbox controllers (and anything in Xbox mode, like switch2connect's), through
//! XInput. Windows drives these itself; their HID face (`045e:02ff`, "IG_" in
//! the path) leaves out the Guide button, joins the triggers on one axis and
//! makes the d-pad a hat, so HID is no good for them.
//!
//! The state is turned into a 4-byte report so the rest of the crate (`held`,
//! `down`, setting a key) works on it as on any HID pad: byte 0 and 1 are
//! XInput's button word (low, high), byte 2 and 3 are the left and right trigger
//! as on/off. Guide is only in the undocumented `XInputGetStateEx` (ordinal 100
//! of xinput1_4.dll), which every Xbox overlay uses.
//!
//! Measured with switch2connect in Xbox mode: home = Guide (0x0400),
//! minus = View (0x0020), plus = Menu (0x0010), the d-pad as four buttons, L/R =
//! LB/RB, ZL/ZR = triggers at 0 or 255, and rumble through XInputSetState is felt.

use crate::Press;
use std::{
    ffi::c_void,
    io,
    sync::OnceLock,
    thread,
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct State {
    packet: u32,
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    thumbs: [i16; 4],
}

#[repr(C)]
struct Vibration {
    left: u16,
    right: u16,
}

type GetState = unsafe extern "system" fn(u32, *mut State) -> u32;
type SetState = unsafe extern "system" fn(u32, *mut Vibration) -> u32;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(name: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
}

struct Api {
    get: GetState,
    set: SetState,
}

fn api() -> Option<&'static Api> {
    static API: OnceLock<Option<Api>> = OnceLock::new();
    API.get_or_init(|| unsafe {
        let name: Vec<u16> = "xinput1_4.dll\0".encode_utf16().collect();
        let module = LoadLibraryW(name.as_ptr());
        if module.is_null() {
            return None;
        }
        // by ordinal: GetProcAddress takes a small integer in place of a name
        let mut get = GetProcAddress(module, 100 as *const u8);
        if get.is_null() {
            get = GetProcAddress(module, b"XInputGetState\0".as_ptr());
        }
        let set = GetProcAddress(module, b"XInputSetState\0".as_ptr());
        if get.is_null() || set.is_null() {
            return None;
        }
        Some(Api {
            get: std::mem::transmute::<*mut c_void, GetState>(get),
            set: std::mem::transmute::<*mut c_void, SetState>(set),
        })
    })
    .as_ref()
}

fn state(slot: u32) -> Option<State> {
    let api = api()?;
    let mut state = State::default();
    (unsafe { (api.get)(slot, &mut state) } == 0).then_some(state)
}

/// The first XInput slot with a controller in it.
pub fn connected() -> Option<u32> {
    (0..4).find(|slot| state(*slot).is_some())
}

/// A trigger counts as pressed past a quarter of its travel.
const TRIGGER: u8 = 64;

pub struct Reader {
    slot: u32,
    last: Option<u32>,
}

impl Reader {
    pub fn open() -> io::Result<Self> {
        let slot = connected().ok_or_else(|| io::Error::other("no Xbox (XInput) controller connected"))?;
        Ok(Reader { slot, last: None })
    }

    /// The state as a 4-byte report when it changed since the last read, else 0
    /// bytes after waiting up to `timeout_ms` for a change. A controller that went
    /// away is an error, as an unplugged HID pad is.
    pub fn read(&mut self, buffer: &mut [u8], timeout_ms: i32) -> io::Result<usize> {
        let until = Instant::now() + Duration::from_millis(timeout_ms.max(0) as u64);
        loop {
            let state = state(self.slot).ok_or_else(|| io::Error::other("the Xbox controller is not connected"))?;
            if self.last != Some(state.packet) && buffer.len() >= 4 {
                self.last = Some(state.packet);
                let [low, high] = state.buttons.to_le_bytes();
                buffer[..4].copy_from_slice(&[
                    low,
                    high,
                    u8::from(state.left_trigger >= TRIGGER),
                    u8::from(state.right_trigger >= TRIGGER),
                ]);
                return Ok(4);
            }
            if Instant::now() >= until {
                return Ok(0);
            }
            thread::sleep(Duration::from_millis(4));
        }
    }

    /// The two motors, 0..255 like the DualSense's: left is the large one.
    pub fn rumble(&self, small: u8, large: u8) -> io::Result<()> {
        let api = api().ok_or_else(|| io::Error::other("XInput is not available"))?;
        let mut vibration = Vibration { left: u16::from(large) * 257, right: u16::from(small) * 257 };
        match unsafe { (api.set)(self.slot, &mut vibration) } {
            0 => Ok(()),
            code => Err(io::Error::other(format!("XInputSetState failed ({code})"))),
        }
    }
}

/// The bits that are buttons in the report above: the button word (d-pad
/// up/down/left/right, Menu, View, the stick clicks; LB, RB, Guide, A, B, X, Y)
/// and the two triggers.
pub const BUTTONS: [Press; 17] = [
    Press { byte: 0, mask: 0x01 },
    Press { byte: 0, mask: 0x02 },
    Press { byte: 0, mask: 0x04 },
    Press { byte: 0, mask: 0x08 },
    Press { byte: 0, mask: 0x10 },
    Press { byte: 0, mask: 0x20 },
    Press { byte: 0, mask: 0x40 },
    Press { byte: 0, mask: 0x80 },
    Press { byte: 1, mask: 0x01 },
    Press { byte: 1, mask: 0x02 },
    Press { byte: 1, mask: 0x04 },
    Press { byte: 1, mask: 0x10 },
    Press { byte: 1, mask: 0x20 },
    Press { byte: 1, mask: 0x40 },
    Press { byte: 1, mask: 0x80 },
    Press { byte: 2, mask: 0x01 },
    Press { byte: 3, mask: 0x01 },
];

/// The keys on an Xbox pad: Guide (WoW ignores it) and the shoulders, LT+RT
/// Quick and LB+RB dictation.
pub const KEYS: super::Defaults = {
    const L1: (Press, &str) = (Press { byte: 1, mask: 0x01 }, "PADLSHOULDER");
    const R1: (Press, &str) = (Press { byte: 1, mask: 0x02 }, "PADRSHOULDER");
    const L2: (Press, &str) = (Press { byte: 2, mask: 0x01 }, "PADLTRIGGER");
    const R2: (Press, &str) = (Press { byte: 3, mask: 0x01 }, "PADRTRIGGER");
    &[
        ("talk", &[(Press { byte: 1, mask: 0x04 }, "PADSYSTEM")]),
        ("l1", &[L1]),
        ("l2", &[L2]),
        ("r1", &[R1]),
        ("r2", &[R2]),
        ("quick", &[L2, R2]),
        ("say", &[L1, R1]),
    ]
};
