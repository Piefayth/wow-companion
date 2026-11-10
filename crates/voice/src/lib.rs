//! Push-to-talk voice capture. Hold a controller chord, speak, release: the whole
//! clip goes to Whisper at once, which reads better than streaming dictation
//! because the model gets to see the end of the sentence before committing to the
//! start of it. Stays on this machine, so a hot mic can't leak the room.

use std::{
    io,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use wow_companion_pad::{self as pad, Pad, DEFAULT_PAD};

const WHISPER_RATE: u32 = 16_000;
const POLL: Duration = Duration::from_millis(16);
// below this there is no speech, just the click of the chord being released
const MINIMUM_CLIP: Duration = Duration::from_millis(250);
/// A press released this quickly was a tap, not speech: it is reported as the
/// role with " tap" appended and no text, so a button can do something on a tap
/// (minus opens the Companion window) and still be push-to-talk when held.
const TAP: Duration = Duration::from_millis(350);
// A sine wave at full scale is far louder than music at the same nominal level, and
// a headset in hands-free mode has its own gain on top. Start very quiet; `volume=`
// tunes it without a rebuild.
const CUE_VOLUME: f32 = 0.015;
// A rising fifth to open, the same fifth falling to close: two notes carry direction
// where one pitch only says "something happened".
const CUE_OPEN: [f32; 2] = [587.33, 880.00];
const CUE_SHUT: [f32; 2] = [880.00, 587.33];
const CUE_NOTE: u64 = 85;
// struck-and-decaying, like a glass or a marimba, rather than a held tone
const CUE_DECAY: f32 = 20.0;

// Whisper has never heard of Hearthstone or Shadowstep and will cheerfully write
// "fire ball". Seeding the decoder with the vocabulary fixes most of it.
const COMMANDS: &str = "Commands: macro, action bar, slot, bind, chat, whisper, party, raid, guild.";
// used until the game has exported a spellbook to take names from
const FALLBACK_SPELLS: &[&str] = &["Hearthstone", "Rejuvenation", "Moonfire", "Bear Form"];
// Whisper keeps only the last ~224 tokens of a prompt; stay well inside that, or
// the cut falls on the spell names, which are the point
const PROMPT_CHARS: usize = 700;
// A Bluetooth pad sleeps and a headset drops its hands-free link; either used to end
// the app. Now a lost device is reopened on this cadence until it comes back.
const RETRY: Duration = Duration::from_secs(2);
// Whisper fills silence with the endings of the videos it was trained on. These only
// count as heard when the clip had real sound in it.
const PHANTOMS: &[&str] = &["thank you", "thanks for watching", "you", "bye", "thank you for watching"];
// RMS of a clip with nobody talking; speech sits well above it. Printed with every
// clip, so it can be tuned from the log rather than guessed.
const SILENCE: f32 = 0.01;
// no buffers for this long and the mic stream is taken for dead
const STALL: Duration = Duration::from_millis(1500);
// at most one automatic reconnect this often, so an absent headset cannot loop
const HEAL_EVERY: Duration = Duration::from_secs(15);
// rumble strength for the listening pulses, of 255 (the test buzz was 192)
const PULSE: u8 = 160;
// the closing pulse: softer than the opening one, so the two are told apart
const PULSE_SOFT: u8 = 90;
// hold mode: how long after the mic closes to wait for the headset to be back in
// stereo before the closing cue (`return=` tunes it, in ms)
const RETURN_MS: u64 = 1000;

/// Ask every active audio endpoint to reconnect its Bluetooth link, the way the
/// Sound control panel's "Connect" does: KSPROPERTY_ONESHOT_RECONNECT on the
/// endpoint's topology part. Endpoints that are not Bluetooth refuse it and are
/// skipped. Needs no admin. Returns how many accepted.
#[cfg(windows)]
fn reconnect_bluetooth_audio() -> usize {
    reconnect_bluetooth_audio_verbose(false)
}

#[cfg(windows)]
fn reconnect_bluetooth_audio_verbose(verbose: bool) -> usize {
    use windows::{
        Win32::{
            Media::{
                Audio::{eAll, IDeviceTopology, IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE},
                KernelStreaming::{
                    IKsControl, KSIDENTIFIER, KSIDENTIFIER_0, KSIDENTIFIER_0_0, KSPROPERTY_ONESHOT_RECONNECT,
                    KSPROPERTY_TYPE_GET, KSPROPSETID_BtAudio,
                },
            },
            System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED},
        },
    };
    let mut accepted = 0;
    unsafe {
        // already initialised on this thread is fine
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let Ok(enumerator) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else {
            return 0;
        };
        let Ok(devices) = enumerator.EnumAudioEndpoints(eAll, DEVICE_STATE_ACTIVE) else { return 0 };
        let count = devices.GetCount().unwrap_or(0);
        for index in 0..count {
            let attempt = || -> Result<(), String> {
                let step = |what: &str, err: windows::core::Error| format!("{what}: {err}");
                let device = devices.Item(index).map_err(|e| step("item", e))?;
                let topology: IDeviceTopology = device.Activate(CLSCTX_ALL, None).map_err(|e| step("topology", e))?;
                let connector = topology.GetConnector(0).map_err(|e| step("connector", e))?;
                // the device on the far side of the endpoint's connector is the
                // Bluetooth audio filter; IKsControl lives on it, not on its parts
                let filter_id = connector.GetDeviceIdConnectedTo().map_err(|e| step("filter id", e))?;
                let filter = enumerator
                    .GetDevice(windows::core::PCWSTR(filter_id.0))
                    .map_err(|e| step("filter", e))?;
                let control: IKsControl = filter.Activate(CLSCTX_ALL, None).map_err(|e| step("ks control", e))?;
                let property = KSIDENTIFIER {
                    Anonymous: KSIDENTIFIER_0 {
                        Anonymous: KSIDENTIFIER_0_0 {
                            Set: KSPROPSETID_BtAudio,
                            Id: KSPROPERTY_ONESHOT_RECONNECT.0 as u32,
                            Flags: KSPROPERTY_TYPE_GET,
                        },
                    },
                };
                let mut returned = 0u32;
                control
                    .KsProperty(
                        &property,
                        std::mem::size_of::<KSIDENTIFIER>() as u32,
                        std::ptr::null_mut(),
                        0,
                        &mut returned,
                    )
                    .map_err(|e| step("reconnect", e))
            };
            match attempt() {
                Ok(()) => accepted += 1,
                Err(why) if verbose => println!("  endpoint {index}: {why}"),
                Err(_) => {}
            }
        }
    }
    accepted
}

#[cfg(not(windows))]
fn reconnect_bluetooth_audio() -> usize {
    0
}

/// For testing the reconnect by hand: `wow-companion reconnect`.
pub fn reconnect() -> io::Result<()> {
    println!("reconnect accepted by {} endpoint(s)", reconnect_bluetooth_audio_verbose(true));
    Ok(())
}

/// The stereo output of the headset whose hands-free mic is `mic`: "Headset
/// (AirPods Max Hands-Free AG Audio)" -> "Headphones (AirPods Max Stereo)".
fn stereo_twin(mic: &str) -> Option<String> {
    let inner = mic.split_once('(')?.1.trim_end_matches(')');
    let base = inner.split(" Hands-Free").next()?.trim().to_ascii_lowercase();
    if base.is_empty() {
        return None;
    }
    let host = cpal::default_host();
    let outputs = host.output_devices().ok()?;
    for device in outputs {
        let Ok(described) = device.description() else { continue };
        let name = described.name().to_string();
        let lowered = name.to_ascii_lowercase();
        if lowered.contains(&base) && !lowered.contains("hands-free") {
            return Some(name);
        }
    }
    None
}

fn prompt(spells: &[String]) -> String {
    let mut prompt = String::from("World of Warcraft. Spells and macros: ");
    let names: Vec<&str> = if spells.is_empty() {
        FALLBACK_SPELLS.to_vec()
    } else {
        spells.iter().map(String::as_str).collect()
    };
    let room = PROMPT_CHARS - COMMANDS.len();
    let mut first = true;
    for name in names {
        if prompt.len() + name.len() + 2 > room {
            break;
        }
        if !first {
            prompt.push_str(", ");
        }
        prompt.push_str(name);
        first = false;
    }
    prompt.push_str(". ");
    prompt.push_str(COMMANDS);
    prompt
}

/// Hold a button, speak, release. `heard` is given which binding fired and what was
/// said (a quick tap arrives as "<role> tap" with no text), so one loop can serve dictation on one button and the agent on another.
///
/// Both default to buttons WoW ignores — Home and minus. We cannot consume the input,
/// so anything the game binds would fire twice: once for us, once in game.
///
/// `vocabulary` is asked afresh for every clip, so names learned at the last reload
/// are in the prompt without restarting.
/// True while a push-to-talk button is held: a restart waits for the release, so
/// no clip is cut off halfway.
pub static HOLDING: AtomicBool = AtomicBool::new(false);

/// Set by a restart: the voice loop closes the mic properly and returns, and only
/// then does the next copy start. Abandoning a live hands-free stream (a killed
/// process, an exit that skips destructors) is the likeliest way the link wedged.
pub static SHUTDOWN: AtomicBool = AtomicBool::new(false);
/// Set once the mic is closed after SHUTDOWN.
pub static STOPPED: AtomicBool = AtomicBool::new(false);
/// Set by the companion when something could not reach the game (every slot
/// spent): the voice loop answers with three quick pulses, which need no slot.
pub static ALERT: AtomicBool = AtomicBool::new(false);

pub fn listen(
    model: &Path,
    options: &[String],
    vocabulary: impl Fn() -> Vec<String>,
    mut heard: impl FnMut(&str, &str) -> io::Result<()>,
) -> io::Result<()> {
    let bindings = [
        ("chat", option(options, "chat").or(option(options, "button")).unwrap_or("home")),
        ("ask", option(options, "ask").unwrap_or("minus")),
    ];
    let bindings: Vec<(&str, pad::Press)> = bindings
        .iter()
        .map(|(role, name)| pad::press(name).map(|press| (*role, press)))
        .collect::<io::Result<_>>()?;
    let (vid, pid) = DEFAULT_PAD;
    let wanted_mic = option(options, "mic");
    // Neither has to be there at startup: the model loads either way, and each device
    // is picked up when it appears. A mistyped `mic=` looks exactly like an unplugged
    // headset from here, so the wait names the inputs it can see; a typo shows up
    // as a name missing from that list.
    let mut controller = match Pad::open(vid, pid) {
        Ok(opened) => Some(opened),
        Err(err) => {
            println!("controller not found ({err}); will pick it up when it connects");
            None
        }
    };
    let mut microphone = match Microphone::open(wanted_mic) {
        Ok(opened) => Some(opened),
        Err(err) => {
            println!("{err}; will pick it up when it connects");
            println!("  inputs I can see now: {}", input_names().join(", "));
            None
        }
    };
    // A Bluetooth headset holding HFP for the mic has its A2DP render endpoint
    // switched off, so the cue has to name the hands-free one or it plays into a
    // dead device. Nothing is audible and nothing errors.
    let mut cue_device = option(options, "cue").map(str::to_string);
    let cue_volume = option(options, "volume")
        .and_then(|given| given.parse().ok())
        .unwrap_or(CUE_VOLUME);

    // Hold mode. A Bluetooth headset's mic only works in the hands-free (phone
    // call) profile, which is 8 kHz both ways and hisses whenever anything plays;
    // stereo cannot run alongside it (a protocol limit, not a driver one). Keeping
    // the mic open all session pinned the headset in hands-free, so every cue
    // hissed. In hold mode the mic is open only while a button is held: the rest of
    // the time the headset is in stereo, the cues play there cleanly, and each cue
    // finishes before the profile switches (the player's condition).
    let hands_free = microphone.as_ref().is_some_and(|mic| mic.name.to_ascii_lowercase().contains("hands-free"));
    // Measured on AirPods Max: after the mic stream opened (8 ms), no audio at all
    // arrived during a whole press, so the switch into hands-free takes longer
    // than a press, let alone the 250 ms cue. Off unless asked for.
    let _ = hands_free;
    let hold_mode = option(options, "mic-mode") == Some("hold");
    let return_after = Duration::from_millis(
        option(options, "return").and_then(|given| given.parse().ok()).unwrap_or(RETURN_MS),
    );
    if hold_mode {
        if let Some(stereo) = microphone.as_ref().and_then(|mic| stereo_twin(&mic.name)) {
            println!("hold mode: mic opens only while held; cues on {stereo}");
            cue_device = Some(stereo);
        } else {
            println!("hold mode: mic opens only while held; no stereo output found, cues stay on {:?}", cue_device);
        }
        // closed until a button is held, so the headset can go back to stereo
        microphone = None;
    }

    // loading the model is the slow part, so do it once and keep it resident
    let path = model.to_str().ok_or_else(|| io::Error::other("model path isn't UTF-8"))?;
    println!("loading {path}");
    let whisper = WhisperContext::new_with_params(path, WhisperContextParameters::default())
        .map_err(|err| io::Error::other(format!("{err:?}")))?;

    for (role, press) in &bindings {
        println!("ready: hold {press} for {role}");
    }
    // Feedback is rumble by default. Cues in a Bluetooth headset play over its
    // hands-free link (8 kHz, the only one this PC negotiates with AirPods Max),
    // which hisses whenever anything plays; the pad's rumble is instant, silent and
    // in the player's hands (the player's choice). `feedback=beep` or `both`.
    let feedback = option(options, "feedback").unwrap_or("rumble");
    let rumbles = feedback == "rumble" || feedback == "both";
    let beeps = feedback == "beep" || feedback == "both";
    // its own handle and thread, so a pulse keeps time while this loop transcribes
    let rumbler = pad::Rumbler::new(vid, pid);
    let mut holding: Option<&str> = None;
    let mut pressed_at = Instant::now();
    // the opening pulse waits until a press has outlasted a tap: a tap (which
    // the game handles itself, opening the window) stays silent, and feeling
    // the pulse means "this is a hold, I'm listening"
    let mut pulsed = false;
    let mut retry_pad = Instant::now();
    let mut retry_mic = Instant::now();
    let mut healed_at: Option<Instant> = None;
    loop {
        if SHUTDOWN.load(Ordering::SeqCst) {
            // close the mic properly before the next copy opens its own
            drop(microphone.take());
            STOPPED.store(true, Ordering::SeqCst);
            return Ok(());
        }
        // The stream open, the device listed, and no audio arriving: the headset's
        // voice link is wedged. Reconnect it the way Sound settings' Connect does,
        // then reopen the mic. The player hears about it in the window.
        if !hold_mode && microphone.as_ref().is_some_and(Microphone::stalled)
            && healed_at.is_none_or(|at| at.elapsed() > HEAL_EVERY)
        {
            healed_at = Some(Instant::now());
            eprintln!("mic stopped delivering audio; reconnecting the headset's voice link");
            drop(microphone.take());
            let reconnected = reconnect_bluetooth_audio();
            eprintln!("  reconnect sent to {reconnected} endpoint(s)");
            thread::sleep(Duration::from_millis(1500));
            microphone = Microphone::open_quietly(wanted_mic, true).ok();
            let _ = heard(
                "notice",
                "The headset's mic stopped sending audio, so I reconnected its voice link. If I still cannot hear you, reconnect the headset.",
            );
        }
        // a dead stream is replaced between presses, never during one
        if !hold_mode && holding.is_none() && microphone.as_ref().is_some_and(Microphone::broken) {
            eprintln!("microphone lost; waiting for it to come back");
            microphone = None;
            retry_mic = Instant::now();
        }
        if !hold_mode && microphone.is_none() && Instant::now() >= retry_mic {
            retry_mic = Instant::now() + RETRY;
            // open prints the device it found, which doubles as "it's back"
            if let Ok(opened) = Microphone::open(wanted_mic) {
                microphone = Some(opened);
            }
        }
        let Some(pad) = controller.as_mut() else {
            if Instant::now() >= retry_pad {
                retry_pad = Instant::now() + RETRY;
                if let Ok(opened) = Pad::open(vid, pid) {
                    println!("controller back");
                    controller = Some(opened);
                }
            }
            thread::sleep(POLL);
            continue;
        };
        if let Err(err) = pad.refresh() {
            eprintln!("controller lost ({err}); waiting for it to come back");
            controller = None;
            retry_pad = Instant::now() + RETRY;
            // a clip cut off by the pad vanishing is not a request
            if holding.take().is_some() {
                if let Some(mic) = &microphone {
                    mic.stop();
                }
                println!("  discarded the clip in progress");
            }
            continue;
        }
        if ALERT.swap(false, Ordering::SeqCst) && rumbles {
            rumbler.play(&[(0, PULSE, PULSE), (60, 0, 0), (120, PULSE, PULSE), (180, 0, 0), (240, PULSE, PULSE), (300, 0, 0)]);
        }
        // first match wins, so holding both does one thing rather than two
        let held = bindings
            .iter()
            .find(|(_, press)| pad.held(press))
            .map(|(role, _)| *role);
        // hold mode: a press plays the opening cue to its end on stereo, and only
        // then opens the mic, which is what switches the headset into hands-free
        if hold_mode && held.is_some() && holding.is_none() && microphone.is_none() {
            if cue_volume > 0.0 {
                if let Err(err) = chime(cue_device.as_deref(), cue_volume, &CUE_OPEN) {
                    eprintln!("cue failed: {err}");
                }
            }
            let opening = Instant::now();
            match Microphone::open_quietly(wanted_mic, true) {
                Ok(opened) => {
                    println!("  mic opened in {} ms", opening.elapsed().as_millis());
                    microphone = Some(opened);
                }
                Err(err) => eprintln!("microphone unavailable: {err}"),
            }
        }
        let Some(mic) = &microphone else {
            if held.is_some() && holding.is_none() {
                println!("no microphone yet; still waiting for it");
            }
            holding = held;
            HOLDING.store(held.is_some(), Ordering::Relaxed);
            thread::sleep(POLL);
            continue;
        };

        match (held, holding) {
            (Some(role), None) => {
                pressed_at = Instant::now();
                mic.start();
                // in hold mode the opening cue has already played, before the switch
                if !hold_mode && beeps {
                    cue(cue_device.clone(), cue_volume, &CUE_OPEN);
                }
                pulsed = false;
                println!("listening for {role}");
            }
            (None, Some(role)) => {
                let clip = mic.stop();
                if hold_mode {
                    match mic.lag() {
                        Some(lag) => println!("  first audio {} ms after the mic opened", lag.as_millis()),
                        None => println!("  no audio arrived while held"),
                    }
                    // Closing the mic lets the headset go back to stereo; the closing
                    // cue waits for that, then plays there, clean.
                    microphone = None;
                    let (device, volume) = (cue_device.clone(), cue_volume);
                    thread::spawn(move || {
                        thread::sleep(return_after);
                        if volume > 0.0 {
                            if let Err(err) = chime(device.as_deref(), volume, &CUE_SHUT) {
                                eprintln!("cue failed: {err}");
                            }
                        }
                    });
                } else if beeps {
                    // falling fifth on release: rising means live, falling means it has it
                    cue(cue_device.clone(), cue_volume, &CUE_SHUT);
                }
                if rumbles && pulsed {
                    // one softer, shorter pulse: got it (the player found two too much);
                    // none after a tap, which never got the opening pulse either
                    rumbler.play(&[(0, PULSE_SOFT, PULSE_SOFT), (80, 0, 0)]);
                }
                let seconds = clip.len() as f32 / WHISPER_RATE as f32;
                if pressed_at.elapsed() < TAP {
                    println!("tap: {role}");
                    if let Err(err) = heard(&format!("{role} tap"), "") {
                        eprintln!("  not delivered: {err}");
                    }
                } else if Duration::from_secs_f32(seconds) < MINIMUM_CLIP {
                    // held long enough to mean it, yet almost no audio arrived
                    println!("too short, ignored ({seconds:.2}s of audio)");
                    let _ = heard("notice", &format!(
                        "I got only {seconds:.1}s of audio from that press, so nothing was sent. If you spoke, the mic may not be sending."
                    ));
                } else {
                    // Every clip goes to Whisper; none is judged by volume. A filter
                    // on level dropped a real, quiet sentence (0.0024, the first
                    // press after a restart) without a word to the player.
                    let level = loudness(&clip);
                    match transcribe(&whisper, &clip, &prompt(&vocabulary())) {
                        Ok(text) if text.is_empty() => {
                            println!("heard nothing (level {level:.4})");
                            let _ = heard("notice", "I heard nothing in that clip, so nothing was sent.");
                        }
                        // Whisper filling silence with its own prompt: nothing but the
                        // echo, or an echo in a clip too quiet to hold speech (a dead
                        // mic measured 0.0011; speech here is 0.016 and up)
                        Ok(text) if without_echo(&text).is_empty()
                            || (level < SILENCE && without_echo(&text) != text.trim()) => {
                            println!("heard only the prompt echoed (level {level:.4}); ignored {text:?}");
                            let _ = heard("notice", "That clip held no words I could make out, so nothing was sent.");
                        }
                        Ok(text) if level < SILENCE && phantom(&text) => {
                            println!("heard only silence (level {level:.4}); ignored {text:?}");
                            let _ = heard("notice", &format!(
                                "That clip sounded like silence (I made out only {text:?}), so nothing was sent."
                            ));
                        }
                        Ok(text) => {
                            // Whisper sometimes glues its prompt onto real speech
                            // ("Commands: and, uh, ..."): keep the speech
                            let text = without_echo(&text);
                            println!("heard ({seconds:.1}s, {role}, level {level:.4}): {text}");
                            // a failed delivery must not kill the loop: the game may
                            // be closed, or every slot spent until the next reload
                            if let Err(err) = heard(role, &text) {
                                eprintln!("  not delivered: {err}");
                            }
                        }
                        Err(err) => eprintln!("transcribe failed: {err}"),
                    }
                }
            }
            (Some(_), Some(_)) => {
                if rumbles && !pulsed && pressed_at.elapsed() >= TAP {
                    // one firm pulse: past a tap, so listening
                    pulsed = true;
                    rumbler.play(&[(0, PULSE, PULSE), (120, 0, 0)]);
                }
            }
            _ => {}
        }
        holding = held;
        HOLDING.store(held.is_some(), Ordering::Relaxed);
        thread::sleep(POLL);
    }
}

fn loudness(clip: &[f32]) -> f32 {
    if clip.is_empty() {
        return 0.0;
    }
    (clip.iter().map(|sample| sample * sample).sum::<f32>() / clip.len() as f32).sqrt()
}

/// The transcript with any echo of Whisper's own prompt taken off the front.
/// Given silence it writes the prompt out ("Commands: the first one."), and given
/// speech it sometimes starts with it ("Commands: and, uh, ..."): dropping every
/// clip that began that way threw away real speech at normal volume. So the echo
/// is cut and what is left is the clip; empty means there was nothing else.
#[cfg(test)]
mod echo_tests {
    use super::without_echo;

    #[test]
    fn keeps_speech_after_an_echo() {
        assert_eq!(without_echo("Commands: and, uh, put Moonfire on R2"), "and, uh, put Moonfire on R2");
        assert_eq!(without_echo("Put Moonfire on R2."), "Put Moonfire on R2.");
    }

    #[test]
    fn an_echo_alone_is_nothing() {
        assert_eq!(without_echo("Commands:"), "");
        assert_eq!(without_echo("World of Warcraft. Spells and macros:"), "");
        assert_eq!(without_echo("Commands: macro, action bar, slot, bind, chat"), "");
    }
}

fn without_echo(text: &str) -> String {
    let mut rest = text.trim();
    loop {
        let lowered = rest.to_lowercase();
        let cut = ["commands:", "world of warcraft.", "spells and macros:"]
            .iter()
            .find_map(|echo| lowered.starts_with(echo).then_some(echo.len()));
        match cut {
            Some(len) => rest = rest[len..].trim_start_matches(|c: char| c.is_whitespace() || c == ','),
            None => break,
        }
    }
    // an echo can carry the prompt's own spell list or command words after it
    if rest.to_lowercase().starts_with("macro, action bar, slot") {
        return String::new();
    }
    rest.trim().to_string()
}

fn phantom(text: &str) -> bool {
    let plain: String = text
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    PHANTOMS.contains(&plain.trim())
}

fn transcribe(whisper: &WhisperContext, clip: &[f32], prompt: &str) -> io::Result<String> {
    let mut state = whisper
        .create_state()
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("en"));
    params.set_initial_prompt(prompt);
    params.set_translate(false);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    state
        .full(params, clip)
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let mut text = String::new();
    for segment in state.as_iter() {
        text.push_str(&segment.to_string());
    }
    Ok(text.trim().to_string())
}


struct Capture {
    recording: bool,
    samples: Vec<f32>,
    // when start() was called, and when the first samples after it arrived: the
    // gap is how long the headset took to switch into hands-free and deliver
    started: Option<Instant>,
    first: Option<Instant>,
    // the last time the stream delivered anything, recording or not: a live
    // stream delivers every few milliseconds, so a gap means the link is dead
    last: Instant,
}

struct Microphone {
    // held because dropping it closes the stream
    _stream: cpal::Stream,
    capture: Arc<Mutex<Capture>>,
    rate: u32,
    channels: u16,
    // set from the stream's error callback when the device is gone, not merely late
    dead: Arc<AtomicBool>,
    name: String,
}

impl Microphone {
    // One stream open for the whole session, gated by a flag. Opening a stream takes
    // long enough that doing it per press would clip the first word.
    fn open(wanted: Option<&str>) -> io::Result<Self> {
        Self::open_quietly(wanted, false)
    }

    fn open_quietly(wanted: Option<&str>, quiet: bool) -> io::Result<Self> {
        let host = cpal::default_host();
        let device = match wanted {
            // match on a fragment: full device names are long and awkward to type
            Some(fragment) => {
                let lowered = fragment.to_ascii_lowercase();
                host.input_devices()
                    .map_err(|err| io::Error::other(err.to_string()))?
                    .find(|device| {
                        device.description().is_ok_and(|described| {
                            described.name().to_ascii_lowercase().contains(&lowered)
                        })
                    })
                    .ok_or_else(|| {
                        io::Error::other(format!("no input device matching {fragment:?}"))
                    })?
            }
            None => host
                .default_input_device()
                .ok_or_else(|| io::Error::other("no input device"))?,
        };
        let config = device
            .default_input_config()
            .map_err(|err| io::Error::other(err.to_string()))?;
        let rate = config.sample_rate();
        let channels = config.channels();
        let name = device
            .description()
            .map(|described| described.name().to_string())
            .unwrap_or_else(|_| "unknown".into());
        if !quiet {
            println!("microphone: {name} at {rate} Hz, {channels} channel(s)");
        }
        // Whisper is trained on 16 kHz. Below that there is nothing to resample from:
        // Bluetooth hands-free runs at 8 kHz and costs real accuracy.
        if rate < WHISPER_RATE && !quiet {
            println!("  warning: {rate} Hz is below Whisper's {WHISPER_RATE} Hz; expect misreadings");
        }

        let capture = Arc::new(Mutex::new(Capture {
            recording: false,
            samples: Vec::new(),
            started: None,
            first: None,
            last: Instant::now(),
        }));
        let sink = Arc::clone(&capture);
        let dead = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&dead);
        // An underrun is a hiccup and the stream carries on; anything else means the
        // device went away (a headset dropping hands-free reports DeviceNotAvailable)
        // and the stream will never deliver again.
        let fail = move |err: cpal::Error| {
            if !matches!(err.kind(), cpal::ErrorKind::Xrun | cpal::ErrorKind::DeviceChanged) {
                if !flag.swap(true, Ordering::Relaxed) {
                    eprintln!("microphone error: {err}");
                }
            }
        };
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                config.config(),
                move |data: &[f32], _: &_| push(&sink, data.iter().copied()),
                fail,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                config.config(),
                move |data: &[i16], _: &_| {
                    push(&sink, data.iter().map(|s| *s as f32 / i16::MAX as f32))
                },
                fail,
                None,
            ),
            other => return Err(io::Error::other(format!("unsupported sample format {other:?}"))),
        }
        .map_err(|err| io::Error::other(err.to_string()))?;
        stream.play().map_err(|err| io::Error::other(err.to_string()))?;

        Ok(Self { _stream: stream, capture, rate, channels, dead, name })
    }

    fn broken(&self) -> bool {
        self.dead.load(Ordering::Relaxed)
    }

    fn start(&self) {
        let mut capture = self.capture.lock().unwrap();
        capture.samples.clear();
        capture.recording = true;
        capture.started = Some(Instant::now());
        capture.first = None;
    }

    /// True when the stream has delivered nothing for `STALL`: the device is
    /// listed and the stream open, but no audio is coming (a wedged hands-free link).
    fn stalled(&self) -> bool {
        self.capture.lock().unwrap().last.elapsed() > STALL
    }

    /// How long after start() the first audio arrived, if it has.
    fn lag(&self) -> Option<Duration> {
        let capture = self.capture.lock().unwrap();
        Some(capture.first?.saturating_duration_since(capture.started?))
    }

    fn stop(&self) -> Vec<f32> {
        let mut capture = self.capture.lock().unwrap();
        capture.recording = false;
        let raw = std::mem::take(&mut capture.samples);
        drop(capture);
        to_whisper(&raw, self.channels, self.rate)
    }
}

fn push(capture: &Arc<Mutex<Capture>>, samples: impl Iterator<Item = f32>) {
    let mut capture = capture.lock().unwrap();
    capture.last = Instant::now();
    if capture.recording {
        let before = capture.samples.len();
        capture.samples.extend(samples);
        if capture.first.is_none() && capture.samples.len() > before {
            capture.first = Some(Instant::now());
        }
    }
}

/// A short tone to the default output, so you can hear that push-to-talk went live
/// rather than guessing from whether text eventually appears.
///
/// Spawned on its own thread: capture has to start now, not after the audio device
/// has finished opening.
fn cue(wanted: Option<String>, volume: f32, notes: &'static [f32]) {
    if volume <= 0.0 {
        return;
    }
    thread::spawn(move || {
        if let Err(err) = chime(wanted.as_deref(), volume, notes) {
            eprintln!("cue failed: {err}");
        }
    });
}

fn chime(wanted: Option<&str>, volume: f32, notes: &[f32]) -> io::Result<()> {
    let host = cpal::default_host();
    let device = match wanted {
        Some(fragment) => {
            let lowered = fragment.to_ascii_lowercase();
            host.output_devices()
                .map_err(|err| io::Error::other(err.to_string()))?
                .find(|device| {
                    device.description().is_ok_and(|described| {
                        described.name().to_ascii_lowercase().contains(&lowered)
                    })
                })
                .ok_or_else(|| io::Error::other(format!("no output matching {fragment:?}")))?
        }
        None => host
            .default_output_device()
            .ok_or_else(|| io::Error::other("no output device"))?,
    };
    let config = device
        .default_output_config()
        .map_err(|err| io::Error::other(err.to_string()))?;
    let rate = config.sample_rate() as f32;
    let channels = config.channels() as usize;
    let per_note = (rate * CUE_NOTE as f32 / 1000.0) as usize;
    let length = per_note * notes.len();
    // a few ms of attack, or the strike itself clicks
    let attack = (rate * 0.003).max(1.0) as usize;
    let count = notes.len() as u64;
    let notes: Vec<f32> = notes.to_vec();

    let mut index = 0usize;
    let mut next = move || {
        if index >= length {
            return 0.0;
        }
        let (note, step) = (index / per_note, index % per_note);
        let seconds = step as f32 / rate;
        let hz = notes[note];
        let phase = seconds * hz * std::f32::consts::TAU;
        // a quiet second harmonic gives it some body; the sine alone sounds like a test
        let wave = phase.sin() + 0.12 * (phase * 2.0).sin();
        let envelope = (step as f32 / attack as f32).min(1.0) * (-seconds * CUE_DECAY).exp();
        index += 1;
        wave * envelope * volume
    };

    let fail = |err| eprintln!("cue stream error: {err}");
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => device.build_output_stream(
            config.config(),
            move |buffer: &mut [f32], _: &_| {
                for frame in buffer.chunks_mut(channels) {
                    frame.fill(next());
                }
            },
            fail,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_output_stream(
            config.config(),
            move |buffer: &mut [i16], _: &_| {
                for frame in buffer.chunks_mut(channels) {
                    frame.fill((next() * i16::MAX as f32) as i16);
                }
            },
            fail,
            None,
        ),
        other => return Err(io::Error::other(format!("unsupported output format {other:?}"))),
    }
    .map_err(|err| io::Error::other(err.to_string()))?;
    stream.play().map_err(|err| io::Error::other(err.to_string()))?;
    // hold the stream open until the notes have actually come out
    thread::sleep(Duration::from_millis(CUE_NOTE * count + 80));
    Ok(())
}

fn input_names() -> Vec<String> {
    let Ok(devices) = cpal::default_host().input_devices() else { return Vec::new() };
    devices
        .filter_map(|device| device.description().ok().map(|d| d.name().to_string()))
        .collect()
}

fn option<'a>(options: &'a [String], key: &str) -> Option<&'a str> {
    options
        .iter()
        .filter_map(|option| option.split_once('='))
        .find(|(name, _)| *name == key)
        .map(|(_, value)| value)
}

pub fn speakers() -> io::Result<()> {
    let host = cpal::default_host();
    let default = host
        .default_output_device()
        .and_then(|device| device.description().ok())
        .map(|described| described.name().to_string());
    for device in host
        .output_devices()
        .map_err(|err| io::Error::other(err.to_string()))?
    {
        let Ok(described) = device.description() else { continue };
        let name = described.name();
        let marker = if Some(name.to_string()) == default { "*" } else { " " };
        println!("{marker} {name}");
    }
    println!("\n* is the current default. A Bluetooth headset held in hands-free mode for");
    println!("  its mic cannot play through its stereo endpoint: name the hands-free one.");
    Ok(())
}

/// Record two seconds from the mic and say how much arrived and how loud it was:
/// "is the headset actually sending audio" without a press or a transcription.
pub fn miccheck(wanted: Option<&str>, wake: Option<&str>) -> io::Result<()> {
    let mic = Microphone::open(wanted)?;
    // optionally play silence on an output meanwhile, to see whether that is what
    // starts a hands-free link's audio
    if let Some(output) = wake {
        let wake = output;
        let output = output.to_string();
        thread::spawn(move || {
            if let Err(err) = chime(Some(&output), 0.000_01, &[440.0; 24]) {
                eprintln!("wake output failed: {err}");
            }
        });
        println!("playing near-silence on the {wake:?} output during the check");
    }
    mic.start();
    thread::sleep(Duration::from_secs(2));
    let lag = mic.lag();
    let clip = mic.stop();
    println!(
        "{} samples at 16 kHz in 2 s ({:.2} s of audio), level {:.4}, first audio after {}",
        clip.len(),
        clip.len() as f32 / WHISPER_RATE as f32,
        loudness(&clip),
        lag.map_or("never".to_string(), |lag| format!("{} ms", lag.as_millis()))
    );
    Ok(())
}

/// Every format each device matching `fragment` accepts: for a Bluetooth headset
/// this says whether its hands-free link can do 16 kHz (wideband speech, mSBC)
/// or only 8 kHz (CVSD, which hisses).
pub fn formats(fragment: &str) -> io::Result<()> {
    let host = cpal::default_host();
    let lowered = fragment.to_ascii_lowercase();
    let named = |device: &cpal::Device| {
        device.description().map(|d| d.name().to_string()).unwrap_or_default()
    };
    for device in host.input_devices().map_err(|err| io::Error::other(err.to_string()))? {
        let name = named(&device);
        if !name.to_ascii_lowercase().contains(&lowered) {
            continue;
        }
        println!("input  {name}");
        if let Ok(configs) = device.supported_input_configs() {
            for config in configs {
                println!("    {:?} {} ch, {}..{} Hz", config.sample_format(), config.channels(),
                    config.min_sample_rate(), config.max_sample_rate());
            }
        }
    }
    for device in host.output_devices().map_err(|err| io::Error::other(err.to_string()))? {
        let name = named(&device);
        if !name.to_ascii_lowercase().contains(&lowered) {
            continue;
        }
        println!("output {name}");
        if let Ok(configs) = device.supported_output_configs() {
            for config in configs {
                println!("    {:?} {} ch, {}..{} Hz", config.sample_format(), config.channels(),
                    config.min_sample_rate(), config.max_sample_rate());
            }
        }
    }
    Ok(())
}

pub fn microphones() -> io::Result<()> {
    let host = cpal::default_host();
    let default = host
        .default_input_device()
        .and_then(|device| device.description().ok())
        .map(|described| described.name().to_string());
    for device in host
        .input_devices()
        .map_err(|err| io::Error::other(err.to_string()))?
    {
        let Ok(described) = device.description() else { continue };
        let name = described.name();
        let rate = device.default_input_config().map(|config| config.sample_rate());
        let marker = if Some(name.to_string()) == default { "*" } else { " " };
        match rate {
            Ok(rate) => println!("{marker} {rate:>6} Hz  {name}"),
            Err(_) => println!("{marker}      ?  {name}"),
        }
    }
    println!("\n* is the current default; {WHISPER_RATE} Hz or better is what Whisper wants");
    Ok(())
}

// Whisper wants 16 kHz mono f32. Averaging each output sample over its whole input
// window both decimates and acts as a crude low-pass, which matters: plain
// nearest-sample decimation from 48 kHz aliases badly enough to cost accuracy.
fn to_whisper(samples: &[f32], channels: u16, rate: u32) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let channels = channels.max(1) as usize;
    let mono: Vec<f32> = samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect();
    if rate == WHISPER_RATE {
        return mono;
    }
    let step = rate as f64 / WHISPER_RATE as f64;
    let count = (mono.len() as f64 / step).floor() as usize;
    (0..count)
        .map(|index| {
            let start = (index as f64 * step) as usize;
            let end = (((index + 1) as f64 * step).ceil() as usize).clamp(start + 1, mono.len());
            let window = &mono[start..end];
            window.iter().sum::<f32>() / window.len() as f32
        })
        .collect()
}
