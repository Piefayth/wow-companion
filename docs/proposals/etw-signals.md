# The game reaching the PC through its file opens (ETW)

Status: idea to test (the player, 2026-11-12: "we should test that at some
point"), not built.

## Why

The game can reach the PC live only through the data strip, which the companion
reads off the screen. Any screen read goes through Windows' compositor, so while
the capture is open the game cannot present straight to the display, and the
cost shows as stutter when the GPU has no headroom. Turning the command-strip
watcher off removed the stutter (2026-11-12). Everything else the game knows
waits for a reload.

The game already touches the disk on our behalf: it plays a slot's bell every
0.1 s, and a bell is over 174,762 bytes so that every play opens the file again
(bells.rs). Windows' own event tracing (ETW, what Process Monitor uses) reports
every file a process opens, by name, in order, as it happens, and the process
never waits on the listener. So the game could speak by playing files, and the
companion could hear it through ETW: no screen read, no polling, no cost in the
game's frames.

## What it could replace

- The command strip (Stop, Cancel, Send now, the settings page's `bind`, `set`,
  `mics`).
- If names carry data (below): the agents' live reads (`strip --send`, `--chat`)
  and much of what waits for a reload today (the export, `look`).

## The test

1. **Permission.** The kernel's file events (`Microsoft-Windows-Kernel-File`, the
   Create keyword, filtered to Wow.exe's process id) need an elevated session or
   a user in Windows' "Performance Log Users" group (one admin prompt, then sign
   out and in). Try the group first: it is what a release's setup would ask for.
2. **Does every play show?** From a `lua` step, play a silent streamed-size file
   of ours a few times: one Create event each, and their order kept when several
   are played in one frame.
3. **Does a name carry data?** Play a file that does not exist,
   `...\Signals\cmd\cancel-l1-1794464490721.ogg`. If the game asks the disk for
   it, the command is in the name: a few hundred characters per play. If it does
   not (it may know its addons' files from load; bells.rs says "never a missing
   file"), commands are sequences of real silent signal files, a few bits each:
   enough for commands, not for kilobyte reads.
4. **Cost.** The game's frame times while a burst of plays is heard, against
   none; the companion's CPU with the session running.

## Open questions

- A second listener (the friend's PC, a release) needs the same permission;
  the setup window would ask for it with one admin prompt.
- What the game does with a missing sound file each time (an error shown, a
  cache of misses) decides whether names can be invented freely.
