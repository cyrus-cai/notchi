import AppKit
import SwiftUI

/// Release-notes source for the "What's New" panel. The notes ship *inside* the
/// app bundle — there's no network fetch — so the panel always has exactly the
/// notes that were built into this copy of Notch, online or off.
///
/// To publish notes for a new release, add an entry to `bundled` below (newest
/// versions can go anywhere in the list — they're sorted newest-first for you)
/// and ship the build. That's the single place to edit.
///
/// The "first launch after an update shows what changed once" behaviour is owned
/// here: `unseenVersion` compares the running build against the last version the
/// user actually saw the panel for, and `markSeen()` records the current one.
@MainActor
final class WhatsNewService: ObservableObject {
    static let shared = WhatsNewService()

    /// One published release. `version` is the only required field; `date` is an
    /// optional adornment. The notes are split into four sections the panel renders
    /// under their own headings — `features` (brand-new capabilities),
    /// `improvements` (refinements to things that already existed), `fixes` (what
    /// got fixed), and `others` (project/personal housekeeping such as support and
    /// license links). Any can be empty; an empty section is omitted entirely.
    struct Entry: Identifiable, Equatable {
        var version: String
        var date: String?
        var heroAssetName: String?
        var features: [String]
        var improvements: [String]
        var fixes: [String]
        var others: [String]
        var action: Action?
        /// Which `features` line the action's button hangs under (0-based). `nil`
        /// puts it at the end of the release's notes.
        var actionAfter: Int?

        var id: String { version }

        /// The one thing a release wants the reader to be able to DO, offered as a
        /// button under its notes — a switch announced in a bullet is otherwise a
        /// scavenger hunt through Settings.
        ///
        /// A closed enum, not a closure: `Entry` is `Equatable` (the panel animates
        /// on it) and closures aren't. The view owns where each case goes.
        enum Action: String, Equatable {
            /// Settings → Appearance, where Force click pressure lives.
            case forceClickPressure

            var title: String {
                switch self {
                case .forceClickPressure: L("whatsnew.action.forceClick")
                }
            }
        }

        init(
            version: String,
            date: String? = nil,
            heroAssetName: String? = nil,
            features: [String] = [],
            improvements: [String] = [],
            fixes: [String] = [],
            others: [String] = [],
            action: Action? = nil,
            actionAfter: Int? = nil
        ) {
            self.version = version; self.date = date
            self.heroAssetName = heroAssetName
            self.features = features; self.improvements = improvements
            self.fixes = fixes; self.others = others
            self.action = action; self.actionAfter = actionAfter
        }
    }

    /// The release notes to render — newest first. Bundled, so always populated.
    @Published private(set) var entries: [Entry]

    /// The version (e.g. "1.0.5") to announce in the idle input cue, or `nil` once
    /// the user has seen the notes for this build. Resolved once at launch (a pure
    /// `@Published` the view can read on every render) and cleared by `markSeen()`.
    @Published private(set) var unseenVersion: String?

    // MARK: - Source

    /// The release notes, written straight into the app. **Edit here each release.**
    ///
    /// Each release has three sections — `features` (brand-new capabilities),
    /// `improvements` (refinements to existing behaviour), and `fixes` (what got
    /// fixed). Write for the user, not the code: say what changed for *them* and
    /// why it's nice, in plain language. Skip internal/refactor churn they'd never
    /// notice. Leave a section empty (omit it) if there's nothing for it.
    /// English-only by design. Order doesn't matter — `sorted` puts the newest
    /// version first. Each string is one bullet; no leading `•`.
    private static let bundled: [Entry] = [
        Entry(
            version: "0.7.3",
            date: "2026-08-29",
            improvements: [
                "The update chip stays in place while an update runs and fills with the download's progress.",
                "The panel holds open until the update finishes, then closes before Notchi relaunches.",
                "A failed update can be retried from the chip itself.",
            ]
        ),
        Entry(
            version: "0.7.2",
            date: "2026-08-28",
            heroAssetName: "WhatsNew072Promo",
            features: [
                "Hover over any model to compare its speed, intelligence, cost efficiency, context window, and capabilities.",
            ],
            improvements: [
                "Models that cannot read images now continue with the text instead of failing the whole reply.",
                "Prompt Shortcut cards use richer colored glass and a clearer visual hierarchy.",
            ]
        ),
        Entry(
            version: "0.7.1",
            date: "2026-08-26",
            features: [
                "A new hover sensitivity level that opens only on click.",
                "Follow-ups accept pasted images.",
                "In Agent, \u{2318}\u{21A9} starts the task and opens its detail page.",
            ],
            improvements: [
                "Selected text appears as a quote below your instruction.",
                "A Prompt Shortcut always runs on the model it shows.",
                "Ask replies run as long as the question needs.",
                "Detached windows scroll to the newest reply.",
            ],
            fixes: [
                "A single ~ no longer swallows the rest of the line.",
                "The panel opens straight down instead of drifting sideways.",
                "An unfocused Notchi window responds to the first click.",
                "The Force Click card no longer leaves a gap when history is open.",
            ]
        ),
        Entry(
            version: "0.7.0",
            date: "2026-08-25",
            features: [
                "Force click selected text in any app to open a composer beside the pointer and use your Prompt Shortcuts.",
                "Force Touch keeps its own history, so you can reopen an earlier answer inside the same card.",
                "Agent’s / menu now lists enabled Codex skills and inserts their $name invocation.",
            ],
            improvements: [
                "Edit a Prompt Shortcut’s prompt, chord, model, and Force Touch visibility in one card.",
                "Prompt Shortcuts now open beside the pointer, keep one width from prompt to answer, and remain draggable.",
                "Selected-text capture now works across more browser, Electron, and PDF surfaces while preserving your clipboard.",
                "Appearance is grouped into Style, Behavior, and Displays, while Dock and menu-bar presence live in General.",
                "Model settings can refresh model lists on demand and distinguish matching names across backends.",
            ],
            fixes: [
                "Closing a Force Touch card no longer interrupts generation, and the completed answer still appears in history.",
            ],
            action: .forceClickPressure,
            actionAfter: 0
        ),
        Entry(
            version: "0.6.3",
            date: "2026-08-19",
            heroAssetName: "WhatsNew063Promo",
            features: [
                "Note and Remind are one Capture mode: name a time and it files a reminder, otherwise a note. Capture stays pinned until you switch.",
                "Several images in an answer stack into a fan you can expand, then open any card in a lightbox.",
                "Ask can save a note or set a reminder for you; confirm on the card first.",
                "A bare image URL in an answer shows as the image itself.",
            ],
            improvements: [
                "Command Code is retired; the same models stay reachable through pi.",
                "Appearance settings group placement and behavior more clearly.",
                "Recent no longer folds away the moment you start typing.",
                "An empty detached composer closes itself when you leave it.",
                "CJK input candidates stay visible above the island while composing.",
            ],
            others: [
                "About credits the Interaction Kit image gallery and its license.",
            ]
        ),
        Entry(
            version: "0.6.2",
            date: "2026-08-18",
            features: [
                "Agent now supports pi, with every provider and model you've signed into through pi.",
                "Type a colon or quotation mark at the start of a prompt to enter Note mode.",
            ],
            improvements: [
                "Agent tasks show thinking, plans, file diffs, and tool output in a clearer work trail.",
                "Queue follow-ups while an Agent is running, or press Command-Return to interrupt the current round and send immediately.",
                "What's New adds version navigation for browsing earlier updates.",
            ],
            fixes: [
                "Instructions sent by interrupt no longer appear twice in Agent task history.",
            ]
        ),
        Entry(
            version: "0.6.1",
            date: "2026-08-16",
            features: [
                "A prompt shortcut can pin its own provider and model, separate from the notch's default.",
            ],
            improvements: [
                "The thinking-strength slider is hidden for models with no adjustable reasoning effort.",
                "The app bundle is about 2.5 MB smaller.",
            ],
            fixes: [
                "Command Code agent runs no longer fail with an unsupported reasoning-effort error.",
            ]
        ),
        Entry(
            version: "0.6.0",
            date: "2026-08-15",
            heroAssetName: "WhatsNew060Promo",
            features: [
                "Stats summarizes chat and Agent messages, captures, token usage, active days, and streaks on this Mac.",
                "The activity calendar shows daily usage intensity and pages back through earlier history.",
            ],
            improvements: [
                "The Agent model picker puts recently used models first for the selected engine.",
                "Settings are reorganized into clearer Model, Capture, Appearance, and Stats sections.",
                "Command Code sign-in and its model catalog are ready immediately after relaunching.",
            ],
            fixes: [
                "Agent tasks reliably run CLIs installed through nvm, fnm, Volta, and other version managers.",
                "Update checks no longer stay busy for long when GitHub or a proxy is unreachable.",
            ]
        ),
        Entry(
            version: "0.5.8",
            date: "2026-08-13",
            features: [
                "Opening Notchi brings in selected text, with controls to drop it or turn the feature off.",
            ],
            improvements: [
                "The Agent model picker lays out models, thinking effort, and engines more clearly.",
                "Long conversations and Agent records open more smoothly.",
                "The copy button stays visible while scrolling through long code blocks.",
                "Prompt shortcut and detached session windows use tighter, more consistent spacing.",
            ],
            fixes: [
                "Agent engine and model choices no longer reset while CLI detection finishes after a relaunch.",
                "Multi-line follow-ups no longer clip against the input field's rounded corners.",
            ]
        ),
        Entry(
            version: "0.5.7",
            date: "2026-08-12",
            heroAssetName: "WhatsNew057Promo",
            features: [
                "Run prompt shortcuts in a compact window beside the pointer, or keep them in the notch.",
                "Global prompt shortcuts can use double-tap Command or Option.",
            ],
            improvements: [
                "Chat and Agent now keep separate Recent lists.",
                "Agent history can be cleared without removing other history.",
                "Plain URLs in answers are now clickable.",
            ],
            fixes: [
                "Codex tasks resume correctly with the current CLI argument format.",
                "Floating menus no longer linger after scrolling Recent or switching between Chat and Agent.",
            ]
        ),
        Entry(
            version: "0.5.6",
            date: "2026-08-10",
            features: [
                "The summon shortcut can now be set to double-tap Command, with quick presets for Command and Option.",
            ],
            improvements: [
                "Settings menus show a checkmark beside the current selection.",
                "Reduce Motion now covers loading dots, agent status, and About controls.",
                "Header and idle controls gain tooltips and clearer VoiceOver labels.",
                "About links now respond visibly on hover.",
            ],
            fixes: [
                "Hovering Permissions or Advanced no longer highlights both sections.",
                "Checking for updates no longer shifts the About layout.",
            ]
        ),
        Entry(
            version: "0.5.5",
            date: "2026-08-09",
            features: [
                "Prompt shortcuts are AI-named and appear as modes in the `/` menu, ready to run on typed input.",
            ],
            improvements: [
                "Slash, model, folder, and agent option menus share a compact floating glass design.",
                "The input box expands smoothly across multiple lines.",
            ],
            fixes: [
                "Wrapping text no longer jumps or clips the first line.",
            ],
            others: [
                "About credits the thinking-orbs loading animation and its license.",
            ]
        ),
        Entry(
            version: "0.5.4",
            date: "2026-08-07",
            features: [
                "Ask and Agent open the page you ask for, in your default browser.",
            ],
            others: [
                "About gains a Buy Me a Coffee button.",
            ]
        ),
        Entry(
            version: "0.5.3",
            date: "2026-08-06",
            features: [
                "Ask's confirmation cards are now Liquid Glass dialogs: each change reads as a full sentence — \"Dock icon will change to Hidden\" — in every language Notchi speaks.",
            ],
            fixes: [
                "The first hover after a relaunch no longer freezes the notch: CLI availability is probed in the background, and the panel catches up the moment it lands.",
            ]
        ),
        Entry(
            version: "0.5.2",
            date: "2026-08-06",
            fixes: [
                "The Prompt action add button is no longer clipped at the top of the Shortcuts pane.",
            ]
        ),
        Entry(
            version: "0.5.1",
            date: "2026-08-06",
            features: [
                "Command Code joins the engines — one account, one sign-in, and about fifty models from a dozen labs to pick from.",
                "CLIs installed by nvm, fnm, volta or another version manager are now found and run correctly.",
            ],
            improvements: [
                "The agent picker's engine control is a dropdown that names each engine, and the card grows to fit it.",
                "Settings keeps one steady height and scrolls inside the panel, with a soft fade at the top edge.",
                "A history entry that settled twice now collapses to one row.",
            ],
            fixes: [
                "A resumed agent run no longer leaves a blank row in Recent.",
            ]
        ),
        Entry(
            version: "0.5.0",
            date: "2026-08-05",
            features: [
                "Shortcuts is its own Settings section — rebind the summon chord and every panel action.",
                "Prompt shortcuts: bind a chord to a prompt and run it on selected text in any app.",
                "Ask can change Notch's own settings; every change is confirmed on a card first.",
                "AnySearch joins the search backends — works without a key, add one for higher limits.",
                "French and Spanish interfaces.",
                "General shows live system permission status and lets you grant missing access.",
            ],
            improvements: [
                "Ask shows images only after you paste them, with multi-image attachments and per-image removal.",
                "What's New links out to the full release archive.",
            ],
            fixes: [
                "Accessibility permission survives updates — builds now carry a stable signing identity.",
            ],
            others: [
                "About links to GitHub, X, and the licenses.",
            ]
        ),
        Entry(
            version: "0.4.4",
            date: "2026-08-02",
            improvements: [
                "Hover sensitivity now has Low, Balanced, and Instant levels.",
                "Available updates appear as an Update to X button in Recent and the home row.",
            ]
        ),
        Entry(
            version: "0.4.3",
            date: "2026-08-01",
            features: [
                "Sensitivity in Settings → General sets how easily hover opens the notch.",
            ],
            fixes: [
                "Moving the mouse across the notch no longer opens it.",
            ]
        ),
        Entry(
            version: "0.4.2",
            date: "2026-08-01",
            improvements: [
                "About's outbound links are one line — GitHub, X, Privacy, Feedback.",
                "Appearance sits above General in Settings.",
                "The What's New cue is a glass chip beside Recent.",
            ],
            fixes: [
                "The sources popover shows all four rows instead of three between blank bands.",
            ]
        ),
        Entry(
            version: "0.4.1",
            date: "2026-08-01",
            improvements: [
                "Choosing a model is a menu now — one level per provider, listing chat models only, one row each, newest first.",
            ]
        ),
        Entry(
            version: "0.4.0",
            date: "2026-07-31",
            features: [
                "First launch plays a short intro instead of the three-step setup guide. About can replay it.",
            ],
            improvements: [
                "Notchi is 4.9 MB on disk, down from 14.6.",
                "With nothing set up, Ask reads “Choose model…” and lists any signed-in CLI.",
                "Settings rows and picker cards highlight on hover.",
                "The detached window's close button matches the header's other controls.",
                "Clearing history starts animating as soon as you confirm.",
            ],
            fixes: [
                "The newest OpenAI models no longer fail outright — Notchi stopped sending a temperature they reject.",
                "Tools work on gpt-5.6.",
                "A failed answer's “Try again” no longer appears in other conversations.",
                "Long tooltips wrap instead of running off the panel.",
            ]
        ),
        Entry(
            version: "0.3.4",
            date: "2026-07-29",
            improvements: [
                "Lists now dissolve at their top edge the way they already did at the bottom — Recent, the model picker, Shortcuts, the archive, and these notes.",
            ],
            fixes: [
                "Recent no longer opens with its first rows resting under the prompt.",
                "The app icon in About no longer carries a white rim on its corners.",
            ]
        ),
        Entry(
            version: "0.3.3",
            date: "2026-07-28",
            improvements: [
                "The keyboard reference moved to About → Shortcuts, and the About links read as grouped rows.",
            ],
            fixes: [
                "Answers no longer come back empty. Three things caused it: a search that kept rewording itself until no room was left to answer, a tool call the model wrote as plain text so nothing ran, and a length cap that cut reasoning models off before they spoke. Search now steps aside after three rounds, a call written as text still runs, the cap is gone — and a round that still ends silent is retried once, then kept in Recent marked Failed instead of vanishing with your question.",
                "Tooltips no longer flash off-centre or get clipped on the left-most icon.",
                "The thinking orb sits level with the word beside it on Chinese lines.",
            ]
        ),
        Entry(
            version: "0.3.2",
            date: "2026-07-27",
            fixes: [
                "The Clear History confirmation no longer shows up in the resting notch on other displays.",
            ]
        ),
        Entry(
            version: "0.3.1",
            date: "2026-07-27",
            features: [
                "A Shortcuts pane in Settings lists every chord the app answers to.",
            ],
            improvements: [
                "Where Enter sends the line now reads on the Ask pill instead of trailing the caret.",
                "Clear History can wipe just the last 24 hours.",
                "Claude Code names the concrete model — \"Opus 5\", not \"Opus\"; the \"Default\" row is gone.",
                "The model menu ends in \"More models…\", into the full catalog.",
                "Model detail drops the Speed / Intelligence bars.",
                "Agent notifications name the task, or why it failed.",
                "Tear-off strips show a grab cursor.",
            ],
            fixes: [
                "Tab while composing an agent task no longer tears the compose down.",
            ]
        ),
        Entry(
            version: "0.3.0",
            date: "2026-07-26",
            features: [
                "Point Notch at your own OpenAI-compatible endpoint — Ollama, LM Studio, vLLM, a gateway, or a vendor not listed. The key is optional.",
                "Ask about your own record: the assistant can search the questions, notes, reminders and agent tasks you've kept here.",
            ]
        ),
        Entry(
            version: "0.2.6",
            date: "2026-07-26",
            features: [
                "Drag the input row out of the notch to get a standalone composer window.",
                "Sending an Ask from that composer turns the window into the conversation.",
            ],
            improvements: [
                "Settings picks the provider first, then that provider's models.",
            ]
        ),
        Entry(
            version: "0.2.5",
            date: "2026-07-25",
            features: [
                "Type / on an empty prompt to pick where the line goes — Ask, Note, Remind, Agent.",
                "Tab now arms a destination before you type; the placeholder says which one.",
            ],
            improvements: [
                "Hover tooltips are built in the island's own glass.",
                "The search line no longer trails off in dots.",
            ],
            fixes: [
                "Tooltips no longer get clipped at the island's edge or nudged off target.",
            ]
        ),
        Entry(
            version: "0.2.4",
            date: "2026-07-25",
            features: [
                "New menu bar icon — open Notch, start a chat, switch model, reach History and Settings. Toggle it in Settings → General.",
            ],
            improvements: [
                "The progress line now names what it's searching for.",
                "The thinking orb changes when a search digs deeper.",
                "Claude Code models show their real name instead of the CLI alias, and follow the CLI when it updates.",
                "Torn-off sessions carry the panel's own composer, and fade softly at the bottom.",
                "Settings actions and the first-run buttons answer a hover; one tooltip style everywhere.",
                "Proxy moved into a folded Advanced block in General.",
            ],
            fixes: [
                "The status line and answer footer no longer crowd the answer.",
                "The placeholder no longer lingers after a ⇧⏎ line break.",
            ]
        ),
        Entry(
            version: "0.2.3",
            date: "2026-07-24",
            features: [
                "Notch now speaks Japanese and Korean — pick 日本語 or 한국어 in Settings, or let it follow your Mac.",
            ],
            improvements: [
                "Ask ⇄ Agent now flips in one continuous move: the word wipes open beside its mark as the well slides across.",
            ]
        ),
        Entry(
            version: "0.2.2",
            date: "2026-07-23",
            features: [
                "New Grok engine — pick Grok CLI for chat or Agent tasks, signed in with your own xAI account (grok login, or XAI_API_KEY).",
            ],
            improvements: [
                "A dotted thinking orb now sits by the status word — a globe while it searches, orbits while a tool runs.",
                "Progress shows the instant the model reaches for a tool, not after its arguments finish streaming.",
                "A search running under a spoken preface keeps its progress line instead of stalling mid-answer.",
            ],
            fixes: [
                "Agent model picker no longer overflows its edges or clips to a single row when you switch engines.",
            ]
        ),
        Entry(
            version: "0.2.1",
            date: "2026-07-21",
            features: [
                "Answers now render LaTeX math as clean symbols (x², α, √) and preview linked images and PDFs inline — tap to open.",
            ],
            improvements: [
                "Follow up on an agent task straight from the notch panel — earlier rounds stay on screen.",
                "Back out of an agent's detail page with ← or the new back button.",
                "Model names show capitalized across the pickers.",
                "Lighter, lit Liquid Glass look for the model and Ask pickers.",
                "Softer top/bottom fade on more scrolling lists.",
            ],
            fixes: [
                "An agent's final answer no longer prints twice in its work trail.",
                "A running agent task no longer shows twice in Recent.",
            ]
        ),
        Entry(
            version: "0.2.0",
            date: "2026-07-19",
            features: [
                "New Agent mode — point Notch at a project folder, describe a task, and it runs autonomously in the background, powered by your own Codex or Claude CLI.",
                "Agent tasks take image attachments, survive a restart with one-tap Resume, notify you when done, and join Recent & History.",
                "Detach any conversation or agent run into a floating window; drag it back over the notch to merge.",
                "The closed notch shows the live step and elapsed time while work runs — toggle in Settings → Appearance.",
                "Proxy support, manual or auto-detected, applied to Notch and the CLIs it spawns — Settings → General.",
            ],
            improvements: [
                "Settings reorganized — a new Appearance tab; General now holds shortcut, language, launch-at-login, and proxy.",
                "⌘⇧I opens a quick picker for the agent's model and reasoning effort.",
                "Correct vendor logos for more model families (Gemma, Qwen QwQ, Yi, Hunyuan, Doubao, Ernie, and more), plus Codex's real mark.",
                "A model picked in Settings now sticks in the Ask quick menu.",
                "Agent mode remembers your last project folder and stays selected after relaunch.",
                "Feedback link added to Settings → About.",
            ],
            fixes: [
                "Fixed a case where two copies of Notch could run at once.",
            ]
        ),
        Entry(
            version: "0.1.16",
            date: "2026-07-12",
            features: [
                "Hide the virtual notch on external displays while an app is full-screen — new toggle in Settings → General.",
            ],
            improvements: [
                "Streaming answers reveal at a smooth, even pace instead of in bursts.",
                "Newly streamed text fades in as it appears.",
                "The wait line shimmers while working, with elapsed time on longer waits.",
            ]
        ),
        Entry(
            version: "0.1.15",
            date: "2026-07-11",
            features: [
                "New Codex model — keyless: uses your ChatGPT sign-in, billed to your ChatGPT plan (needs the Codex CLI).",
                "Notes can save to plain Markdown files in a folder you choose, instead of Apple Notes.",
            ]
        ),
        Entry(
            version: "0.1.14",
            date: "2026-07-10",
            features: [
                "Provider filter in the model picker, with configured providers listed first.",
            ],
            improvements: [
                "Direct answers for stable questions; time-sensitive ones still search the web first.",
                "Free OpenRouter models fail over to an alternate model when one is unavailable.",
                "Model capabilities are shown as tags, and Show all models stays pinned while the list is expanded.",
                "Faster rendering for streaming answers and the Recent list.",
                "Large history archives no longer delay launch or saving.",
                "Model lists are cached for an hour, avoiding a refetch each time Settings opens.",
                "Larger click targets for the idle prompt's trailing icons.",
            ],
            fixes: [
                "Notch controls no longer lose contrast in Light Mode.",
            ]
        ),
        Entry(
            version: "0.1.13",
            date: "2026-07-09",
            features: [
                "One searchable model picker across every provider — speed, context, and capabilities at a glance.",
                "Vercel AI Gateway added as a provider.",
                "A History window holds the full archive — search it, filter by Ask, Notes, or Reminders.",
                "Copy an image and it previews above the prompt.",
                "Pin from the idle prompt — ⌘P no longer needs an answer on screen.",
            ],
            improvements: [
                "Copied text previews above the prompt again.",
                "Provider and API key fold into a collapsed section; picking a model without a key jumps to its setup.",
                "Clear and See all history moved to the end of Recent, out of the ⋯ menu.",
                "Long answers stream more smoothly.",
            ],
            fixes: [
                "Stop freezes exactly the text on screen — a late chunk can no longer overwrite it.",
                "Items past the newest 50 move to History instead of being dropped.",
            ]
        ),
        Entry(
            version: "0.1.12",
            date: "2026-07-07",
            features: [
                "Ask can now read a web page, not just search — it opens a result to dig deeper.",
                "Shows which model actually answered when using OpenRouter's free auto-router.",
                "Free OpenRouter models are ranked by popularity — top picks up front, the rest in a submenu.",
                "Copy an answer as plain text or as Markdown — both from the footer.",
            ],
            improvements: [
                "Cut-off answers now say so instead of trailing off silently.",
                "Very long conversations no longer hit a hard context error — oldest turns trim first.",
                "Settings hints tuck behind a small ⓘ, and tooltips match the app's dark glass look.",
                "Recent captures: tap the row safely; jumping out to Notes or Reminders is its own button now.",
            ],
            fixes: [
                "Removed \"Save to Notes\" (and ⌘S) from answers.",
                "Removed the \"light model for quick tasks\" setting — everything uses your main model now.",
            ]
        ),
        Entry(
            version: "0.1.11",
            date: "2026-07-07",
            features: [
                "Notch is now Notchi — new name, same app.",
            ],
            improvements: [
                "Long questions collapse to a short preview — Show more expands, and very long text scrolls inside the bubble.",
                "Custom instructions now live in Settings → AI.",
                "The copy-sensing setting shows a small diagram of the ⌘C gesture.",
                "About panel regrouped: version and update check beside the name, links under Updates and More.",
                "Tighter hint copy across Settings.",
            ],
            fixes: [
                "Pasting a very long question no longer freezes the panel.",
            ]
        ),
        Entry(
            version: "0.1.10",
            date: "2026-07-05",
            features: [
                "Copy something that reads as a note or reminder, and the closed notch quietly offers to save it — press ⌘C again to file it.",
                "Filter Recent to just Notes, Reminders, or Ask from the menu.",
            ],
            improvements: [
                "Keyboard shortcuts for a finished answer: ⌘C copy, ⌘S save to Notes, ⌘R regenerate.",
                "Translate, summarize, and titles can now route to a lighter, faster model — configurable in Settings.",
                "Check for updates on demand from Settings → About.",
                "Smoother placeholder text and recent-list animations.",
            ]
        ),
        Entry(
            version: "0.1.9",
            date: "2026-07-04",
            features: [
                "Copy a screenshot and ask about it directly — vision-capable models can now see the image.",
                "Save an answer straight to Apple Notes from the footer, right beside Copy.",
            ],
            improvements: [
                "Model shortlists and defaults now update automatically without an app update.",
                "Fixed an intermittent issue where the prompt field could briefly show system text-completion suggestions.",
                "Multi-turn follow-ups are more robust against malformed context.",
            ]
        ),
        Entry(
            version: "0.1.8",
            date: "2026-07-04",
            features: [
                "Pin an answer to keep it open when your cursor leaves — click the pin, or press ⌘P.",
                "Copy answer and Regenerate buttons now sit in the answer's footer.",
            ],
            improvements: [
                "Reopening the notch returns you to the page you left, not a blank prompt.",
                "Typing in Settings no longer folds the panel when the pointer drifts off the island.",
            ]
        ),
        Entry(
            version: "0.1.7",
            date: "2026-07-03",
            features: [
                "The AI can ask a clarifying question — tap an option to answer.",
                "Launch at login, in Settings → General.",
            ],
            improvements: [
                "Hover the busy notch to get back to the streaming answer.",
                "Voice tools like Typeless can now type into the prompt.",
            ]
        ),
        Entry(
            version: "0.1.6",
            date: "2026-07-02",
            features: [
                "Math is now computed with an exact calculator, so answers to arithmetic, percentages, tips, and conversions are always right.",
                "Web search now supports Keenable as a backend — add your key in Settings → Search.",
                "Pick which engine powers web search with the new Search backend picker in Settings.",
                "Press ↑ / ↓ in the prompt to recall your previous questions, like a terminal.",
                "Search status now names the page it's reading (e.g. \"Reading tmtpost.com\").",
            ],
            improvements: [
                "Your half-typed question is now restored when you reopen the notch.",
                "⌘, opens Settings only when Notch is the active app.",
                "The AI stops re-searching and answers instead of looping on unanswerable queries.",
                "Translate chip shows just the destination language (e.g. \"→En\").",
                "Multi-line question bubbles use a cleaner rounded card.",
            ],
            fixes: [
                "Stray tool-call markup from MiniMax/DeepSeek/GLM/Kimi/Qwen no longer leaks into answers.",
            ]
        ),
        Entry(
            version: "0.1.5",
            date: "2026-06-29",
            features: [
                "Guided first-run setup, right in the notch.",
                "Get notified when an answer finishes after you walk away.",
                "Privacy link in Settings.",
            ],
            improvements: [
                "Copied text is now available to the model for any question.",
                "Answers no longer shift when streaming ends.",
                "Calmer \"thinking\" animation.",
                "Clipboard preview now leads with a quotation mark.",
            ],
            fixes: [
                "Transient network failures now retry before erroring.",
                "No more blank frame between rounds.",
                "Refocusing the prompt no longer selects all text.",
                "Stray tool-call markup is filtered out of answers.",
            ]
        ),
        Entry(
            version: "0.1.4",
            date: "2026-06-27",
            improvements: [
                "Recent's settings and Clear controls now sit in a fixed bar at the bottom-left.",
                "Faster to open a long history.",
            ]
        ),
        Entry(
            version: "0.1.3",
            date: "2026-06-27",
            features: [
                "Set your own Exa search key in Settings → Search to power web search for every model.",
                "Thinking dots now stay lit beside the notch even after the panel folds away mid-answer.",
            ],
            fixes: [
                "A question now shows in Recent right away with an \"Answering…\" marker.",
            ]
        ),
        Entry(
            version: "0.1.2",
            date: "2026-06-25",
            features: [
                "While thinking, Notch now drifts through evocative mood words — Gazing, Dreaming, Shimmering — that cross-fade one into the next, instead of bare dots.",
            ],
            fixes: [
                "Answers grow smoothly as they stream — no more per-line jump.",
                "Long answers no longer go pale mid-stream and re-brighten at the end.",
                "The screen no longer blanks for a beat while a web search runs.",
                "Your own question is now selectable — drag to highlight and copy it.",
            ]
        ),
        Entry(
            version: "0.1.1",
            date: "2026-06-24",
            fixes: [
                "In a conversation, every line you type is now a follow-up question — no more accidental Note/Remind routing mid-chat.",
                "Performance: opening the recent list is now snappier.",
            ]
        ),
        Entry(
            version: "0.1.0",
            date: "2026-06-23",
            features: [
                "Notch can now search the web to answer — live results, no extra setup.",
                "Answers grounded by a search show their sources beneath, each opening the original page.",
                "Providers without web search are tucked into a submenu, so the picker leads with the ones that can.",
            ],
            fixes: [
                "Switching models now takes effect immediately — no Save step.",
            ]
        ),
        Entry(
            version: "0.0.8",
            date: "2026-06-22",
            features: [
                "Translate now flips between your two preferred languages and shows the direction on the chip.",
                "A failed answer now shows what went wrong, with a one-tap Try Again or Open Settings.",
            ],
            fixes: [
                "Clipboard action chips no longer stop responding after backing out of a save.",
            ]
        ),
        Entry(
            version: "0.0.7",
            date: "2026-06-22",
            features: [
                "Double-tap ⌥ to summon Notch — the new default shortcut.",
                "Choose which clipboard quick-tools (Summarize, Translate, Proofread…) show up, in Settings → General.",
                "Closing now settles with a soft spring instead of snapping shut.",
            ],
            fixes: [
                "Long clipboard summaries and translations are no longer cut off mid-thought.",
                "Timed reminders no longer occasionally lose their time and never fire.",
            ]
        ),
        Entry(
            version: "0.0.6",
            date: "2026-06-19",
            features: [
                "Set a global shortcut to summon Notch (default ⌥Space) in Settings → General.",
                "Chinese relative dates now become reminders.",
                "Closing now fades the content out before the shell retracts.",
            ],
            fixes: [
                "Chinese/Japanese/Korean input candidates now show above the island while typing.",
                "Re-granting Reminders access after revoking it no longer needs a restart.",
                "A corrupted Recent entry no longer wipes the whole history.",
                "Interrupted answers are marked instead of cut off silently.",
            ]
        ),
        Entry(
            version: "0.0.5",
            date: "2026-06-19",
            features: [
                "Copied text now previews inside the prompt without collapsing Recent.",
                "Clipboard actions show one chip; the rest unfurl on hover.",
                "\"What's New\" is now a permanent link in Settings.",
            ],
            fixes: [
                "Saving to Apple Notes is more reliable, including non-English Notes folders.",
                "Recent rows no longer leave a text halo when scrolling behind the prompt.",
            ]
        ),
        Entry(
            version: "0.0.4",
            date: "2026-06-18",
            features: [
                "After an update, a quiet \"what's new\" hint shows up next to the prompt.",
                "Press ⌘↵ from the prompt to read what changed in each release, any time.",
            ]
        ),
        Entry(
            version: "0.0.3",
            date: "2026-06-10",
            features: [
                "Notch wakes up noticeably faster when you first hover.",
            ],
            fixes: [
                "Coming back from Settings now lands you right back in the prompt.",
            ]
        ),
    ]

    private let lastSeenVersionKey = "whatsnew_last_seen_version"

    /// Debug switch: when on, the cue and panel always appear and never record
    /// "seen", so What's New can be re-opened any number of times. Off by default.
    /// Flip it without a rebuild via either:
    ///   · `defaults write com.notchglass.app whatsnew_always_show -bool YES`
    ///   · launching with the `NOTCH_WHATSNEW_ALWAYS=1` environment variable
    /// (Set the default back to NO / unset the env var to restore normal once-per
    /// -version behaviour.)
    static let alwaysShowKey = "whatsnew_always_show"
    static var alwaysShow: Bool {
        if let env = ProcessInfo.processInfo.environment["NOTCH_WHATSNEW_ALWAYS"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: alwaysShowKey)
    }

    private init() {
        entries = Self.sorted(Self.bundled)
        unseenVersion = Self.resolveUnseenVersion(key: lastSeenVersionKey)
    }

    // MARK: - "Seen once per version"

    /// The running build, normalized to the same string `UpdaterService` compares.
    private var currentVersion: String { UpdaterService.currentVersion }

    /// Resolve, once at launch, whether the cue should announce this build — and
    /// record a baseline on a brand-new install so the very first launch stays
    /// quiet. A first-ever launch (no stored version) is treated as "seen": we
    /// don't pop What's New before the user has done anything. Only a genuine
    /// version *change* from a known baseline announces.
    private static func resolveUnseenVersion(key: String) -> String? {
        let current = UpdaterService.currentVersion
        // Debug switch wins: always announce, and never record a baseline.
        if alwaysShow { return current }
        guard let seen = UserDefaults.standard.string(forKey: key) else {
            UserDefaults.standard.set(current, forKey: key)
            return nil
        }
        return seen != current ? current : nil
    }

    /// Record that the user has now seen the notes for the running build, so the
    /// cue doesn't fire again until the next update. Clears `unseenVersion`, which
    /// dismisses the input-row cue.
    func markSeen() {
        // With the debug switch on, the cue is meant to persist — don't record a
        // baseline and don't clear the announce, so What's New keeps coming back.
        guard !Self.alwaysShow else { return }
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
        unseenVersion = nil
    }

    // MARK: - Ordering

    /// Newest version first, so the panel leads with the latest release.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { UpdaterService.isNewer($0.version, than: $1.version) }
    }
}
