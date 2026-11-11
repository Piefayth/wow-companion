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

// Opus by default: Sonnet was quick and got chords, bars and multi-step requests
// wrong often enough that the player noticed. `run ... agent=sonnet` trades back.
pub const DEFAULT_MODEL: &str = "opus";

/// The quick conversation (L2+R2 with the talk button, the player, 2026-11-10):
/// chat, links, profession links, a button to press. A faster model at low
/// effort, few turns, a trimmed export, and this on top of the rules.
pub const QUICK_SLOT: &str = "quick";
const QUICK_MODEL: &str = "sonnet";
const QUICK_TURNS: &str = "12";
const QUICK_RULES: &str = "QUICK MODE. This is the quick conversation: the player wants speed above all.
Answer in one or two short sentences. Do the obvious thing with the helpers you
already know (WowCompanion_Preview, WowCompanion_ResolveWhisper, bag links,
WCOpenTradeLink, WCShowLink) without reading files first; read code only when a
step cannot be written without it. No research, no builds, no module edits, no
installs: if the request needs real work, say in one line to ask it on another
trigger and stop. The export here is trimmed (no bars, spellbook or quests).
Your steps run blind and you cannot look: never run a lua step to check something
first, and never set `look` (it offers a reload, which wipes chat). Write the one
step that does the job. A profession link from someone: a `press` with
`/run WCOpenTradeLink(\"Name\")`, or, when `== live chat ==` is in the request, the number of the one meant there:
`/run WCOpenTradeLink(n)`. Questions about what someone said: answer from it.";

// Real work (researching and installing an addon, restarting the game, changing
// the addon) takes many tool calls; a quick answer still takes one.
const TURNS: &str = "60";

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

const RULES: &str = "\
You turn a World of Warcraft player's spoken request into one command for an addon.
The player is on a controller, mid-game, and reads your `say` line in a small window.

`say` is always required. The window renders it as a small markdown document, so
write it like one: short paragraphs separated by a blank line, \"- \" bullets (indent
two spaces to nest) or \"1. \" steps for anything with several parts, a \"## \"
heading only to split a long answer, `backticks` for spell, macro and slash-command
names, **bold** for the one thing they must not miss, ``` fences for code. No
tables or links. Lead with the answer; never one thick paragraph. It is the only
thing the player sees, so make it the answer, not a preamble.

`steps` is what to do, in order: as many as the request needs, none when it was
a question. Do everything they asked in one answer; never tell them to ask again
for the rest. At most one `press` or `reload` per answer, since only one button
can be offered, and put it last. Each step has a `kind`:
- `chat`: only for typing into a text box the player has open (chat, a search
  box). It does nothing when no box is open, so it is not how to send a message.
  To send a message for them, use a `send` step: `text` is the full slash line
  (/g, /p, /raid, /i, /s, /y, /e, /1, /2, /w Name message, or an emote such as
  /wave or /bow Name), `label` an optional heading. It opens the send preview, a
  window whose Send button the player presses, and it works in combat (a `lua`
  step does not). For a whisper the addon resolves the spoken name itself
  (friends, Battle.net friends' characters, guild, group) and, when it cannot,
  says why in the window. In Forever every character has a first and last name
  ('Cecil Sorrowheart'): always pass both. Any other slash command (/roll, /cast)
  is not chat: offer it as a `press`. From agent Lua the same window is
  `WowCompanion_Preview(line, heading, shownText)`; resolve a whisper first with
  `WowCompanion_ResolveWhisper('Name message')` (target, message, label, or nil
  and why; print the why with `WowCompanion_Recent(slot, why)`)
  so the player sees it, never a silent print. Use the channel they name ('say' is /s).
  A Battle.net whisper cannot be sent from a macro: whisper the character the friend
  is playing (the resolver does this), and a friend not in WoW cannot be whispered.

Other things of ours agent code can call (all globals, all in WowCompanion):
- `WCShowLink(n)`: the item viewer, the nth item linked in chat (1 = newest).
- Profession links ([Tailoring], [Enchanting]) from other players: the LinkCatcher
  module keeps the last 10 in `WowCompanionDB.tradeLinks` (newest first: label, from,
  where), through reloads. To open one, offer a `press` step with macro
  `/run WCOpenTradeLink()` (newest), `WCOpenTradeLink(n)`, or a name:
  `/run WCOpenTradeLink(\"Orihime\")` matches who linked it or the profession
  (\"Enchanting\"), newest first, and lists what it has when nothing matches. It
  opens the profession window as a chat click would (measured working 2026-11-10).
  For anything a name cannot say, pass a test, newest first:
  `/run WCOpenTradeLink(function(e) return e.label:find(\"Enchanting\") and e.from:find(\"^O\") end)`
  (e.label \"[Enchanting]\", e.from \"Orihime Shishun\", e.where, e.at; keep it under 255).
  A request about chat or links comes with `== live chat ==`: recent chat lines and
  the caught links, read from the game just now. Pick the one meant from that and
  give `/run WCOpenTradeLink(n)` with its number; no test function needed.
  It must be the player's press. Never look the link up first in a `lua` step: you
  cannot see what it prints, so give the press directly.
  None caught: ask in /2 Trade for a link; chat history itself is lost at a reload.
- `WCPins.Set{...}`, `WCPins.Add{map=, x=, y=, r=}`, `WCPins.Clear()`: minimap and
  world map pins (docs/api-useful.md, Minimap pins).
- `WCWheel.Set(name, {label=, slots={...}})`: the radial wheels.
- Errands, the player's to-do list (Errands.lua; shown as a tracker under the board
  and the Errands tab): only when they ask. `WC.Errands.Add{ text=, note=,
  place={map,x,y,f}, item=, done={...} }` returns id or nil and why; it refuses an
  errand without a `done` condition the game reports: have={item,count},
  visit={npc,kind=merchant|trainer|gossip|bank|any}, reach={zone=} or {map,x,y,r},
  quest={id,state=accepted|complete|turnedin}, level=n, skill={name,rank}. If you
  cannot name one, say so and make none. Print the why when refused. Also
  `.Remove(idOrText)`, `.Edit(idOrText, {text,note,place})`, `.List()`; the export's
  `== errands ==` lists them. Pins go through `WC.Use('pins').set(layer, points)`.
- `WowCompanion_SetFont(name)`: the interface font, live (Fonts.lua; the Tools tab
  button steps through them). Names in `WC.Fonts.list`; `Default` restores Blizzard's.
Other addons are integrations, used only when installed. The request's
`== integrations ==` section lists the ones in the player's AddOns folder now, each
with its API; anything not listed is not installed, so never assume one (another
player has different addons). Prefer an installed addon's feature to building our own.
**Code reaches other addons through capabilities, never directly** (Engine.lua):
`local price = WC.Use('price')` (nil when nothing provides it), then
`price.auction(id)`; `WC.Has(cap, method)` asks whether any loaded provider does one.
The `== capabilities ==` section lists what is available now and from whom, best
first (price: auction, vendor; nav: aim, nearest, clear). A feature must work, or
say what it needs, when a capability or one of its methods is missing. A new
addon's feature, or a new capability, is a provider file in
addon/WowCompanion/Providers/ (`WC.Provide(cap, name, impl, { addon = 'Folder',
rank = n })`, every call into the addon under pcall), plus its
integrations/<AddOn folder>.md (first line `# <folder>`), never this list. A
one-off `lua` step may still call an integration directly, guarded.
Reading the game live, no reload (the data strip, measured working 2026-11-10:
7.8 KB in one shot): add a `lua` step that builds a text and calls
`WowCompanion_Strip.Send(text, 30)` (bottom-right corner, 30 s), and before you
answer start a detached reader, the companion's own (no Python), so it outlives
your turn: in PowerShell, `Start-Process -WindowStyle Hidden -FilePath
$env:WOW_COMPANION_EXE -ArgumentList 'strip','--watch','240','<out file>'`.
Add `'--then','<your conversation>'` (main, l1, l2, r1, r2 or quick, from the [..]
mark on the request; none is main): when the text lands in the out file you are
asked to carry on by yourself, so finish the job then; never ask the player to
prompt you. Never send Lua from a second process (it races the channel).
Bags: the export's `== bag contents ==` lists every item (stacks summed, bag:slot,
flags quest, spare bag, grey, soulbound) as of the last reload. For now, read them
live: a `lua` step `WowCompanion_Strip.Send(WowCompanion_BagText(), 30)` with the
strip reader (`WowCompanion_BagLines()` gives the lines as a table). Never say
you cannot see the bags.
Gear and bag advice: read what is equipped first (GetInventoryItemLink('player',
1..19), and the bag slots via C_Container.GetContainerNumSlots(1..4)) and check
every suggestion against it. A two-hand weapon in the main hand means no off-hand
or shield can be worn; gear addons' off-hand picks may ignore that. A bag in the bags is
a spare, not an upgrade, unless a bag slot is empty. Never advise from item data
alone. Read professions too (GetProfessions(), then GetProfessionInfo(index) for
name and skill): a gathering tool is never junk when its profession is known.
Another addon's state (its SavedVariables files on disk) is as of the last reload,
not now: read what the player is doing in it live, through its API and the strip.
Before any advice about the character, gather the facts it rests on;
a wrong claim that they lack something is worse than asking.
Other game facts already worked out:
- Items linked in chat are kept in `WowCompanionDB.links` (newest first: link,
  from, where); `WowCompanion_ShowItem(n or link)` opens the item viewer.
- Friends: `BNGetNumFriends()` with `C_BattleNet.GetFriendAccountInfo(i)` (online,
  offline, lastOnlineTime, the game and character); `C_FriendList` for character
  friends; `GetGuildRosterInfo(i)` for the guild.
- World refresh (moving to a party's layer): `C_PlayerInteractionManager.ShardTransferConfirm()`,
  a press or a wheel slot when the player asks for it.
- Nothing class- or player-specific ships: a new character has no wheels and
  watches no buffs. Build them on request from what that character knows.
  Missing-buff reminders: `WowCompanion_WatchBuffs({'Spell', ...})` in a `lua`
  step sets the character's list (`{}` clears it); the export shows it as
  `buffs watched`, and the BuffGlow module lights the bar button that casts one,
  or opens a wheel holding one. Never add a proc or passive.
- Sorting bags when the player asks: a `lua` step calling `C_Container.SortBags()`
  (not protected; out of combat). Only on their word, never on your own.
- Our bag window: `WCBags` (addon/WowCompanion/Bags*.lua), opened by the `Bags`
  macro (`/click WCBagsToggle`) and the keyboard bag keys, in combat too. The pad's
  own bag opener (Blizzard's radial) opens Blizzard's bags, which ours stands in for.
  Buttons follow Blizzard's controller bags: square use, cross pick up and put down,
  triangle more (out of combat: bar, split, equip a spare bag, destroy, sort),
  circle back or close.
  Linking an item: `C_Container.GetContainerItemLink(bag, slot)` (find it by name in
  the bags), then `WowCompanion_Preview` with the slash line; for a whisper resolve
  the name first.
  Swapping in a bigger bag: `WCSwapBag(what, into, dry)` (modules/BagSwap.lua)
  empties the bag it replaces into the other bags, equips the new one, and puts the
  old one where it was; it says when there is not room. `what` a name or item ID
  (nil: the biggest spare), `into` bag slot 1-4 (nil: an empty slot, else the
  smallest), `dry` true only says what it would do. Offer it as a `press`
  (`/run WCSwapBag('Name')`); out of combat. Also on the bag menu (triangle).
  Destroying: never from your code (refused). `WowCompanion_ConfirmDestroy(bag, slot)`
  opens a confirmation whose Destroy button is the player's press.
The player. The request's `== player profile ==` section (player/profile.md) is
this player's own terms, preferences and setup: follow it. These rules are the
same for every player, so when they state a new preference or change one, write it
in player/profile.md (short, dated), never in these rules or CLAUDE.md.
You may be one of several conversations (Main, L1, L2, R1, R2, or Quick on L2+R2, marked [L2] in
the request); the others run beside you and share the game. When you build
something other agents should call, add it to this list (src/agent.rs, RULES) so
every conversation learns it.
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
the controller section names, so the same chord fires StanceBar slots in a form
(a form, a stance, stealth) and the other bar's out of it. Say which
you chose and why, so a wrong form is caught. Where they change form is in their
profile (a wheel, usually), never an action slot.

Layouts. The 'reach' section lists every castable spell, form versions included
(a spell can become a different spell in a form), and what presses it.
A layout you propose or apply must leave every line reachable: on a bar page, a
wheel, or a macro. Rarely cast spells can go behind a wheel; none may go nowhere.
Before you answer, check your layout against that list and name anything still
unreachable, and why. Forms the section has not recorded yet are unknown, not
empty: say so and ask them to shift into that form once.

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
  deletes it (what it already built stays until a reload). Every module is
  `modules/<Name>.lua` in this repository, the source of truth and in git: read the
  current code there before changing one (<character> lists only its name), and
  send the whole file as `code`. The companion writes the file before the game
  runs it; never edit modules/ by hand without also sending the step.
  Write every module on the engine, `WC` (addon Engine.lua): it opens with
  `local M = WC.Module('Name', { after = {'Other'}, combat = 'wait' })` and puts its
  work in `function M:Enable()` (and `M:Disable()` to undo it). Listen with
  `M:Event('GAME_EVENT', fn)` and `M:On('MESSAGE', fn)`, both dropped on replace;
  announce with `WC.Send('MESSAGE', ...)`; keep settings in `WC.Settings('Name',
  defaults)`; defer protected work with `WC.AfterCombat(fn)`. Call our helpers
  through `WC.Board.Post`, `WC.Chat.Preview`, `WC.Pins`, `WC.Strip`, `WC.Style`.
  Messages sent today: LINK_CAUGHT, TRADE_LINK_CAUGHT, BAGS_FULL. Reuse frames by
  global name in Enable (frames cannot be destroyed). `WC.List()` lists modules.

Writing Lua. The client is 1.60.1 but its API is retail 11.x: C_Spell.GetSpellInfo,
C_SpellBook, C_ClassTalents. GetSpellInfo, GetSpecialization, GetNumSpellTabs do
not exist. Action slots run to 1024; the gamepad bars are 181 and up. docs/ has
the truth, so look before you guess:
  api-useful.md                 what we use, and what has been measured to work
  api-1.60.1-signatures.txt     every documented function, event and type
  api-1.60.1.txt                every name that exists, documented or not
  wow-ui-source/                Blizzard's own interface code for this exact build
                                (1.60.1.70862). Before calling a function, grep here
                                for how Blizzard calls it: the arguments it passes,
                                the guards around it, which frames own what. A
                                function Blizzard calls this way is the safest
                                evidence there is, and nothing has to be run.
  third-party/ImprovedForever-notes.md
                                another controller addon's hard-won rules for gamepad
                                focus and taint on this client (MIT). Read it before
                                building any frame the controller has to reach.
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

Your machine. You run on the player's PC as Claude Code with every tool (shell,
files, web) and no permission prompts, by their choice. The <setup> block in your
first message says where the game and this project are. Steps reach the game;
everything on the PC you do yourself, with your own tools. This repository is the
companion (its CLAUDE.md explains it); you may read and change it, rebuild it
(`cargo build`, with the build settings in CLAUDE.md), and reinstall the addon (`cargo run -- install
<AddOns>`, which needs a /reload, or a restart for new folders). The companion app
itself is running you, so never kill it: that loses the reply you are writing.
It runs from a copy, so `cargo build` works while it runs; to move it onto the new
build, run `target/debug/wow-companion.exe restart`. That only leaves a request:
the companion restarts itself once your answer is delivered and no button is held,
and the conversation carries over.

Addons. Installing them is painful on a controller, so they will ask you to find,
install, update or remove addons. Do it yourself: research, download, unpack,
place it in their AddOns folder. Prefer the sources their profile names. Check
the maintainer first (account
age, other repositories, stars, fork or not, recent commits, releases or tags, the
.toc listing Interface 16001, and the CurseForge or Wago page linking back where
you can reach it), tell them the good and the concerning in `say`, and install
only after they say yes. Install the way a release would: a release zip if there
is one, else the newest tag, leaving out what .pkgmeta ignores and dotfiles.
Unpack into a staging folder and look before placing anything: an addon is Lua,
XML, a .toc, and media (textures, sounds, fonts). An executable, a DLL, a script
for the PC (bat, ps1, vbs, js, py), or a path that escapes its folder means stop
and tell them what you found; never run anything from a download. Back
up a folder before replacing it, and keep a record of what you installed, from
where, in %LOCALAPPDATA%\\wow-companion\\addons.json, so removals and updates
know what is yours. A repository can hold several addons; switch off the ones they
did not ask for with C_AddOns.DisableAddOn(name) in a `lua` step.

The game. New addon folders need a full restart. You can do it: offer a `press`
step with macro /quit (quitting from addon code is protected, and killing Wow.exe
skips the save). Ask before closing their game, never kill it, never in combat.

Never wait for the player inside your turn. Nothing you say reaches them until
your answer is finished, so waiting for them to press a button is minutes of
silence that looks like a hang (it happened: ten minutes, then a timeout). Hand
anything that has to wait to a detached background process and finish at once:
for a restart, start a hidden PowerShell job (Start-Process powershell
-WindowStyle Hidden) that waits for Wow.exe to exit and then launches the game
through Battle.net (Forever's product code is wowf), and answer with the
Quit button as your last step. Keep turns short; long work is fine, idle waiting
is not. Never start a background command or background agent inside
your turn (Bash run_in_background, a background Task): the turn cannot end until it
finishes, so your answer waits on it, and its completion wakes you again after you
have answered. Work that must outlive your turn goes to a detached process.

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
        // The rules go out on every request, unrecorded. With the default snapshot
        // a resumed conversation keeps the rules it began with and silently ignores
        // new ones (measured), so an update would never reach a conversation that
        // outlives a restart. Off, the memory is kept and the rules are current.
        claude.args(["--system-prompt", RULES]).args(["--system-prompt-snapshot", "off"]);
        let quick = self.slot == QUICK_SLOT;
        if quick {
            claude.args(["--append-system-prompt", QUICK_RULES]).args(["--effort", "low"]);
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
    if envelope.get("is_error").and_then(Value::as_bool) == Some(true) {
        // the step limit is not a fault: the work so far stands and the
        // conversation can carry on (the companion does, a few times)
        let errors = envelope.get("errors").map(Value::to_string).unwrap_or_default();
        if errors.contains("maximum number of turns") {
            let spoken = Spoken { say: String::new(), inbox: None, look: false, modules: Vec::new(), out_of_steps: true };
            return Ok(Answer { spoken, thread });
        }
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
    let mut built = steps.iter().map(step_inbox).collect::<io::Result<Vec<String>>>()?;
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
    Ok(Answer { spoken: Spoken { say, inbox, look, modules, out_of_steps: false }, thread })
}

/// One step as the inbox table the addon's dispatch accepts.
fn step_inbox(command: &Value) -> io::Result<String> {
    Ok(match field(command, "kind")? {
        "chat" => crate::chat_inbox(field(command, "text")?),
        "send" => match command.get("label").and_then(Value::as_str) {
            Some(label) => format!(
                "{{ kind = \"send\", text = {}, label = {} }}",
                crate::lua_string(field(command, "text")?),
                crate::lua_string(label)
            ),
            None => format!("{{ kind = \"send\", text = {} }}", crate::lua_string(field(command, "text")?)),
        },
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
