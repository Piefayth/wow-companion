//! Turning what you said into one command the addon will accept.
//!
//! Routed through headless `claude -p` rather than the API: no key to manage, it
//! draws on the signed-in subscription, and its file tools suit a channel that is
//! already files. The cost is process startup per utterance: seconds, not
//! milliseconds, so this is a deliberate trade, not an oversight.
//!
//! The answer is constrained by `--json-schema` to one of the shapes the addon's
//! dispatch table accepts, and anything outside that is rejected here. One of those
//! shapes is Lua: the agent may write code, which the addon runs in a sandboxed
//! environment out of combat, with a taint check after. The client's own security
//! is the real fence there: insecure code cannot cast, target or move.
//!
//! The agent is Claude Code with every tool and no permission prompts, at the
//! player's request: an agent walled off from the shell could not install an
//! addon or restart the game, so we wrote code to do it for it, which is the code
//! Claude Code already is. It runs from the repository root, so it reads the docs,
//! this code and the addon, and can change them. What it reads from the web or
//! from chat can steer it; the player accepted that trade.

use std::{
    io::{self, BufRead, BufReader, Read, Write},
    thread,
    process::{Child, Command, Stdio},
};

use serde_json::Value;
use crate::message::Msg;

// Opus by default: Sonnet was quick and got chords, bars and multi-step requests
// wrong often enough that the player noticed. `run ... agent=sonnet` trades back.
pub const DEFAULT_MODEL: &str = "opus";

/// The quick conversation (L2+R2 with the talk button): chat, links, profession
/// links, a button to press. A faster model at low effort, few turns, a trimmed
/// export, and agent/quick.md on top of the rules.
pub const QUICK_SLOT: &str = crate::voice::Slot::Quick.key();
const QUICK_MODEL: &str = "sonnet";
const QUICK_TURNS: &str = "12";

// Real work (researching and installing an addon, restarting the game, changing
// the addon) takes many tool calls; a quick answer still takes one.
const TURNS: &str = "60";

const SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "say":   { "type": "string" },
    "look":  { "type": "boolean" },
    "fresh": { "type": "boolean" },
    "steps": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind":  { "type": "string", "enum": ["chat", "send", "macro", "press", "reload", "bar", "lua", "module"] },
          "text":  { "type": "string" },
          "name":  { "type": "string" },
          "body":  { "type": "string" },
          "label": { "type": "string" },
          "macro": { "type": "string" },
          "slot":  { "type": "integer" },
          "what":  { "type": "string", "enum": ["spell", "macro", "item", "empty"] },
          "code":  { "type": "string" },
          "remove": { "type": "boolean" }
        },
        "required": ["kind"],
        "additionalProperties": false
      }
    }
  },
  "required": ["say", "steps"],
  "additionalProperties": false
}"#;


/// What the model decided, already checked against what the addon accepts.
pub struct Spoken {
    /// the line to show in the companion window
    pub say: String,
    /// the steps to deliver, or None when nothing should change in game
    pub inbox: Option<crate::message::Msg>,
    /// the agent wants to see its steps' results: call it again after the reload
    pub look: bool,
    /// the player asked to start this conversation over: after this answer it
    /// begins anew
    pub fresh: bool,
    /// `module` steps, stored in modules/ before sending: name, and code or None
    /// to remove (src/modules.rs)
    pub modules: Vec<(String, Option<String>)>,

    /// the request ran out of steps before answering: nothing to deliver, the
    /// conversation can be told to carry on
    pub out_of_steps: bool,
}

/// One continuing conversation with the agent.
///
/// Without this every utterance starts cold, so "put it on the other bar instead"
/// has no idea what "it" was. The CLI hands back a `session_id`; replaying it with
/// `--resume` keeps the thread, and the rules are sent afresh with every request.
///
/// The character's state is sent when it differs from what this thread last saw,
/// which is once per reload rather than once per utterance.
#[derive(Default)]
pub struct Session {
    /// the `--model` to ask for; empty means DEFAULT_MODEL
    pub model: String,
    thread: Option<String>,
    /// the context this thread has already been given
    seen: Option<String>,
    /// the context in the request now in flight, adopted once it succeeds
    offered: Option<String>,
    /// told once, at the start of the thread: where the game and this project are
    pub setup: String,
    /// which conversation this is: "" for the main one, else the trigger held
    /// with the talk button ("l1", "l2", "r1", "r2"), each kept in its own file
    pub slot: String,
}

/// Where the conversation's ID is kept, so a restart of the companion resumes
/// the same conversation instead of starting a stranger.
fn thread_file(slot: &str) -> Option<std::path::PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")?;
    let dir = std::path::PathBuf::from(base).join("wow-companion");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join(if slot.is_empty() { "thread.txt".to_string() } else { format!("thread-{slot}.txt") }))
}

fn save_thread(slot: &str, thread: &str) {
    if let Some(file) = thread_file(slot) {
        let _ = std::fs::write(file, thread);
    }
}

impl Session {
    /// The conversation the companion was last in, if any; delete thread.txt to
    /// start over.
    pub fn resumed() -> Self {
        Self::resumed_slot("")
    }

    /// The conversation kept for one trigger slot ("" is the main one).
    pub fn resumed_slot(slot: &str) -> Self {
        let thread = thread_file(slot)
            .and_then(|file| std::fs::read_to_string(file).ok())
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty());
        Session { thread, slot: slot.to_string(), ..Session::default() }
    }

    /// Forget this conversation: the next request starts a fresh one.
    pub fn forget(&mut self) {
        self.thread = None;
        self.seen = None;
        self.offered = None;
        if let Some(file) = thread_file(&self.slot) {
            let _ = std::fs::remove_file(file);
        }
    }

    /// Start the agent without waiting for it. A request takes seconds, and the
    /// caller has its own seconds of work to do (announcing itself in game), so the
    /// two should overlap rather than queue.
    pub fn start(&mut self, transcript: &str, context: Option<String>) -> io::Result<Child> {
        let fresh = context.filter(|context| self.seen.as_ref() != Some(context));
        let message = match &fresh {
            Some(context) => format!(
                "<character>
{context}
</character>

The player said: {transcript}"
            ),
            None => format!("The player said: {transcript}"),
        };
        let message = if self.thread.is_none() && !self.setup.is_empty() {
            format!("<setup>\n{}\n</setup>\n\n{message}", self.setup)
        } else {
            message
        };
        self.offered = fresh;
        let mut claude = Command::new("claude");
        // the companion's own exe, for the strip reader the rules have the agent
        // start: this running copy, so a reader never locks the build itself
        if let Ok(exe) = std::env::current_exe() {
            claude.env("WOW_COMPANION_EXE", exe);
        }
        // the message goes on stdin: with the character export in it, it is past
        // Windows' 32,767-character limit for a whole command line
        claude.arg("--print");
        if let Some(thread) = &self.thread {
            claude.args(["--resume", thread]);
        }
        // The rules (agent/rules.md, and agent/quick.md on top for Quick) go out on
        // every request, read by the CLI from the file, unrecorded: an edit applies
        // at the next request, with no build. With the default snapshot a resumed
        // conversation keeps the rules it began with and silently ignores new ones
        // (measured).
        let rules = crate::home().join("agent");
        claude.arg("--system-prompt-file").arg(rules.join("rules.md")).args(["--system-prompt-snapshot", "off"]);
        let quick = self.slot == QUICK_SLOT;
        if quick {
            claude.arg("--append-system-prompt-file").arg(rules.join("quick.md")).args(["--effort", "low"]);
        }
        // the repository root: docs, this code, the addon, and its CLAUDE.md
        claude.current_dir(crate::home());
        claude
            // every tool, no prompts: the player's choice, and nothing should ever
            // block on a prompt nobody is at the keyboard to answer
            .arg("--dangerously-skip-permissions")
            // streamed, so the player sees what it is doing; the last event is
            // the same result the plain json format would have printed
            .args(["--output-format", "stream-json", "--verbose"])
            .args(["--json-schema", SCHEMA])
            .args(["--model", if quick { QUICK_MODEL } else if self.model.is_empty() { DEFAULT_MODEL } else { &self.model }])
            .args(["--max-turns", if quick { QUICK_TURNS } else { TURNS }])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = claude.spawn()?;
        // written whole, then closed, so the CLI knows the prompt has ended
        child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("claude has no stdin"))?
            .write_all(message.as_bytes())?;
        Ok(child)
    }

    /// Wait for the answer, handing each thing the agent does to `progress` as it
    /// happens ("reading StanceBar.lua"), so a minute of work is not a minute of
    /// silence.
    pub fn finish(&mut self, waiting: Child, progress: impl FnMut(&str)) -> io::Result<Spoken> {
        let answer = read(waiting, progress)?;
        // remember the thread even on the first reply, so the next utterance resumes
        if let Some(thread) = answer.thread {
            save_thread(&self.slot, &thread);
            self.thread = Some(thread);
        }
        if let Some(context) = self.offered.take() {
            self.seen = Some(context);
        }
        Ok(answer.spoken)
    }
}

struct Answer {
    spoken: Spoken,
    thread: Option<String>,
}

/// One line for the player about a tool call: what, not how.
fn describe(tool: &str, input: &Value) -> String {
    let get = |key: &str| input.get(key).and_then(Value::as_str).unwrap_or("");
    let short = |text: &str| -> String {
        let text = text.lines().next().unwrap_or("").trim();
        if text.chars().count() > 70 { format!("{}...", text.chars().take(70).collect::<String>()) } else { text.to_string() }
    };
    let file = |path: &str| path.rsplit(['/', '\\']).next().unwrap_or(path).to_string();
    match tool {
        "Read" => format!("reading {}", file(get("file_path"))),
        "Grep" => format!("searching for {}", short(get("pattern"))),
        "Glob" => format!("looking for {}", short(get("pattern"))),
        "WebSearch" => format!("searching the web: {}", short(get("query"))),
        "WebFetch" => format!("reading {}", short(get("url").trim_start_matches("https://"))),
        "Edit" | "Write" | "MultiEdit" => format!("editing {}", file(get("file_path"))),
        "Bash" | "PowerShell" => {
            let what = if get("description").is_empty() { get("command") } else { get("description") };
            format!("running: {}", short(what))
        }
        "Agent" | "Task" => format!("asking a helper: {}", short(get("description"))),
        other => other.to_string(),
    }
}

fn read(mut waiting: Child, mut progress: impl FnMut(&str)) -> io::Result<Answer> {
    // stderr drained on its own thread: a full pipe would stall the agent
    let mut stderr = waiting.stderr.take();
    let complaints = thread::spawn(move || {
        let mut text = String::new();
        if let Some(pipe) = stderr.as_mut() {
            let _ = pipe.read_to_string(&mut text);
        }
        text
    });
    let stdout = waiting.stdout.take().ok_or_else(|| io::Error::other("claude has no stdout"))?;
    let mut envelope: Option<Value> = None;
    for line in BufReader::new(stdout).lines() {
        let Ok(event) = serde_json::from_str::<Value>(&line?) else { continue };
        match event.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                let content = event.pointer("/message/content").and_then(Value::as_array);
                for part in content.into_iter().flatten() {
                    match part.get("type").and_then(Value::as_str) {
                        Some("tool_use") => {
                            let name = part.get("name").and_then(Value::as_str).unwrap_or("");
                            // the answer itself arrives as this tool; it is not progress
                            if name != "StructuredOutput" {
                                progress(&describe(name, part.get("input").unwrap_or(&Value::Null)));
                            }
                        }
                        Some("text") => {
                            let text = part.get("text").and_then(Value::as_str).unwrap_or("").trim();
                            if !text.is_empty() {
                                progress(text.lines().next().unwrap_or(text));
                            }
                        }
                        _ => {}
                    }
                }
            }
            // The first result is the answer to the player. A turn can wake again
            // after it: a background command the agent started finishes, and the
            // reply to that ("No change from my last message...") came last and
            // replaced the real answer twice (2026-11-10). Later ones are logged.
            Some("result") if envelope.is_none() => envelope = Some(event),
            Some("result") => {
                let later = event.get("result").and_then(Value::as_str).unwrap_or("");
                println!("  a later result from the same turn, not delivered: {}", later.chars().take(160).collect::<String>());
            }
            _ => {}
        }
    }
    let status = waiting.wait()?;
    let complaint = complaints.join().unwrap_or_default();
    if !status.success() && envelope.is_none() {
        return Err(io::Error::other(format!("claude exited {status}: {}", complaint.trim())));
    }
    let envelope = envelope.ok_or_else(|| io::Error::other(format!("claude gave no result: {}", complaint.trim())))?;
    let thread = envelope.get("session_id").and_then(Value::as_str).map(str::to_string);
    // the step limit is not a fault: the work so far stands and the conversation
    // can carry on (the companion does, a few times). The result names it.
    if envelope.get("subtype").and_then(Value::as_str) == Some("error_max_turns") {
        let spoken = Spoken { say: String::new(), inbox: None, look: false, fresh: false, modules: Vec::new(), out_of_steps: true };
        return Ok(Answer { spoken, thread });
    }
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
    let steps = match command.get("steps") {
        Some(Value::Array(steps)) => steps.as_slice(),
        None => &[],
        Some(other) => return Err(io::Error::other(format!("steps isn't a list: {other}"))),
    };
    let buttons = steps
        .iter()
        .filter(|step| matches!(step.get("kind").and_then(Value::as_str), Some("press" | "reload")))
        .count();
    if buttons > 1 {
        return Err(io::Error::other("more than one button in one answer; only one can be offered"));
    }
    let mut built = steps.iter().map(step_inbox).collect::<io::Result<Vec<Msg>>>()?;
    let modules = steps
        .iter()
        .filter(|step| step.get("kind").and_then(Value::as_str) == Some("module"))
        .filter_map(|step| {
            let name = step.get("name").and_then(Value::as_str)?.to_string();
            let removed = step.get("remove").and_then(Value::as_bool) == Some(true);
            let code = if removed { None } else { step.get("code").and_then(Value::as_str).map(str::to_string) };
            Some((name, code))
        })
        .collect();
    let look = command.get("look").and_then(Value::as_bool) == Some(true);
    let fresh = command.get("fresh").and_then(Value::as_bool) == Some(true);
    // looking needs a reload, and a reload needs the player's press: offer it,
    // unless the answer already offers its own button
    if look && buttons == 0 {
        built.push(Msg::new("reload"));
    }
    // several steps still ride in one message: one bell, applied in order
    let inbox = match built.len() {
        0 => None,
        1 => built.pop(),
        _ => Some(Msg::new("batch").list("steps", built)),
    };
    Ok(Answer { spoken: Spoken { say, inbox, look, fresh, modules, out_of_steps: false }, thread })
}

/// One step as the message the addon's dispatch accepts.
fn step_inbox(command: &Value) -> io::Result<Msg> {
    Ok(match field(command, "kind")? {
        "chat" => crate::message::chat_line(field(command, "text")?),
        "send" => {
            let send = Msg::new("send").text("text", field(command, "text")?);
            match command.get("label").and_then(Value::as_str) {
                Some(label) => send.text("label", label),
                None => send,
            }
        }
        "macro" => Msg::new("macro").text("name", field(command, "name")?).text("body", field(command, "body")?),
        "press" => Msg::new("press").text("label", field(command, "label")?).text("macro", field(command, "macro")?),
        "reload" => Msg::new("reload"),
        "lua" => Msg::new("lua").text("code", field(command, "code")?),
        "module" => {
            let module = Msg::new("module").text("name", field(command, "name")?);
            if command.get("remove").and_then(Value::as_bool) == Some(true) {
                module.flag("remove", true)
            } else {
                module.text("code", field(command, "code")?)
            }
        }
        "bar" => {
            let slot = command
                .get("slot")
                .and_then(Value::as_u64)
                .filter(|slot| (1..=1024).contains(slot))
                .ok_or_else(|| io::Error::other(format!("no usable slot in {command}")))?;
            let what = field(command, "what")?;
            let name = if what == "empty" { "" } else { field(command, "name")? };
            Msg::new("bar").int("slot", slot).text("what", what).text("name", name)
        }
        other => return Err(io::Error::other(format!("unknown kind {other:?}"))),
    })
}

fn field<'a>(command: &'a Value, name: &str) -> io::Result<&'a str> {
    command
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| io::Error::other(format!("no {name} in {command}")))
}
