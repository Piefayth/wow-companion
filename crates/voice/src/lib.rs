//! Push-to-talk voice capture. Hold a controller chord, speak, release: Whisper
//! gets the whole clip at release, or the streaming engine (stream.rs)
//! hears it while the button is held and has the text at release. Stays on this
//! machine, so a hot mic can't leak the room.

use std::{
    io,
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc::TryRecvError,
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
mod stream;
mod cue;
use bluetooth::*;
use mic::*;
use transcribe::*;
use cue::*;
pub use bluetooth::reconnect;
pub use mic::{formats, miccheck, microphones, speakers};
pub use transcribe::transcribe_file;
pub use stream::transcribe_stream_file;

const POLL: Duration = Duration::from_millis(16);
/// A press released this quickly was a tap, not speech, and is no clip: the
/// game answers the talk button's tap itself (it opens the Companion window).
const TAP: Duration = Duration::from_millis(350);
// A Bluetooth pad sleeps and a headset drops its hands-free link; either used to end
// the app. Now a lost device is reopened on this cadence until it comes back.
const RETRY: Duration = Duration::from_secs(2);
// rumble strength for the listening pulses, of 255 (the test buzz was 192)
const PULSE: u8 = 160;
// the closing pulse: softer than the opening one, so the two are told apart
const PULSE_SOFT: u8 = 90;

/// One line in `%LOCALAPPDATA%\wow-companion\timing.log`: milliseconds since the
/// epoch and what happened, so the gap from release to words on screen can be
/// split into its parts. Past 8 MB it becomes timing.old.log, as audit.log does.
pub fn mark(what: &str) {
    use std::io::Write;
    let Some(base) = std::env::var_os("LOCALAPPDATA") else { return };
    let ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let path = std::path::PathBuf::from(base).join("wow-companion").join("timing.log");
    if std::fs::metadata(&path).is_ok_and(|meta| meta.len() > 8 << 20) {
        let _ = std::fs::rename(&path, path.with_extension("old.log"));
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{ms} {what}");
    }
}

/// True while the talk button is held: a restart waits for the release, so no
/// clip is cut off halfway.
pub static HOLDING: AtomicBool = AtomicBool::new(false);
/// Clips handed to the speech engine whose words (or why there are none) have not
/// been handed on yet: a restart waits for none.
pub static PENDING: AtomicUsize = AtomicUsize::new(0);

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
/// Paused by the player (the tray's "Pause listening"): the talk button does
/// nothing until resumed. Its own flag, so a resume can never undo a hand-over's
/// DEAF.
pub static PAUSED: AtomicBool = AtomicBool::new(false);

/// The speech engine the loop feeds: Whisper takes a whole clip at release; the
/// streaming engine takes the audio while the button is held.
enum Engine {
    Whisper(std::sync::mpsc::Sender<Job>),
    Streaming(std::sync::mpsc::Sender<stream::Feed>),
}

impl Engine {
    /// A press that will not become a clip: the streaming engine forgets it.
    fn drop_clip(&self) {
        if let Engine::Streaming(feed) = self {
            let _ = feed.send(stream::Feed::Drop);
        }
    }

    /// The streaming engine gets what the mic captured since its last piece.
    fn feed(&self, mic: &Microphone) {
        if let Engine::Streaming(feed) = self {
            let samples = mic.take_new();
            if !samples.is_empty() {
                let _ = feed.send(stream::Feed::Audio(samples));
            }
        }
    }
}

/// Which conversation a clip is for: the triggers held with the talk button.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Slot {
    /// no trigger
    Main,
    L1,
    L2,
    R1,
    R2,
    /// L2 and R2 together: the fast agent
    Quick,
    /// L1 and R1 together: the words go straight to the chat box, no agent
    Dictation,
}

impl Slot {
    /// The conversations a request can be typed into (`tell`): all but dictation.
    pub const CONVERSATIONS: [Slot; 6] = [Slot::Main, Slot::L1, Slot::L2, Slot::R1, Slot::R2, Slot::Quick];

    /// The conversation's name everywhere else ("" is the main one).
    pub const fn key(self) -> &'static str {
        match self {
            Slot::Main => "",
            Slot::L1 => "l1",
            Slot::L2 => "l2",
            Slot::R1 => "r1",
            Slot::R2 => "r2",
            Slot::Quick => "quick",
            Slot::Dictation => "say",
        }
    }
}

/// What the voice loop tells the companion, in the order it happens to a clip.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Event<'a> {
    /// A clip was let go and is at the speech engine; its words follow.
    Released(Slot),
    /// What was said in a released clip.
    Words(Slot, &'a str),
    /// A released clip came back with no words: why, for the player.
    Empty(Slot, &'a str),
    /// A press too short in audio to transcribe, never released: why.
    Unheard(Slot, &'a str),
    /// The loop's own news (a reconnected headset).
    Notice(&'a str),
}

impl Event<'_> {
    /// The same event for another conversation (the agents off: every clip is
    /// dictation's).
    pub fn for_slot(self, slot: Slot) -> Self {
        match self {
            Event::Released(_) => Event::Released(slot),
            Event::Words(_, text) => Event::Words(slot, text),
            Event::Empty(_, why) => Event::Empty(slot, why),
            Event::Unheard(_, why) => Event::Unheard(slot, why),
            Event::Notice(text) => Event::Notice(text),
        }
    }
}

/// Hold the talk button, speak, release; `heard` is told each clip's events.
///
/// The talk button defaults to one WoW ignores (minus; Guide on an Xbox pad): we
/// cannot consume the input, so anything the game binds would fire twice.
///
/// `vocabulary` is asked afresh for every clip, so names learned at the last reload
/// are in the prompt without restarting.
pub fn listen(
    model: &Path,
    options: &[String],
    vocabulary: impl Fn() -> Vec<String>,
    mut heard: impl FnMut(Event) -> io::Result<()>,
) -> io::Result<()> {
    // the pad: `pad=vid:pid` or `pad=xinput` (the setup window picks it), else
    // this setup's own; button names mean different bits on an Xbox pad
    let (vid, pid) = match option(options, "pad") {
        Some(id) => pad::split(id)?,
        None => DEFAULT_PAD,
    };
    let talk = pad::press_for(option(options, "ask").unwrap_or(pad::default_talk(vid, pid)), vid, pid)?;
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

    // One engine, chosen in the setup window (`speech=`): Whisper, or the streaming
    // engine (stream.rs). Loading is the slow part, so it is done once
    // and kept resident; results come back on `results` either way, in order.
    let (outbox, results) = std::sync::mpsc::channel::<Done>();
    let engine = match option(options, "speech").unwrap_or("whisper") {
        "whisper" => {
            let path = model.to_str().ok_or_else(|| io::Error::other("model path isn't UTF-8"))?;
            println!("loading {path}");
            let whisper = WhisperContext::new_with_params(path, WhisperContextParameters::default())
                .map_err(|err| io::Error::other(format!("{err:?}")))?;
            let (jobs, inbox) = std::sync::mpsc::channel::<Job>();
            std::thread::spawn(move || {
                for job in inbox {
                    mark(&format!("whisper start ({:.1}s of audio, prompt {} chars)", job.seconds, job.prompt.len()));
                    let result = transcribe(&whisper, &job.clip, &job.prompt);
                    mark("whisper done");
                    let done = Done { slot: job.slot, level: job.level, seconds: job.seconds, result };
                    if outbox.send(done).is_err() {
                        break;
                    }
                }
            });
            Engine::Whisper(jobs)
        }
        "streaming" => {
            let dir = option(options, "stream_model")
                .map(std::path::PathBuf::from)
                .ok_or_else(|| io::Error::other("speech=streaming needs stream_model=<folder>: download it in the setup window"))?;
            println!("loading the streaming model in {}", dir.display());
            let (feed, inbox) = std::sync::mpsc::channel::<stream::Feed>();
            let (loaded, outcome) = std::sync::mpsc::channel::<Result<(), String>>();
            // the recognizer lives on its own thread from the start: loaded there,
            // the load's outcome reported back before the loop reads the pad
            std::thread::spawn(move || match stream::load(&dir, stream::THREADS) {
                Ok(recognizer) => {
                    let _ = loaded.send(Ok(()));
                    stream::run(recognizer, inbox, outbox);
                }
                Err(err) => {
                    let _ = loaded.send(Err(err.to_string()));
                }
            });
            outcome
                .recv()
                .map_err(|_| io::Error::other("the streaming engine's thread ended while loading"))?
                .map_err(io::Error::other)?;
            Engine::Streaming(feed)
        }
        other => return Err(io::Error::other(format!("speech={other}: it is whisper or streaming"))),
    };

    println!("ready: hold {talk} to talk");
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
    let mut holding = false;
    // Conversation slots: a trigger held with the talk button picks one; none is
    // the main conversation.
    let triggers: Vec<(Slot, pad::Press)> = [(Slot::L1, "l1"), (Slot::L2, "l2"), (Slot::R1, "r1"), (Slot::R2, "r2")]
        .iter()
        .map(|(slot, name)| pad::press_for(name, vid, pid).map(|press| (*slot, press)))
        .collect::<io::Result<_>>()?;
    let trigger = |slot: Slot| &triggers.iter().find(|(each, _)| *each == slot).expect("every trigger has a press").1;
    // None until a trigger is pulled during the press
    let mut slot: Option<Slot> = None;
    let mut pressed_at = Instant::now();
    // the opening pulse waits until a press has outlasted a tap: a tap (which
    // the game handles itself, opening the window) stays silent, and feeling
    // the pulse means "this is a hold, I'm listening"
    let mut pulsed = false;
    let mut retry_pad = Instant::now();
    let mut retry_mic = Instant::now();
    let mut healed_at: Option<Instant> = None;
    loop {
        // transcripts finished by the engine's thread, delivered in order (the
        // echo and silence checks below are for Whisper's habits; streaming text
        // passes them unless a near-silent clip reads as one of Whisper's phrases)
        loop {
            let done = match results.try_recv() {
                Ok(done) => done,
                Err(TryRecvError::Empty) => break,
                // the engine's thread is gone: no clip it held will come back
                Err(TryRecvError::Disconnected) => {
                    PENDING.store(0, Ordering::SeqCst);
                    break;
                }
            };
            let Done { slot, level, seconds, result } = done;
            match result {
                        Ok(text) if text.is_empty() => {
                            println!("heard nothing (level {level:.4})");
                            let _ = heard(Event::Empty(slot, "I heard nothing in that clip, so nothing was sent."));
                        }
                        // Whisper filling silence with its own prompt: nothing but the
                        // echo, or an echo in a clip too quiet to hold speech (a dead
                        // mic measured 0.0011; speech here is 0.016 and up)
                        Ok(text) if without_echo(&text).is_empty()
                            || (level < SILENCE && without_echo(&text) != text.trim()) => {
                            println!("heard only the prompt echoed (level {level:.4}); ignored {text:?}");
                            let _ = heard(Event::Empty(slot, "That clip held no words I could make out, so nothing was sent."));
                        }
                        Ok(text) if level < SILENCE && phantom(&text) => {
                            println!("heard only silence (level {level:.4}); ignored {text:?}");
                            let _ = heard(Event::Empty(slot, &format!(
                                "That clip sounded like silence (I made out only {text:?}), so nothing was sent."
                            )));
                        }
                        Ok(text) => {
                            mark("transcript reached the voice loop");
                            // Whisper sometimes glues its prompt onto real speech
                            // ("Commands: and, uh, ..."): keep the speech
                            let text = without_echo(&text);
                            println!("heard ({seconds:.1}s, {slot:?}, level {level:.4}): {text}");
                            // a failed delivery must not kill the loop: the game may
                            // be closed, or every slot spent until the next reload
                            if let Err(err) = heard(Event::Words(slot, &text)) {
                                eprintln!("  not delivered: {err}");
                            }
                        }
                        Err(err) => {
                            eprintln!("transcribe failed: {err}");
                            let _ = heard(Event::Empty(slot, &format!("I could not transcribe that clip ({err}), so nothing was sent.")));
                        }
            }
            PENDING.fetch_sub(1, Ordering::SeqCst);
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
            let _ = heard(Event::Notice(
                "The headset's mic stopped sending audio, so I reconnected its voice link. If I still cannot hear you, reconnect the headset.",
            ));
        }
        // a dead stream is replaced between presses, never during one
        if !holding && microphone.as_ref().is_some_and(Microphone::broken) {
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
            if std::mem::take(&mut holding) {
                if let Some(mic) = &microphone {
                    mic.stop();
                }
                engine.drop_clip();
                println!("  discarded the clip in progress");
            }
            continue;
        }
        if DEAF.load(Ordering::SeqCst) || PAUSED.load(Ordering::SeqCst) {
            if std::mem::take(&mut holding) {
                if let Some(mic) = &microphone {
                    mic.stop();
                }
                engine.drop_clip();
            }
            HOLDING.store(false, Ordering::Relaxed);
            thread::sleep(POLL);
            continue;
        }
        if ALERT.swap(false, Ordering::SeqCst) && rumbles {
            rumbler.play(&[(0, PULSE, PULSE), (60, 0, 0), (120, PULSE, PULSE), (180, 0, 0), (240, PULSE, PULSE), (300, 0, 0)]);
        }
        let held = pad.held(&talk);
        // L2 and R2 together are the quick conversation: a fast agent for chat,
        // links and buttons. L1 and R1 together are dictation: the words go
        // straight to the chat box on the channel picked on the chat wheel, with
        // no agent in the way
        let modifier = if pad.held(trigger(Slot::L2)) && pad.held(trigger(Slot::R2)) {
            Some(Slot::Quick)
        } else if pad.held(trigger(Slot::L1)) && pad.held(trigger(Slot::R1)) {
            Some(Slot::Dictation)
        } else {
            triggers.iter().find(|(_, press)| pad.held(press)).map(|(slot, _)| *slot)
        };
        let Some(mic) = &microphone else {
            if held && !holding {
                println!("no microphone yet; still waiting for it");
            }
            holding = held;
            HOLDING.store(held, Ordering::Relaxed);
            thread::sleep(POLL);
            continue;
        };

        match (held, holding) {
            (true, false) => {
                pressed_at = Instant::now();
                slot = modifier;
                mic.start();
                if let Engine::Streaming(feed) = &engine {
                    let _ = feed.send(stream::Feed::Start { hotwords: stream::hotwords(&vocabulary()), rate: mic.rate });
                }
                if beeps {
                    cue(cue_device.clone(), cue_volume, &CUE_OPEN);
                }
                pulsed = false;
                println!("listening");
            }
            (false, true) => {
                let slot = slot.unwrap_or(Slot::Main);
                mark(&format!("released {slot:?}"));
                // the recording ends first, so the streaming engine's last piece
                // is the last of the audio
                mic.end();
                engine.feed(mic);
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
                    engine.drop_clip();
                    println!("tap");
                } else if Duration::from_secs_f32(seconds) < MINIMUM_CLIP {
                    // held long enough to mean it, yet almost no audio arrived
                    engine.drop_clip();
                    println!("too short, ignored ({seconds:.2}s of audio)");
                    let _ = heard(Event::Unheard(slot, &format!(
                        "I got only {seconds:.1}s of audio from that press, so nothing was sent. If you spoke, the mic may not be sending."
                    )));
                } else {
                    // Every clip goes to the engine; none is judged by volume. A
                    // filter on level dropped a real, quiet sentence (0.0024, the
                    // first press after a restart) without a word to the player.
                    let level = loudness(&clip);
                    // said at once, before the engine has the text: the player sees
                    // the clip arrived instead of wondering whether it was dropped
                    let _ = heard(Event::Released(slot));
                    // The engine runs on its own thread, so the pad and mic stay
                    // live: slipping back onto the button while this clip is
                    // transcribed starts the next one at once. Results come back
                    // in order, above.
                    let sent = match &engine {
                        Engine::Whisper(jobs) => {
                            let prompt = prompt(&vocabulary());
                            mark("prompt built");
                            jobs.send(Job { slot, clip, prompt, level, seconds }).is_ok()
                        }
                        Engine::Streaming(feed) => feed.send(stream::Feed::Finish { slot, level, seconds }).is_ok(),
                    };
                    if sent {
                        PENDING.fetch_add(1, Ordering::SeqCst);
                    } else {
                        eprintln!("  the speech engine's thread has ended");
                        // empty, not unheard: the clip was already released
                        let _ = heard(Event::Empty(slot, "The speech engine has stopped, so this was not transcribed: restart the companion."));
                    }
                }
            }
            (true, true) => {
                // a trigger pulled just after the talk button still counts
                if slot.is_none() {
                    slot = modifier;
                }
                // the second trigger of L2+R2 (or L1+R1) pulled a moment after the first
                if modifier == Some(Slot::Quick) && matches!(slot, Some(Slot::L2 | Slot::R2)) {
                    slot = modifier;
                }
                if modifier == Some(Slot::Dictation) && matches!(slot, Some(Slot::L1 | Slot::R1)) {
                    slot = modifier;
                }
                engine.feed(mic);
                if rumbles && !pulsed && pressed_at.elapsed() >= TAP {
                    // one firm pulse: past a tap, so listening
                    pulsed = true;
                    rumbler.play(&[(0, PULSE, PULSE), (120, 0, 0)]);
                }
            }
            _ => {}
        }
        holding = held;
        HOLDING.store(held, Ordering::Relaxed);
        thread::sleep(POLL);
    }
}

/// The transcript with any echo of Whisper's own prompt taken off the front.
/// Given silence it writes the prompt out ("Commands: the first one."), and given
/// speech it sometimes starts with it ("Commands: and, uh, ..."): dropping every
/// clip that began that way threw away real speech at normal volume. So the echo
/// is cut and what is left is the clip; empty means there was nothing else.
#[cfg(test)]
mod slot_tests {
    use super::{Event, Slot};

    #[test]
    fn every_slot_has_its_own_name_and_dictation_is_no_conversation() {
        let all = [Slot::Main, Slot::L1, Slot::L2, Slot::R1, Slot::R2, Slot::Quick, Slot::Dictation];
        let mut keys: Vec<&str> = all.iter().map(|slot| slot.key()).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), all.len());
        assert!(!Slot::CONVERSATIONS.contains(&Slot::Dictation));
        assert_eq!(Slot::Main.key(), "");
    }

    #[test]
    fn an_event_moves_to_another_slot_whole() {
        assert_eq!(Event::Words(Slot::L2, "hi").for_slot(Slot::Dictation), Event::Words(Slot::Dictation, "hi"));
        assert_eq!(Event::Notice("n").for_slot(Slot::Dictation), Event::Notice("n"));
    }
}

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
