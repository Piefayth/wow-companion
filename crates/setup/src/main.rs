//! The setup window: everything `wow-companion run` needs on a new PC, picked by
//! looking and pressing instead of typed as arguments. It writes the settings file
//! (crates/settings) and can run `doctor` against it. Day to day the companion
//! stays in the game; this is for the first run and for changing hardware.
#![windows_subsystem = "windows"]

mod look;
mod models;

use std::{
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use eframe::egui::{self, RichText};
use look::Status;
use wow_companion_pad as pad;
use wow_companion_settings::{Settings, changes::Changes, platform};

/// Child processes (claude, the companion, tasklist) open no console window.
const NO_WINDOW: u32 = 0x0800_0000;

/// The agent models offered, as Claude Code's aliases, with what each is for.
/// Which ones this account may use is checked when the window opens.
const AGENT_MODELS: &[(&str, &str, &str)] = &[
    ("opus", "Opus", "the default: the most careful with your addons"),
    ("fable", "Fable", "the newest family"),
    ("sonnet", "Sonnet", "faster, a little less careful"),
    ("haiku", "Haiku", "fastest, for simple asks"),
];

fn main() -> eframe::Result<()> {
    // what "Start with Windows" runs: start the watcher with no window at all
    // (this exe has none; wow-companion.exe would flash a console), then leave
    if std::env::args().any(|arg| arg == "--start") {
        start_watcher();
        return Ok(());
    }
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([720.0, 860.0])
            .with_min_inner_size([560.0, 480.0])
            .with_title("WoW Companion setup"),
        ..Default::default()
    };
    eframe::run_native(
        "WoW Companion setup",
        options,
        Box::new(|cc| {
            look::apply(&cc.egui_ctx);
            Ok(Box::new(Setup::new()))
        }),
    )
}

struct Setup {
    settings: Settings,
    addons: String,
    model: String,
    pad: String,
    ask: String,
    mic: String,
    agent: String,
    /// `cpu` when the player chose the CPU build
    engine: String,
    found_addons: Vec<String>,
    models: Vec<String>,
    /// a model file typed by hand, outside the folders searched
    other_model: bool,
    pads: Vec<(u16, u16, String)>,
    mics: Vec<String>,
    learning: Arc<Mutex<Learning>>,
    meter: Meter,
    claude: String,
    /// alias -> None while checking, Some(Ok) usable, Some(Err(why)) not
    agents: Arc<Mutex<Vec<(&'static str, Option<Result<(), String>>)>>>,
    /// output of doctor or the last save
    report: Arc<Mutex<String>>,
    /// the try-it test: what it is doing, and what it heard
    talk: Arc<Mutex<Talk>>,
    /// the talk button, read on its own thread
    held_on_pad: Arc<AtomicBool>,
    pad_target: Arc<Mutex<(String, String)>>,
    /// the companion listens to the same button; then the pad does not record here
    companion_running: bool,
    /// whether the hold (pad or mouse) was down last frame
    was_held: bool,
    saved: bool,
    download: Arc<Mutex<models::Download>>,
    cancel: Arc<AtomicBool>,
    /// what uninstall would remove, looked up when that section opens
    changes: Option<Changes>,
    remove_agent_addons: bool,
    confirm_uninstall: bool,
    uninstalled: Option<Vec<String>>,
    /// the game and the companion running, when the changes were looked up
    running: (bool, bool),
    /// "Start with Windows", as the system has it
    autostart: bool,
    /// what the watcher says (waiting, listening, paused...), None if none runs
    watcher: Option<String>,
    /// when the companion's state was last looked at
    looked: Instant,
}

#[derive(Clone, Default)]
enum Learning {
    #[default]
    Idle,
    Waiting,
    Failed(String),
}

#[derive(Clone, Default)]
enum Talk {
    #[default]
    Idle,
    Listening(Instant),
    Transcribing,
    Heard { text: String, timing: String, device: String },
    Failed { why: String, details: String },
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
            other_model: false,
            pads: Vec::new(),
            mics: Vec::new(),
            learning: Arc::default(),
            meter: Meter::default(),
            claude: claude_version(),
            agents: Arc::new(Mutex::new(AGENT_MODELS.iter().map(|(alias, ..)| (*alias, None)).collect())),
            report: Arc::default(),
            talk: Arc::default(),
            held_on_pad: Arc::default(),
            pad_target: Arc::default(),
            companion_running: companion_running(),
            was_held: false,
            saved: false,
            download: Arc::default(),
            cancel: Arc::default(),
            changes: None,
            remove_agent_addons: false,
            confirm_uninstall: false,
            uninstalled: None,
            running: (false, false),
            autostart: platform::autostart().is_some(),
            watcher: platform::watcher_status(),
            looked: Instant::now(),
        };
        setup.refresh_devices();
        if setup.addons.is_empty() {
            setup.addons = setup.found_addons.first().cloned().unwrap_or_default();
        }
        if setup.model.is_empty() {
            setup.model = setup.models.first().cloned().unwrap_or_default();
        }
        setup.other_model = !setup.model.is_empty() && !setup.models.contains(&setup.model);
        if setup.pad.is_empty() {
            if let Some((vid, pid, _)) = setup.pads.first() {
                setup.pad = format!("{vid:04x}:{pid:04x}");
            }
        }
        setup.meter.watch(&setup.mic);
        setup.watch_pad();
        setup.check_agents();
        thread::spawn(|| VIDEO_MEMORY.get_or_init(models::video_memory));
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
            Ok(path) => {
                self.saved = true;
                format!("Saved to {}.\nNext: tick Start with Windows below (or press Start now).", path.display())
            }
            Err(err) => format!("Could not save: {err}"),
        };
    }
}

impl eframe::App for Setup {
    // eframe 0.37 hands the app its root Ui instead of a Context
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        ui.ctx().request_repaint_after(Duration::from_millis(33));
        *self.pad_target.lock().unwrap() = (self.pad.clone(), self.ask.clone());

        egui::Panel::bottom("actions")
            .frame(egui::Frame::new().fill(look::BAR).inner_margin(egui::Margin::symmetric(24, 14)))
            .show(ui, |ui| self.actions(ui));

        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(look::BACKGROUND))
            .show(ui, |ui| {
                egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
                    egui::Frame::new().inner_margin(egui::Margin { left: 24, right: 24, top: 22, bottom: 24 }).show(
                        ui,
                        |ui| {
                            ui.label(RichText::new("WoW Companion").size(26.0).strong().color(look::TEXT));
                            ui.label(
                                RichText::new("Hold a button, speak, and it happens in game. Six things to set up.")
                                    .color(look::MUTED),
                            );
                            ui.add_space(14.0);
                            self.game(ui);
                            self.controller(ui);
                            self.microphone(ui);
                            self.speech(ui);
                            self.agent(ui);
                            self.starting(ui);
                            ui.add_space(6.0);
                            let header = egui::CollapsingHeader::new(
                                RichText::new("What this put on your PC, and uninstall").color(look::MUTED),
                            )
                            .id_salt("changes")
                            .show(ui, |ui| self.what_changed(ui));
                            if header.body_returned.is_none() {
                                // looked up again each time it opens
                                self.changes = None;
                            }
                        },
                    );
                });
            });
    }
}

// the five cards
impl Setup {
    fn game(&mut self, ui: &mut egui::Ui) {
        let exists = Path::new(&self.addons).is_dir();
        let status = if self.addons.is_empty() {
            Status::Todo("not found")
        } else if exists {
            Status::Ready("found")
        } else {
            Status::Problem("folder missing")
        };
        look::card(ui, 1, "Game", status, |ui| {
            ui.label(RichText::new("The game's AddOns folder").color(look::MUTED));
            if self.found_addons.len() > 1 || (!self.found_addons.is_empty() && !self.found_addons.contains(&self.addons)) {
                egui::ComboBox::from_id_salt("addons")
                    .width(ui.available_width())
                    .selected_text(&self.addons)
                    .show_ui(ui, |ui| {
                        for found in &self.found_addons {
                            ui.selectable_value(&mut self.addons, found.clone(), found);
                        }
                    });
            }
            ui.add(egui::TextEdit::singleline(&mut self.addons).desired_width(f32::INFINITY).hint_text(
                r"...\World of Warcraft\_forever_\Interface\AddOns",
            ));
            if !self.addons.is_empty() && !exists {
                ui.colored_label(look::BAD, "That folder does not exist.");
            }
            if exists {
                ui.add_space(4.0);
                ui.horizontal(|ui| {
                    if ui.button("Install the addon into the game").clicked() {
                        self.install();
                    }
                    ui.label(RichText::new("Then fully restart the game: a reload does not see new addons.").color(look::MUTED));
                });
            }
        });
    }

    fn controller(&mut self, ui: &mut egui::Ui) {
        let learning = self.learning.lock().unwrap().clone();
        let status = match (&learning, self.ask.is_empty(), self.pad_connected()) {
            (Learning::Waiting, ..) => Status::Busy("listening"),
            (_, _, false) => Status::Problem("not connected"),
            (_, true, _) => Status::Todo("pick a talk button"),
            _ => Status::Ready("ready"),
        };
        look::card(ui, 2, "Controller", status, |ui| {
            let pad_before = self.pad.clone();
            ui.horizontal(|ui| {
                egui::ComboBox::from_id_salt("pad")
                    .width((ui.available_width() - 90.0).max(200.0))
                    .selected_text(self.pad_name())
                    .show_ui(ui, |ui| {
                        for (vid, pid, name) in &self.pads {
                            let id = format!("{vid:04x}:{pid:04x}");
                            ui.selectable_value(&mut self.pad, id.clone(), format!("{}  ({id})", pad_label(*vid, name)));
                        }
                    });
                if ui.button("Refresh").clicked() {
                    self.refresh_devices();
                }
            });
            // a learned button is a bit in one controller's report: another
            // controller starts from its own default
            if self.pad != pad_before {
                let (vid, pid) = pad::split(&self.pad).unwrap_or((0, 0));
                self.ask = pad::default_talk(vid, pid).to_string();
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.label(RichText::new("Talk button").color(look::MUTED));
                ui.add_space(8.0);
                match &learning {
                    Learning::Waiting => {
                        look::keycap(ui, "press it now...", true);
                    }
                    _ => {
                        look::keycap(ui, &self.talk_name(), false);
                        let label = if self.ask.is_empty() { "Set it" } else { "Change" };
                        if ui.button(label).clicked() {
                            self.learn();
                        }
                    }
                }
            });
            match &learning {
                Learning::Waiting => {
                    ui.label(RichText::new("Press the button you want to hold to talk.").color(look::ACCENT));
                }
                Learning::Failed(why) => {
                    ui.colored_label(look::BAD, why);
                }
                Learning::Idle => {
                    if pad::split(&self.pad).ok() == Some(pad::XINPUT) && self.talk_name() == "Guide" {
                        ui.label(
                            RichText::new(
                                "Windows opens Xbox Game Bar on the Guide button. Turn that off: Settings > Gaming >                                  Xbox Game Bar > \"Open Xbox Game Bar using this button on a controller\".",
                            )
                            .small()
                            .color(look::WARN),
                        );
                    }
                    ui.label(
                        RichText::new("Hold it to talk. A trigger held with it (L1, L2, R1, R2) picks a conversation.")
                            .small()
                            .color(look::MUTED),
                    );
                }
            }
        });
    }

    fn microphone(&mut self, ui: &mut egui::Ui) {
        let level = self.meter.level();
        let status = if self.meter.error().is_some() {
            Status::Problem("no signal")
        } else if level > 0.02 {
            Status::Ready("hearing you")
        } else {
            Status::Ready("connected")
        };
        look::card(ui, 3, "Microphone", status, |ui| {
            let before = self.mic.clone();
            egui::ComboBox::from_id_salt("mic")
                .width(ui.available_width())
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
            ui.add_space(4.0);
            look::level(ui, (level * 8.0).min(1.0));
            match self.meter.error() {
                Some(err) => {
                    ui.colored_label(look::BAD, err);
                }
                None => {
                    ui.label(RichText::new("Say something: the bar should move.").small().color(look::MUTED));
                }
            }
        });
    }

    fn speech(&mut self, ui: &mut egui::Ui) {
        let talk = self.talk.lock().unwrap().clone();
        let status = match &talk {
            Talk::Heard { .. } => Status::Ready("works"),
            Talk::Failed { .. } => Status::Problem("failed"),
            Talk::Listening(_) | Talk::Transcribing => Status::Busy("testing"),
            Talk::Idle if self.model.is_empty() => Status::Todo("needs a model"),
            Talk::Idle => Status::Todo("try it"),
        };
        look::card(ui, 4, "Speech recognition", status, |ui| {
            ui.label(RichText::new("Whisper model").color(look::MUTED));
            egui::ComboBox::from_id_salt("model")
                .width(ui.available_width())
                .selected_text(if self.other_model { "Another file...".to_string() } else { model_label(&self.model) })
                .show_ui(ui, |ui| {
                    for found in &self.models {
                        if ui.selectable_label(!self.other_model && &self.model == found, model_label(found)).clicked() {
                            self.model = found.clone();
                            self.other_model = false;
                        }
                    }
                    if ui.selectable_label(self.other_model, "Another file...").clicked() {
                        self.other_model = true;
                    }
                });
            if self.other_model {
                ui.add(egui::TextEdit::singleline(&mut self.model).desired_width(f32::INFINITY).hint_text(r"C:\...\ggml-large-v3-turbo.bin"));
            }
            self.downloads(ui);

            ui.add_space(10.0);
            ui.label(RichText::new("Try it").color(look::MUTED));
            let via_pad = !self.companion_running && !self.ask.is_empty();
            let hint = match (&talk, via_pad) {
                (Talk::Listening(_), _) => "Listening... let go when you're done.".to_string(),
                (Talk::Transcribing, _) => "Working out what you said...".to_string(),
                (_, true) => format!("Hold your talk button ({}) or this button, and say something.", self.talk_name()),
                (_, false) => "Hold this button and say something.".to_string(),
            };
            let busy = matches!(talk, Talk::Transcribing);
            let mouse_held = look::hold_button(ui, &hint, matches!(talk, Talk::Listening(_)), busy, self.meter.level());
            if self.companion_running && !self.ask.is_empty() {
                ui.label(
                    RichText::new("The companion is running and listens to your talk button too, so only the button above records here.")
                        .small()
                        .color(look::MUTED),
                );
            }
            let held = !busy && (mouse_held || (via_pad && self.held_on_pad.load(Ordering::Relaxed)));
            self.hold(held);

            match &talk {
                Talk::Heard { text, timing, device } => {
                    ui.add_space(6.0);
                    look::quote(ui, if text.is_empty() { "(nothing)" } else { text });
                    ui.label(RichText::new(format!("{timing} on {device}")).small().color(look::MUTED));
                    if device == "CPU" && self.engine != "cpu" {
                        ui.colored_label(look::WARN, "This ran on the CPU: the GPU build found no usable graphics card.");
                    }
                }
                Talk::Failed { why, details } => {
                    ui.add_space(6.0);
                    ui.colored_label(look::BAD, why);
                    if !details.is_empty() {
                        ui.collapsing("Details", |ui| {
                            ui.label(RichText::new(details).monospace().small());
                        });
                    }
                }
                _ => {}
            }

            ui.add_space(8.0);
            let cpu_ready = companion().is_some_and(|exe| exe.with_file_name("wow-companion-cpu.exe").exists());
            ui.horizontal(|ui| {
                ui.label(RichText::new("Runs on").small().color(look::MUTED));
                if self.engine == "cpu" {
                    ui.label(RichText::new("CPU").small().strong());
                    if ui.small_button("Use the graphics card").clicked() {
                        self.engine.clear();
                        self.save();
                    }
                } else {
                    ui.label(RichText::new("graphics card").small().strong());
                    if cpu_ready && matches!(talk, Talk::Failed { .. }) && ui.small_button("Use the CPU instead (slower)").clicked() {
                        self.engine = "cpu".into();
                        self.save();
                    }
                }
            });
            if self.engine == "cpu" {
                // measured: large-v3-turbo on the CPU took 16.5 s for 6 s of speech
                ui.label(
                    RichText::new("On the CPU the large model takes about 16 s per sentence: pick ggml-small.bin or ggml-base.en.bin.")
                        .small()
                        .color(look::WARN),
                );
            }
        });
    }

    fn agent(&mut self, ui: &mut egui::Ui) {
        let agents = self.agents.lock().unwrap().clone();
        let chosen = if self.agent.is_empty() { "opus".to_string() } else { self.agent.clone() };
        let chosen = chosen.as_str();
        let chosen_state = agents.iter().find(|(alias, _)| *alias == chosen).and_then(|(_, state)| state.clone());
        let status = if self.claude.is_empty() {
            Status::Problem("Claude Code missing")
        } else {
            match &chosen_state {
                None if agents.iter().any(|(alias, _)| *alias == chosen) => Status::Busy("checking"),
                Some(Err(_)) => Status::Problem("model unavailable"),
                _ => Status::Ready("ready"),
            }
        };
        look::card(ui, 5, "Agent", status, |ui| {
            if self.claude.is_empty() {
                ui.colored_label(look::BAD, "Claude Code was not found. Install it and sign in: claude.com/claude-code");
                return;
            }
            ui.label(RichText::new(format!("Claude Code {}, on your own subscription.", self.claude)).color(look::MUTED));
            ui.add_space(4.0);
            let selected = AGENT_MODELS.iter().find(|(alias, ..)| *alias == chosen).map(|(_, name, _)| *name).unwrap_or(chosen);
            egui::ComboBox::from_id_salt("agent")
                .width(ui.available_width())
                .selected_text(selected)
                .show_ui(ui, |ui| {
                    for (alias, name, about) in AGENT_MODELS {
                        let state = agents.iter().find(|(a, _)| a == alias).and_then(|(_, s)| s.clone());
                        let suffix = match &state {
                            None => "  (checking...)",
                            Some(Ok(())) => "",
                            Some(Err(_)) => "  (not on this account)",
                        };
                        let usable = !matches!(state, Some(Err(_)));
                        let value = if *alias == "opus" { String::new() } else { alias.to_string() };
                        ui.add_enabled_ui(usable, |ui| {
                            ui.selectable_value(&mut self.agent, value, format!("{name}: {about}{suffix}"));
                        });
                    }
                });
            if let Some(Err(why)) = &chosen_state {
                ui.colored_label(look::BAD, why);
            }
            ui.label(
                RichText::new("The agent runs on your PC with full permissions, so it can write and install addons (it always asks first).")
                    .small()
                    .color(look::MUTED),
            );
        });
    }

    fn actions(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if ui.add(look::primary("Save")).clicked() {
                self.save();
            }
            if ui.button("Save and check everything").clicked() {
                self.save();
                let report = Arc::clone(&self.report);
                *report.lock().unwrap() = "Checking...".into();
                thread::spawn(move || {
                    let out = companion().map(|exe| Command::new(exe).arg("doctor").creation_flags(NO_WINDOW).output());
                    *report.lock().unwrap() = match out {
                        Some(Ok(out)) => format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)),
                        Some(Err(err)) => format!("Could not run the check: {err}"),
                        None => "wow-companion.exe was not found next to this window.".into(),
                    };
                });
            }
            if self.saved {
                ui.label(RichText::new("Saved").color(look::GOOD));
            }
        });
        let report = self.report.lock().unwrap().clone();
        if !report.is_empty() {
            ui.add_space(8.0);
            egui::ScrollArea::vertical().max_height(150.0).show(ui, |ui| {
                ui.label(RichText::new(report).monospace().size(12.0).color(look::MUTED));
            });
        }
    }
}

// starting the companion: it wakes with WoW (wow-companion start, the watcher)
impl Setup {
    fn starting(&mut self, ui: &mut egui::Ui) {
        if self.looked.elapsed() > Duration::from_secs(2) {
            self.looked = Instant::now();
            self.watcher = platform::watcher_status();
            self.companion_running = companion_running();
        }
        let status = match self.watcher.as_deref() {
            Some("listening") => Status::Ready("listening"),
            Some("paused") => Status::Busy("paused"),
            Some("waiting") => Status::Ready("waiting for WoW"),
            Some("gave-up") => Status::Problem("stopped after crashes"),
            Some(_) => Status::Busy("starting"),
            None if self.companion_running => Status::Ready("running"),
            None => Status::Todo("not started"),
        };
        look::card(ui, 6, "Start", status, |ui| {
            ui.label(
                RichText::new("The companion wakes when you start WoW and sleeps when you close it. Its icon in the notification area shows its state; right-click it to pause or quit.")
                    .color(look::MUTED),
            );
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                let mut wanted = self.autostart;
                if ui.checkbox(&mut wanted, "Start with Windows").changed() {
                    let command = std::env::current_exe().ok().map(|exe| format!("\"{}\" --start", exe.display()));
                    let result = if wanted { platform::set_autostart(command.as_deref()) } else { platform::set_autostart(None) };
                    match result {
                        Ok(()) => {
                            self.autostart = wanted;
                            self.changes = None;
                        }
                        Err(err) => *self.report.lock().unwrap() = format!("Could not change Start with Windows: {err}"),
                    }
                }
                if self.watcher.is_none() && ui.button("Start now").clicked() {
                    start_watcher();
                    self.looked = Instant::now() - Duration::from_secs(10);
                    *self.report.lock().unwrap() = "Started: the companion wakes when you start WoW.".into();
                }
            });
            if self.watcher.as_deref() == Some("gave-up") {
                ui.colored_label(look::BAD, "It stopped 3 times in 10 minutes. Restart WoW to try again; crash.log in %LOCALAPPDATA%\\wow-companion has why.");
            }
        });
    }
}

// installing, and what it changed (crates/settings/src/changes.rs)
impl Setup {
    fn install(&mut self) {
        let addons = self.addons.clone();
        let report = Arc::clone(&self.report);
        *report.lock().unwrap() = "Installing...".into();
        thread::spawn(move || {
            let out = companion().map(|exe| Command::new(exe).arg("install").arg(&addons).creation_flags(NO_WINDOW).output());
            *report.lock().unwrap() = match out {
                Some(Ok(out)) => format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)),
                Some(Err(err)) => format!("Could not run the install: {err}"),
                None => "wow-companion.exe was not found next to this window.".into(),
            };
        });
    }

    fn what_changed(&mut self, ui: &mut egui::Ui) {
        let addons = Some(Path::new(&self.addons)).filter(|path| path.is_dir());
        let muted = |ui: &mut egui::Ui, text: String| {
            ui.label(RichText::new(text).color(look::MUTED));
        };
        if let Some(failed) = &self.uninstalled {
            if failed.is_empty() {
                ui.colored_label(look::GOOD, "Removed. To finish, close this window and delete its folder:");
            } else {
                ui.colored_label(look::BAD, "Some things could not be removed (close what holds them and try again):");
                for line in failed {
                    muted(ui, line.clone());
                }
                ui.label("The rest is gone. The program folder is yours to delete:");
            }
            muted(ui, program_folder());
            return;
        }
        if self.changes.is_none() {
            // looked up once per opening, not every frame
            self.running = (game_running(), companion_running());
        }
        let changes = self.changes.get_or_insert_with(|| Changes::find(addons));

        if changes.is_empty() {
            muted(ui, "Nothing of the companion's is installed outside this folder.".into());
        }
        if !changes.folders.is_empty() {
            let names: Vec<String> =
                changes.folders.iter().filter_map(|f| f.file_name()).map(|n| n.to_string_lossy().to_string()).collect();
            let slots = names.iter().filter(|name| name.starts_with("WowCompanion_S")).count();
            let mut named: Vec<String> = names.into_iter().filter(|name| !name.starts_with("WowCompanion_S")).collect();
            if slots > 0 {
                named.push(format!("{slots} message slots (WowCompanion_S001...)"));
            }
            ui.label("Addons in the game's AddOns folder");
            muted(ui, named.join(", "));
        }
        if !changes.saved.is_empty() {
            let n = changes.saved.len();
            ui.label("Our addon's saved data in the game's WTF folder");
            muted(ui, format!("{n} file{} (WowCompanion*.lua)", if n == 1 { "" } else { "s" }));
        }
        if !changes.agent_addons.is_empty() {
            ui.label("Addons the agent installed for you (kept unless you tick the box)");
            let list: Vec<&str> = changes.agent_addons.iter().map(|(name, _)| name.as_str()).collect();
            muted(ui, list.join(", "));
            ui.checkbox(&mut self.remove_agent_addons, "Remove these too");
        }
        if let Some(data) = &changes.data {
            ui.label("Settings, conversations, logs and backups");
            muted(ui, data.display().to_string());
        }
        ui.label("This program's folder (and a speech model downloaded into it)");
        muted(ui, format!("{}  (delete it yourself afterwards)", program_folder()));
        match &changes.startup {
            Some((command, place)) => {
                ui.label("Starts with Windows (the checkbox above)");
                muted(ui, format!("{place} = {command}"));
            }
            None => muted(ui, "Nothing in the registry, no services, nothing starts with Windows.".into()),
        }
        if changes.is_empty() {
            return;
        }

        ui.add_space(6.0);
        let (game, companion) = self.running;
        if game || companion {
            ui.colored_label(
                look::WARN,
                match (game, companion) {
                    (true, true) => "Close the game and quit the companion (its tray icon) to uninstall.",
                    (true, false) => "Close the game to uninstall: it holds these files.",
                    _ => "Quit the companion to uninstall (its tray icon's Quit).",
                },
            );
            if ui.small_button("Look again").clicked() {
                self.changes = None;
            }
            return;
        }
        if !self.confirm_uninstall {
            if ui.button("Uninstall...").clicked() {
                self.confirm_uninstall = true;
            }
            return;
        }
        ui.colored_label(
            look::BAD,
            "This deletes everything listed above, your conversations and settings too. It can't be undone.",
        );
        let mut remove = false;
        ui.horizontal(|ui| {
            let button = egui::Button::new(RichText::new("Remove it all").color(look::TEXT)).fill(look::BAD.gamma_multiply(0.6));
            remove = ui.add(button).clicked();
            if ui.button("Cancel").clicked() {
                self.confirm_uninstall = false;
            }
        });
        if remove {
            let failed = changes.remove(self.remove_agent_addons);
            self.uninstalled = Some(failed);
            self.confirm_uninstall = false;
        }
    }
}

/// The folder this window runs from (the unzipped release).
fn program_folder() -> String {
    std::env::current_exe().ok().and_then(|exe| exe.parent().map(|dir| dir.display().to_string())).unwrap_or_default()
}

/// Whether World of Warcraft is running.
fn game_running() -> bool {
    Command::new("tasklist")
        .args(["/FI", "IMAGENAME eq Wow.exe", "/NH"])
        .creation_flags(NO_WINDOW)
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).to_lowercase().contains("wow.exe"))
        .unwrap_or(false)
}

// the pad: its name, the talk button, learning one
impl Setup {
    fn pad_connected(&self) -> bool {
        self.pads.iter().any(|(vid, pid, _)| format!("{vid:04x}:{pid:04x}") == self.pad)
    }

    fn pad_name(&self) -> String {
        self.pads
            .iter()
            .find(|(vid, pid, _)| format!("{vid:04x}:{pid:04x}") == self.pad)
            .map(|(vid, _, name)| pad_label(*vid, name))
            .unwrap_or_else(|| if self.pad.is_empty() { "No controller found".into() } else { format!("{} (not connected)", self.pad) })
    }

    /// The talk button as a player would call it.
    fn talk_name(&self) -> String {
        if self.ask.is_empty() {
            return "not set".into();
        }
        let (vid, pid) = pad::split(&self.pad).unwrap_or((0, 0));
        match pad::press_for(&self.ask, vid, pid) {
            Ok(press) => match press.name(vid, pid) {
                Some(name) => name.to_string(),
                None => format!("button {}", press.spec()),
            },
            Err(_) => self.ask.clone(),
        }
    }

    fn learn(&mut self) {
        let Ok((vid, pid)) = pad::split(&self.pad) else {
            *self.learning.lock().unwrap() = Learning::Failed("Pick a controller first.".into());
            return;
        };
        *self.learning.lock().unwrap() = Learning::Waiting;
        let learning = Arc::clone(&self.learning);
        let target = Arc::clone(&self.pad_target);
        thread::spawn(move || {
            let result = pad::learn(vid, pid, Duration::from_secs(15), |_| {});
            *learning.lock().unwrap() = match result {
                Ok(press) => {
                    // the window picks the new button up from here on its next frame
                    target.lock().unwrap().1 = press.spec();
                    LEARNED.lock().unwrap().replace(press.spec());
                    Learning::Idle
                }
                Err(err) => Learning::Failed(format!("Could not learn it: {err}. Try again.")),
            };
        });
    }

    /// Reads whether the talk button is held, on its own thread, so the try-it
    /// test can use the real button.
    fn watch_pad(&self) {
        let target = Arc::clone(&self.pad_target);
        let held = Arc::clone(&self.held_on_pad);
        thread::spawn(move || {
            let mut open: Option<(String, pad::Pad)> = None;
            loop {
                let (id, ask) = target.lock().unwrap().clone();
                if open.as_ref().is_none_or(|(was, _)| *was != id) {
                    open = pad::split(&id).ok().and_then(|(vid, pid)| pad::Pad::open(vid, pid).ok()).map(|p| (id.clone(), p));
                }
                let (vid, pid) = pad::split(&id).unwrap_or((0, 0));
                let down = match (&mut open, pad::press_for(&ask, vid, pid)) {
                    (Some((_, device)), Ok(press)) => match device.refresh() {
                        Ok(()) => device.held(&press),
                        Err(_) => {
                            open = None;
                            false
                        }
                    },
                    _ => false,
                };
                held.store(down, Ordering::Relaxed);
                thread::sleep(Duration::from_millis(if open.is_some() { 10 } else { 1000 }));
            }
        });
    }
}

/// The graphics card's memory, read once on a thread (PowerShell is slow to start).
static VIDEO_MEMORY: std::sync::OnceLock<Option<u64>> = std::sync::OnceLock::new();

// getting a model
impl Setup {
    fn downloads(&mut self, ui: &mut egui::Ui) {
        let state = self.download.lock().unwrap().clone();
        match state {
            models::Download::Running { file, done, total } => {
                let name = models::by_file(file).map(|m| m.name).unwrap_or(file);
                ui.label(RichText::new(format!("Downloading {name}: {} of {}", size(done), size(total))).color(look::MUTED));
                ui.horizontal(|ui| {
                    look::level(ui, if total > 0 { done as f32 / total as f32 } else { 0.0 });
                });
                if ui.small_button("Cancel").clicked() {
                    self.cancel.store(true, Ordering::Relaxed);
                }
                return;
            }
            models::Download::Checking { file } => {
                ui.label(RichText::new(format!("Checking {file}...")).color(look::MUTED));
                return;
            }
            models::Download::Done(path) => {
                *self.download.lock().unwrap() = models::Download::Idle;
                self.models = find_models();
                self.model = path.display().to_string();
                self.other_model = false;
                self.save();
                *self.report.lock().unwrap() = "Model downloaded and checked. Hold the button below and say something.".into();
            }
            models::Download::Failed(why) => {
                ui.colored_label(look::BAD, why);
            }
            models::Download::Idle => {}
        }

        let installed = self.models.clone();
        let have = |file: &str| installed.iter().any(|m| Path::new(m).file_name().is_some_and(|n| n == file));
        let video = VIDEO_MEMORY.get().copied().flatten();
        let best = models::recommended(self.engine == "cpu", video);
        let chosen_ok = !self.model.is_empty() && Path::new(&self.model).is_file();
        if !have(best.file) {
            ui.add_space(4.0);
            egui::Frame::new()
                .fill(look::ACCENT.gamma_multiply(0.08))
                .stroke(egui::Stroke::new(1.0, look::ACCENT.gamma_multiply(0.4)))
                .corner_radius(8)
                .inner_margin(egui::Margin::same(12))
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    let lead = if chosen_ok { "Better for this PC" } else { "Recommended for this PC" };
                    ui.label(RichText::new(format!("{lead}: {} ({})", best.name, size(best.bytes))).strong());
                    ui.label(RichText::new(best.about).small().color(look::MUTED));
                    if ui.add(look::primary("Download")).clicked() {
                        models::start(best, Arc::clone(&self.download), Arc::clone(&self.cancel));
                    }
                });
        }
        ui.collapsing(RichText::new("Other models").small().color(look::MUTED), |ui| {
            for model in models::MODELS {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(format!("{} ({})", model.name, size(model.bytes))).small());
                    if have(model.file) {
                        ui.label(RichText::new("downloaded").small().color(look::GOOD));
                    } else if ui.small_button("Download").clicked() {
                        models::start(model, Arc::clone(&self.download), Arc::clone(&self.cancel));
                    }
                });
                ui.label(RichText::new(model.about).small().color(look::MUTED));
            }
        });
    }
}

/// Bytes as MB or GB.
fn size(bytes: u64) -> String {
    if bytes >= 1_000_000_000 { format!("{:.1} GB", bytes as f64 / 1e9) } else { format!("{} MB", bytes / 1_000_000) }
}

/// A button the learn thread found, for the window to take on its next frame.
static LEARNED: Mutex<Option<String>> = Mutex::new(None);

// the try-it test
impl Setup {
    /// Called every frame with whether the hold is down: starts recording on the
    /// press, and on the release hands the clip to the companion's own build.
    fn hold(&mut self, held: bool) {
        if let Some(spec) = LEARNED.lock().unwrap().take() {
            self.ask = spec;
        }
        if held && !self.was_held {
            self.meter.record(true);
            *self.talk.lock().unwrap() = Talk::Listening(Instant::now());
        }
        if !held && self.was_held {
            let clip = self.meter.record(false);
            let started = match &*self.talk.lock().unwrap() {
                Talk::Listening(at) => *at,
                _ => Instant::now(),
            };
            if started.elapsed() < Duration::from_millis(400) || clip.samples.is_empty() {
                *self.talk.lock().unwrap() =
                    Talk::Failed { why: "Too short: hold it the whole time you speak.".into(), details: String::new() };
            } else {
                self.transcribe(clip);
            }
        }
        self.was_held = held;
    }

    fn transcribe(&mut self, clip: Clip) {
        // saved first: the companion reads `engine` to pick its build
        self.save();
        let model = self.model.clone();
        let talk = Arc::clone(&self.talk);
        *talk.lock().unwrap() = Talk::Transcribing;
        thread::spawn(move || {
            let result = (|| {
                let exe = companion().ok_or("wow-companion.exe was not found next to this window.")?;
                let wav = std::env::temp_dir().join("wow-companion-setup-test.wav");
                std::fs::write(&wav, clip.wav()).map_err(|e| format!("Could not save the recording: {e}"))?;
                let out = Command::new(exe)
                    .arg("transcribe")
                    .arg(&model)
                    .arg(&wav)
                    .creation_flags(NO_WINDOW)
                    .output()
                    .map_err(|e| e.to_string())?;
                Ok::<_, String>(format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
            })();
            *talk.lock().unwrap() = match result {
                Err(why) => Talk::Failed { why, details: String::new() },
                Ok(output) => judge(&output),
            };
        });
    }

    /// Which agent models this account may use: one tiny request each, with no
    /// tools and no project files, in parallel.
    fn check_agents(&self) {
        if self.claude.is_empty() {
            return;
        }
        for (alias, ..) in AGENT_MODELS {
            let agents = Arc::clone(&self.agents);
            thread::spawn(move || {
                let state = check_agent(alias);
                if let Some(entry) = agents.lock().unwrap().iter_mut().find(|(a, _)| a == alias) {
                    entry.1 = Some(state);
                }
            });
        }
    }
}

fn check_agent(alias: &str) -> Result<(), String> {
    use std::io::Write;
    let mut child = Command::new("claude")
        .args(["-p", "--model", alias, "--system-prompt", "Reply with the single word ok.", "--tools", ""])
        .args(["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands", "--output-format", "json"])
        .current_dir(std::env::temp_dir())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .creation_flags(NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(b"ok?");
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout);
    if out.status.success() && text.contains("\"is_error\":false") {
        return Ok(());
    }
    // Claude Code's own message, when it gave one
    let reason = text
        .split("\"result\":\"")
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .map(str::to_string)
        .unwrap_or_else(|| String::from_utf8_lossy(&out.stderr).trim().to_string());
    Err(if reason.is_empty() { "This model did not answer.".into() } else { reason })
}

/// A recording: interleaved samples at the mic's own rate.
#[derive(Default)]
struct Clip {
    samples: Vec<f32>,
    channels: u16,
    rate: u32,
}

impl Clip {
    /// As a 16-bit PCM WAV, which the companion's `transcribe` reads (and
    /// resamples for Whisper).
    fn wav(&self) -> Vec<u8> {
        let data = (self.samples.len() * 2) as u32;
        let block = self.channels * 2;
        let mut out = Vec::with_capacity(44 + data as usize);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&self.channels.to_le_bytes());
        out.extend_from_slice(&self.rate.to_le_bytes());
        out.extend_from_slice(&(self.rate * block as u32).to_le_bytes());
        out.extend_from_slice(&block.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data.to_le_bytes());
        for sample in &self.samples {
            out.extend_from_slice(&((sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes());
        }
        out
    }
}

/// The chosen mic, live: its level for the meter, and a recording while the
/// try-it button is held.
#[derive(Default)]
struct Meter {
    stream: Option<cpal::Stream>,
    level: Arc<AtomicU32>,
    recording: Arc<AtomicBool>,
    clip: Arc<Mutex<Clip>>,
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

    /// Start (true) or stop (false) recording; stopping hands back the clip.
    fn record(&mut self, on: bool) -> Clip {
        if on {
            let mut clip = self.clip.lock().unwrap();
            clip.samples.clear();
            self.recording.store(true, Ordering::Relaxed);
            return Clip::default();
        }
        self.recording.store(false, Ordering::Relaxed);
        let mut clip = self.clip.lock().unwrap();
        Clip { samples: std::mem::take(&mut clip.samples), channels: clip.channels, rate: clip.rate }
    }

    fn open(&self, wanted: &str) -> Result<cpal::Stream, String> {
        let host = cpal::default_host();
        let device = if wanted.is_empty() {
            host.default_input_device()
        } else {
            let wanted = wanted.to_lowercase();
            host.input_devices()
                .map_err(|e| e.to_string())?
                .find(|d| d.description().is_ok_and(|d| d.name().to_lowercase().contains(&wanted)))
        }
        .ok_or("That microphone is not connected.")?;
        let config = device.default_input_config().map_err(|e| e.to_string())?;
        {
            let mut clip = self.clip.lock().unwrap();
            clip.channels = config.channels();
            clip.rate = config.sample_rate();
        }
        let level = Arc::clone(&self.level);
        let recording = Arc::clone(&self.recording);
        let clip = Arc::clone(&self.clip);
        let report = move |samples: &mut dyn Iterator<Item = f32>| {
            let keep = recording.load(Ordering::Relaxed);
            let mut clip = if keep { clip.lock().ok() } else { None };
            let (mut sum, mut n) = (0.0f32, 0u32);
            for x in samples {
                sum += x * x;
                n += 1;
                if let Some(clip) = clip.as_mut() {
                    clip.samples.push(x);
                }
            }
            if n > 0 {
                level.store((sum / n as f32).sqrt().to_bits(), Ordering::Relaxed);
            }
        };
        let fail = |err| eprintln!("microphone error: {err}");
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => {
                device.build_input_stream(config.config(), move |data: &[f32], _: &_| report(&mut data.iter().copied()), fail, None)
            }
            cpal::SampleFormat::I16 => device.build_input_stream(
                config.config(),
                move |data: &[i16], _: &_| report(&mut data.iter().map(|s| *s as f32 / i16::MAX as f32)),
                fail,
                None,
            ),
            other => return Err(format!("Unsupported sample format {other:?}.")),
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

/// What the companion's `transcribe` heard, how fast, and on which device.
fn judge(output: &str) -> Talk {
    let text = output.lines().find_map(|l| l.strip_prefix("text: ")).map(str::trim);
    let timing = output.lines().find(|l| l.contains("transcribed in")).unwrap_or("").trim().to_string();
    let device = if output.contains("using Vulkan") || output.contains("ggml_vulkan: Found") {
        "Vulkan (graphics card)"
    } else if output.contains("using CUDA") {
        "CUDA (graphics card)"
    } else {
        "CPU"
    };
    match text {
        Some(text) => Talk::Heard { text: text.to_string(), timing, device: device.to_string() },
        None => {
            let details = output
                .lines()
                .filter(|l| !l.starts_with("whisper_full") && !l.contains("decoder") && !l.trim().is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            Talk::Failed { why: "Speech recognition did not run (see details).".into(), details }
        }
    }
}

/// A model file as the dropdown shows it: its name and size.
fn model_label(path: &str) -> String {
    if path.is_empty() {
        return "None".into();
    }
    let name = Path::new(path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| path.to_string());
    match std::fs::metadata(path) {
        Ok(meta) => format!("{name}  ({:.1} GB)", meta.len() as f64 / 1e9),
        Err(_) => format!("{name}  (missing)"),
    }
}

/// A controller as a player knows it: by its maker, since adapters report
/// names like "HID VHF Driver".
fn pad_label(vid: u16, name: &str) -> String {
    match vid {
        0x054c => "PlayStation controller (DualSense layout)".into(),
        0xffff => "Xbox controller".into(),
        0x045e => "Xbox controller".into(),
        0x057e => "Nintendo controller".into(),
        _ if name.trim().is_empty() => "Controller".into(),
        _ => name.to_string(),
    }
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

/// Whisper model files in the usual places: the models folder beside this
/// program, the checkout's, and %LOCALAPPDATA%\wow-companion\models.
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
                let path = path.display().to_string().trim_start_matches(r"\\?\").to_string();
                if !found.contains(&path) {
                    found.push(path);
                }
            }
        }
    }
    found
}

/// Claude Code's version, or empty when it is not installed.
fn claude_version() -> String {
    match Command::new("claude").arg("--version").creation_flags(NO_WINDOW).output() {
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout).split_whitespace().next().unwrap_or_default().to_string()
        }
        _ => String::new(),
    }
}

/// Whether the companion is running: the lock it holds while it runs.
fn companion_running() -> bool {
    platform::lock_exists(platform::COMPANION_LOCK)
}

/// `wow-companion start`, with no window.
fn start_watcher() {
    if let Some(exe) = companion() {
        let _ = Command::new(exe).arg("start").creation_flags(NO_WINDOW).spawn();
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
    use super::{Clip, Talk, judge};

    #[test]
    fn a_transcript_on_cuda_is_reported_with_its_device() {
        let output = "whisper_backend_init_gpu: using CUDA0 backend\nmodel loaded in 1.66s\n6.1s of audio transcribed in 0.29s\ntext: Put Moonfire on the right bar.\n";
        match judge(output) {
            Talk::Heard { text, timing, device } => {
                assert_eq!(text, "Put Moonfire on the right bar.");
                assert_eq!(timing, "6.1s of audio transcribed in 0.29s");
                assert_eq!(device, "CUDA (graphics card)");
            }
            _ => panic!("expected a transcript"),
        }
    }

    #[test]
    fn a_failed_load_fails_and_says_so() {
        assert!(matches!(judge("Error: failed to load model\n"), Talk::Failed { .. }));
    }

    #[test]
    fn a_clip_writes_a_wav_header_the_reader_accepts() {
        let wav = Clip { samples: vec![0.0, 0.5, -0.5, 1.0], channels: 2, rate: 48_000 }.wav();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(wav.len(), 44 + 8);
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 48_000);
    }
}
