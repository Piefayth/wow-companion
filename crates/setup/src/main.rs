//! The setup window: everything `wow-companion run` needs on a new PC, picked by
//! looking and pressing instead of typed as arguments. It writes the settings file
//! (crates/settings) and can run `doctor` against it. Day to day the companion
//! stays in the game; this is for the first run and for changing hardware.
#![windows_subsystem = "windows"]

use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU32, Ordering},
    },
    thread,
    time::Duration,
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use eframe::egui;
use wow_companion_pad as pad;
use wow_companion_settings::Settings;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([620.0, 640.0]).with_title("WoW Companion setup"),
        ..Default::default()
    };
    eframe::run_native("WoW Companion setup", options, Box::new(|_| Ok(Box::new(Setup::new()))))
}

struct Setup {
    settings: Settings,
    addons: String,
    model: String,
    pad: String,
    ask: String,
    mic: String,
    agent: String,
    found_addons: Vec<String>,
    models: Vec<String>,
    pads: Vec<(u16, u16, String)>,
    mics: Vec<String>,
    /// what the learn thread is saying, and the button it found
    learning: Arc<Mutex<(String, Option<String>)>>,
    meter: Meter,
    claude: String,
    /// output of doctor or the last save
    report: Arc<Mutex<String>>,
    /// `cpu` when the self-test chose the CPU build
    engine: String,
    /// the speech self-test: running, then its verdict and details
    speech: Arc<Mutex<Option<SpeechTest>>>,
}

#[derive(Clone)]
struct SpeechTest {
    passed: bool,
    summary: String,
    details: String,
}

impl Setup {
    fn new() -> Self {
        let settings = Settings::load();
        let value = |key: &str| settings.get(key).unwrap_or_default().to_string();
        let mut setup = Self {
            addons: value("addons"),
            model: value("model"),
            pad: value("pad"),
            ask: value("ask"),
            mic: value("mic"),
            agent: value("agent"),
            engine: value("engine"),
            settings,
            found_addons: find_addons(),
            models: find_models(),
            pads: Vec::new(),
            mics: Vec::new(),
            learning: Arc::default(),
            meter: Meter::default(),
            claude: claude_version(),
            report: Arc::default(),
            speech: Arc::default(),
        };
        setup.refresh_devices();
        if setup.addons.is_empty() {
            setup.addons = setup.found_addons.first().cloned().unwrap_or_default();
        }
        if setup.model.is_empty() {
            setup.model = setup.models.first().cloned().unwrap_or_default();
        }
        if setup.pad.is_empty() {
            if let Some((vid, pid, _)) = setup.pads.first() {
                setup.pad = format!("{vid:04x}:{pid:04x}");
            }
        }
        setup.meter.watch(&setup.mic);
        setup
    }

    fn refresh_devices(&mut self) {
        self.pads = pad::gamepads().unwrap_or_default();
        self.mics = cpal::default_host()
            .input_devices()
            .map(|devices| devices.filter_map(|d| d.description().ok().map(|d| d.name().to_string())).collect())
            .unwrap_or_default();
    }

    fn save(&mut self) {
        for (key, value) in [
            ("addons", &self.addons),
            ("model", &self.model),
            ("pad", &self.pad),
            ("ask", &self.ask),
            ("mic", &self.mic),
            ("agent", &self.agent),
            ("engine", &self.engine),
        ] {
            self.settings.set(key, value.trim());
        }
        *self.report.lock().unwrap() = match self.settings.save() {
            Ok(path) => format!("saved {}\nstart the companion with: wow-companion run", path.display()),
            Err(err) => format!("could not save: {err}"),
        };
    }
}

impl eframe::App for Setup {
    // eframe 0.37 hands the app its root Ui instead of a Context
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        ui.ctx().request_repaint_after(Duration::from_millis(50));
        egui::CentralPanel::default().show(ui, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.heading("Game");
                ui.label("The game's Interface\\AddOns folder (World of Warcraft\\_forever_\\Interface\\AddOns):");
                ui.add(egui::TextEdit::singleline(&mut self.addons).desired_width(f32::INFINITY));
                for found in self.found_addons.clone() {
                    if found != self.addons && ui.small_button(format!("use {found}")).clicked() {
                        self.addons = found;
                    }
                }
                if !self.addons.is_empty() && !Path::new(&self.addons).is_dir() {
                    ui.colored_label(egui::Color32::LIGHT_RED, "that folder does not exist");
                }

                ui.separator();
                ui.heading("Controller");
                ui.horizontal(|ui| {
                    egui::ComboBox::from_label("pad")
                        .selected_text(self.pad_name())
                        .show_ui(ui, |ui| {
                            for (vid, pid, name) in &self.pads {
                                let id = format!("{vid:04x}:{pid:04x}");
                                ui.selectable_value(&mut self.pad, id.clone(), format!("{name} ({id})"));
                            }
                        });
                    if ui.button("refresh").clicked() {
                        self.refresh_devices();
                    }
                });
                ui.horizontal(|ui| {
                    ui.label("talk button:");
                    ui.text_edit_singleline(&mut self.ask);
                    if ui.button("learn it").clicked() {
                        self.learn();
                    }
                });
                let (said, found) = self.learning.lock().unwrap().clone();
                if !said.is_empty() {
                    ui.label(said);
                }
                if let Some(found) = found {
                    self.ask = found;
                    self.learning.lock().unwrap().1 = None;
                }
                ui.small("Hold it to talk; a trigger (L1, L2, R1, R2) held with it picks a conversation.");

                ui.separator();
                ui.heading("Microphone");
                let before = self.mic.clone();
                egui::ComboBox::from_label("mic")
                    .selected_text(if self.mic.is_empty() { "Windows default" } else { self.mic.as_str() })
                    .show_ui(ui, |ui| {
                        ui.selectable_value(&mut self.mic, String::new(), "Windows default");
                        for name in &self.mics {
                            ui.selectable_value(&mut self.mic, name.clone(), name);
                        }
                    });
                if self.mic != before {
                    self.meter.watch(&self.mic);
                }
                let level = self.meter.level();
                ui.add(egui::ProgressBar::new((level * 8.0).min(1.0)).text("speak to test"));
                if let Some(err) = self.meter.error() {
                    ui.colored_label(egui::Color32::LIGHT_RED, err);
                }

                ui.separator();
                ui.heading("Speech recognition");
                ui.label("Whisper model file:");
                ui.add(egui::TextEdit::singleline(&mut self.model).desired_width(f32::INFINITY));
                for found in self.models.clone() {
                    if found != self.model && ui.small_button(format!("use {found}")).clicked() {
                        self.model = found;
                    }
                }
                if self.models.is_empty() {
                    ui.small("No model found: download ggml-large-v3-turbo.bin (or ggml-small.bin for a slower GPU) from huggingface.co/ggerganov/whisper.cpp into a models folder.");
                }
                ui.horizontal(|ui| {
                    if ui.button("Test speech recognition").clicked() {
                        self.test_speech();
                    }
                    ui.label(if self.engine == "cpu" { "using: CPU build" } else { "using: GPU build" });
                });
                let test = self.speech.lock().unwrap().clone();
                if let Some(test) = test {
                    let colour = if test.passed { egui::Color32::LIGHT_GREEN } else { egui::Color32::LIGHT_RED };
                    ui.colored_label(colour, &test.summary);
                    ui.collapsing("details", |ui| ui.monospace(&test.details));
                    let cpu_ready = companion().is_some_and(|exe| exe.with_file_name("wow-companion-cpu.exe").exists());
                    if !test.passed && self.engine != "cpu" && cpu_ready && ui.button("Use the CPU build instead (slower, works anywhere)").clicked() {
                        self.engine = "cpu".into();
                        self.save();
                        self.test_speech();
                    }
                }
                if self.engine == "cpu" {
                    // measured: large-v3-turbo on the CPU took 16.5 s for 6 s of speech
                    ui.small("On the CPU the large model is slow (about 16 s for a 6 s sentence): pick a small one, ggml-small.bin or ggml-base.en.bin.");
                }
                if self.engine == "cpu" && ui.small_button("go back to the GPU build").clicked() {
                    self.engine.clear();
                    self.save();
                }

                ui.separator();
                ui.heading("Agent");
                ui.label(format!("Claude Code: {}", self.claude));
                ui.horizontal(|ui| {
                    ui.label("model (empty = opus):");
                    ui.text_edit_singleline(&mut self.agent);
                });

                ui.separator();
                ui.horizontal(|ui| {
                    if ui.button("Save").clicked() {
                        self.save();
                    }
                    if ui.button("Save and check everything (doctor)").clicked() {
                        self.save();
                        let report = Arc::clone(&self.report);
                        *report.lock().unwrap() = "running doctor...".into();
                        thread::spawn(move || {
                            let out = companion().map(|exe| Command::new(exe).arg("doctor").output());
                            *report.lock().unwrap() = match out {
                                Some(Ok(out)) => format!(
                                    "{}{}",
                                    String::from_utf8_lossy(&out.stdout),
                                    String::from_utf8_lossy(&out.stderr)
                                ),
                                Some(Err(err)) => format!("could not run doctor: {err}"),
                                None => "wow-companion.exe not found next to this window".into(),
                            };
                        });
                    }
                });
                let report = self.report.lock().unwrap().clone();
                if !report.is_empty() {
                    ui.add(egui::TextEdit::multiline(&mut report.as_str()).code_editor().desired_rows(8));
                }
            });
        });
    }
}

impl Setup {
    fn pad_name(&self) -> String {
        self.pads
            .iter()
            .find(|(vid, pid, _)| format!("{vid:04x}:{pid:04x}") == self.pad)
            .map(|(_, _, name)| format!("{name} ({})", self.pad))
            .unwrap_or_else(|| if self.pad.is_empty() { "none found".into() } else { format!("{} (not connected)", self.pad) })
    }

    /// Whisper on the bundled sample clip through the companion itself (the build
    /// that will really run), checked against the clip's known script.
    fn test_speech(&mut self) {
        // saved first: the companion reads `engine` to pick its build
        self.save();
        let model = self.model.clone();
        let speech = Arc::clone(&self.speech);
        *speech.lock().unwrap() = Some(SpeechTest { passed: false, summary: "testing...".into(), details: String::new() });
        thread::spawn(move || {
            let result = (|| {
                let exe = companion().ok_or("wow-companion.exe not found next to this window")?;
                let clip = sample_clip().ok_or("the sample clip (assets/sample.wav) is missing")?;
                let out = Command::new(exe).arg("transcribe").arg(&model).arg(clip).output().map_err(|e| e.to_string())?;
                Ok::<_, String>(format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
            })();
            *speech.lock().unwrap() = Some(match result {
                Err(why) => SpeechTest { passed: false, summary: why, details: String::new() },
                Ok(output) => judge(&output),
            });
        });
    }

    fn learn(&mut self) {
        let Ok((vid, pid)) = pad::split(&self.pad) else {
            *self.learning.lock().unwrap() = ("pick a controller first".into(), None);
            return;
        };
        let learning = Arc::clone(&self.learning);
        thread::spawn(move || {
            let said = Arc::clone(&learning);
            let result = pad::learn(vid, pid, Duration::from_secs(10), |text| {
                said.lock().unwrap().0 = text.to_string();
            });
            *learning.lock().unwrap() = match result {
                Ok(press) => (format!("learned: {press}"), Some(press.spec())),
                Err(err) => (format!("could not learn it: {err}"), None),
            };
        });
    }
}

/// The input level of the chosen mic, live, so a dead or wrong mic shows before
/// the first try in game.
#[derive(Default)]
struct Meter {
    stream: Option<cpal::Stream>,
    level: Arc<AtomicU32>,
    error: Option<String>,
}

impl Meter {
    fn watch(&mut self, wanted: &str) {
        self.stream = None;
        self.error = None;
        self.level.store(0, Ordering::Relaxed);
        match self.open(wanted) {
            Ok(stream) => self.stream = Some(stream),
            Err(err) => self.error = Some(err),
        }
    }

    fn open(&self, wanted: &str) -> Result<cpal::Stream, String> {
        let host = cpal::default_host();
        let device = if wanted.is_empty() {
            host.default_input_device()
        } else {
            let wanted = wanted.to_lowercase();
            host.input_devices().map_err(|e| e.to_string())?.find(|d| {
                d.description().is_ok_and(|d| d.name().to_lowercase().contains(&wanted))
            })
        }
        .ok_or("that microphone is not connected")?;
        let config = device.default_input_config().map_err(|e| e.to_string())?;
        let level = Arc::clone(&self.level);
        let report = move |samples: &mut dyn Iterator<Item = f32>| {
            let (sum, n) = samples.fold((0.0f32, 0u32), |(s, n), x| (s + x * x, n + 1));
            if n > 0 {
                level.store((sum / n as f32).sqrt().to_bits(), Ordering::Relaxed);
            }
        };
        let fail = |err| eprintln!("microphone error: {err}");
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                config.config(),
                move |data: &[f32], _: &_| report(&mut data.iter().copied()),
                fail,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                config.config(),
                move |data: &[i16], _: &_| report(&mut data.iter().map(|s| *s as f32 / i16::MAX as f32)),
                fail,
                None,
            ),
            other => return Err(format!("unsupported sample format {other:?}")),
        }
        .map_err(|e| e.to_string())?;
        stream.play().map_err(|e| e.to_string())?;
        Ok(stream)
    }

    fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }

    fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
}

/// The self-test's verdict from the companion's output: the right words, and on
/// which device.
fn judge(output: &str) -> SpeechTest {
    let text = output.lines().find_map(|l| l.strip_prefix("text: ")).unwrap_or("").to_lowercase();
    let timing = output.lines().find(|l| l.contains("transcribed in")).unwrap_or("").to_string();
    let device = if output.contains("using Vulkan") || output.contains("ggml_vulkan: Found") {
        "Vulkan (GPU)"
    } else if output.contains("using CUDA") {
        "CUDA (GPU)"
    } else {
        "CPU"
    };
    let details = output
        .lines()
        .filter(|l| !l.starts_with("whisper_full") && !l.contains("decoder") && !l.trim().is_empty())
        .collect::<Vec<_>>()
        .join("
");
    let passed = text.contains("moonfire") && text.contains("flight master");
    let summary = if passed {
        format!("works: {timing} on {device}")
    } else if text.is_empty() {
        "did not work: no transcript (see details)".to_string()
    } else {
        format!("heard something else: \"{text}\" on {device}")
    };
    SpeechTest { passed, summary, details }
}

/// The bundled sample clip: beside the exes in a release, in the checkout's
/// assets/ in development.
fn sample_clip() -> Option<PathBuf> {
    let beside = std::env::current_exe().ok()?.parent()?.join("assets").join("sample.wav");
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("assets").join("sample.wav");
    [beside, checkout].into_iter().find(|clip| clip.exists())
}

/// Where Forever is usually installed, on every drive.
fn find_addons() -> Vec<String> {
    let mut found = Vec::new();
    for drive in 'C'..='Z' {
        for base in ["", "Program Files (x86)\\", "Program Files\\", "Games\\"] {
            let path = format!("{drive}:\\{base}World of Warcraft\\_forever_\\Interface\\AddOns");
            if Path::new(&path).is_dir() {
                found.push(path);
            }
        }
    }
    found
}

/// Whisper model files in the usual places: the project's models folder and
/// %LOCALAPPDATA%\wow-companion\models.
fn find_models() -> Vec<String> {
    let mut dirs = vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("models")];
    if let Some(beside) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(|dir| dir.join("models"))) {
        dirs.insert(0, beside);
    }
    if let Some(base) = std::env::var_os("LOCALAPPDATA") {
        dirs.push(PathBuf::from(base).join("wow-companion").join("models"));
    }
    let mut found = Vec::new();
    for dir in dirs {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "bin") {
                let path = std::fs::canonicalize(&path).unwrap_or(path);
                found.push(path.display().to_string().trim_start_matches(r"\\?\").to_string());
            }
        }
    }
    found
}

fn claude_version() -> String {
    match Command::new("claude").arg("--version").output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string() + " (installed)",
        _ => "not found: install Claude Code and sign in (claude.com/claude-code)".into(),
    }
}

/// wow-companion.exe, beside this window's exe.
fn companion() -> Option<PathBuf> {
    let beside = std::env::current_exe().ok()?.with_file_name("wow-companion.exe");
    // in development the two are built in different target folders
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/debug/wow-companion.exe");
    [beside, checkout].into_iter().find(|exe| exe.exists())
}

#[cfg(test)]
mod tests {
    use super::judge;

    #[test]
    fn a_right_transcript_on_cuda_passes() {
        let output = "whisper_backend_init_gpu: using CUDA0 backend\nmodel loaded in 1.66s\n6.1s of audio transcribed in 0.29s\ntext: Put Moonfire on the right bar, then whisper my guild that I am on my way to the flight master.\n";
        let test = judge(output);
        assert!(test.passed);
        assert_eq!(test.summary, "works: 6.1s of audio transcribed in 0.29s on CUDA (GPU)");
    }

    #[test]
    fn a_failed_load_fails_and_says_so() {
        let test = judge("Error: failed to load model\n");
        assert!(!test.passed);
        assert!(test.summary.contains("no transcript"));
    }
}
