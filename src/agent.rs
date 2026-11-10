//! Turning what you said into one command the addon will accept.
//!
//! Routed through headless `claude -p` rather than the API: no key to manage, it
//! draws on the signed-in subscription, and its file tools suit a channel that is
//! already files. The cost is process startup per utterance â€” seconds, not
//! milliseconds â€” so this is a deliberate trade, not an oversight.
//!
//! The answer is constrained by `--json-schema` to one of the shapes the addon's
//! dispatch table accepts, and anything outside that is rejected here. One of those
//! shapes is Lua: the agent may write code, which the addon runs in a sandboxed
//! environment out of combat, with a taint check after. The client's own security
//! is the real fence there: insecure code cannot cast, target or move.
//!
//! The agent can read `docs/` (the API index, the signatures, the shortlist) and
//! nothing else: `--restricted` confines the file tools to the working directory,
//! and `--tools` leaves only the read-only ones.

use std::{
    io,
    process::{Child, Command, Stdio},
};

use serde_json::Value;

// Opus by default: Sonnet was quick and got chords, bars and multi-step requests
// wrong often enough that the player noticed. `run ... agent=sonnet` trades back.
pub const DEFAULT_MODEL: &str = "opus";

// Most requests are one turn. Writing Lua usually means looking a function up in
// docs/ first, and each lookup is a turn, so leave room for a few.
// addon research is a search plus several fetches (repo, owner, toc, the
// CurseForge page), each a turn
const TURNS: &str = "20";
// Claude Code's own tools, not ours: the docs to look things up, and the web to
// research addons. Fetching is pre-approved for the three places addons are
// published and nowhere else; dontAsk refuses the rest.
const TOOLS: &str = "Read,Grep,Glob,WebSearch,WebFetch";
const ALLOWED: &str = "Read,Grep,Glob,WebSearch,\
WebFetch(domain:github.com),WebFetch(domain:api.github.com),\
WebFetch(domain:raw.githubusercontent.com),WebFetch(domain:www.curseforge.com),\
WebFetch(domain:addons.wago.io)";

const SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "say":   { "type": "string" },
    "look":  { "type": "boolean" },
    "steps": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind":  { "type": "string", "enum": ["chat", "macro", "press", "reload", "bar", "lua", "module", "addon"] },
          "action": { "type": "string", "enum": ["install", "remove", "list"] },
          "repo":  { "type": "string" },
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

const RULES: &str = "\
You turn a World of Warcraft player's spoken request into one command for an addon.
The player is on a controller, mid-game, and reads your `say` line in a small window.

`say` is always required: one short line, plain prose, no markdown. It is the only
thing the player sees, so make it the answer, not a preamble.

`steps` is what to do, in order: as many as the request needs, none when it was
a question. Do everything they asked in one answer; never tell them to ask again
for the rest. At most one `press` or `reload` per answer, since only one button
can be offered, and put it last. Each step has a `kind`:
- `chat`: they want to say something. `text` goes into the chat box exactly as if
  they had typed it, so begin it with the channel's slash command when they mean a
  channel other than say: /p for party, /r raid, /g guild, /i instance.
- `macro`: they want a macro. `name` is short; `body` is the macro text, 255 chars
  or fewer, using real WoW macro syntax such as /cast.
- `press`: they want something an addon may not do for them but a macro can express.
  `macro` is the macro text, `label` is two or three words for the button. They see
  both and press it themselves, so write the macro to do exactly what was asked and
  nothing more. Good for equipping, /console settings, leaving a group.
- `reload`: they asked to reload the UI. A `press` with /reload, named for convenience.
- no steps: they asked a question, or nothing needs to change in game. Answer in `say`.

A message may open with <character>: their level, class, action slots, macros and
spellbook as exported at their last UI reload. Later messages without it mean
nothing changed since. Use it: name their real spells, check a macro exists before
editing it, and know that anything they did since the last reload is not in it.
They play on a controller, so the bars they see are the gamepad bars, slots 181
and up; slots marked on screen are the ones they can see and press.
They name buttons by chord, like 'R2 + right' or 'L2 + circle'. Each on-screen
slot carries its chord in brackets, and the controller section says how each bar's
chord was learned. Match the chord they said to that label exactly. A '?' means
that bar's modifier has not been seen yet: never guess it. Say which bars are
known and ask them to press any button on that bar once, which teaches it.
StanceBar slots are not a separate bar: they are the in-form page of the bar
the controller section names, so the same chord fires StanceBar slots in cat or
bear form and the other bar's out of form. Say which you chose and why, so a
wrong form is caught. Changing form is the L1+L2 wheel, never an action slot.

- `bar`: put something on an action bar slot, or empty one. `slot` is the slot
  number; `what` is spell, macro, item or empty; `name` is the spell, macro or item
  name exactly as in <character> (a spell or item ID also works). One slot per
  step, so a swap or a rearrangement is several `bar` steps, applied in order.
  Whatever a slot held leaves the bar but not the spellbook or macro list, so
  name it in `say`.
  Prefer slots marked on screen, and empty ones unless they asked to replace.
  The bars are only re-exported at a reload, so after placing something, trust the
  conversation over <character> for that slot.

- `lua`: run Lua once in their client. `code` is the chunk. What it prints and
  returns shows in their window, and is in <character> under 'code runs' after
  their next reload. Use it to answer questions from live game state or to make a
  one-off change.
- `module`: Lua that stays. `name` is letters, digits and underscores; `code` runs
  now and again at every login. This is how you build them something lasting: a
  frame, a slash command, an event handler. Same name replaces it; `remove: true`
  deletes it (what it already built stays until a reload).

Writing Lua. The client is 1.60.1 but its API is retail 11.x: C_Spell.GetSpellInfo,
C_SpellBook, C_ClassTalents. GetSpellInfo, GetSpecialization, GetNumSpellTabs do
not exist. Action slots run to 1024; the gamepad bars are 181 and up. Your working
directory has the truth, so look before you guess:
  api-useful.md                 what we use, and what has been measured to work
  api-1.60.1-signatures.txt     every documented function, event and type
  api-1.60.1.txt                every name that exists, documented or not
Grep for a name before calling it. Never call functions blind or in bulk: calling
unknown functions crashed the game outright, which pcall cannot catch.
The code runs as an addon, Lua 5.1. print() goes to their window. Globals you
create are allowed; replacing one of Blizzard's is refused, because it taints the
UI. Never open or show Blizzard frames (the chat box, panels): that broke the
controller's A and B buttons. Some functions are refused (deleting items, sending
chat, trading, spending gold, leaving groups); do not try them. Insecure code
cannot cast, target or move, so do not write code that tries.
Keep chunks small and say in `say` what the code will do.

Looking. Your steps run blind: what Lua printed, whether a placement landed,
reaches you only in <character> after a reload. When you need that before you can
finish (exploring an API, checking code worked, a change that depends on a
result), set `look`. The player is offered a Reload button; when they press it you
are called again with the refreshed <character> and carry on, so say in `say` what
you are about to check. Do not add a reload step yourself when looking. Leave
`look` off when the answer is already complete.

Addons. Installing them is painful on a controller, so they will ask you to find,
install, update or remove addons. Research with WebSearch and WebFetch (GitHub,
CurseForge and Wago only). Prefer the addon's own GitHub repository, and check its
maintainer before recommending it: api.github.com/repos/OWNER/REPO and
/users/OWNER for account age, other repositories, stars and whether it is a fork;
recent commits; releases or tags; that its .toc lists Interface 16001, which is
this client; and, where you can reach it, that the CurseForge or Wago page links
to that same repository. Tell them what you found, the good and the concerning,
in `say`, name the repository, and ask. Only after they have said yes in this
conversation, add a step: kind `addon`, action `install`, repo OWNER/REPO. An
update is the same install again. `remove` takes the folder or repo, and only
removes what you installed; `list` shows those. You will see each result in your
next message. A new addon needs a full game restart (exit and relaunch); say so,
since you cannot do it for them.

Never act for the player in combat. Writing is yours; pressing is theirs.

Never act for the player. You write configuration; they press the button. Do not
offer to attack, move, target, or take any action in combat.";

/// What the model decided, already checked against what the addon accepts.
pub struct Spoken {
    /// the line to show in the companion window
    pub say: String,
    /// the inbox table to deliver, or None when nothing should change in game
    pub inbox: Option<String>,
    /// the agent wants to see its steps' results: call it again after the reload
    pub look: bool,
    /// steps carried out on this machine, not in game: (action, repo or folder)
    pub addons: Vec<(String, String)>,
}

/// One continuing conversation with the agent.
///
/// Without this every utterance starts cold, so "put it on the other bar instead"
/// has no idea what "it" was. The CLI hands back a `session_id`; replaying it with
/// `--resume` keeps the thread. `--system-prompt-snapshot` is on by default, so the
/// rules recorded on the first call are reused verbatim on every resume â€” they do
/// not need resending, and resending them would not help if they did.
///
/// The character's state rides along the same way: sent when it differs from what
/// this thread last saw, which is once per reload rather than once per utterance.
#[derive(Default)]
pub struct Session {
    /// the `--model` to ask for; empty means DEFAULT_MODEL
    pub model: String,
    thread: Option<String>,
    /// the context this thread has already been given
    seen: Option<String>,
    /// the context in the request now in flight, adopted once it succeeds
    offered: Option<String>,
    /// what this machine did for the last answer (addon installs), told next time
    pub note: Option<String>,
}

impl Session {
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
        let message = match self.note.take() {
            Some(note) => format!("<results>\n{note}\n</results>\n\n{message}"),
            None => message,
        };
        self.offered = fresh;
        let mut claude = Command::new("claude");
        claude.arg("--print").arg(message);
        match &self.thread {
            Some(thread) => {
                claude.args(["--resume", thread]);
            }
            // the rules only go out on the first call; the snapshot carries them
            None => {
                claude.args(["--system-prompt", RULES]);
            }
        }
        // the docs folder is the agent's whole world: --restricted keeps the file
        // tools inside it
        claude.current_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/docs"));
        claude
            .args(["--tools", TOOLS])
            // dontAsk refuses whatever is not pre-approved, read-only tools included
            .args(["--allowedTools", ALLOWED])
            .args(["--output-format", "json"])
            .args(["--json-schema", SCHEMA])
            .args(["--model", if self.model.is_empty() { DEFAULT_MODEL } else { &self.model }])
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
    // addon steps run on this machine; the rest go to the game
    let (machine, game): (Vec<&Value>, Vec<&Value>) =
        steps.iter().partition(|step| step.get("kind").and_then(Value::as_str) == Some("addon"));
    let addons = machine
        .iter()
        .map(|step| {
            let action = field(step, "action")?.to_string();
            let target = if action == "list" { String::new() } else { field(step, "repo")?.to_string() };
            Ok((action, target))
        })
        .collect::<io::Result<Vec<_>>>()?;
    let mut built = game.into_iter().map(step_inbox).collect::<io::Result<Vec<String>>>()?;
    let look = command.get("look").and_then(Value::as_bool) == Some(true);
    // looking needs a reload, and a reload needs the player's press: offer it,
    // unless the answer already offers its own button
    if look && buttons == 0 {
        built.push("{ kind = \"reload\" }".to_string());
    }
    // several steps still ride in one message: one bell, applied in order
    let inbox = match built.len() {
        0 => None,
        1 => built.pop(),
        _ => Some(format!("{{ kind = \"batch\", steps = {{ {} }} }}", built.join(", "))),
    };
    let thread = envelope
        .get("session_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    Ok(Answer { spoken: Spoken { say, inbox, look, addons }, thread })
}

/// One step as the inbox table the addon's dispatch accepts.
fn step_inbox(command: &Value) -> io::Result<String> {
    Ok(match field(command, "kind")? {
        "chat" => crate::chat_inbox(field(command, "text")?),
        "macro" => format!(
            "{{ kind = \"macro\", name = {}, body = {} }}",
            crate::lua_string(field(command, "name")?),
            crate::lua_string(field(command, "body")?)
        ),
        "press" => format!(
            "{{ kind = \"press\", label = {}, macro = {} }}",
            crate::lua_string(field(command, "label")?),
            crate::lua_string(field(command, "macro")?)
        ),
        "reload" => "{ kind = \"reload\" }".to_string(),
        "lua" => format!("{{ kind = \"lua\", code = {} }}", crate::lua_string(field(command, "code")?)),
        "module" => {
            let name = field(command, "name")?;
            if command.get("remove").and_then(Value::as_bool) == Some(true) {
                format!("{{ kind = \"module\", name = {}, remove = true }}", crate::lua_string(name))
            } else {
                format!(
                    "{{ kind = \"module\", name = {}, code = {} }}",
                    crate::lua_string(name),
                    crate::lua_string(field(command, "code")?)
                )
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
            format!(
                "{{ kind = \"bar\", slot = {slot}, what = {}, name = {} }}",
                crate::lua_string(what),
                crate::lua_string(name)
            )
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
