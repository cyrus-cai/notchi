<div align="center">

<img src=".github/icon.png" width="96" alt="Notchi" />

# Notchi

**Your notch, always ready.**

A beautifully simple way to **save a note**, **set a reminder**, or
**ask AI** — right from your Mac's notch.

[notch.website](https://www.notch.website) ·
[Release Notes](https://www.notch.website/releases)

Fully open source · Built in Liquid Glass

<!-- Demo video: open this file in GitHub's web editor and drag the .mp4 in
     here — GitHub hosts and embeds it automatically. -->

</div>

## You type. It sorts.

Type the thought the way it arrived — half-formed is fine. Notchi reads it and
routes it: a question to AI, a note to keep, or a reminder with a time.

- **Ask** — the answer streams into the panel; you never leave what you're
  doing.
- **Note** — anything that reads like something to keep (a name, an idea, a
  number) lands in Apple Notes.
- **Remind** — anything with a time in it lands in Apple Reminders, due date
  already set.

## Native, not bolted on.

Notchi is drawn in the same Liquid Glass material as the rest of macOS — same
blur, same edge light, same spring — so it feels like part of the system, not
something stuck on top.

## Your model. Your key.

Sorting happens on your Mac. Then your question goes to the provider you
picked, signed with your own key. Questions go straight to your provider —
nothing passes through our servers.

OpenAI · Anthropic · Google Gemini · DeepSeek · Qwen · Kimi · GLM · MiniMax · MiMo

## Install

Via Homebrew:

```bash
brew install --cask cyrus-cai/lofi-lab/notchi
```

Or with the one-line script:

```bash
curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notchi/master/install.sh | bash
```

Or hand it to your coding agent — paste this into **Claude Code / Codex**:

> Please install Notchi for macOS for me. Run this in my terminal:
> `brew install --cask cyrus-cai/lofi-lab/notchi`
> It is a free, open-source menu-bar app (https://github.com/cyrus-cai/notchi).
> After it finishes, confirm Notchi is installed in /Applications and launch it.

No account · No backend · Free & open source · Native to macOS

## Developers

Open `NotchGlass.xcodeproj` (Xcode 16+), or run `./scripts/reinstall.sh` for
the build → reinstall → relaunch loop. The model seam is `AIService.swift`;
the on-device Ask/Note router is `IntentEngine.swift`.
