//! The game's settings page, the companion's half
//! (docs/proposals/settings-in-game.md). The companion is the one truth for its
//! settings: `status` shows the page what this companion runs with and the mics
//! there are, and the page's `bind` and `set` commands, read off the strip
//! (requests.rs `watch_commands`), change them. A change is written to
//! settings.toml and handed to the voice loop, which takes it between presses
//! (`voice::change`): no restart, so a request in flight never holds one up.

use std::{
    path::{Path, PathBuf},
    sync::OnceLock,
    time::Instant,
};

use wow_companion_settings::Settings;

use crate::message::Msg;
use crate::{pad, voice};

/// The Whisper model file `run` was given: Whisper is there to pick when it is.
static MODEL: OnceLock<PathBuf> = OnceLock::new();

const FEEDBACK: [&str; 3] = ["rumble", "beep", "both"];
const SPEECH: [&str; 2] = ["whisper", "streaming"];

fn option<'a>(options: &'a [String], key: &str) -> Option<&'a str> {
    options.iter().find_map(|each| each.strip_prefix(key)?.strip_prefix('='))
}

pub(crate) fn running(model: &Path) {
    let _ = MODEL.set(model.to_path_buf());
}

/// What the voice loop runs with now: the keys, feedback, the engine and the
/// mic, and the engines there are to pick.
struct Running {
    keys: Vec<(&'static str, pad::Bound)>,
    feedback: String,
    speech: String,
    mic: Option<String>,
    engines: Vec<String>,
}

fn now() -> Running {
    let options = voice::running();
    let (vid, pid) = option(&options, "pad").and_then(|id| pad::split(id).ok()).unwrap_or((0, 0));
    let keys = pad::KEYS
        .iter()
        .filter_map(|key| pad::bound(key, option(&options, key), vid, pid).ok().flatten().map(|bound| (*key, bound)))
        .collect();
    let mut engines = Vec::new();
    if MODEL.get().is_some_and(|model| model.is_file()) {
        engines.push("whisper".to_string());
    }
    if option(&options, "stream_model").is_some_and(|folder| Path::new(folder).is_dir()) {
        engines.push("streaming".to_string());
    }
    Running {
        keys,
        feedback: option(&options, "feedback").unwrap_or("rumble").to_string(),
        speech: option(&options, "speech").unwrap_or("whisper").to_string(),
        mic: option(&options, "mic").map(str::to_string),
        engines,
    }
}

/// `{ kind = "status", mic = ..., settings = {...}, binding = "<key>" }`: whether
/// the mic is open, the settings this companion runs with (each key's buttons
/// as WoW names joined with `+`) with the mics Windows lists (`mics`), and the
/// key being set while the page waits for its press. Sent again when the mics
/// listed change (heartbeat.rs).
pub(crate) fn status(mic: bool, mics: &[String]) -> Msg {
    let mut msg = Msg::new("status").flag("mic", mic);
    let running = now();
    if !running.keys.is_empty() || !running.engines.is_empty() {
        let mut settings = Msg::table();
        for (key, bound) in &running.keys {
            settings = settings.text(key, &bound.name());
        }
        settings = settings.text("feedback", &running.feedback).text("speech", &running.speech);
        if let Some(mic) = &running.mic {
            settings = settings.text("mic", mic);
        }
        settings = settings.texts("engines", running.engines.clone()).texts("mics", mics.to_vec());
        msg = msg.msg("settings", settings);
    }
    if let Some(binding) = voice::BINDING.lock().unwrap().as_ref() {
        msg = msg.text("binding", &binding.key);
    }
    msg
}

fn send(addons: &Path, msg: Msg) {
    if let Err(err) = crate::send(addons, &msg) {
        eprintln!("  settings page: not delivered: {err}");
    }
}

/// `status` as it stands now.
fn current() -> Msg {
    status(voice::MIC.load(std::sync::atomic::Ordering::Relaxed), &voice::input_names())
}

/// `status` with what went wrong in the row of `key`: `bind` or `set`.
fn refuse(addons: &Path, field: &'static str, key: &str, why: &str) {
    println!("  settings page: {field} {key} refused: {why}");
    send(addons, current().msg(field, Msg::table().text("key", key).text("error", why)));
}

/// `bind <key> start|cancel|<PADNAME>+...`: a key set by pressing its buttons
/// on the page, every button that went down named.
pub(crate) fn bind(addons: &Path, key: &str, what: &str) {
    let Some(key) = pad::KEYS.iter().find(|each| **each == key).copied() else {
        return refuse(addons, "bind", key, "The companion has no such button.");
    };
    match what {
        "start" => {
            *voice::BINDING.lock().unwrap() = Some(voice::Binding { key: key.to_string(), since: Instant::now(), pressed: Vec::new() });
            println!("  settings page: waiting for the {key} press");
            send(addons, current());
        }
        "cancel" => {
            let mut binding = voice::BINDING.lock().unwrap();
            if binding.as_ref().is_some_and(|each| each.key == key) {
                *binding = None;
            }
        }
        names => {
            let pressed = {
                let mut binding = voice::BINDING.lock().unwrap();
                match binding.take() {
                    Some(each) if each.key == key => each.pressed,
                    other => {
                        *binding = other;
                        return refuse(addons, "bind", key, "The companion was not waiting for that press. Try again.");
                    }
                }
            };
            let mut presses: Vec<pad::Press> = Vec::new();
            for press in pressed {
                if !presses.contains(&press) {
                    presses.push(press);
                }
            }
            let names: Vec<String> = names.split('+').map(str::to_string).collect();
            let result = if presses.is_empty() {
                Err("No press of a button reached the companion. Press it again.".to_string())
            } else if presses.len() != names.len() {
                Err(format!("The companion saw {} buttons go down and the game {}. Press it again.", presses.len(), names.len()))
            } else {
                bound(key, pad::Bound { presses, names })
            };
            match result {
                Ok(()) => send(addons, current()),
                Err(why) => refuse(addons, "bind", key, &why),
            }
        }
    }
}

/// The talk button is one button, in no chord; a chord is no other key's.
fn bound(key: &'static str, bound: pad::Bound) -> Result<(), String> {
    if let Some(name) = bound.names.iter().find(|name| !name.starts_with("PAD") || !name.chars().all(|c| c.is_ascii_alphanumeric())) {
        return Err(format!("{name:?} is not a WoW button name."));
    }
    let running = now();
    let talk = running.keys.iter().find(|(each, _)| *each == "talk").map(|(_, talk)| talk);
    if key == "talk" {
        if bound.presses.len() > 1 {
            return Err("The talk button is one button. Press only the one you want.".to_string());
        }
        if let Some((other, _)) = running.keys.iter().find(|(each, chord)| *each != "talk" && chord.presses.contains(&bound.presses[0])) {
            return Err(format!("That button is in the {other} chord."));
        }
    } else {
        if talk.is_some_and(|talk| bound.presses.contains(&talk.presses[0])) {
            return Err("That holds the talk button.".to_string());
        }
        if let Some((other, _)) = running.keys.iter().find(|(each, chord)| *each != key && chord.same_buttons(&bound)) {
            return Err(format!("That is already the {other} chord."));
        }
    }
    let now = running.keys.iter().find(|(each, _)| *each == key).map(|(_, held)| held.spec());
    apply(key, &bound.spec(), now.as_deref())
}

/// `set <key> <value>`: feedback, the speech engine or the mic.
pub(crate) fn set(addons: &Path, key: &str, value: &str) {
    let value = value.trim();
    let running = now();
    let result = match key {
        "feedback" if FEEDBACK.contains(&value) => apply("feedback", value, Some(&running.feedback)),
        "speech" if SPEECH.contains(&value) => {
            if running.engines.iter().any(|each| each == value) {
                apply("speech", value, Some(&running.speech))
            } else {
                Err(format!("The {value} engine's model is not downloaded: download it in the setup window."))
            }
        }
        "mic" if !value.is_empty() => apply("mic", value, running.mic.as_deref()),
        _ => Err(format!("{key} cannot be {value:?}.")),
    };
    if let Err(why) = result {
        refuse(addons, "set", key, &why);
    }
}

/// Write `key = value` and hand it to the voice loop, unless it already runs
/// with it. The loop's taking it sends `status` again (heartbeat.rs).
fn apply(key: &str, value: &str, running: Option<&str>) -> Result<(), String> {
    let mut file = Settings::load();
    if file.get(key) != Some(value) {
        file.set(key, value);
        file.save().map_err(|err| format!("The settings file could not be written: {err}"))?;
    }
    if running == Some(value) {
        return Ok(());
    }
    println!("  settings page: {key} = {value}");
    voice::change(key, value);
    Ok(())
}
