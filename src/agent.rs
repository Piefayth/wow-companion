//! Turning what you said into what the addon will do.
//!
//! Routed through headless `claude -p` rather than the API: no key to manage, it
//! draws on the signed-in subscription, and its file tools suit a channel that is
//! already files. The cost is process startup per utterance: seconds, not
//! milliseconds, so this is a deliberate trade, not an oversight.
//!
//! The answer is constrained by `--json-schema` to `say` plus steps, each one of
//! the shapes the addon's dispatch table accepts, and anything outside that is
//! rejected here. One of those shapes is Lua: the agent may write code, which
//! the addon runs in a sandboxed environment out of combat, with a taint check
//! after. The client's own security is the real fence there: insecure code
//! cannot cast, target or move.
//!
//! The agent is Claude Code with every tool and no permission prompts: walled off
//! from the shell, it could not install an addon or restart the game, and code of
//! ours would have to do it for it, which is the code Claude Code already is. It
//! runs from the repository root, so it reads the docs, this code and the addon,
//! and can change them. What it reads from the web or from chat can steer it; the
//! player accepted that trade.

use std::{io, process::Command};

use serde_json::Value;
use crate::message::Msg;

// Opus by default: Sonnet is quicker and gets chords, bars and multi-step requests
// wrong too often. `run ... agent=sonnet` trades back.
pub const DEFAULT_MODEL: &str = "opus";

/// The quick conversation (L2+R2 with the talk button): chat, links, profession
/// links, a button to press. A faster model at low effort, few turns, a trimmed
/// export, and agent/quick.md on top of the rules.
pub const QUICK_SLOT: &str = crate::voice::Slot::Quick.key();
/// A request that compacts its conversation (the conversation menu's Compact):
/// Claude Code's own command, the whole message. A request like any other, so it
/// waits its turn behind the conversation's others and outlives a restart; its
/// answer is the compaction.
pub const COMPACT: &str = "/compact";
/// `think`'s conversation: no conversation the player talks to.
const SCRATCH_SLOT: &str = "think";
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
          "remove": { "type": "boolean" },
          "times": { "type": "integer" }
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
/// The character's state is a file the agent reads (`character_file`), never the
/// message: a copy in every request after a reload filled the conversations
/// (2026-11-12: 940k tokens in L1, most of it old exports). A message says only
/// that it changed and where each section is, when it differs from what this
/// thread last saw.
///
/// Every session is a conversation kept in its slot's files (`resumed_slot`,
/// `scratch`); there is no blank one: a default session was Main's, and `think`
/// made with it replaced Main's conversation with its own (2026-11-12).
pub struct Session {
    /// the `--model` to ask for; empty means DEFAULT_MODEL
    pub model: String,
    thread: Option<String>,
    /// the context this thread has already been told of
    seen: Option<String>,
    /// the context in the request now in flight, adopted once it succeeds
    offered: Option<String>,
    /// how full the conversation is after its last answer: tokens, of the
    /// model's window
    pub context: Option<(u64, u64)>,
    /// told once, at the start of the thread: where the game and this project are
    pub setup: String,
    /// which conversation this is: "" for the main one, else the trigger held
    /// with the talk button ("l1", "l2", "r1", "r2"), each kept in its own file
    pub slot: String,
}

/// `<name>.<ext>` for the main conversation, `<name>-<slot>.<ext>` for another,
/// in the companion's folder.
fn slot_file(slot: &str, name: &str, ext: &str) -> Option<std::path::PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")?;
    let dir = std::path::PathBuf::from(base).join("wow-companion");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join(if slot.is_empty() { format!("{name}.{ext}") } else { format!("{name}-{slot}.{ext}") }))
}

/// Where the conversation's ID is kept, so a restart of the companion resumes
/// the same conversation instead of starting a stranger.
fn thread_file(slot: &str) -> Option<std::path::PathBuf> {
    slot_file(slot, "thread", "txt")
}

/// The character as the conversation's agent reads it: the export, Lua errors
/// and integrations (context.rs), its own file so a conversation's line numbers
/// are the ones it was told.
fn character_file(slot: &str) -> io::Result<std::path::PathBuf> {
    slot_file(slot, "character", "txt").ok_or_else(|| io::Error::other("no LOCALAPPDATA for the character file"))
}

/// What the message says of a changed character: the export's stamp and where
/// each section starts and ends in the file, so the agent reads only what the
/// request needs.
fn character_note(context: &str) -> String {
    let mut sections: Vec<(String, usize, usize)> = Vec::new();
    let lines: Vec<&str> = context.lines().collect();
    for (at, line) in lines.iter().enumerate() {
        if let Some(name) = line.strip_prefix("== ").and_then(|rest| rest.strip_suffix(" ==")) {
            if let Some(last) = sections.last_mut() {
                last.2 = at;
            }
            sections.push((name.to_string(), at + 1, lines.len()));
        }
    }
    let index: Vec<String> = sections.iter().map(|(name, from, to)| format!("{name} {from}-{to}")).collect();
    format!(
        "Changed since your last message: {}\nSections by line: {}",
        lines.first().unwrap_or(&"").trim_start_matches("-- "),
        index.join(", ")
    )
}

/// The system prompt's second half, written for each run: Quick's own rules,
/// the player's profile, and where their character is. The CLI takes one file
/// to append.
fn appended_prompt(slot: &str, quick: Option<&std::path::Path>) -> io::Result<std::path::PathBuf> {
    let mut text = String::new();
    if let Some(quick) = quick {
        text.push_str(&std::fs::read_to_string(quick)?);
        text.push_str("\n\n");
    }
    text.push_str("# The player's profile (player/profile.md)\n\n");
    text.push_str(
        &std::fs::read_to_string(crate::context::profile())
            .unwrap_or_else(|_| "(none yet: player/profile.md does not exist)".to_string()),
    );
    text.push_str(&format!(
        "\n\n# Their character\n\nThe game's export as of the player's last UI reload, with the Lua errors \
         since the game launched and the integrations installed, is in {}. A message that opens with \
         <character> means it changed since your last one and says where each section is: read the \
         sections the request needs.\n",
        character_file(slot)?.display()
    ));
    let file = slot_file(slot, "agent-prompt", "md").ok_or_else(|| io::Error::other("no LOCALAPPDATA for the agent's prompt"))?;
    std::fs::write(&file, text)?;
    Ok(file)
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
        Session { model: String::new(), thread, seen: None, offered: None, context: None, setup: String::new(), slot: slot.to_string() }
    }

    /// A conversation of its own for `think`, begun afresh; `forget` it when done.
    pub fn scratch() -> Self {
        let mut session = Self::resumed_slot(SCRATCH_SLOT);
        session.forget();
        session
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

    /// Start the agent without waiting for it, as round `round` of job `job`'s
    /// run (src/runs.rs: detached, its stream in a file any companion copy can
    /// follow). A request takes seconds, and the caller has its own seconds of
    /// work to do (announcing itself in game), so the two should overlap rather
    /// than queue.
    pub fn start(&mut self, job: u64, round: u32, transcript: &str, context: Option<String>) -> io::Result<crate::runs::Run> {
        // a compaction is the command alone: a changed character waits for the
        // next request
        let fresh = context.filter(|context| self.seen.as_ref() != Some(context) && transcript != COMPACT);
        let message = match &fresh {
            Some(context) => {
                std::fs::write(character_file(&self.slot)?, context)?;
                format!("<character>\n{}\n</character>\n\nThe player said: {transcript}", character_note(context))
            }
            None if transcript == COMPACT => COMPACT.to_string(),
            None => format!("The player said: {transcript}"),
        };
        let message = if self.thread.is_none() && !self.setup.is_empty() && transcript != COMPACT {
            format!("<setup>\n{}\n</setup>\n\n{message}", self.setup)
        } else {
            message
        };
        self.offered = fresh;
        let mut claude = Command::new("claude");
        // the companion's own exe, for the strip reader the rules have the agent
        // start: this running copy, so a reader never locks the build itself
        if let Ok(exe) = std::env::current_exe() {
            // nothing started in the background: it would die with the turn (hook.rs)
            claude.arg("--settings").arg(crate::hook::settings(&exe));
            claude.env("WOW_COMPANION_EXE", exe);
        }
        // its conversation, for the strip asks it makes (src/strip.rs ask)
        claude.env(crate::strip::SLOT_ENV, &self.slot);
        // a conversation compacts at a fifth of the window (about 200k tokens of
        // 1M) rather than near its end, where an agent works worse and every step
        // rereads it all (measured: honoured by --print on a resumed session)
        claude.env("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "20");
        // the message goes on stdin (a file, src/runs.rs)
        claude.arg("--print");
        if let Some(thread) = &self.thread {
            claude.args(["--resume", thread]);
        }
        // The rules (agent/rules.md; Quick's agent/quick.md, the profile and where
        // the character is appended) go out on every request, read by the CLI from
        // the files, unrecorded: an edit applies at the next request, with no
        // build. With the default snapshot a resumed conversation keeps the rules
        // it began with and silently ignores new ones (measured).
        let rules = crate::home().join("agent");
        claude.arg("--system-prompt-file").arg(rules.join("rules.md")).args(["--system-prompt-snapshot", "off"]);
        let quick = self.slot == QUICK_SLOT;
        let quick_rules = rules.join("quick.md");
        claude.arg("--append-system-prompt-file").arg(appended_prompt(&self.slot, quick.then_some(quick_rules.as_path()))?);
        if quick {
            claude.args(["--effort", "low"]);
        }
        // the repository root: docs, this code, the addon, and its CLAUDE.md
        claude.current_dir(crate::home());
        claude
            // every tool, no prompts: nothing should ever block on a prompt nobody
            // is at the keyboard to answer
            .arg("--dangerously-skip-permissions")
            // streamed, so the player sees what it is doing; the last event is
            // the same result the plain json format would have printed
            .args(["--output-format", "stream-json", "--verbose"])
            .args(["--json-schema", SCHEMA])
            .args(["--model", if quick { QUICK_MODEL } else if self.model.is_empty() { DEFAULT_MODEL } else { &self.model }])
            .args(["--max-turns", if quick { QUICK_TURNS } else { TURNS }]);
        crate::runs::start(job, &self.slot, round, claude, &message)
    }

    /// Follow the run to its answer, handing each thing the agent does to
    /// `progress` as it happens ("reading StanceBar.lua"), so a minute of work is
    /// not a minute of silence. None when `leave()` says this copy is handing
    /// over: the run goes on, and the next copy follows it.
    pub fn finish(&mut self, run: &crate::runs::Run, progress: impl FnMut(Progress), leave: impl Fn() -> bool) -> io::Result<Option<Spoken>> {
        let Some(answer) = read(run, progress, leave)? else { return Ok(None) };
        // remember the thread even on the first reply, so the next utterance resumes
        if let Some(thread) = answer.thread {
            save_thread(&self.slot, &thread);
            self.thread = Some(thread);
        }
        if let Some(context) = self.offered.take() {
            self.seen = Some(context);
        }
        if answer.context.is_some() {
            self.context = answer.context;
        }
        Ok(Some(answer.spoken))
    }
}

/// What a run tells the player while it works.
pub enum Progress<'a> {
    /// a progress line: what it is doing now
    Doing(&'a str),
    /// its conversation is being compacted (asked for, or at the threshold)
    Compacting,
    /// the compaction is done: the conversation's size now, in tokens
    Compacted(u64),
}

struct Answer {
    spoken: Spoken,
    thread: Option<String>,
    /// the conversation's size at the turn's last call, and the model's window
    context: Option<(u64, u64)>,
}

/// One line for the player about a tool call: what, not how. None for a call
/// with nothing to say to them: a command the agent gave no description (its
/// first line is `python - <<'EOF'` or `cd \`), a tool they would not know.
fn describe(tool: &str, input: &Value) -> Option<String> {
    let get = |key: &str| input.get(key).and_then(Value::as_str).unwrap_or("");
    let short = |text: &str| -> String {
        let text = text.lines().next().unwrap_or("").trim();
        if text.chars().count() > 70 { format!("{}...", text.chars().take(70).collect::<String>()) } else { text.to_string() }
    };
    let file = |path: &str| path.rsplit(['/', '\\']).next().unwrap_or(path).to_string();
    Some(match tool {
        "Read" => format!("reading {}", file(get("file_path"))),
        "Grep" => format!("searching for {}", short(get("pattern"))),
        "Glob" => format!("looking for {}", short(get("pattern"))),
        "WebSearch" => format!("searching the web: {}", short(get("query"))),
        "WebFetch" => format!("reading {}", short(get("url").trim_start_matches("https://"))),
        "Edit" | "Write" | "MultiEdit" => format!("editing {}", file(get("file_path"))),
        "Bash" | "PowerShell" if !get("description").is_empty() => format!("running: {}", short(get("description"))),
        "Agent" | "Task" => format!("asking a helper: {}", short(get("description"))),
        _ => return None,
    })
}

/// `939,512` as `940k`.
fn thousands(tokens: u64) -> String {
    format!("{}k", (tokens + 500) / 1000)
}

/// Whether a result carries the schema'd answer.
fn answers(result: &Value) -> bool {
    matches!(result.get("structured_output"), Some(Value::Object(_)))
}

fn read(run: &crate::runs::Run, mut progress: impl FnMut(Progress), leave: impl Fn() -> bool) -> io::Result<Option<Answer>> {
    let mut envelope: Option<Value> = None;
    // the conversation's size at each call, and the model the turn runs on
    let (mut size, mut model): (Option<u64>, Option<String>) = (None, None);
    // a compaction in the turn, asked for or automatic: its size before and after
    let mut compacted: Option<(u64, u64, bool)> = None;
    let followed = crate::runs::follow(run, leave, |line| {
        let Ok(event) = serde_json::from_str::<Value>(line) else { return };
        match (event.get("type").and_then(Value::as_str), event.get("subtype").and_then(Value::as_str)) {
            (Some("system"), Some("init")) => {
                model = event.get("model").and_then(Value::as_str).map(str::to_string);
            }
            (Some("system"), Some("status")) if event.get("status").and_then(Value::as_str) == Some("compacting") => {
                progress(Progress::Compacting);
            }
            (Some("system"), Some("compact_boundary")) => {
                let count = |key: &str| event.pointer(&format!("/compact_metadata/{key}")).and_then(Value::as_u64).unwrap_or(0);
                let manual = event.pointer("/compact_metadata/trigger").and_then(Value::as_str) == Some("manual");
                compacted = Some((count("pre_tokens"), count("post_tokens"), manual));
                size = Some(count("post_tokens"));
                progress(Progress::Compacted(count("post_tokens")));
            }
            (Some("assistant"), _) => {
                if let Some(usage) = event.pointer("/message/usage") {
                    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
                    size = Some(count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens"));
                }
                let content = event.pointer("/message/content").and_then(Value::as_array);
                for part in content.into_iter().flatten() {
                    match part.get("type").and_then(Value::as_str) {
                        Some("tool_use") => {
                            let name = part.get("name").and_then(Value::as_str).unwrap_or("");
                            // the answer itself arrives as this tool; it is not progress
                            if name != "StructuredOutput" {
                                if let Some(line) = describe(name, part.get("input").unwrap_or(&Value::Null)) {
                                    progress(Progress::Doing(&line));
                                }
                            }
                        }
                        Some("text") => {
                            let text = part.get("text").and_then(Value::as_str).unwrap_or("").trim();
                            if !text.is_empty() {
                                progress(Progress::Doing(text.lines().next().unwrap_or(text)));
                            }
                        }
                        _ => {}
                    }
                }
            }
            // The answer is the result that carries one (the schema'd reply). A
            // turn can hold others: a stale notice in a resumed session woke it
            // first and gave an empty result, and the real answer came second
            // (R1, 2026-11-12). Until one carries an answer the latest stands, so
            // a run that ends in an error still reports it; the rest are logged.
            (Some("result"), _) if envelope.as_ref().map_or(true, |kept| !answers(kept)) => envelope = Some(event),
            (Some("result"), _) => {
                let later = event.get("result").and_then(Value::as_str).unwrap_or("");
                println!("  a later result from the same turn, not delivered: {}", later.chars().take(160).collect::<String>());
            }
            _ => {}
        }
    })?;
    if matches!(followed, crate::runs::Followed::Left) {
        return Ok(None);
    }
    let envelope = envelope.ok_or_else(|| io::Error::other(format!("claude gave no result: {}", crate::runs::complaints(run).trim())))?;
    let thread = envelope.get("session_id").and_then(Value::as_str).map(str::to_string);
    // the window is the turn's own model's (its helpers' models are listed too)
    let window = model.and_then(|model| envelope.pointer(&format!("/modelUsage/{model}/contextWindow"))?.as_u64());
    let context = size.zip(window);
    // the step limit is not a fault: the work so far stands and the conversation
    // can carry on (the companion does, a few times). The result names it.
    if envelope.get("subtype").and_then(Value::as_str) == Some("error_max_turns") {
        let spoken = Spoken { say: String::new(), inbox: None, look: false, fresh: false, modules: Vec::new(), out_of_steps: true };
        return Ok(Some(Answer { spoken, thread, context }));
    }
    if envelope.get("is_error").and_then(Value::as_bool) == Some(true) {
        return Err(io::Error::other(format!("claude reported an error: {envelope}")));
    }
    // a compaction asked for (COMPACT) answers with what it did
    if let (false, Some((before, after, true))) = (answers(&envelope), compacted) {
        let say = format!("Compacted: {} to {} tokens.", thousands(before), thousands(after));
        let spoken = Spoken { say, inbox: None, look: false, fresh: false, modules: Vec::new(), out_of_steps: false };
        return Ok(Some(Answer { spoken, thread, context }));
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
    Ok(Some(Answer { spoken: Spoken { say, inbox, look, fresh, modules, out_of_steps: false }, thread, context }))
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
        "press" => {
            let press = Msg::new("press").text("label", field(command, "label")?).text("macro", field(command, "macro")?);
            // how many presses the button lasts; 0 keeps it until the next offer
            match command.get("times").and_then(Value::as_i64) {
                Some(times) => press.int("times", times.max(0)),
                None => press,
            }
        }
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

#[cfg(test)]
mod tests {
    use super::character_note;

    #[test]
    fn a_changed_character_is_named_by_its_stamp_and_where_each_section_is() {
        let context = "-- WowCompanion context, 2026-11-12 23:26:41\n== character ==\nDruid 22\n== bags ==\na\nb\n== lua errors ==\nnone";
        let note = character_note(context);
        assert_eq!(
            note,
            "Changed since your last message: WowCompanion context, 2026-11-12 23:26:41\n\
             Sections by line: character 2-3, bags 4-6, lua errors 7-8"
        );
    }
}
