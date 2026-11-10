//! How the setup window looks: a dark theme with a warm gold accent, Windows'
//! own Segoe UI, and the few pieces the window is built from (cards with a
//! status, a key cap, a level bar, the hold-to-talk button).

use eframe::egui::{
    self, Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Margin, RichText, Sense, Stroke,
    TextStyle, Vec2,
};
use std::sync::Arc;

pub const BACKGROUND: Color32 = Color32::from_rgb(0x12, 0x14, 0x19);
pub const BAR: Color32 = Color32::from_rgb(0x0e, 0x10, 0x14);
const CARD: Color32 = Color32::from_rgb(0x1a, 0x1d, 0x24);
const EDGE: Color32 = Color32::from_rgb(0x2a, 0x2e, 0x38);
const FIELD: Color32 = Color32::from_rgb(0x0f, 0x11, 0x15);
const RAISED: Color32 = Color32::from_rgb(0x25, 0x29, 0x32);
const HOVER: Color32 = Color32::from_rgb(0x2f, 0x34, 0x3f);
pub const TEXT: Color32 = Color32::from_rgb(0xe9, 0xe6, 0xdf);
pub const MUTED: Color32 = Color32::from_rgb(0x8e, 0x94, 0xa1);
pub const ACCENT: Color32 = Color32::from_rgb(0xe2, 0xb3, 0x4a);
pub const GOOD: Color32 = Color32::from_rgb(0x62, 0xc9, 0x8f);
pub const WARN: Color32 = Color32::from_rgb(0xe6, 0xa5, 0x4e);
pub const BAD: Color32 = Color32::from_rgb(0xef, 0x6d, 0x6d);
const BUSY: Color32 = Color32::from_rgb(0x72, 0xa8, 0xff);

/// A card's state, shown as a chip beside its title.
pub enum Status {
    Ready(&'static str),
    Todo(&'static str),
    Busy(&'static str),
    Problem(&'static str),
}

pub fn apply(ctx: &egui::Context) {
    ctx.set_theme(egui::Theme::Dark);

    // Segoe UI is on every Windows; without it egui's own font stays
    let mut fonts = FontDefinitions::default();
    for (name, file) in [("segoe", "segoeui.ttf"), ("segoe-semibold", "seguisb.ttf")] {
        if let Ok(bytes) = std::fs::read(format!(r"C:\Windows\Fonts\{file}")) {
            fonts.font_data.insert(name.into(), Arc::new(FontData::from_owned(bytes)));
        }
    }
    if fonts.font_data.contains_key("segoe") {
        fonts.families.entry(FontFamily::Proportional).or_default().insert(0, "segoe".into());
    }
    let mut semibold = vec![];
    for name in ["segoe-semibold", "segoe"] {
        if fonts.font_data.contains_key(name) {
            semibold.push(name.to_string());
        }
    }
    semibold.extend(fonts.families.get(&FontFamily::Proportional).cloned().unwrap_or_default());
    fonts.families.insert(FontFamily::Name("semibold".into()), semibold);
    ctx.set_fonts(fonts);

    ctx.all_styles_mut(|style| {
        use TextStyle::*;
        style.text_styles = [
            (Heading, FontId::new(18.0, FontFamily::Name("semibold".into()))),
            (Body, FontId::new(15.0, FontFamily::Proportional)),
            (Button, FontId::new(15.0, FontFamily::Proportional)),
            (Small, FontId::new(12.5, FontFamily::Proportional)),
            (Monospace, FontId::new(13.0, FontFamily::Monospace)),
        ]
        .into();
        style.spacing.item_spacing = Vec2::new(8.0, 8.0);
        style.spacing.button_padding = Vec2::new(14.0, 7.0);
        style.spacing.interact_size.y = 32.0;
        style.spacing.combo_height = 320.0;

        let v = &mut style.visuals;
        v.panel_fill = BACKGROUND;
        v.window_fill = CARD;
        v.window_stroke = Stroke::new(1.0, EDGE);
        v.window_corner_radius = CornerRadius::same(10);
        v.menu_corner_radius = CornerRadius::same(8);
        v.extreme_bg_color = FIELD;
        v.faint_bg_color = RAISED;
        v.hyperlink_color = ACCENT;
        v.selection.bg_fill = ACCENT.gamma_multiply(0.35);
        v.selection.stroke = Stroke::new(1.0, ACCENT);
        v.text_cursor.stroke = Stroke::new(2.0, ACCENT);
        let radius = CornerRadius::same(8);
        let w = &mut v.widgets;
        w.noninteractive.fg_stroke = Stroke::new(1.0, TEXT);
        w.noninteractive.bg_stroke = Stroke::new(1.0, EDGE);
        w.noninteractive.corner_radius = radius;
        for (state, fill, edge) in [
            (&mut w.inactive, RAISED, EDGE),
            (&mut w.hovered, HOVER, ACCENT.gamma_multiply(0.6)),
            (&mut w.active, HOVER, ACCENT),
            (&mut w.open, RAISED, ACCENT.gamma_multiply(0.6)),
        ] {
            state.bg_fill = fill;
            state.weak_bg_fill = fill;
            state.bg_stroke = Stroke::new(1.0, edge);
            state.fg_stroke = Stroke::new(1.0, TEXT);
            state.corner_radius = radius;
            state.expansion = 0.0;
        }
    });
}

/// One step of the setup: a numbered card with a title and a status chip.
pub fn card(ui: &mut egui::Ui, step: u8, title: &str, status: Status, body: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::new()
        .fill(CARD)
        .stroke(Stroke::new(1.0, EDGE))
        .corner_radius(12)
        .inner_margin(Margin::same(18))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(26.0), Sense::hover());
                ui.painter().circle_filled(rect.center(), 13.0, ACCENT.gamma_multiply(0.16));
                ui.painter().text(
                    rect.center(),
                    egui::Align2::CENTER_CENTER,
                    step.to_string(),
                    FontId::new(14.0, FontFamily::Name("semibold".into())),
                    ACCENT,
                );
                ui.add_space(4.0);
                ui.label(RichText::new(title).heading().color(TEXT));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| chip(ui, &status));
            });
            ui.add_space(8.0);
            body(ui);
        });
    ui.add_space(12.0);
}

fn chip(ui: &mut egui::Ui, status: &Status) {
    let (colour, text) = match status {
        Status::Ready(text) => (GOOD, *text),
        Status::Todo(text) => (MUTED, *text),
        Status::Busy(text) => (BUSY, *text),
        Status::Problem(text) => (BAD, *text),
    };
    egui::Frame::new()
        .fill(colour.gamma_multiply(0.14))
        .corner_radius(255)
        .inner_margin(Margin::symmetric(10, 3))
        .show(ui, |ui| {
            ui.label(RichText::new(format!("●  {text}")).small().color(colour));
        });
}

/// A button's name drawn like a key cap; lit while waiting for a press.
pub fn keycap(ui: &mut egui::Ui, text: &str, lit: bool) {
    egui::Frame::new()
        .fill(if lit { ACCENT.gamma_multiply(0.14) } else { FIELD })
        .stroke(Stroke::new(1.0, if lit { ACCENT } else { EDGE }))
        .corner_radius(6)
        .inner_margin(Margin::symmetric(14, 5))
        .show(ui, |ui| {
            ui.label(RichText::new(text).strong().color(if lit { ACCENT } else { TEXT }));
        });
}

/// A thin level bar, 0..1.
pub fn level(ui: &mut egui::Ui, value: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 8.0), Sense::hover());
    ui.painter().rect_filled(rect, 4, FIELD);
    if value > 0.0 {
        let mut full = rect;
        full.set_width(rect.width() * value.clamp(0.0, 1.0));
        ui.painter().rect_filled(full, 4, GOOD);
    }
}

/// The hold-to-talk button: wide, lit while listening, with the mic level along
/// its bottom. True while the mouse holds it.
pub fn hold_button(ui: &mut egui::Ui, hint: &str, listening: bool, busy: bool, mic: f32) -> bool {
    let (rect, response) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 60.0), Sense::click_and_drag());
    let held = response.is_pointer_button_down_on();
    let (fill, edge) = if listening {
        (ACCENT.gamma_multiply(0.18), ACCENT)
    } else if response.hovered() && !busy {
        (HOVER, ACCENT.gamma_multiply(0.6))
    } else {
        (RAISED, EDGE)
    };
    let painter = ui.painter();
    painter.rect(rect, 10, fill, Stroke::new(1.0, edge), egui::StrokeKind::Inside);
    painter.text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        hint,
        FontId::new(15.0, FontFamily::Proportional),
        if listening { ACCENT } else if busy { MUTED } else { TEXT },
    );
    if listening {
        let mut bar = rect.shrink(10.0);
        bar.set_top(bar.bottom() - 4.0);
        bar.set_width(bar.width() * (mic * 8.0).clamp(0.0, 1.0));
        painter.rect_filled(bar, 2, ACCENT);
    }
    held
}

/// What was heard, set apart from the rest.
pub fn quote(ui: &mut egui::Ui, text: &str) {
    egui::Frame::new()
        .fill(FIELD)
        .stroke(Stroke::new(1.0, EDGE))
        .corner_radius(8)
        .inner_margin(Margin::symmetric(14, 10))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(RichText::new(format!("\u{201c}{text}\u{201d}")).size(16.0).color(TEXT));
        });
}

/// The main action: filled with the accent.
pub fn primary(text: &str) -> egui::Button<'_> {
    egui::Button::new(RichText::new(text).strong().color(BAR)).fill(ACCENT).min_size(Vec2::new(110.0, 34.0))
}
