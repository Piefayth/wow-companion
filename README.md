# WoW Companion

Makes World of Warcraft: Forever playable with a controller, through a
collection of small addons, including agentic integrations (only Claude today)
and streaming dictation.

## You need

* Windows (other platforms WIP)
* WoW: Forever, controller, microphone
* (For agentic features) [Claude Code](https://claude.com/claude-code)

## Install

Download the [latest release](https://github.com/Piefayth/wow-companion/releases/latest), unzip, run `wow-companion-setup.exe`.

## Settings

* Game: Automatically detects your WoW folder, may need to correct manually.
  Once detected, can install the addons through here
* Controller: Your controller selection and push to talk binding
* Microphone: Input audio device selection. (Note: Some device + OS + Bluetooth
  card combinations may not support bidirectional audio / will require
  separate input and output devices)
* Speech: Your transcription model
  * Whisper: More accurate, uses GPU, slower, doesn't begin until you stop talking
  * Streaming: Less accurate, uses CPU, faster, begins when you start talking
* Agent: Which Claude model answers, or Off for dictation only
* Start: Start now, or Start with Windows

## Controls

* Push to talk: the agent
* Push to talk + L1 / L2 / R1 / R2: separate conversations
* Push to talk + L2+R2: quick agent (faster model, for chat and links)
* Push to talk + L1+R1: dictation, no agent. Into the focused text box, else
  the chat box on the channel picked with the right stick
* Tap push to talk: Companion window

## Uninstall

Settings window (wow-companion-setup.exe), Uninstall.

## Note

Agentic features run Claude Code with every tool and no permission prompts: it
can change files on your PC. Transcription is local.
