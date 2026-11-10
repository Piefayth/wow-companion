WoW Companion
=============

Voice and agent control for World of Warcraft: Forever on a controller. Hold a
button, speak, and it turns into something done in game: chat, macros, bars,
addon changes, answers about your character.

What you need
-------------
- Windows 10 or 11, and World of Warcraft: Forever.
- Claude Code installed and signed in (https://claude.com/claude-code). The
  companion runs it on your own subscription.
- A controller and a microphone.
- About 2 GB free (the speech model is 1.6 GB).

First run
---------
1. Unzip this folder anywhere you like (it does not need to be in Program Files).
2. Run wow-companion-setup.exe. Windows may warn that the app is unrecognised:
   it is not code-signed. "More info", then "Run anyway".
3. In the setup window: check the game folder, pick your controller and press
   "learn it" for your talk button, pick your mic (speak: the bar should move),
   and press "Test speech recognition". If the GPU test fails, use the CPU
   button it offers, with a small model (ggml-small.bin): the large one is
   far too slow on a CPU.
4. Save, then "Save and check everything".
5. Run wow-companion.exe install (once), then fully restart the game.
6. Start the companion: wow-companion.exe run
7. In game: /wc talkkey, then press your talk button once.

What this changes on your PC (and how to undo it)
--------------------------------------------------
- This folder: everything here. Delete it to remove the programs.
- Your game's Interface\AddOns folder: WowCompanion, WowCompanion_Wheel, and
  512 small folders WowCompanion_S001 to WowCompanion_S512 (how messages reach
  the game; they show grouped in the addon list). Delete those folders to undo.
  Addons the agent installs for you are listed in
  %LOCALAPPDATA%\wow-companion\addons.json, with where each came from.
- %LOCALAPPDATA%\wow-companion: your settings, conversations, logs and backups.
  Delete the folder to undo.
- Nothing in the registry, no services, nothing starts with Windows.

The agent
---------
The agent is Claude Code running on your PC with every tool and no permission
prompts, so it can write addons, install them (after you say yes) and fix things
itself. That is powerful: it can change files on your PC. It never plays for you:
casting, targeting, moving, spending and sending are always your press.
Your preferences go in player\profile.md; the agent keeps it up to date.
