//! While this process reads the screen, the game stays composited.
//!
//! A game hands its frames straight to the display (independent flip) while
//! nothing covers it. Every screen capture (duplication.rs) made Windows switch
//! WoW onto the compositor for it and back, and the switches cost frames: 120 fps
//! fell to 116 with the strip read twice a second, at any graphics setting, potato
//! included (measured 2026-11-12). A 2x2 window of ours at the main screen's
//! top-left, nearly transparent, click-through, never focused and always on top,
//! keeps the game composited the whole time instead: 120 fps while reading. The
//! cost is that a frame reaches the screen up to one refresh later.
//!
//! It is made with the capture session and lives as long as this process: the
//! companion's whole run, or a `strip` command's few seconds.

use std::{sync::Once, thread};

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{BLACK_BRUSH, GetStockObject, HBRUSH};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, LWA_ALPHA, MSG, RegisterClassW, SW_SHOWNOACTIVATE,
    SetLayeredWindowAttributes, ShowWindow, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    WS_EX_TRANSPARENT, WS_POPUP,
};
use windows::core::w;

// of 255: 2, as the measured test had it (WinForms' Opacity 0.01)
const ALPHA: u8 = 2;

unsafe extern "system" fn procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe { DefWindowProcW(window, message, wparam, lparam) }
}

/// Put the window up, once per process, on a thread of its own that answers its
/// messages (a window that does not is shown as a ghost by Windows).
pub(crate) fn hold() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        thread::spawn(|| {
            if let Err(err) = show() {
                eprintln!("the window that keeps the game composited was not made: {err}");
            }
        });
    });
}

fn show() -> windows::core::Result<()> {
    // SAFETY: a plain window of this thread's own, and its message loop
    unsafe {
        let instance = GetModuleHandleW(None)?.into();
        let class = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: instance,
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            lpszClassName: w!("WowCompanionComposited"),
            ..Default::default()
        };
        RegisterClassW(&class);
        // never activated, no taskbar button, always on top, layered, click-through
        let style = WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT;
        let window =
            CreateWindowExW(style, w!("WowCompanionComposited"), w!("WoW Companion"), WS_POPUP, 0, 0, 2, 2, None, None, Some(instance), None)?;
        SetLayeredWindowAttributes(window, COLORREF(0), ALPHA, LWA_ALPHA)?;
        let _ = ShowWindow(window, SW_SHOWNOACTIVATE);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            DispatchMessageW(&msg);
        }
        Ok(())
    }
}
