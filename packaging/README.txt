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
- About 2 GB free (the speech model, downloaded by the setup window, is up to 1.6 GB).

First run
---------
1. Unzip this folder anywhere you like (it does not need to be in Program Files).
2. Run wow-companion-setup.exe. Windows may warn that the app is unrecognised:
   it is not code-signed. "More info", then "Run anyway".
3. In the setup window: check the game folder, pick your controller and press
   "Set it" then the button you want to talk with, pick your mic (speak: the
   bar should move), press "Download" for the speech model it recommends
   (0.5 to 1.6 GB, checked before use), then hold the talk button and say
   something: it shows what it heard. If that fails on the graphics card, use
   the CPU button it offers; it then recommends the small model.
4. Press "Install the addon into the game" (in the Game step), then fully
   restart the game: a reload does not see new addons.
5. Save, then "Save and check everything".
6. Tick Start with Windows (or press Start now). The companion wakes when you
   start WoW and sleeps when you close it; its tray icon shows its state
   (green listening, amber paused, grey waiting for WoW, red if it kept
   stopping). Right-click it to pause listening, open setup, see the log or quit.
7. In game: /wc talkkey, then press your talk button once.

Graphics cards
--------------
The GPU build runs Whisper on Vulkan, which every NVIDIA card since the GTX 900
series supports with a current driver (AMD and Intel too). On an RTX 4090 it
measured as fast as CUDA. If speech is slow or fails on the card, the setup
window offers the CPU build. A CUDA build (GTX 10 to RTX 50) can be made on
request.

Updating
--------
Quit the companion first (its tray icon's Quit), so its files are free. Unzip
the new release over this folder, replacing files, then press "Install the
addon into the game" again. Your profile (player\profile.md), settings,
conversations and downloaded model are kept.

What this changes on your PC (and how to undo it)
--------------------------------------------------
The setup window lists all of it under "What this put on your PC, and
uninstall", and its Uninstall removes it (addons the agent installed for you
only if you tick the box). Close the game and quit the companion (its tray icon) first. In detail:
- This folder: everything here. Delete it to remove the programs.
- Your game's Interface\AddOns folder: WowCompanion, WowCompanion_Wheel, and
  512 small folders WowCompanion_S001 to WowCompanion_S512 (how messages reach
  the game; they show grouped in the addon list). Delete those folders to undo.
  Addons the agent installs for you are listed in
  %LOCALAPPDATA%\wow-companion\addons.json, with where each came from.
- %LOCALAPPDATA%\wow-companion: your settings, conversations, logs (companion.log,
  and crash.log if it ever stopped unexpectedly) and backups. Delete the folder
  to undo.
- Only if you tick Start with Windows: one entry in the registry,
  HKCU\Software\Microsoft\Windows\CurrentVersion\Run\WowCompanion, which
  starts the watcher at login. Untick it (or Uninstall) to remove it. No
  services.

The agent
---------
The agent is Claude Code running on your PC with every tool and no permission
prompts, so it can write addons, install them (after you say yes) and fix things
itself. That is powerful: it can change files on your PC. It never plays for you:
casting, targeting, moving, spending and sending are always your press.
Your preferences go in player\profile.md; the agent keeps it up to date.
