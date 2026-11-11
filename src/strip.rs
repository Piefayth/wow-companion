//! The data strip, read off the screen: the game's one fast way to the PC
//! (`WowCompanion_Strip.Send(text)`, addon/WowCompanion/Strip.lua), read here
//! in the companion.
//!
//! Layout, as Strip.lua draws it: 4 px cells, 256 to a row, filling from the
//! screen's bottom-right corner rightward along the bottom row, then rows upward.
//! Cells 0-1 magic C0FFEE, 123456; cell 2 the byte length; cells 3-4 the sum of
//! the bytes and the sum of the running sums (both mod 2^24); then 3 bytes a cell,
//! zero padded. Every cell is a colour (r, g, b) read at its centre.
//!
//! Used for: the game's commands (`serve`: Stop, cancel, send now, drawn as
//! "WCCMD ..." strips), asks from other processes (`serve_asks`: an agent's
//! `strip --chat`, a developer's `strip --send <lua>`, put through this
//! companion's channel), and the agents' detached readers (`strip --watch`).

use super::*;

pub(crate) const CELL: usize = 4;
pub(crate) const COLS: usize = 256;
/// How tall a full read is: 64 rows of cells, about 49 KB.
const FULL_HEIGHT: usize = 256;
const MAGIC_A: [u8; 3] = [0xC0, 0xFF, 0xEE];
const MAGIC_B: [u8; 3] = [0x12, 0x34, 0x56];

/// A capture of the screen's bottom-right corner: BGRA, rows top-down.
pub(crate) struct Shot {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl Shot {
    /// The (r, g, b) at pixel (x, y), y counted from the top.
    fn rgb(&self, x: usize, y: usize) -> [u8; 3] {
        let at = (y * self.width + x) * 4;
        [self.pixels[at + 2], self.pixels[at + 1], self.pixels[at]]
    }

    /// Cell `i`'s colour, read at its centre.
    fn cell(&self, i: usize) -> Result<[u8; 3], String> {
        let (col, row) = (i % COLS, i / COLS);
        let x = col * CELL + CELL / 2;
        let from_bottom = row * CELL + CELL / 2;
        if from_bottom >= self.height || x >= self.width {
            return Err("strip taller than the capture".into());
        }
        Ok(self.rgb(x, self.height - 1 - from_bottom))
    }

    /// The first cell shows the magic: a strip is (or is starting to be) up.
    fn magic_shows(&self) -> bool {
        self.cell(0).is_ok_and(|cell| cell == MAGIC_A)
    }

    /// The pixel row through the bottom row of cells, to tell a new strip from
    /// the one already read.
    fn bottom_row(&self) -> &[u8] {
        let y = self.height - 1 - CELL / 2;
        &self.pixels[y * self.width * 4..(y + 1) * self.width * 4]
    }
}

fn number(cell: [u8; 3]) -> usize {
    (cell[0] as usize) << 16 | (cell[1] as usize) << 8 | cell[2] as usize
}

/// The payload a capture holds, or why there is none.
pub(crate) fn decode(shot: &Shot) -> Result<Vec<u8>, String> {
    let (a, b) = (shot.cell(0)?, shot.cell(1)?);
    if a != MAGIC_A || b != MAGIC_B {
        return Err(format!("no strip on screen (corner reads {a:?} {b:?})"));
    }
    let n = number(shot.cell(2)?);
    let want = (number(shot.cell(3)?), number(shot.cell(4)?));
    let mut out = Vec::with_capacity(n + 2);
    for k in 0..n.div_ceil(3) {
        out.extend_from_slice(&shot.cell(5 + k)?);
    }
    out.truncate(n);
    let (mut sum, mut sums) = (0usize, 0usize);
    for byte in &out {
        sum = (sum + *byte as usize) % 16_777_216;
        sums = (sums + sum) % 16_777_216;
    }
    if (sum, sums) != want {
        return Err(format!("checksum mismatch: {n} bytes read, sums ({sum}, {sums}) vs ({}, {})", want.0, want.1));
    }
    Ok(out)
}

/// The corner, `height` pixels tall and one strip (1024 px) wide, in real
/// pixels whatever the display scaling; each grab is timed for the bridge probe
/// (docs/proposals/bridge-probe.md, section 3).
pub(crate) fn capture(height: usize) -> io::Result<Shot> {
    let began = Instant::now();
    let shot = grab(height);
    crate::bridge_probe::note_capture(height, began.elapsed(), shot.is_ok());
    shot
}

/// The capture, through DXGI Desktop Duplication: the compositor hands over the
/// frame it already composed, so reading it never makes the game wait (GDI's
/// BitBlt of the desktop did: 8 ms a look, up to 287 ms, and the player felt a
/// stutter at every data read, 2026-11-11).
///
/// One session stays open. Each new desktop frame, only the corner the strip
/// can use (1024 x FULL_HEIGHT) is copied off the GPU and kept; a look while
/// nothing changed reads that copy, which is exactly the screen (Duplication
/// hands a frame only when the desktop changed). The screen is the primary
/// one (the output whose desktop origin is 0,0), as the GDI capture's was;
/// its texture is in real pixels whatever the display scaling.
#[cfg(windows)]
mod duplication {
    use super::{CELL, COLS, FULL_HEIGHT, Shot};
    use std::{io, sync::Mutex};
    use windows::{
        Win32::Foundation::HMODULE,
        Win32::Graphics::{
            Direct3D::D3D_DRIVER_TYPE_UNKNOWN,
            Direct3D11::{
                D3D11_BOX, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAP_READ,
                D3D11_MAPPED_SUBRESOURCE, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
                D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
            },
            Dxgi::{
                Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION_IDENTITY, DXGI_MODE_ROTATION_UNSPECIFIED, DXGI_SAMPLE_DESC},
                CreateDXGIFactory1, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO, IDXGIAdapter,
                IDXGIFactory1, IDXGIOutput1, IDXGIOutputDuplication, IDXGIResource,
            },
        },
        core::Interface,
    };

    const WIDTH: usize = CELL * COLS;

    struct Session {
        context: ID3D11DeviceContext,
        duplication: IDXGIOutputDuplication,
        /// a CPU-readable texture the size of the corner
        staging: ID3D11Texture2D,
        /// the corner as of the last desktop frame (BGRA, rows top-down)
        corner: Option<Vec<u8>>,
    }

    // SAFETY: the D3D11 device and DXGI objects are free-threaded; the one
    // immediate context is only used under SESSION's lock.
    unsafe impl Send for Session {}

    static SESSION: Mutex<Option<Session>> = Mutex::new(None);

    fn err(what: &str, error: windows::core::Error) -> io::Error {
        io::Error::other(format!("{what}: {error}"))
    }

    /// The primary output (desktop origin 0,0), its adapter's device, and a
    /// duplication of it.
    unsafe fn open() -> io::Result<Session> {
        unsafe {
            let factory: IDXGIFactory1 = CreateDXGIFactory1().map_err(|e| err("no DXGI factory", e))?;
            let mut adapter_index = 0;
            loop {
                let adapter = factory
                    .EnumAdapters1(adapter_index)
                    .map_err(|e| err("no graphics adapter shows the primary screen", e))?;
                let mut output_index = 0;
                while let Ok(output) = adapter.EnumOutputs(output_index) {
                    output_index += 1;
                    let desc = output.GetDesc().map_err(|e| err("an output could not describe itself", e))?;
                    if (desc.DesktopCoordinates.left, desc.DesktopCoordinates.top) != (0, 0) {
                        continue;
                    }
                    let mut device: Option<ID3D11Device> = None;
                    let mut context: Option<ID3D11DeviceContext> = None;
                    let base: IDXGIAdapter = adapter.cast().map_err(|e| err("the adapter", e))?;
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
                    .map_err(|e| err("no Direct3D device on the primary screen's adapter", e))?;
                    let (device, context) = (device.ok_or_else(|| io::Error::other("no device"))?, context.ok_or_else(|| io::Error::other("no device context"))?);
                    let output1: IDXGIOutput1 = output.cast().map_err(|e| err("the output has no duplication (IDXGIOutput1)", e))?;
                    let duplication = output1.DuplicateOutput(&device).map_err(|e| err("the screen cannot be duplicated", e))?;
                    let rotation = duplication.GetDesc().Rotation;
                    if rotation != DXGI_MODE_ROTATION_IDENTITY && rotation != DXGI_MODE_ROTATION_UNSPECIFIED {
                        return Err(io::Error::other("the primary screen is rotated; the strip reader expects it upright"));
                    }
                    let desc = D3D11_TEXTURE2D_DESC {
                        Width: WIDTH as u32,
                        Height: FULL_HEIGHT as u32,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        Usage: D3D11_USAGE_STAGING,
                        BindFlags: 0,
                        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                        MiscFlags: 0,
                    };
                    let mut staging: Option<ID3D11Texture2D> = None;
                    device.CreateTexture2D(&desc, None, Some(&mut staging)).map_err(|e| err("no staging texture", e))?;
                    let staging = staging.ok_or_else(|| io::Error::other("no staging texture"))?;
                    return Ok(Session { context, duplication, staging, corner: None });
                }
                adapter_index += 1;
            }
        }
    }

    /// Take the newest desktop frame, if there is one, into `corner`. Ok(false):
    /// nothing changed since the last frame (the kept corner is current).
    unsafe fn refresh(session: &mut Session, wait_ms: u32) -> windows::core::Result<bool> {
        unsafe {
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource: Option<IDXGIResource> = None;
            match session.duplication.AcquireNextFrame(wait_ms, &mut info, &mut resource) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(false),
                Err(e) => return Err(e),
            }
            let copied = (|| -> windows::core::Result<Vec<u8>> {
                let frame: ID3D11Texture2D = resource.ok_or_else(windows::core::Error::empty)?.cast()?;
                let mut desc = D3D11_TEXTURE2D_DESC::default();
                frame.GetDesc(&mut desc);
                let (w, h) = (desc.Width as usize, desc.Height as usize);
                if w < WIDTH || h < FULL_HEIGHT {
                    return Err(windows::core::Error::new(windows::core::HRESULT(-1), "the screen is smaller than the strip"));
                }
                let corner = D3D11_BOX {
                    left: (w - WIDTH) as u32,
                    top: (h - FULL_HEIGHT) as u32,
                    front: 0,
                    right: w as u32,
                    bottom: h as u32,
                    back: 1,
                };
                session.context.CopySubresourceRegion(&session.staging, 0, 0, 0, 0, &frame, 0, Some(&corner));
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                session.context.Map(&session.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
                let mut pixels = vec![0u8; WIDTH * FULL_HEIGHT * 4];
                for row in 0..FULL_HEIGHT {
                    let from = (mapped.pData as *const u8).add(row * mapped.RowPitch as usize);
                    std::ptr::copy_nonoverlapping(from, pixels.as_mut_ptr().add(row * WIDTH * 4), WIDTH * 4);
                }
                session.context.Unmap(&session.staging, 0);
                Ok(pixels)
            })();
            let released = session.duplication.ReleaseFrame();
            session.corner = Some(copied?);
            released?;
            Ok(true)
        }
    }

    pub(super) fn grab(height: usize) -> io::Result<Shot> {
        let height = height.min(FULL_HEIGHT);
        let mut held = SESSION.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if held.is_none() {
            *held = Some(unsafe { open()? });
        }
        let session = held.as_mut().expect("opened above");
        // the first look waits for the session's first frame; later ones take a
        // new frame if the desktop changed, else the kept corner is current
        let wait_ms = if session.corner.is_none() { 500 } else { 0 };
        match unsafe { refresh(session, wait_ms) } {
            Ok(_) => {}
            Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                // a mode change, a fullscreen switch, the lock screen: this
                // session is over; the next look opens a new one
                *held = None;
                return Err(io::Error::other("the screen's duplication was lost (a mode change, fullscreen switch or lock screen); reopening at the next look"));
            }
            Err(e) => return Err(err("the screen could not be read", e)),
        }
        let corner = session.corner.as_ref().ok_or_else(|| io::Error::other("no desktop frame arrived within 500 ms"))?;
        let skip = (FULL_HEIGHT - height) * WIDTH * 4;
        Ok(Shot { width: WIDTH, height, pixels: corner[skip..].to_vec() })
    }
}

#[cfg(windows)]
fn grab(height: usize) -> io::Result<Shot> {
    duplication::grab(height)
}

#[cfg(not(windows))]
fn grab(_height: usize) -> io::Result<Shot> {
    Err(io::Error::other("the data strip is read on Windows only"))
}

/// Up to three looks a moment apart: a strip just drawn may not be painted yet.
pub(crate) fn read() -> Result<Vec<u8>, String> {
    let mut why = String::from("nothing seen");
    for _ in 0..3 {
        match capture(FULL_HEIGHT).map_err(|err| err.to_string()).and_then(|shot| decode(&shot)) {
            Ok(payload) => return Ok(payload),
            Err(err) => why = err,
        }
        thread::sleep(Duration::from_millis(400));
    }
    Err(why)
}

fn is_command(payload: &[u8]) -> bool {
    payload.starts_with(b"WCCMD ")
}

/// Watch the corner for up to `seconds` for a strip of ours (not a command):
/// a look at the bottom row (1024x4) each second until the magic shows, then one
/// capture as tall as a strip can be.
pub(crate) fn watch(seconds: f64) -> Result<Vec<u8>, String> {
    let end = Instant::now() + Duration::from_secs_f64(seconds.max(0.0));
    let mut why = String::from("nothing seen");
    while Instant::now() < end {
        match capture(CELL) {
            Ok(look) if look.magic_shows() => match capture(FULL_HEIGHT).map_err(|err| err.to_string()).and_then(|shot| decode(&shot)) {
                Ok(payload) if is_command(&payload) => why = "a command strip, not ours".into(),
                Ok(payload) => return Ok(payload),
                Err(err) => why = err,
            },
            Ok(_) => why = "nothing seen".into(),
            Err(err) => why = err.to_string(),
        }
        thread::sleep(Duration::from_secs(1));
    }
    Err(why)
}

/// Watch, then write the payload (or "STRIP FAILED: why") to `out`; with `then`
/// (main, l1, l2, r1, r2, quick) that conversation is asked to carry on once the
/// result is in (the player, 2026-11-10: the agent reminds itself).
pub(crate) fn watch_to_file(seconds: f64, out: &Path, then: Option<&str>) -> io::Result<bool> {
    let result = watch(seconds);
    match &result {
        Ok(payload) => fs::write(out, payload)?,
        Err(why) => fs::write(out, format!("STRIP FAILED: {why}"))?,
    }
    if let Some(slot) = then {
        follow_up(slot, out, result.is_ok())?;
    }
    Ok(result.is_ok())
}

/// A typed request into `slot`'s conversation, as `tell` makes.
fn follow_up(slot: &str, out: &Path, arrived: bool) -> io::Result<()> {
    let dir = typed_dir().ok_or_else(|| io::Error::other("LOCALAPPDATA is not set"))?;
    let slot = slot.to_lowercase();
    let slot = if slot == "main" { "" } else { slot.as_str() };
    let text = format!(
        "(automatic: the data strip you started has {}, in {}. Read it and finish what was asked; the player has not said anything new.)",
        if arrived { "arrived" } else { "failed" },
        out.display()
    );
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_millis()).unwrap_or_default();
    let part = dir.join(format!("{stamp}.part"));
    fs::write(&part, format!("{slot}\n{text}\n"))?;
    fs::rename(&part, dir.join(format!("{stamp}.txt")))
}

/// The Lua that has the game draw its recent chat and the profession links it
/// caught (LinkCatcher's `WCChatStrip`), for an agent's `strip --chat`.
const CHAT_LUA: &str = "if WCChatStrip then WCChatStrip() end";
/// How long a chat read watches: `WCChatStrip` shows its strip for 6 s.
const CHAT_SECONDS: f64 = 8.0;

/// Where asks wait for the running companion: `<id>.ask` (first line the
/// seconds to watch, then the Lua), taken as `<id>.taken`, answered as
/// `<id>.out` (the strip's text) or `<id>.err` (why not).
fn asks_dir() -> io::Result<PathBuf> {
    let dir = crate::restart::companion_dir()?.join("strip-asks");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// `strip --send <lua> [seconds]` and `strip --chat`, from any process: the
/// running companion puts the Lua through its own channel (a second process
/// sending would race it) and reads the strip it draws. Returns the strip's
/// text, or exactly why not.
fn ask(lua: &str, seconds: f64) -> io::Result<Vec<u8>> {
    if !crate::lifecycle::running() {
        return Err(io::Error::other("the companion is not running: nothing can reach the game"));
    }
    let dir = asks_dir()?;
    let id = SystemTime::now().duration_since(UNIX_EPOCH).map(|at| at.as_nanos()).unwrap_or_default();
    let part = dir.join(format!("{id}.part"));
    fs::write(&part, format!("{seconds}\n{lua}"))?;
    fs::rename(&part, dir.join(format!("{id}.ask")))?;
    // the send waits for the channel (a bell's 2 s per message ahead of it),
    // then the watch itself: the deadline covers both, and passing it is said
    let deadline = Instant::now() + Duration::from_secs_f64(seconds + 60.0);
    let (out, err) = (dir.join(format!("{id}.out")), dir.join(format!("{id}.err")));
    while Instant::now() < deadline {
        if let Ok(payload) = fs::read(&out) {
            let _ = fs::remove_file(&out);
            return Ok(payload);
        }
        if let Ok(why) = fs::read_to_string(&err) {
            let _ = fs::remove_file(&err);
            return Err(io::Error::other(why));
        }
        thread::sleep(Duration::from_millis(100));
    }
    // never served: withdraw it; served but late: its answer is not wanted
    if fs::remove_file(dir.join(format!("{id}.ask"))).is_err() {
        let _ = fs::write(dir.join(format!("{id}.abandoned")), "");
    }
    Err(io::Error::other(format!("the companion did not answer within {:.0} s", seconds + 60.0)))
}

/// For the running companion: serve asks one at a time, in the order made.
pub(crate) fn serve_asks(addons: &Path) {
    let addons = addons.to_path_buf();
    thread::spawn(move || loop {
        thread::sleep(Duration::from_millis(200));
        let Ok(dir) = asks_dir() else { continue };
        let mut waiting: Vec<PathBuf> = fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "ask"))
            .collect();
        waiting.sort();
        for path in waiting {
            let taken = path.with_extension("taken");
            if fs::rename(&path, &taken).is_err() {
                continue;
            }
            let answer = fs::read_to_string(&taken).map_err(|err| err.to_string()).and_then(|text| {
                let (seconds, lua) = text.split_once('\n').ok_or("an ask without its Lua")?;
                let seconds: f64 = seconds.trim().parse().map_err(|_| "an ask without its seconds")?;
                serve_one(&addons, lua, seconds)
            });
            let _ = fs::remove_file(&taken);
            let abandoned = path.with_extension("abandoned");
            if fs::remove_file(&abandoned).is_ok() {
                continue;
            }
            let (name, body) = match answer {
                Ok(payload) => ("out", payload),
                Err(why) => ("err", why.into_bytes()),
            };
            let part = path.with_extension("answer");
            if fs::write(&part, body).and_then(|()| fs::rename(&part, path.with_extension(name))).is_err() {
                eprintln!("strip ask: could not write its answer in {}", dir.display());
            }
        }
    });
}

fn serve_one(addons: &Path, lua: &str, seconds: f64) -> Result<Vec<u8>, String> {
    if !channel::game_running().map_err(|err| err.to_string())? {
        return Err("the game is closed".into());
    }
    channel::send(addons, &crate::message::Msg::new("lua").text("code", lua))
        .map_err(|err| format!("the Lua could not be sent: {err}"))?;
    watch(seconds).map_err(|why| {
        format!("no strip in {seconds:.0} s ({why}); the game runs Lua from the companion out of combat only, and the code must call WowCompanion_Strip.Send")
    })
}

/// For the running companion: watch the corner for command strips ("WCCMD ...",
/// drawn when the player presses Stop, cancel or send now in the window) and hand
/// each new one to `command`, newlines made spaces. Never returns. A look at the
/// bottom row twice a second; a full read only when that row changes.
pub(crate) fn serve(mut command: impl FnMut(String)) -> ! {
    let mut seen: Option<Vec<u8>> = None;
    let mut last_row: Option<Vec<u8>> = None;
    loop {
        if let Ok(look) = capture(CELL) {
            if look.magic_shows() {
                let row = look.bottom_row().to_vec();
                if last_row.as_ref() != Some(&row) {
                    if let Ok(payload) = capture(FULL_HEIGHT).map_err(|err| err.to_string()).and_then(|shot| decode(&shot)) {
                        last_row = Some(row);
                        if is_command(&payload) && seen.as_ref() != Some(&payload) {
                            command(String::from_utf8_lossy(&payload).replace('\n', " "));
                            seen = Some(payload);
                        }
                    }
                }
            } else {
                last_row = None;
            }
        }
        thread::sleep(Duration::from_millis(500));
    }
}

fn print(payload: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let mut stdout = io::stdout();
    stdout.write_all(payload)?;
    stdout.write_all(b"\n")
}

/// `wow-companion strip`: print what the strip shows now (or why not, exit 1).
/// `wow-companion strip --chat`: the game's recent chat and caught links, now.
/// `wow-companion strip --send <lua> [seconds]`: run Lua that draws a strip
/// (through the running companion's channel) and print what it drew.
/// `wow-companion strip --watch <seconds> <out file> [--then <conversation>]`:
/// the agents' detached reader (src/agent.rs, "Reading the game live").
pub(crate) fn command(args: &[String]) -> io::Result<()> {
    match args {
        [] => match read() {
            Ok(payload) => print(&payload),
            Err(why) => Err(io::Error::other(format!("strip: {why}"))),
        },
        [flag] if flag == "--chat" => print(&ask(CHAT_LUA, CHAT_SECONDS)?),
        [flag, lua] if flag == "--send" => print(&ask(lua, 10.0)?),
        [flag, lua, seconds] if flag == "--send" => {
            let seconds: f64 = seconds.parse().map_err(|_| io::Error::other("--send <lua> [seconds]"))?;
            print(&ask(lua, seconds)?)
        }
        [flag, seconds, out, rest @ ..] if flag == "--watch" => {
            let seconds: f64 = seconds.parse().map_err(|_| io::Error::other("--watch wants seconds, then the out file"))?;
            let then = match rest {
                [] => None,
                [flag, slot] if flag == "--then" => Some(slot.as_str()),
                _ => return Err(io::Error::other("after the out file only --then <conversation>")),
            };
            if watch_to_file(seconds, Path::new(out), then)? {
                Ok(())
            } else {
                std::process::exit(1)
            }
        }
        _ => Err(io::Error::other("strip [--chat | --send <lua> [seconds] | --watch <seconds> <out file> [--then <conversation>]]")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The capture on this PC's real screen (`--ignored --nocapture`): its size,
    /// and what each look and each full grab costs.
    #[test]
    #[ignore]
    fn capture_on_this_screen() {
        let stats = |height: usize, n: usize| {
            let mut took: Vec<u128> = (0..n)
                .map(|_| {
                    let began = Instant::now();
                    let shot = grab(height).expect("capture");
                    assert_eq!((shot.width, shot.height, shot.pixels.len()), (CELL * COLS, height, CELL * COLS * height * 4));
                    let us = began.elapsed().as_micros();
                    thread::sleep(Duration::from_millis(20));
                    us
                })
                .collect();
            took.sort();
            println!("height {height}: n {n}, us min {} median {} p95 {} max {}", took[0], took[n / 2], took[n * 95 / 100], took[n - 1]);
        };
        grab(CELL).expect("the first look opens the session");
        stats(CELL, 200);
        stats(FULL_HEIGHT, 50);
    }

    /// A capture holding what Strip.lua draws for `text`: its cells as 4x4
    /// blocks from the bottom-left of a 1024-wide shot, unused cells of the last
    /// row black, the rest of the shot `background`.
    fn drawn(text: &[u8], height: usize, background: [u8; 3]) -> Shot {
        let width = CELL * COLS;
        let mut pixels = Vec::with_capacity(width * height * 4);
        for _ in 0..width * height {
            pixels.extend_from_slice(&[background[2], background[1], background[0], 255]);
        }
        let mut shot = Shot { width, height, pixels };
        let (mut a, mut b) = (0u32, 0u32);
        for byte in text {
            a = (a + *byte as u32) % 16_777_216;
            b = (b + a) % 16_777_216;
        }
        let triple = |v: u32| [(v >> 16) as u8, (v >> 8) as u8, v as u8];
        let mut cells = vec![[0xC0, 0xFF, 0xEE], [0x12, 0x34, 0x56], triple(text.len() as u32), triple(a), triple(b)];
        for chunk in text.chunks(3) {
            let mut cell = [0u8; 3];
            cell[..chunk.len()].copy_from_slice(chunk);
            cells.push(cell);
        }
        let rows = cells.len().div_ceil(COLS);
        cells.resize(rows * COLS, [0, 0, 0]);
        for (i, cell) in cells.iter().enumerate() {
            let (col, row) = (i % COLS, i / COLS);
            for dy in 0..CELL {
                for dx in 0..CELL {
                    let x = col * CELL + dx;
                    let y = height - 1 - (row * CELL + dy);
                    let at = (y * width + x) * 4;
                    shot.pixels[at..at + 3].copy_from_slice(&[cell[2], cell[1], cell[0]]);
                }
            }
        }
        shot
    }

    #[test]
    fn a_short_payload_is_read_back() {
        let shot = drawn(b"hello, chat", FULL_HEIGHT, [20, 30, 40]);
        assert_eq!(decode(&shot).unwrap(), b"hello, chat");
        assert!(shot.magic_shows());
    }

    #[test]
    fn a_payload_over_several_rows_is_read_back() {
        // 7.8 KB, as measured in game: 2,600 cells, eleven rows
        let text: Vec<u8> = (0..7800u32).map(|i| (i * 7 + i / 255) as u8).collect();
        assert_eq!(decode(&drawn(&text, FULL_HEIGHT, [0, 0, 0])).unwrap(), text);
        // lengths that leave 1 and 2 bytes of padding in the last cell
        for len in [1usize, 2, 4, 5, 767, 768] {
            let text: Vec<u8> = (0..len).map(|i| (i % 251) as u8 + 1).collect();
            assert_eq!(decode(&drawn(&text, FULL_HEIGHT, [9, 9, 9])).unwrap(), text, "length {len}");
        }
    }

    #[test]
    fn a_damaged_strip_fails_its_checksum() {
        let mut shot = drawn(b"WCCMD 123 stop l1", FULL_HEIGHT, [0, 0, 0]);
        // one byte of cell 6 changed: the centre pixel is what is read
        let (x, y) = (6 * CELL + CELL / 2, FULL_HEIGHT - 1 - CELL / 2);
        let at = (y * shot.width + x) * 4;
        shot.pixels[at] ^= 0x01;
        assert!(decode(&shot).unwrap_err().starts_with("checksum mismatch"));
    }

    #[test]
    fn no_strip_and_a_strip_taller_than_the_capture_say_why() {
        let empty = Shot { width: CELL * COLS, height: CELL, pixels: vec![0; CELL * COLS * CELL * 4] };
        assert!(decode(&empty).unwrap_err().starts_with("no strip on screen"));
        assert!(!empty.magic_shows());
        // a look at the bottom row sees the magic, but the bytes need a full read
        let text = vec![b'x'; 2000];
        let full = drawn(&text, FULL_HEIGHT, [0, 0, 0]);
        let bottom = Shot {
            width: full.width,
            height: CELL,
            pixels: full.pixels[(FULL_HEIGHT - CELL) * full.width * 4..].to_vec(),
        };
        assert!(bottom.magic_shows());
        assert_eq!(decode(&bottom).unwrap_err(), "strip taller than the capture");
    }

    #[test]
    fn commands_are_told_apart() {
        assert!(is_command(b"WCCMD 42 hear l1 1794361011767"));
        assert!(!is_command(b"WCCMDX"));
        assert!(!is_command(b"[General] hi"));
    }
}
