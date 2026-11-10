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

mod bluetooth;
mod mic;
mod transcribe;
mod cue;
use bluetooth::*;
use mic::*;
use transcribe::*;
use cue::*;
pub use bluetooth::reconnect;
pub use mic::{formats, miccheck, microphones, speakers};

const POLL: Duration = Duration::from_millis(16);
/// A press released this quickly was a tap, not speech: it is reported as the
/// role with " tap" appended and no text, so a button can do something on a tap
/// (minus opens the Companion window) and still be push-to-talk when held.
const TAP: Duration = Duration::from_millis(350);
// A Bluetooth pad sleeps and a headset drops its hands-free link; either used to end
// the app. Now a lost device is reopened on this cadence until it comes back.
const RETRY: Duration = Duration::from_secs(2);
// rumble strength for the listening pulses, of 255 (the test buzz was 192)
const PULSE: u8 = 160;
// the closing pulse: softer than the opening one, so the two are told apart
const PULSE_SOFT: u8 = 90;

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
/// One line in %LOCALAPPDATA%\wow-companion	iming.log: milliseconds since the
/// epoch and what happened, so the gap from release to words on screen can be
/// split into its parts (the player, 2026-11-10: "still takes four seconds").
pub fn mark(what: &str) {
    use std::io::Write;
    let Some(base) = std::env::var_os("LOCALAPPDATA") else { return };
    let ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let path = std::path::PathBuf::from(base).join("wow-companion").join("timing.log");
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{ms} {what}");
    }
}

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
/// True once the loop is reading the pad with a model loaded: the companion can
/// hear the player. The in-game "companion" mark beats only while this holds.
pub static READY: AtomicBool = AtomicBool::new(false);
/// Set by a companion handing over to a newer copy once that copy is listening:
/// this one stops reading the pad, so a press is never handled twice, while its
/// requests in flight finish (two copies answering one clip, measured 2026-11-10).
pub static DEAF: AtomicBool = AtomicBool::new(false);

pub fn listen(
    model: &Path,
    options: &[String],
    vocabulary: impl Fn() -> Vec<String>,
    mut heard: impl FnMut(&str, &str) -> io::Result<()>,
) -> io::Result<()> {
    // One talk button (the player, 2026-11-10): the ask button also takes chat
    // lines, routed by their channel word, so the old dictation button (home) is
    // free for something else. `chat=` is still read, but only `chat=on:<button>`
    // brings the second button back.
    let chat = option(options, "chat").and_then(|value| value.strip_prefix("on:"));
    let mut bindings = vec![("ask", option(options, "ask").unwrap_or("minus"))];
    if let Some(button) = chat {
        bindings.push(("chat", button));
    }
    let bindings: Vec<(&str, pad::Press)> = bindings
        .iter()
        .map(|(role, name)| pad::press(name).map(|press| (*role, press)))
        .collect::<io::Result<_>>()?;
    // the pad: `pad=vid:pid` (the setup window learns it), else this setup's own
    let (vid, pid) = match option(options, "pad") {
        Some(id) => pad::split(id)?,
        None => DEFAULT_PAD,
    };
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
    let cue_device = option(options, "cue").map(str::to_string);
    let cue_volume = option(options, "volume")
        .and_then(|given| given.parse().ok())
        .unwrap_or(CUE_VOLUME);

    // loading the model is the slow part, so do it once and keep it resident
    let path = model.to_str().ok_or_else(|| io::Error::other("model path isn't UTF-8"))?;
    println!("loading {path}");
    let whisper = WhisperContext::new_with_params(path, WhisperContextParameters::default())
        .map_err(|err| io::Error::other(format!("{err:?}")))?;
    let (jobs, results) = {
        let (jobs, inbox) = std::sync::mpsc::channel::<Job>();
        let (outbox, results) = std::sync::mpsc::channel::<Done>();
        std::thread::spawn(move || {
            for job in inbox {
                mark(&format!("whisper start ({:.1}s of audio, prompt {} chars)", job.seconds, job.prompt.len()));
                let result = transcribe(&whisper, &job.clip, &job.prompt);
                mark("whisper done");
                let done = Done { role: job.role, level: job.level, seconds: job.seconds, result };
                if outbox.send(done).is_err() {
                    break;
                }
            }
        });
        (jobs, results)
    };

    for (role, press) in &bindings {
        println!("ready: hold {press} for {role}");
    }
    // Started by a restart: the mic is already open (above), so the headset's
    // hands-free link never dropped between copies. Say so, then wait for the old
    // copy to close its mic and step away (it deletes the flag) before reading the
    // pad, so a press is never handled twice.
    if let Some(flag) = std::env::var_os("WOW_COMPANION_READY_FILE") {
        let flag = std::path::PathBuf::from(flag);
        let _ = std::fs::write(&flag, "");
        let since = Instant::now();
        while flag.exists() && since.elapsed() < Duration::from_secs(15) {
            thread::sleep(Duration::from_millis(20));
        }
    }
    READY.store(true, Ordering::SeqCst);
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
    // Conversation slots (the player, 2026-11-10): a trigger held with the talk
    // button picks one; none is the main conversation.
    let slots = [("l1", pad::press("l1")?), ("l2", pad::press("l2")?), ("r1", pad::press("r1")?), ("r2", pad::press("r2")?)];
    let mut slot: Option<&str> = None;
    let mut pressed_at = Instant::now();
    // the opening pulse waits until a press has outlasted a tap: a tap (which
    // the game handles itself, opening the window) stays silent, and feeling
    // the pulse means "this is a hold, I'm listening"
    let mut pulsed = false;
    let mut retry_pad = Instant::now();
    let mut retry_mic = Instant::now();
    let mut healed_at: Option<Instant> = None;
    loop {
        // transcripts finished by the Whisper thread, delivered in order
        while let Ok(done) = results.try_recv() {
            let Done { role, level, seconds, result } = done;
            let role = role.as_str();
            match result {
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
                            mark("transcript reached the voice loop");
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
                        Err(err) => {
                            eprintln!("transcribe failed: {err}");
                            let _ = heard("notice", &format!("I could not transcribe that clip ({err}), so nothing was sent."));
                        }
            }
        }
        if SHUTDOWN.load(Ordering::SeqCst) {
            // close the mic properly before the next copy opens its own
            drop(microphone.take());
            STOPPED.store(true, Ordering::SeqCst);
            return Ok(());
        }
        // The stream open, the device listed, and no audio arriving: the headset's
        // voice link is wedged. Reconnect it the way Sound settings' Connect does,
        // then reopen the mic. The player hears about it in the window.
        if microphone.as_ref().is_some_and(Microphone::stalled)
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
        if holding.is_none() && microphone.as_ref().is_some_and(Microphone::broken) {
            eprintln!("microphone lost; waiting for it to come back");
            microphone = None;
            retry_mic = Instant::now();
        }
        if microphone.is_none() && Instant::now() >= retry_mic {
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
        if DEAF.load(Ordering::SeqCst) {
            if holding.take().is_some() {
                if let Some(mic) = &microphone {
                    mic.stop();
                }
            }
            HOLDING.store(false, Ordering::Relaxed);
            thread::sleep(POLL);
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
        // L2 and R2 together are the quick conversation (the player, 2026-11-10):
        // a fast agent for chat, links and buttons
        let modifier = if pad.held(&slots[1].1) && pad.held(&slots[3].1) {
            Some("quick")
        } else {
            slots.iter().find(|(_, press)| pad.held(press)).map(|(name, _)| *name)
        };
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
                slot = if role == "ask" { modifier } else { None };
                mic.start();
                if beeps {
                    cue(cue_device.clone(), cue_volume, &CUE_OPEN);
                }
                pulsed = false;
                println!("listening for {role}");
            }
            (None, Some(role)) => {
                mark(&format!("released {role}"));
                let clip = mic.stop();
                if beeps {
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
                    // said at once, before Whisper runs: the player sees the clip
                    // arrived instead of wondering whether it was dropped
                    // the slot rides on the role: "ask@l2"
                    let tagged = match slot {
                        Some(name) if role == "ask" => format!("ask@{name}"),
                        _ => role.to_string(),
                    };
                    let _ = heard(&format!("{tagged} heard"), "");
                    // Whisper runs on its own thread, so the pad and mic stay
                    // live: slipping back onto the button while this clip is
                    // transcribed starts the next one at once (the player,
                    // 2026-11-10). Results come back in order, below.
                    let prompt = prompt(&vocabulary());
                    mark("prompt built");
                    let _ = jobs.send(Job { role: tagged, clip, prompt, level, seconds });
                }
            }
            (Some(role), Some(_)) => {
                // a trigger pulled just after the talk button still counts
                if role == "ask" && slot.is_none() {
                    slot = modifier;
                }
                // the second trigger of L2+R2 pulled a moment after the first
                if role == "ask" && modifier == Some("quick") && matches!(slot, Some("l2") | Some("r2")) {
                    slot = modifier;
                }
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

fn option<'a>(options: &'a [String], key: &str) -> Option<&'a str> {
    options
        .iter()
        .filter_map(|option| option.split_once('='))
        .find(|(name, _)| *name == key)
        .map(|(_, value)| value)
}
