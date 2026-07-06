<div align="center">

<img src=".github/icon.png" width="96" alt="Notchi" />

# Notchi

Ask AI, take a note, or set a reminder right from your Mac's notch —
without opening an app. **5× faster**, and **design-first**.

<!-- Demo video: open this file in GitHub's web editor and drag the .mp4 in
     here — GitHub hosts and embeds it automatically. -->

</div>

## You type. It sorts.

Type the thought the way it arrived — half-formed is fine. Notchi reads it and
routes it:

- **Ask** — a question goes to AI; the answer appears in the panel, without
  leaving what you're doing.
- **Note** — anything to keep (a name, an idea, a number) lands in Apple Notes.
- **Remind** — anything with a time in it lands in Apple Reminders, due date
  already set.

## Native, not bolted on

Notchi is drawn with the same Liquid Glass material as the rest of macOS — same
blur, same edge light, same spring — so it reads as part of the system, not
stuck on top of it.

## Your model. Your key.

Sorting happens on your Mac. Then your question goes to the provider you picked,
signed with your own key.

OpenAI · Anthropic · Google Gemini · DeepSeek · Qwen · Kimi · GLM · MiniMax · MiMo

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notchi/master/install.sh | bash
```

Or hand it to your coding agent — paste this into **Claude Code / Codex**:

> Please install Notchi for macOS for me. Run this in my terminal:
> `curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notchi/master/install.sh | bash`
> It is a free, open-source menu-bar app (https://github.com/cyrus-cai/notchi).
> After it finishes, confirm Notchi is installed in /Applications and launch it.

macOS only · free and open source · no account · no sign-up · no telemetry

## Developers

Open `NotchGlass.xcodeproj` (Xcode 16+), or run `./scripts/reinstall.sh` for
the build → reinstall → relaunch loop. The model seam is `AIService.swift`;
the on-device Ask/Note router is `IntentEngine.swift`.
