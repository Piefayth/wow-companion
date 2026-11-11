//! This PC's settings: where the game is, which model, pad, buttons and mic.
//!
//! One file, `%LOCALAPPDATA%\wow-companion\settings.toml`, written by the setup
//! window (`wow-companion-setup`) and read by `wow-companion run` and `doctor`.
//! Flat `key = "value"` lines, so it is plain to read and edit by hand; command-line
//! options still win over it.
//!
//! Keys: `addons` (the game's Interface\AddOns folder), `model` (the Whisper
//! model file), `engine` (`cpu` to use the CPU build a release ships beside the
//! GPU one), and the run options: `pad` (vid:pid), `ask` (the talk button: a
//! name or byte:mask), `chat`, `mic`, `cue`, `volume`, `agent`, `speech`
//! (`whisper` or `streaming`) and `stream_model` (the
//! streaming model's folder).

pub mod changes;
pub mod platform;
pub mod stream_model;

use std::{fs, io, path::PathBuf};

/// `agent = "off"`: dictation only. No agent addons in the game, no agent on the
/// PC; everything said goes to the chat box.
pub const AGENT_OFF: &str = "off";

/// Which build this is: the release's tag (the release workflow sets
/// `WOW_COMPANION_VERSION` from it), or a build from the source.
pub const VERSION: &str = match option_env!("WOW_COMPANION_VERSION") {
    Some(version) => version,
    None => "a development build",
};

/// The run options a settings file may carry, in the order they are written.
pub const OPTIONS: &[&str] = &["pad", "ask", "chat", "mic", "cue", "volume", "agent", "speech", "stream_model"];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Settings {
    entries: Vec<(String, String)>,
}

impl Settings {
    pub fn path() -> Option<PathBuf> {
        let base = std::env::var_os("LOCALAPPDATA")?;
        Some(PathBuf::from(base).join("wow-companion").join("settings.toml"))
    }

    /// The saved settings, or empty ones if there are none yet.
    pub fn load() -> Self {
        Self::path().and_then(|path| fs::read_to_string(path).ok()).map(|text| Self::parse(&text)).unwrap_or_default()
    }

    pub fn parse(text: &str) -> Self {
        let mut settings = Self::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((key, value)) = line.split_once('=') {
                let value = value.trim();
                let value = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
                settings.set(key.trim(), &value.replace("\\\\", "\\").replace("\\\"", "\""));
            }
        }
        settings
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.entries.iter().find(|(name, _)| name == key).map(|(_, value)| value.as_str()).filter(|v| !v.is_empty())
    }

    /// Set a key; an empty value removes it.
    pub fn set(&mut self, key: &str, value: &str) {
        self.entries.retain(|(name, _)| name != key);
        if !value.is_empty() {
            self.entries.push((key.to_string(), value.to_string()));
        }
    }

    /// The run options as `key=value` strings, for the voice loop's option list.
    pub fn options(&self) -> Vec<String> {
        OPTIONS.iter().filter_map(|key| self.get(key).map(|value| format!("{key}={value}"))).collect()
    }

    pub fn render(&self) -> String {
        let mut out = String::from("# WoW Companion settings for this PC (the setup window writes this)\n");
        let mut keys: Vec<&str> = vec!["addons", "model", "engine"];
        keys.extend(OPTIONS);
        let extra: Vec<&str> =
            self.entries.iter().map(|(k, _)| k.as_str()).filter(|k| !keys.contains(k)).collect();
        keys.extend(extra);
        for key in keys {
            if let Some(value) = self.get(key) {
                out.push_str(&format!("{key} = \"{}\"\n", value.replace('\\', "\\\\").replace('"', "\\\"")));
            }
        }
        out
    }

    pub fn save(&self) -> io::Result<PathBuf> {
        let path = Self::path().ok_or_else(|| io::Error::other("LOCALAPPDATA is not set"))?;
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(&path, self.render())?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::Settings;

    #[test]
    fn round_trips_paths_and_options() {
        let mut settings = Settings::default();
        settings.set("addons", r"S:\World of Warcraft\_forever_\Interface\AddOns");
        settings.set("ask", "9:0x10");
        settings.set("mic", "AirPods \"Max\"");
        let again = Settings::parse(&settings.render());
        assert_eq!(again, settings);
        assert_eq!(again.options(), vec!["ask=9:0x10".to_string(), "mic=AirPods \"Max\"".to_string()]);
    }

    #[test]
    fn an_empty_value_removes_a_key() {
        let mut settings = Settings::parse("mic = \"airpods\"\n");
        settings.set("mic", "");
        assert_eq!(settings.get("mic"), None);
    }
}
