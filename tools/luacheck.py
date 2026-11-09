"""A syntax sanity check for Lua we cannot run.

The addon only ever executes inside the game, so a mistake in it costs a full
write-reload-read cycle to discover -- and twice now that mistake was mechanical:
an unterminated string literal, and a block left open. Both are catchable here in
milliseconds, so they should be.

This is deliberately not a Lua parser. It tokenizes far enough to know what is a
string and what is a comment, then checks the two things that have actually gone
wrong. It will not catch a misspelled function name or a bad argument; `luac -p`
would, and if Lua is ever on the PATH that is the better check.

    python -I tools/luacheck.py addon/WowCompanion/Companion.lua
"""

import re
import sys

# `end` closes function/do/if; `until` closes repeat. `if` rather than `then` is
# the opener to count, so that `elseif ... then` -- which opens nothing -- does not
# inflate the total. `while x do` and `for x do` are counted by their `do`.
OPENERS = ("function", "do", "if", "repeat")
CLOSERS = ("end", "until")


def strip(source):
    """The source with strings and comments blanked, and any string left open."""
    out = []
    unterminated = None
    at, line = 0, 1
    length = len(source)
    while at < length:
        char = source[at]
        if char == "\n":
            line += 1
            out.append(char)
            at += 1
            continue
        # long comment or long string: --[[ ]] and [[ ]], with any number of =
        long_bracket = re.compile(r"(--)?\[(=*)\[").match(source, at)
        if long_bracket and (long_bracket.group(1) or source[at] == "["):
            level = long_bracket.group(2)
            close = source.find("]%s]" % level, long_bracket.end())
            body = source[at : close + len(level) + 2] if close != -1 else source[at:]
            line += body.count("\n")
            out.append("\n" * body.count("\n"))
            at += len(body)
            continue
        if source.startswith("--", at):
            stop = source.find("\n", at)
            at = length if stop == -1 else stop
            continue
        if char in "\"'":
            began, at = line, at + 1
            while at < length:
                if source[at] == "\\":
                    at += 2
                    continue
                if source[at] == char:
                    at += 1
                    break
                if source[at] == "\n":
                    # Lua does not allow a raw newline inside a short string, so
                    # this is the "escape arrived as a literal line break" failure
                    unterminated = unterminated or began
                    break
                at += 1
            else:
                unterminated = unterminated or began
            continue
        out.append(char)
        at += 1
    return "".join(out), unterminated


def check(path):
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    code, unterminated = strip(source)
    complaints = []
    if unterminated:
        complaints.append(f"{path}:{unterminated}: string literal is not closed")

    words = re.findall(r"\b\w+\b", code)
    opened = sum(words.count(word) for word in OPENERS)
    closed = sum(words.count(word) for word in CLOSERS)
    if opened != closed:
        over = "unclosed" if opened > closed else "extra end/until"
        complaints.append(
            f"{path}: {opened} openers vs {closed} closers ({over}); "
            + ", ".join(f"{word}={words.count(word)}" for word in OPENERS + CLOSERS)
        )

    for name, kind in (("(", ")"), ("{", "}"), ("[", "]")):
        if code.count(name) != code.count(kind):
            complaints.append(
                f"{path}: {code.count(name)} {name} vs {code.count(kind)} {kind}"
            )
    return complaints


if __name__ == "__main__":
    found = [complaint for path in sys.argv[1:] for complaint in check(path)]
    for complaint in found:
        print(complaint)
    print("looks syntactically sound" if not found else f"{len(found)} problem(s)")
    sys.exit(1 if found else 0)
