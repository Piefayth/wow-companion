//! Every message to the game, as a value, written as Lua in exactly one place
//! (`Msg::lua`). A conversation line is a `Line`: numbered in its conversation
//! and kept by the ledger (src/ledger.rs) until a save shows the game holds it.
//! Everything else (progress, steps, a stop's answer) is a `Msg` about now.
//!
//! Before this, messages were Lua text built by `format!`, edited with
//! `replacen` and told apart by their prefix; a field added in front broke a
//! reader elsewhere and lost every reply made while the game was closed
//! (2026-11-11). A message is now built once, read by its fields.

use crate::jobs::State;
use crate::lua_string;

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Value {
    Text(String),
    Int(i128),
    Bool(bool),
    List(Vec<Value>),
    Msg(Msg),
}

impl Value {
    fn lua(&self) -> String {
        match self {
            Value::Text(text) => lua_string(text),
            Value::Int(n) => n.to_string(),
            Value::Bool(b) => b.to_string(),
            Value::List(items) => {
                let inner: Vec<String> = items.iter().map(Value::lua).collect();
                if inner.is_empty() { "{ }".to_string() } else { format!("{{ {} }}", inner.join(", ")) }
            }
            Value::Msg(msg) => msg.lua(),
        }
    }
}

/// A table for the game: `kind` (when it has one) and its fields, in order.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Msg {
    kind: Option<&'static str>,
    fields: Vec<(&'static str, Value)>,
}

impl Msg {
    /// A message the addon's dispatch takes by its `kind`.
    pub(crate) fn new(kind: &'static str) -> Msg {
        Msg { kind: Some(kind), fields: Vec::new() }
    }

    /// A plain table (an entry of a list).
    pub(crate) fn table() -> Msg {
        Msg { kind: None, fields: Vec::new() }
    }

    pub(crate) fn text(mut self, key: &'static str, value: &str) -> Msg {
        self.fields.push((key, Value::Text(value.to_string())));
        self
    }

    pub(crate) fn int(mut self, key: &'static str, value: impl Into<i128>) -> Msg {
        self.fields.push((key, Value::Int(value.into())));
        self
    }

    pub(crate) fn flag(mut self, key: &'static str, value: bool) -> Msg {
        self.fields.push((key, Value::Bool(value)));
        self
    }

    pub(crate) fn list(mut self, key: &'static str, items: Vec<Msg>) -> Msg {
        self.fields.push((key, Value::List(items.into_iter().map(Value::Msg).collect())));
        self
    }

    pub(crate) fn msg(mut self, key: &'static str, value: Msg) -> Msg {
        self.fields.push((key, Value::Msg(value)));
        self
    }

    pub(crate) fn kind(&self) -> Option<&'static str> {
        self.kind
    }

    pub(crate) fn int_of(&self, key: &str) -> Option<i128> {
        self.fields.iter().find_map(|(k, value)| match value {
            Value::Int(n) if *k == key => Some(*n),
            _ => None,
        })
    }

    pub(crate) fn has(&self, key: &str) -> bool {
        self.fields.iter().any(|(k, value)| *k == key && *value != Value::Bool(false))
    }

    /// The one place a message becomes Lua.
    pub(crate) fn lua(&self) -> String {
        let mut parts = Vec::with_capacity(self.fields.len() + 1);
        if let Some(kind) = self.kind {
            parts.push(format!("kind = {}", lua_string(kind)));
        }
        for (key, value) in &self.fields {
            parts.push(format!("{key} = {}", value.lua()));
        }
        if parts.is_empty() { "{ }".to_string() } else { format!("{{ {} }}", parts.join(", ")) }
    }
}

/// `{ job = 7, slot = "l1", state = "answered" }`: one request and where it stands.
pub(crate) fn job_entry(id: u64, slot: &str, state: State) -> Msg {
    Msg::table().int("job", id).text("slot", slot).text("state", state.name())
}

/// A line of a conversation, as the Companion window shows it: what you said,
/// a reply, a failure, a notice.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Line {
    /// Its conversation: "" is the main one, "l1".."r2" the trigger slots.
    pub(crate) slot: String,
    /// Its number in its conversation, 1, 2, 3... with no gaps (the ledger gives it).
    pub(crate) n: u64,
    pub(crate) who: String,
    pub(crate) text: String,
    /// What the spinner says until the next line ("thinking").
    pub(crate) pending: Option<String>,
    /// The request this line is about, and the state it had reached.
    pub(crate) job: Option<(u64, State)>,
    /// Every request a reply or failure ended, each with its state.
    pub(crate) ended: Vec<(u64, String, State)>,
    /// Shown waiting behind the request running in its conversation.
    pub(crate) queued: bool,
    /// The changes a reply carries (macros, bars, code), run as it arrives.
    /// Live only: never kept, never in the mailbox.
    pub(crate) steps: Option<Msg>,
}

impl Line {
    pub(crate) fn new(slot: &str, who: &str, text: &str) -> Line {
        Line {
            slot: slot.to_string(),
            n: 0,
            who: who.to_string(),
            text: text.to_string(),
            pending: None,
            job: None,
            ended: Vec::new(),
            queued: false,
            steps: None,
        }
    }

    pub(crate) fn pending(mut self, label: &str) -> Line {
        self.pending = Some(label.to_string());
        self
    }

    pub(crate) fn job(mut self, id: u64, state: State) -> Line {
        self.job = Some((id, state));
        self
    }

    pub(crate) fn ended(mut self, jobs: Vec<(u64, String, State)>) -> Line {
        self.ended = jobs;
        self
    }

    pub(crate) fn queued(mut self) -> Line {
        self.queued = true;
        self
    }

    pub(crate) fn steps(mut self, steps: Option<Msg>) -> Line {
        self.steps = steps;
        self
    }

    /// The `log` message the game takes, from a slot or from the mailbox (which
    /// never carries steps).
    pub(crate) fn msg(&self, with_steps: bool) -> Msg {
        let mut msg = Msg::new("log").text("slot", &self.slot).int("n", self.n).text("who", &self.who).text("text", &self.text);
        if let Some(label) = &self.pending {
            msg = msg.text("pending", label);
        }
        if let Some((id, state)) = self.job {
            msg = msg.int("job", id).text("state", state.name());
        }
        if !self.ended.is_empty() {
            msg = msg.list("list", self.ended.iter().map(|(id, slot, state)| job_entry(*id, slot, *state)).collect());
        }
        if self.queued {
            msg = msg.flag("queued", true);
        }
        if let (true, Some(steps)) = (with_steps, &self.steps) {
            msg = msg.msg("andThen", steps.clone());
        }
        msg
    }
}

/// What the courier carries: a line (kept by the ledger) or a message about now.
pub(crate) enum Out {
    Line(Line),
    Now(Msg),
}

/// A line for the chat box the player opened (an agent's `chat` step).
pub(crate) fn chat_line(text: &str) -> Msg {
    Msg::new("chat").text("text", text)
}

/// L1+R1 dictation: the words as said, for the chat box on the channel picked
/// on the chat wheel (`wheel`: the addon puts that channel on the line).
pub(crate) fn dictated(words: &str) -> Msg {
    Msg::new("chat").text("text", words.trim()).flag("wheel", true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_is_written_as_lua_with_everything_escaped() {
        let msg = Msg::new("progress").text("text", "reading \"main.rs\"\nC:\\x\r\0").int("job", 1794363312223u64).flag("started", true);
        assert_eq!(
            msg.lua(),
            r#"{ kind = "progress", text = "reading \"main.rs\"\nC:\\x\r\0", job = 1794363312223, started = true }"#
        );
        assert!(msg.has("started"));
        assert!(!Msg::new("progress").flag("started", false).has("started"));
    }

    #[test]
    fn a_line_carries_its_number_job_and_ended_list_and_steps_only_live() {
        let line = Line::new("l1", "claude", "Done")
            .job(7, State::Answered)
            .ended(vec![(7, "l1".into(), State::Answered), (6, "l1".into(), State::Cancelled)])
            .steps(Some(Msg::new("reload")));
        let mut numbered = line.clone();
        numbered.n = 12;
        assert_eq!(
            numbered.msg(true).lua(),
            r#"{ kind = "log", slot = "l1", n = 12, who = "claude", text = "Done", job = 7, state = "answered", list = { { job = 7, slot = "l1", state = "answered" }, { job = 6, slot = "l1", state = "cancelled" } }, andThen = { kind = "reload" } }"#
        );
        assert!(!numbered.msg(false).lua().contains("andThen"));
    }
}
