[English](README.md) · [简体中文](README.zh-CN.md)

<div align="center">

<img src=".github/icon.png" width="96" alt="Notchi" />

# Notchi

**Your notch, always ready.**

**Ask**, **save a note**, **set a reminder**, or **hand a task to an AI agent** — all from your Mac's notch.

[notch.website](https://www.notch.website) ·
[Release Notes](https://www.notch.website/releases)

MIT · Apple Liquid Glass

</div>

Notchi is a free, open-source macOS app that turns the notch into a place to think and act. Whatever you type is automatically recognized as a chat, a note, a reminder, or a coding-agent task.

## Install

Via Homebrew:

```bash
brew install --cask cyrus-cai/lofi-lab/notchi
```

Installer script:

```bash
curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notchi/master/install.sh | bash
```

Or hand it to **Claude Code / Codex**:

> Please install Notchi for macOS for me. Run this in my terminal:
> `brew install --cask cyrus-cai/lofi-lab/notchi`
> It is a free, open-source menu-bar app (https://github.com/cyrus-cai/notchi).
> After it finishes, confirm Notchi is installed in /Applications and launch it.

- Notchi requires **macOS 14 (Sonoma) or later**.
- A hardware notch is optional.
- Notchi currently ships un-notarized. If you have a Developer account and would like to help, send your inquiry to [xiikii@outlook.com](mailto:xiikii@outlook.com?subject=An%20Apple%20Developer%20account%20for%20Notchi).

## Automatic intent detection

Notchi automatically figures out what you type:

- **Ask** — get an answer instantly
- **Note** — save to Apple Notes or a Markdown file
- **Remind** — turn it into an Apple Reminder
- **Agent** — hand a coding task and a project folder to Codex, Claude Code, Grok, and more

<img src=".github/shots/verb-ask.jpg" width="860" alt="Asking a question in the notch: the answer streams in below the prompt." />

| ![Added to Notes](.github/shots/verb-note-saved.jpg) | ![Added to Reminders](.github/shots/verb-remind-saved.jpg) |
| --- | --- |

## Built-in tools

Notchi supports:

- Web search (requires a corresponding API key)
- Opening web links
- Exact arithmetic
- Settings changes

| ![A web-searched answer with its source cited](.github/shots/power-search.jpg) | ![A question answered from what you copied](.github/shots/power-vision.jpg) |
| --- | --- |

<img src=".github/shots/power-math.jpg" width="860" alt="Exact arithmetic: a tip split three ways." />

## Agent

Notchi can drive your **Codex**, **Claude Code**, **Grok**, and other CLIs, with support for follow-up instructions and resuming after an interruption.

<img src=".github/shots/agent-compose.jpg" width="860" alt="Handing a task to the agent: project folder and engine shown under the prompt." />

<img src=".github/shots/agent-answer.jpg" width="860" alt="A finished run: the calls the agent made are listed above its answer, with a follow-up field below." />

## BYOK

- AI services:
  - Including but not limited to: OpenRouter, Vercel AI Gateway, OpenAI, Anthropic, Google Gemini, DeepSeek, Qwen, Kimi, GLM, MiniMax, MiMo, or your own OpenAI-compatible endpoint
  - You can also use a locally installed, signed-in Codex, Claude Code, Grok, or PI CLI
- Web search
  - Including but not limited to: Exa, Keenable, or AnySearch

## Design

Notchi is drawn in macOS Liquid Glass — including the edge glow and physical motion of native macOS 26.

## Privacy

- No account or sign-in is required.
- Prompts, chats, notes, reminders, agent sessions, clipboard, and history stay on your Mac, or go directly to the AI provider you configured. Notchi does not relay any request content.

## Questions

**Does Notchi work on a Mac without a notch?**

Yes. On Macs without a notch and on external displays, Notchi draws a virtual notch at the top of the display and behaves the same way.

**Do I need an account or an API key?**

Notchi itself has no account. For hosted AI, connect a provider with its API key or supported sign-in flow. Alternatively, use Codex, Claude Code, Grok, or PI through a locally installed CLI that is already signed in. Notes and reminders do not need a provider connection.

**Can I use local models?**

Yes. Add any OpenAI-compatible endpoint in Settings; this works for Ollama, LM Studio, vLLM, self-hosted gateways, and providers Notchi does not list. A key is optional for custom endpoints.

**Can I ask about screenshots or images?**

Yes, with a vision-capable Ask model.

**Can Notchi run Codex, Claude Code, Grok, or PI?**

Yes. Agent mode runs the official CLI you already installed and signed in to, inside the project folder you choose.

**Where does my data go?**

Notchi does not operate a user-data backend. AI prompts and deliberately added context go to the provider or CLI you selected; web-search requests go to the configured search service. Notes, reminders, local history, clipboard contents, and local files otherwise remain on your Mac.

**Why does Notchi ask for system permissions?**

Notchi needs permission for Notes automation, Reminders, and notifications. Settings → General shows the status of each authorization.

**How do I uninstall Notchi?**

Run `brew uninstall --cask cyrus-cai/lofi-lab/notchi`

## Developers

Open `NotchGlass.xcodeproj` (Xcode 16+), or run `./scripts/reinstall.sh`.

## License

Notchi is released under the [MIT License](LICENSE).
