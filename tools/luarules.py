"""Check our Lua against the game-code rules we learned the hard way.

CLAUDE.md, "Rules for game code", holds rules every agent must follow by hand;
on 2026-11-10 the Companion window broke one ("mark frames out of combat") and
the player got "Interface action failed" for most of a day. This reads our
files (it never runs in the game) and reports each place a rule is broken:

  error  open-blizzard   opening or closing Blizzard's windows from our code
                         (the chat box, bags, character sheet): taints the
                         gamepad focus, A and B stop working
  error  blizzard-write  setting a field of one of Blizzard's frames or tables
  error  blizzard-call   changing one of Blizzard's frames (Show, SetPoint,
                         SetScript, SetAttribute...)
  error  custom-nav      useCustomNavigation / FocusGamepad / UnfocusGamepad on
                         our frames: the focus manager reads them while
                         switching, so the switch runs tainted
  error  panel-event     firing the panel manager's or bags' events ourselves
  error  click-edge      a SecureActionButtonTemplate on "AnyUp" alone: the
                         wrapper runs and the macro does not ("AnyDown")
  error  module-window   a controller-managed window in modules/ (modules run
                         force-tainted; such windows live in the addon's files)
  warn   combat-focus    a SecureHelper-wrapped focus call (SmartNavigation_Mark*,
                         FrameControlsManager, ShowUIPanel/HideUIPanel) with no
                         InCombatLockdown check before it in its function, and
                         not handed to WC.AfterCombat: in a fight it fails with
                         "Interface action failed"

A line (or the line above it) holding `rules: ok <why>` in a comment is
accepted: say why the rule does not apply there.

    python -I tools/luarules.py                 # every addon and module file
    python -I tools/luarules.py <file.lua> ...  # only these
    python -I tools/luarules.py --self-test     # the positive control
The control, tools/luarules_control.lua, breaks every rule once (and holds
lines that must pass): a checker that misses one of its own examples proves
nothing when it reports a file clean. Run it after changing a rule.
Exit status 1 when an error is found. Not a Lua parser: patterns over the code
with comments and strings blanked (tools/luacheck.py's strip), so code inside a
secure snippet is not checked.
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from luacheck import strip  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Blizzard's tables an addon is meant to write into: slash commands, popups,
# key binding names. Writing these is the documented way, not taint.
SANCTIONED_TABLES = {"SlashCmdList", "StaticPopupDialogs", "UISpecialFrames", "UIPanelWindows"}
# shared frames addons are meant to drive: the tooltips (SetOwner, Show, Hide)
SANCTIONED_FRAMES = {"GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2", "EmbeddedItemTooltip"}
FRAME_CHANGES = ("Show|Hide|SetShown|SetScript|SetPoint|ClearAllPoints|SetAllPoints|SetParent|"
                 "SetAlpha|SetAttribute|SetSize|SetWidth|SetHeight|EnableMouse|SetFrameStrata|"
                 "SetFrameLevel|RegisterForClicks|UnregisterAllEvents|UnregisterEvent|SetScale|"
                 "SetMovable|SetClampedToScreen|Raise|Lower")
OPEN_BLIZZARD = ("ChatFrame_OpenChat|ChatFrameUtil%.OpenChat|ChatFrameUtil%.ActivateChat|ChatEdit_ActivateChat|"
                 "CloseAllBags|OpenAllBags|ToggleAllBags|ToggleBackpack|ToggleBag|OpenBag|CloseBag|"
                 "ToggleBackpack_Combined|ToggleCharacter|ToggleSpellBook|ToggleFriendsFrame|"
                 "ToggleGameMenu|ToggleWorldMap|ToggleQuestLog|ToggleCollectionsJournal").replace("%.", r"\.")
FOCUS_CALL = re.compile(r"\b(SmartNavigation_Mark\w*|FrameControlsManager\s*[:.]\s*\w+|ShowUIPanel|HideUIPanel)\s*\(?")


def ours_globals(files):
    """Global names our own files define (assigned at the top level)."""
    names = {"WC"}
    for path in files:
        code, _ = strip(open(path, encoding="utf-8", errors="replace").read())
        for m in re.finditer(r"(?m)^([A-Za-z_]\w*)\s*=(?!=)", code):
            names.add(m.group(1))
        for m in re.finditer(r"(?m)^function\s+([A-Za-z_]\w*)\b", code):
            names.add(m.group(1))
        for m in re.finditer(r"CreateFrame\(\s*\"[^\"]*\"\s*,\s*\"([A-Za-z_]\w*)\"", open(path, encoding="utf-8", errors="replace").read()):
            names.add(m.group(1))
    return names


def is_ours(name, ours):
    return name in ours or name.startswith(("WC", "WowCompanion"))


def accepted(raw_lines, index):
    for at in (index, index - 1):
        if 0 <= at < len(raw_lines) and "rules: ok" in raw_lines[at]:
            return True
    return False


def function_start(lines, index):
    """The line where the function holding `index` begins (indentation-based)."""
    here = len(lines[index]) - len(lines[index].lstrip())
    for at in range(index, -1, -1):
        line = lines[at]
        indent = len(line) - len(line.lstrip())
        if re.search(r"\bfunction\b", line) and (indent < here or at == index):
            return at
        if line.strip() and indent == 0 and at != index:
            return at
    return 0


def check(path, ours):
    raw = open(path, encoding="utf-8", errors="replace").read()
    code, _ = strip(raw)
    raw_lines, lines = raw.split("\n"), code.split("\n")
    try:
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    except ValueError:  # another drive
        rel = path.replace(os.sep, "/")
    in_module = rel.startswith("modules/")
    found = []

    def report(index, severity, rule, text):
        if not accepted(raw_lines, index):
            found.append((rel, index + 1, severity, rule, text))

    # names given to buttons made from SecureActionButtonTemplate in this file
    secure_buttons = set(re.findall(
        r"\b([A-Za-z_]\w*)\s*=\s*[^\n]*CreateFrame\(\s*\"Button\"[^\n]*SecureActionButtonTemplate", raw))

    for index, line in enumerate(lines):
        rawline = raw_lines[index] if index < len(raw_lines) else ""
        for m in re.finditer(r"\b(" + OPEN_BLIZZARD + r")\s*\(", line):
            report(index, "error", "open-blizzard", f"{m.group(1)}() opens or closes Blizzard's window from our code")
        for m in re.finditer(r"(?<![\w.:])([A-Z][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_]\w*)\s*=(?!=)", line):
            name = m.group(1)
            if not is_ours(name, ours) and name not in SANCTIONED_TABLES:
                report(index, "error", "blizzard-write", f"sets {name}.{m.group(2)}, a field of Blizzard's")
        for m in re.finditer(r"(?<![\w.:])([A-Z][A-Za-z0-9_]*)\s*:\s*(" + FRAME_CHANGES + r")\s*\(", line):
            name = m.group(1)
            if not is_ours(name, ours) and name not in SANCTIONED_FRAMES:
                report(index, "error", "blizzard-call", f"{name}:{m.group(2)}() changes Blizzard's frame")
        if re.search(r"\.\s*useCustomNavigation\s*=(?!=)", line) or re.search(r"[.:]\s*(FocusGamepad|UnfocusGamepad)\s*=(?!=)", line) \
                or re.search(r"\bfunction\s+[\w.:]*[.:](FocusGamepad|UnfocusGamepad)\b", line):
            report(index, "error", "custom-nav", "useCustomNavigation/FocusGamepad/UnfocusGamepad on our frame taints the focus switch")
        if re.search(r"TriggerEvent\s*\(", line) and re.search(r"TriggerEvent\s*\(\s*[\"'](UIParentPanelManager|ContainerFrame)\.", rawline):
            report(index, "error", "panel-event", "fires the panel manager's or bags' event from our code")
        # the measured trap (2026-11-09): a secure action button on "AnyUp" alone
        # runs PreClick and PostClick but not its macro. Two edges on purpose
        # (a snippet reading down and up) and plain buttons are fine.
        click = re.search(r"\b([A-Za-z_]\w*)\s*:\s*RegisterForClicks\s*\(", line)
        if click and click.group(1) in secure_buttons and re.search(r"RegisterForClicks\s*\(\s*[\"']AnyUp[\"']\s*\)", rawline):
            report(index, "error", "click-edge", "a secure action button on \"AnyUp\" alone: its macro never runs; register \"AnyDown\"")
        if in_module and re.search(r"\b(SmartNavigation_MarkFrameFocusable|ShowUIPanel)\s*\(|UIPanelWindows\s*\[", line):
            report(index, "error", "module-window", "a controller-managed window in a module (modules run force-tainted)")
        m = FOCUS_CALL.search(line)
        if m and not re.match(r"\s*(local\s+)?function\b", line) and "hooksecurefunc" not in line:
            start = function_start(lines, index)
            # WC.AfterCombat(fn) is the shared guard (Engine.lua): fn runs now
            # out of combat, else when the fight ends. A call inside it, or an
            # `if <name> then` whose next line hands it to it, is guarded.
            guard = range(start, min(index + 2, len(lines)))
            if not any("InCombatLockdown" in lines[at] or "AfterCombat" in lines[at] for at in guard):
                report(index, "warn", "combat-focus", f"{m.group(1).replace(' ', '')} with no InCombatLockdown check before it in its function")
    return found


def self_test(ours):
    """Every `-- <rule>` comment in the control must be reported on its line,
    and nothing else."""
    control = os.path.join(ROOT, "tools", "luarules_control.lua")
    rules = {"open-blizzard", "blizzard-write", "blizzard-call", "custom-nav", "panel-event",
             "click-edge", "module-window", "combat-focus"}
    want = set()
    for number, line in enumerate(open(control, encoding="utf-8").read().split("\n"), 1):
        m = re.search(r"--\s*([a-z-]+)", line)
        if m and m.group(1) in rules:
            want.add((number, m.group(1)))
    got = {(line, rule) for _, line, _, rule, _ in check(control, ours)}
    for line, rule in sorted(want - got):
        print(f"MISSED  line {line}: {rule}")
    for line, rule in sorted(got - want):
        print(f"EXTRA   line {line}: {rule}")
    print(f"self-test: {len(want & got)}/{len(want)} caught, {len(got - want)} extra")
    return 0 if want == got else 1


def main(argv):
    every = sorted(glob.glob(os.path.join(ROOT, "addon", "**", "*.lua"), recursive=True)
                   + glob.glob(os.path.join(ROOT, "modules", "*.lua")))
    every = [p for p in every if not os.path.basename(p) == "Modules.lua" and "WowCompanion_S" not in p]
    ours = ours_globals(every)
    if argv == ["--self-test"]:
        return self_test(ours)
    targets = [os.path.abspath(a) for a in argv] or every
    found = []
    for path in targets:
        found += check(path, ours)
    for rel, line, severity, rule, text in found:
        print(f"{rel}:{line}: {severity} {rule}: {text}")
    errors = sum(1 for f in found if f[2] == "error")
    warns = len(found) - errors
    print(f"{errors} error(s), {warns} warning(s)" if found else "no rule broken")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
