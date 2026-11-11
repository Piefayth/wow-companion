//! The watcher's icon in the notification area: green while the companion is
//! listening, amber while paused, grey while it waits for WoW (or is starting),
//! red after it gave up restarting a companion that kept stopping. Its menu:
//! Pause/Resume listening, Open setup, Show log, Quit.
//!
//! Windows only for now, straight on the Win32 API (Shell_NotifyIconW, a hidden
//! window for its messages, a popup menu), as src/strip.rs does for the
//! screen: no GUI library to compile. Elsewhere `run` says "not supported yet"
//! and the watcher works without an icon.

use super::*;
use std::sync::mpsc::Sender;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Look {
    Waiting,
    Starting,
    Listening,
    Paused,
    GaveUp,
}

impl Look {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Look::Waiting => "waiting",
            Look::Starting => "starting",
            Look::Listening => "listening",
            Look::Paused => "paused",
            Look::GaveUp => "gave-up",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum Choice {
    TogglePause,
    OpenSetup,
    ShowLog,
    Quit,
}

/// Show the icon and run its messages on this thread until `close`. Choices
/// from the menu go to `choices`.
pub(crate) fn run(choices: Sender<Choice>) -> io::Result<()> {
    imp::run(choices)
}

/// Change the icon and its tooltip (any thread).
pub(crate) fn show(look: Look, tip: &str) {
    imp::show(look, tip)
}

/// Take the icon away and end `run` (any thread).
pub(crate) fn close() {
    imp::close()
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::{ffi::c_void, sync::atomic::AtomicIsize};

    const WM_APP: u32 = 0x8000;
    const CALLBACK: u32 = WM_APP + 1;
    const REFRESH: u32 = WM_APP + 2;
    const CLOSE: u32 = WM_APP + 3;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_RBUTTONUP: u32 = 0x0205;
    const NIM_ADD: u32 = 0;
    const NIM_MODIFY: u32 = 1;
    const NIM_DELETE: u32 = 2;
    const NIF_MESSAGE: u32 = 1;
    const NIF_ICON: u32 = 2;
    const NIF_TIP: u32 = 4;
    const MF_STRING: u32 = 0;
    const MF_SEPARATOR: u32 = 0x800;
    const TPM_RETURNCMD: u32 = 0x100;
    const TPM_NONOTIFY: u32 = 0x80;
    const TPM_RIGHTBUTTON: u32 = 0x2;

    #[repr(C)]
    struct Guid {
        a: u32,
        b: u16,
        c: u16,
        d: [u8; 8],
    }

    #[repr(C)]
    pub(super) struct NotifyIconData {
        size: u32,
        window: isize,
        id: u32,
        flags: u32,
        callback: u32,
        icon: isize,
        tip: [u16; 128],
        state: u32,
        state_mask: u32,
        info: [u16; 256],
        version: u32,
        info_title: [u16; 64],
        info_flags: u32,
        guid: Guid,
        balloon_icon: isize,
    }

    #[repr(C)]
    struct WindowClass {
        style: u32,
        procedure: extern "system" fn(isize, u32, usize, isize) -> isize,
        class_extra: i32,
        window_extra: i32,
        instance: isize,
        icon: isize,
        cursor: isize,
        background: isize,
        menu_name: *const u16,
        class_name: *const u16,
    }

    #[repr(C)]
    struct Point {
        x: i32,
        y: i32,
    }

    #[repr(C)]
    struct Msg {
        window: isize,
        message: u32,
        wparam: usize,
        lparam: isize,
        time: u32,
        point: Point,
        private: u32,
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetModuleHandleW(name: *const u16) -> isize;
    }
    #[link(name = "user32")]
    unsafe extern "system" {
        fn RegisterClassW(class: *const WindowClass) -> u16;
        fn CreateWindowExW(
            ex_style: u32,
            class: *const u16,
            name: *const u16,
            style: u32,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            parent: isize,
            menu: isize,
            instance: isize,
            param: *const c_void,
        ) -> isize;
        fn DefWindowProcW(window: isize, message: u32, wparam: usize, lparam: isize) -> isize;
        fn GetMessageW(msg: *mut Msg, window: isize, min: u32, max: u32) -> i32;
        fn TranslateMessage(msg: *const Msg) -> i32;
        fn DispatchMessageW(msg: *const Msg) -> isize;
        fn PostMessageW(window: isize, message: u32, wparam: usize, lparam: isize) -> i32;
        fn PostQuitMessage(code: i32);
        fn DestroyWindow(window: isize) -> i32;
        fn CreatePopupMenu() -> isize;
        fn AppendMenuW(menu: isize, flags: u32, id: usize, text: *const u16) -> i32;
        fn TrackPopupMenu(menu: isize, flags: u32, x: i32, y: i32, reserved: i32, window: isize, rect: *const c_void) -> i32;
        fn DestroyMenu(menu: isize) -> i32;
        fn GetCursorPos(point: *mut Point) -> i32;
        fn SetForegroundWindow(window: isize) -> i32;
        fn CreateIcon(instance: isize, width: i32, height: i32, planes: u8, bits: u8, and: *const u8, xor: *const u8) -> isize;
        fn RegisterWindowMessageW(name: *const u16) -> u32;
    }
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn Shell_NotifyIconW(message: u32, data: *mut NotifyIconData) -> i32;
    }

    static WINDOW: AtomicIsize = AtomicIsize::new(0);
    static TASKBAR_CREATED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

    struct State {
        look: Look,
        tip: String,
        icons: Vec<(Look, isize)>,
        choices: Option<Sender<Choice>>,
    }

    static STATE: Mutex<State> = Mutex::new(State { look: Look::Waiting, tip: String::new(), icons: Vec::new(), choices: None });

    fn state() -> std::sync::MutexGuard<'static, State> {
        STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    /// A 16x16 dot: `rgb` inside a circle, a darker rim, transparent outside.
    fn dot(instance: isize, rgb: (u8, u8, u8)) -> isize {
        const SIZE: usize = 16;
        let mut and = [0u8; SIZE * 2];
        let mut xor = vec![0u8; SIZE * SIZE * 4];
        for y in 0..SIZE {
            for x in 0..SIZE {
                let (dx, dy) = (x as f32 - 7.5, y as f32 - 7.5);
                let distance = (dx * dx + dy * dy).sqrt();
                let at = (y * SIZE + x) * 4;
                if distance > 7.0 {
                    // transparent: the AND bit set, the colour black
                    and[y * 2 + x / 8] |= 0x80 >> (x % 8);
                    continue;
                }
                let shade = if distance > 5.6 { 0.6 } else { 1.0 };
                xor[at] = (rgb.2 as f32 * shade) as u8;
                xor[at + 1] = (rgb.1 as f32 * shade) as u8;
                xor[at + 2] = (rgb.0 as f32 * shade) as u8;
                xor[at + 3] = 255;
            }
        }
        // SAFETY: 16x16 masks of the sizes CreateIcon reads (1 bpp AND, 32 bpp XOR)
        unsafe { CreateIcon(instance, SIZE as i32, SIZE as i32, 1, 32, and.as_ptr(), xor.as_ptr()) }
    }

    fn colour(look: Look) -> (u8, u8, u8) {
        match look {
            Look::Listening => (60, 179, 113),
            Look::Paused => (230, 170, 40),
            Look::Waiting => (140, 140, 140),
            Look::Starting => (190, 190, 190),
            Look::GaveUp => (220, 60, 50),
        }
    }

    fn data(window: isize) -> NotifyIconData {
        let state = state();
        let icon = state.icons.iter().find(|(look, _)| *look == state.look).map(|(_, icon)| *icon).unwrap_or(0);
        // SAFETY: a plain C struct; zero is a valid value for every field
        let mut data: NotifyIconData = unsafe { std::mem::zeroed() };
        data.size = std::mem::size_of::<NotifyIconData>() as u32;
        data.window = window;
        data.id = 1;
        data.flags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        data.callback = CALLBACK;
        data.icon = icon;
        let tip: Vec<u16> = state.tip.encode_utf16().take(127).collect();
        data.tip[..tip.len()].copy_from_slice(&tip);
        data
    }

    fn notify(message: u32) {
        let window = WINDOW.load(Ordering::SeqCst);
        if window == 0 {
            return;
        }
        let mut data = data(window);
        // SAFETY: a filled, sized NOTIFYICONDATAW for our window
        unsafe { Shell_NotifyIconW(message, &mut data) };
    }

    fn menu(window: isize) {
        let paused = state().look == Look::Paused;
        let items: [(usize, &str); 4] = [
            (1, if paused { "Resume listening" } else { "Pause listening" }),
            (2, "Open setup"),
            (3, "Show log"),
            (4, "Quit"),
        ];
        // SAFETY: a popup menu made, shown and destroyed here; the strings live
        // until AppendMenuW has copied them
        let chosen = unsafe {
            let menu = CreatePopupMenu();
            for (id, text) in items {
                if id == 4 {
                    AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                }
                let text = wide(text);
                AppendMenuW(menu, MF_STRING, id, text.as_ptr());
            }
            let mut point = Point { x: 0, y: 0 };
            GetCursorPos(&mut point);
            // without this the menu does not close when clicking elsewhere
            SetForegroundWindow(window);
            let chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, point.x, point.y, 0, window, std::ptr::null());
            PostMessageW(window, 0, 0, 0);
            DestroyMenu(menu);
            chosen
        };
        let choice = match chosen {
            1 => Choice::TogglePause,
            2 => Choice::OpenSetup,
            3 => Choice::ShowLog,
            4 => Choice::Quit,
            _ => return,
        };
        if let Some(choices) = &state().choices {
            let _ = choices.send(choice);
        }
    }

    extern "system" fn procedure(window: isize, message: u32, wparam: usize, lparam: isize) -> isize {
        match message {
            CALLBACK => {
                let mouse = (lparam as u32) & 0xFFFF;
                if mouse == WM_RBUTTONUP || mouse == WM_LBUTTONUP {
                    menu(window);
                }
                0
            }
            REFRESH => {
                notify(NIM_MODIFY);
                0
            }
            CLOSE => {
                notify(NIM_DELETE);
                // SAFETY: our own window, from its own thread
                unsafe {
                    DestroyWindow(window);
                    PostQuitMessage(0);
                }
                0
            }
            // Explorer restarted: the icon has to be added again
            other if other != 0 && other == TASKBAR_CREATED.load(Ordering::SeqCst) => {
                notify(NIM_ADD);
                0
            }
            // SAFETY: the default handling for everything else
            _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
        }
    }

    pub(super) fn run(choices: Sender<Choice>) -> io::Result<()> {
        let class = wide("WowCompanionTray");
        // SAFETY: registers a class and makes a hidden window for the icon's
        // messages; the strings outlive the calls that read them
        let window = unsafe {
            let instance = GetModuleHandleW(std::ptr::null());
            {
                let mut state = state();
                state.choices = Some(choices);
                state.icons = [Look::Waiting, Look::Starting, Look::Listening, Look::Paused, Look::GaveUp]
                    .into_iter()
                    .map(|look| (look, dot(instance, colour(look))))
                    .collect();
                if state.tip.is_empty() {
                    state.tip = "WoW Companion".into();
                }
            }
            let definition = WindowClass {
                style: 0,
                procedure,
                class_extra: 0,
                window_extra: 0,
                instance,
                icon: 0,
                cursor: 0,
                background: 0,
                menu_name: std::ptr::null(),
                class_name: class.as_ptr(),
            };
            RegisterClassW(&definition);
            let title = wide("WoW Companion");
            let window = CreateWindowExW(0, class.as_ptr(), title.as_ptr(), 0, 0, 0, 0, 0, 0, 0, instance, std::ptr::null());
            if window == 0 {
                return Err(io::Error::last_os_error());
            }
            TASKBAR_CREATED.store(RegisterWindowMessageW(wide("TaskbarCreated").as_ptr()), Ordering::SeqCst);
            window
        };
        WINDOW.store(window, Ordering::SeqCst);
        notify(NIM_ADD);
        // SAFETY: the standard message loop for this thread's window
        unsafe {
            let mut msg: Msg = std::mem::zeroed();
            while GetMessageW(&mut msg, 0, 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        WINDOW.store(0, Ordering::SeqCst);
        Ok(())
    }

    pub(super) fn show(look: Look, tip: &str) {
        {
            let mut state = state();
            state.look = look;
            state.tip = tip.to_string();
        }
        let window = WINDOW.load(Ordering::SeqCst);
        if window != 0 {
            // SAFETY: posting to our own window; handled on its thread
            unsafe { PostMessageW(window, REFRESH, 0, 0) };
        }
    }

    pub(super) fn close() {
        let window = WINDOW.load(Ordering::SeqCst);
        if window != 0 {
            // SAFETY: posting to our own window; handled on its thread
            unsafe { PostMessageW(window, CLOSE, 0, 0) };
        }
    }

    #[cfg(all(test, target_pointer_width = "64"))]
    #[test]
    fn the_notify_struct_has_the_size_windows_expects() {
        assert_eq!(std::mem::size_of::<NotifyIconData>(), 976);
    }
}

#[cfg(not(windows))]
mod imp {
    use super::*;
    pub(super) fn run(_choices: Sender<Choice>) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "a tray icon is not supported on this platform yet"))
    }
    pub(super) fn show(_look: Look, _tip: &str) {}
    pub(super) fn close() {}
}
