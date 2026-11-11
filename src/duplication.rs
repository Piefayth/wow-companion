//! The strip's corner, read through DXGI Desktop Duplication in the colours the
//! game drew, whatever the display's mode.
//!
//! Why not GDI: a BitBlt of the desktop made the compositor wait on the game
//! (7.8 ms a look, p95 15.8, max 287, twice a second: the stutter the player felt
//! at every data read). Duplication hands over the frame the compositor already
//! made: 1.5 ms a look.
//!
//! Why the mode matters: on an HDR desktop Windows composes SDR content (the
//! game's UI) in scRGB, linear, with sRGB white raised to the display's SDR
//! white level. The legacy `DuplicateOutput` hands that back as 8 bits without
//! undoing the raise: the strip's 12 34 56 read as 25 5A 90 (3x in linear, the
//! 240-nit white level), C0 FF EE clipped to FF FF FF (measured 2026-11-11). So
//! frames are taken in whichever format the desktop is in (`DuplicateOutput1`
//! offering FP16 and BGRA8): an 8-bit SDR frame is the game's bytes as they are;
//! an FP16 scRGB frame is divided by the SDR white level (scRGB 1.0 = 80 nits),
//! sRGB-encoded and rounded back to the byte the game drew. Proven against GDI
//! on strips of 16 to 6000 bytes on an HDR10 desktop at 240 nits: every cell
//! exact (2026-11-11).

use crate::strip::{CELL, COLS, FULL_HEIGHT, Shot};
use std::{io, sync::Mutex};
use windows::{
    Win32::Devices::Display::{
        DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL, DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
        DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_SDR_WHITE_LEVEL,
        DISPLAYCONFIG_SOURCE_DEVICE_NAME, DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QDC_ONLY_ACTIVE_PATHS,
        QueryDisplayConfig,
    },
    Win32::Foundation::{ERROR_SUCCESS, HMODULE},
    Win32::Graphics::{
        Direct3D::D3D_DRIVER_TYPE_UNKNOWN,
        Direct3D11::{
            D3D11_BOX, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE,
            D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING, D3D11CreateDevice, ID3D11Device,
            ID3D11DeviceContext, ID3D11Texture2D,
        },
        Dxgi::{
            Common::{
                DXGI_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_MODE_ROTATION_IDENTITY,
                DXGI_MODE_ROTATION_UNSPECIFIED, DXGI_SAMPLE_DESC,
            },
            CreateDXGIFactory1, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO, IDXGIAdapter,
            IDXGIFactory1, IDXGIOutput5, IDXGIOutput6, IDXGIOutputDuplication, IDXGIResource,
        },
    },
    Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext},
    core::{Error, HRESULT, Interface},
};

const WIDTH: usize = CELL * COLS;

struct Session {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    /// the output's GDI device name (\\.\DISPLAY1...), to read its white level by
    device_name: [u16; 32],
    /// the corner of the newest desktop frame taken, kept on the GPU in the
    /// frames' format, CPU-readable: a look while the desktop is unchanged reads it
    staging: Option<(DXGI_FORMAT, ID3D11Texture2D)>,
    /// DISPLAYCONFIG_SDR_WHITE_LEVEL.SDRWhiteLevel (nits = value / 1000 * 80),
    /// read again at every look: the brightness slider moves it without a mode change
    white_level: u32,
    /// FP16 bits -> the byte the game drew, at `white_level`
    to_byte: Vec<u8>,
}

// SAFETY: the D3D11 device and DXGI objects are free-threaded; the one immediate
// context is only used under SESSION's lock.
unsafe impl Send for Session {}

static SESSION: Mutex<Option<Session>> = Mutex::new(None);

fn failed(what: &str, error: Error) -> io::Error {
    io::Error::other(format!("{what}: {error}"))
}

fn refused(why: &str) -> Error {
    Error::new(HRESULT(-1), why)
}

/// The SDR white level of the display showing the GDI device `device_name`,
/// from the active display paths.
unsafe fn sdr_white_level(device_name: &[u16; 32]) -> io::Result<u32> {
    unsafe {
        let (mut paths, mut modes) = (0u32, 0u32);
        let status = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut paths, &mut modes);
        if status != ERROR_SUCCESS {
            return Err(io::Error::other(format!("GetDisplayConfigBufferSizes: {status:?}")));
        }
        let mut path_info = vec![DISPLAYCONFIG_PATH_INFO::default(); paths as usize];
        let mut mode_info = vec![DISPLAYCONFIG_MODE_INFO::default(); modes as usize];
        let status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut paths, path_info.as_mut_ptr(), &mut modes, mode_info.as_mut_ptr(), None);
        if status != ERROR_SUCCESS {
            return Err(io::Error::other(format!("QueryDisplayConfig: {status:?}")));
        }
        for path in &path_info[..paths as usize] {
            let mut source = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
            source.header = DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
                size: size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32,
                adapterId: path.sourceInfo.adapterId,
                id: path.sourceInfo.id,
            };
            if DisplayConfigGetDeviceInfo(&mut source.header) != 0 || &source.viewGdiDeviceName != device_name {
                continue;
            }
            let mut white = DISPLAYCONFIG_SDR_WHITE_LEVEL {
                header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                    r#type: DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL,
                    size: size_of::<DISPLAYCONFIG_SDR_WHITE_LEVEL>() as u32,
                    adapterId: path.targetInfo.adapterId,
                    id: path.targetInfo.id,
                },
                SDRWhiteLevel: 0,
            };
            let status = DisplayConfigGetDeviceInfo(&mut white.header);
            if status != 0 {
                return Err(io::Error::other(format!("the SDR white level could not be read ({status})")));
            }
            return Ok(white.SDRWhiteLevel);
        }
        Err(io::Error::other("no active display path shows the primary screen"))
    }
}

/// The primary output (desktop origin 0,0), its adapter's device, and a
/// duplication of it in the desktop's own format.
unsafe fn open() -> io::Result<Session> {
    unsafe {
        // DuplicateOutput1 is for per-monitor DPI-aware processes, and the strip
        // is read in real pixels. Refused when already set: not an error.
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let factory: IDXGIFactory1 = CreateDXGIFactory1().map_err(|e| failed("no DXGI factory", e))?;
        let mut adapter_index = 0;
        loop {
            let adapter = factory
                .EnumAdapters1(adapter_index)
                .map_err(|e| failed("no graphics adapter shows the primary screen", e))?;
            let mut output_index = 0;
            while let Ok(output) = adapter.EnumOutputs(output_index) {
                output_index += 1;
                let output6: IDXGIOutput6 = output.cast().map_err(|e| failed("the output has no IDXGIOutput6", e))?;
                let desc = output6.GetDesc1().map_err(|e| failed("the output could not describe itself", e))?;
                if (desc.DesktopCoordinates.left, desc.DesktopCoordinates.top) != (0, 0) {
                    continue;
                }
                if desc.Rotation != DXGI_MODE_ROTATION_IDENTITY && desc.Rotation != DXGI_MODE_ROTATION_UNSPECIFIED {
                    return Err(io::Error::other("the primary screen is rotated; the strip reader expects it upright"));
                }
                let mut device: Option<ID3D11Device> = None;
                let mut context: Option<ID3D11DeviceContext> = None;
                let base: IDXGIAdapter = adapter.cast().map_err(|e| failed("the adapter", e))?;
                D3D11CreateDevice(
                    &base,
                    D3D_DRIVER_TYPE_UNKNOWN,
                    HMODULE::default(),
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    None,
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    Some(&mut context),
                )
                .map_err(|e| failed("no Direct3D device on the primary screen's adapter", e))?;
                let device = device.ok_or_else(|| io::Error::other("no device"))?;
                let context = context.ok_or_else(|| io::Error::other("no device context"))?;
                let output5: IDXGIOutput5 = output.cast().map_err(|e| failed("the output has no IDXGIOutput5", e))?;
                let duplication = output5
                    .DuplicateOutput1(&device, 0, &[DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_B8G8R8A8_UNORM])
                    .map_err(|e| failed("the screen cannot be duplicated", e))?;
                let white_level = sdr_white_level(&desc.DeviceName)?;
                return Ok(Session {
                    device,
                    context,
                    duplication,
                    device_name: desc.DeviceName,
                    staging: None,
                    white_level,
                    to_byte: byte_table(white_level),
                });
            }
            adapter_index += 1;
        }
    }
}

/// An IEEE half float.
fn half(bits: u16) -> f32 {
    let sign = if bits & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exponent = ((bits >> 10) & 0x1f) as i32;
    let mantissa = (bits & 0x3ff) as f32;
    match exponent {
        0 => sign * mantissa * 2f32.powi(-24),
        31 => f32::NAN,
        e => sign * (1.0 + mantissa / 1024.0) * 2f32.powi(e - 15),
    }
}

/// The sRGB byte an SDR value became in scRGB (linear, 1.0 = 80 nits, sRGB
/// white raised to `white_nits`).
fn srgb_byte(scrgb: f32, white_nits: f32) -> u8 {
    let linear = (scrgb * 80.0 / white_nits).clamp(0.0, 1.0);
    let encoded = if linear <= 0.003_130_8 { 12.92 * linear } else { 1.055 * linear.powf(1.0 / 2.4) - 0.055 };
    (encoded * 255.0).round() as u8
}

/// For every FP16 value, the byte it was before Windows raised it to `white_level`.
fn byte_table(white_level: u32) -> Vec<u8> {
    let white_nits = white_level as f32 / 1000.0 * 80.0;
    (0..=u16::MAX).map(|bits| srgb_byte(half(bits), white_nits)).collect()
}

/// The newest desktop frame's corner, if the desktop changed, into the staging
/// texture (a copy on the GPU; the frame is released at once).
unsafe fn refresh(session: &mut Session, wait_ms: u32) -> windows::core::Result<()> {
    unsafe {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;
        match session.duplication.AcquireNextFrame(wait_ms, &mut info, &mut resource) {
            Ok(()) => {}
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(()),
            Err(e) => return Err(e),
        }
        let copied = (|| -> windows::core::Result<()> {
            let frame: ID3D11Texture2D = resource.ok_or_else(Error::empty)?.cast()?;
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            frame.GetDesc(&mut desc);
            let (w, h, format) = (desc.Width as usize, desc.Height as usize, desc.Format);
            if format != DXGI_FORMAT_R16G16B16A16_FLOAT && format != DXGI_FORMAT_B8G8R8A8_UNORM {
                return Err(refused(&format!("the desktop's frames are in DXGI_FORMAT {}, which the strip reader does not read", format.0)));
            }
            if w < WIDTH || h < FULL_HEIGHT {
                return Err(refused("the screen is smaller than the strip"));
            }
            if session.staging.as_ref().is_none_or(|(have, _)| *have != format) {
                let staging_desc = D3D11_TEXTURE2D_DESC {
                    Width: WIDTH as u32,
                    Height: FULL_HEIGHT as u32,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: format,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_STAGING,
                    BindFlags: 0,
                    CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                    MiscFlags: 0,
                };
                let mut texture: Option<ID3D11Texture2D> = None;
                session.device.CreateTexture2D(&staging_desc, None, Some(&mut texture))?;
                session.staging = Some((format, texture.ok_or_else(Error::empty)?));
            }
            let staging = &session.staging.as_ref().expect("made above").1;
            let corner = D3D11_BOX { left: (w - WIDTH) as u32, top: (h - FULL_HEIGHT) as u32, front: 0, right: w as u32, bottom: h as u32, back: 1 };
            session.context.CopySubresourceRegion(staging, 0, 0, 0, 0, &frame, 0, Some(&corner));
            Ok(())
        })();
        let released = session.duplication.ReleaseFrame();
        copied?;
        released
    }
}

/// The staging corner's bottom `height` rows, in the game's bytes (BGRA, rows top-down).
unsafe fn read(session: &Session, height: usize) -> windows::core::Result<Vec<u8>> {
    unsafe {
        let Some((format, staging)) = &session.staging else {
            return Err(refused("no desktop frame arrived within 500 ms"));
        };
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        session.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
        let mut pixels = vec![0u8; WIDTH * height * 4];
        for (row, out) in (FULL_HEIGHT - height..FULL_HEIGHT).zip(pixels.chunks_exact_mut(WIDTH * 4)) {
            let line = (mapped.pData as *const u8).add(row * mapped.RowPitch as usize);
            if *format == DXGI_FORMAT_B8G8R8A8_UNORM {
                std::ptr::copy_nonoverlapping(line, out.as_mut_ptr(), WIDTH * 4);
            } else {
                let halves = std::slice::from_raw_parts(line as *const u16, WIDTH * 4);
                for (rgba, bgra) in halves.chunks_exact(4).zip(out.chunks_exact_mut(4)) {
                    let byte = |bits: u16| session.to_byte[bits as usize];
                    bgra.copy_from_slice(&[byte(rgba[2]), byte(rgba[1]), byte(rgba[0]), 255]);
                }
            }
        }
        session.context.Unmap(staging, 0);
        Ok(pixels)
    }
}

/// The corner of the primary screen, `height` rows tall and one strip wide, in
/// the game's bytes and real pixels.
pub(crate) fn grab(height: usize) -> io::Result<Shot> {
    let height = height.min(FULL_HEIGHT);
    let mut held = SESSION.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if held.is_none() {
        *held = Some(unsafe { open()? });
    }
    let session = held.as_mut().expect("opened above");
    let white_level = unsafe { sdr_white_level(&session.device_name)? };
    if white_level != session.white_level {
        session.white_level = white_level;
        session.to_byte = byte_table(white_level);
    }
    // the first look waits for the session's first frame; later ones take a new
    // frame if the desktop changed, else the staging corner is current
    let wait_ms = if session.staging.is_none() { 500 } else { 0 };
    match unsafe { refresh(session, wait_ms).and_then(|()| read(session, height)) } {
        Ok(pixels) => Ok(Shot { width: WIDTH, height, pixels }),
        Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
            // a mode change (HDR switched too), a fullscreen switch, the lock
            // screen: this session is over; the next look opens one in the new mode
            *held = None;
            Err(io::Error::other("the screen's duplication was lost (a mode change, fullscreen switch or lock screen); reopening at the next look"))
        }
        Err(e) => Err(failed("the screen could not be read", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn halves_decode() {
        assert_eq!(half(0x3c00), 1.0);
        assert_eq!(half(0x4000), 2.0);
        assert_eq!(half(0x3800), 0.5);
        assert_eq!(half(0x0000), 0.0);
        assert!((half(0x4200) - 3.0).abs() < 1e-6);
    }

    /// Every byte survives Windows' SDR-in-HDR raise when it is undone, at the
    /// FP16 precision the frame has: the inverse is exact for all 256 values.
    #[test]
    fn every_byte_round_trips_through_scrgb_at_fp16_precision() {
        for white_level in [1000u32, 2500, 3000, 6000] {
            let table = byte_table(white_level);
            let white_nits = white_level as f32 / 1000.0 * 80.0;
            for byte in 0..=255u8 {
                let c = byte as f32 / 255.0;
                let linear = if c <= 0.040_45 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) };
                let bits = f32_to_half(linear * white_nits / 80.0);
                assert_eq!(table[bits as usize], byte, "byte {byte} at white level {white_level}");
            }
        }
    }

    /// Round-to-nearest f32 -> half for the positive normal and subnormal range.
    fn f32_to_half(v: f32) -> u16 {
        if v == 0.0 {
            return 0;
        }
        let exponent = v.log2().floor() as i32;
        if exponent < -14 {
            return (v / 2f32.powi(-24)).round() as u16;
        }
        let mantissa = ((v / 2f32.powi(exponent) - 1.0) * 1024.0).round() as u16;
        if mantissa == 1024 {
            return ((exponent + 16) as u16) << 10;
        }
        (((exponent + 15) as u16) << 10) | mantissa
    }
}
