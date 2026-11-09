//! Turning what you said into one command the addon will accept.
//!
//! Routed through headless `claude -p` rather than the API: no key to manage, it
//! draws on the signed-in subscription, and its file tools suit a channel that is
//! already files. The cost is process startup per utterance — seconds, not
//! milliseconds — so this is a deliberate trade, not an oversight.
//!
//! The model does not get to write Lua. `--output-schema` constrains it to one of
//! the shapes the addon's dispatch table already accepts, and anything outside that
//! is rejected here, before it reaches the game.

use std::{
    io,
    process::{Child, Command, Stdio},
};

use serde_json::Value;

const MODEL: &str = "sonnet";
// a translation, not an investigation: one turn, no tools, nothing to approve
const TURNS: &str = "1";

const SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "say":  { "type": "string" },
    "kind": { "type": "string", "enum": ["chat", "macro", "reload", "none"] },
    "text": { "type": "string" },
    "name": { "type": "string" },
    "body": { "type": "string" }
  },
  "required": ["say", "kind"],
  "additionalProperties": false
}"#;

const RULES: &str = "\
You turn a World of Warcraft player's spoken request into one command for an addon.
The player is on a controller, mid-game, and reads your `say` line in a small window.

`say` is always required: one short line, plain prose, no markdown. It is the only
thing the player sees, so make it the answer, not a preamble.

Pick one `kind`:
- `chat`: they want to say something. `text` goes into the chat box exactly as if
  they had typed it, so begin it with the channel's slash command when they mean a
  channel other than say: /p for party, /r raid, /g guild, /i instance.
- `macro`: they want a macro. `name` is short; `body` is the macro text, 255 chars
  or fewer, using real WoW macro syntax such as /cast.
- `reload`: they asked to reload the UI.
- `none`: they asked a question, or nothing needs to change in game. Answer in `say`.

Never act for the player. You write configuration; they press the button. Do not
offer to attack, move, target, or take any action in combat.";

/// What the model decided, already checked against what the addon accepts.
pub struct Spoken {
    /// the line to show in the companion window
    pub say: String,
    /// the inbox table to deliver, or None when nothing should change in game
    pub inbox: Option<String>,
}

/// One continuing conversation with the agent.
///
/// Without this every utterance starts cold, so "put it on the other bar instead"
/// has no idea what "it" was. The CLI hands back a `session_id`; replaying it with
/// `--resume` keeps the thread. `--system-prompt-snapshot` is on by default, so the
/// rules recorded on the first call are reused verbatim on every resume — they do
/// not need resending, and resending them would not help if they did.
#[derive(Default)]
pub struct Session {
    thread: Option<String>,
}

impl Session {
    /// Start the agent without waiting for it. A request takes seconds, and the
    /// caller has its own seconds of work to do (announcing itself in game), so the
    /// two should overlap rather than queue.
    pub fn start(&self, transcript: &str) -> io::Result<Child> {
        let mut claude = Command::new("claude");
        claude.arg("--print").arg(transcript);
        match &self.thread {
            Some(thread) => {
                claude.args(["--resume", thread]);
            }
            // the rules only go out on the first call; the snapshot carries them
            None => {
                claude.args(["--system-prompt", RULES]);
            }
        }
        claude
            .args(["--output-format", "json"])
            .args(["--json-schema", SCHEMA])
            .args(["--model", MODEL])
            .args(["--max-turns", TURNS])
            // nothing here should run commands or edit files, and nothing should
            // ever block on a permission prompt mid-raid
            .arg("--restricted")
            .args(["--permission-mode", "dontAsk"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
    }

    pub fn finish(&mut self, waiting: Child) -> io::Result<Spoken> {
        let answer = read(waiting)?;
        // remember the thread even on the first reply, so the next utterance resumes
        if let Some(thread) = answer.thread {
            self.thread = Some(thread);
        }
        Ok(answer.spoken)
    }
}

struct Answer {
    spoken: Spoken,
    thread: Option<String>,
}

fn read(waiting: Child) -> io::Result<Answer> {
    let spawned = waiting.wait_with_output()?;
    if !spawned.status.success() {
        let complaint = String::from_utf8_lossy(&spawned.stderr);
        return Err(io::Error::other(format!(
            "claude exited {}: {}",
            spawned.status,
            complaint.trim()
        )));
    }

    let envelope: Value = serde_json::from_slice(&spawned.stdout)
        .map_err(|err| io::Error::other(format!("claude's output wasn't JSON: {err}")))?;
    if envelope.get("is_error").and_then(Value::as_bool) == Some(true) {
        return Err(io::Error::other(format!("claude reported an error: {envelope}")));
    }
    // `structured_output` is the schema'd answer already parsed; `result` carries
    // the same thing as a JSON string. Prefer the former, fall back to the latter.
    let command: Value = match envelope.get("structured_output") {
        Some(Value::Object(fields)) => Value::Object(fields.clone()),
        _ => match envelope.get("result") {
            Some(Value::String(text)) => serde_json::from_str(text).map_err(|err| {
                io::Error::other(format!("result wasn't the schema: {err}: {text}"))
            })?,
            _ => return Err(io::Error::other(format!("no usable output in {envelope}"))),
        },
    };

    let say = field(&command, "say")?.to_string();
    let inbox = match field(&command, "kind")? {
        "chat" => Some(crate::chat_inbox(field(&command, "text")?)),
        "macro" => Some(format!(
            "{{ kind = \"macro\", name = {}, body = {} }}",
            crate::lua_string(field(&command, "name")?),
            crate::lua_string(field(&command, "body")?)
        )),
        "reload" => Some("{ kind = \"reload\" }".to_string()),
        "none" => None,
        other => return Err(io::Error::other(format!("unknown kind {other:?}"))),
    };
    let thread = envelope
        .get("session_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    Ok(Answer { spoken: Spoken { say, inbox }, thread })
}

fn field<'a>(command: &'a Value, name: &str) -> io::Result<&'a str> {
    command
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| io::Error::other(format!("no {name} in {command}")))
}
