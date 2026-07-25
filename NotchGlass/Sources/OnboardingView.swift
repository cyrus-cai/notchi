import AppKit
import SwiftUI

/// The guided first-run flow, rendered inside the notch like `InlineSettingsView`
/// / `WhatsNewView` — same glass, same spring. Opens on the first panel-open of a
/// fresh install (see `OnboardingService` / `NotchModel.openOnboarding`).
///
/// Two columns: LEFT is the controls (per-step copy + Back/Next), RIGHT is a square
/// demo pane (placeholder today, a per-step video later — swap `demoPane(for:)`).
/// Three steps: what Notch does → connect a model → try it. No Skip, but never a
/// trap: the connect step isn't a gate (Note/Remind work keyless), and the last
/// step's single button sends a real first question (no plain "Done" exit).
struct OnboardingView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var orAuth = OpenRouterAuth.shared

    /// Which step is on screen (0…2).
    @State private var step = 0

    /// The "paste a key" screen is a sub-step of the connect step that takes over the
    /// left column in place of the two connect cards — NOT a route out to Settings.
    /// (Routing to Settings used to close the guide for good, stranding the user with
    /// no way back to the last step.) Saving a key advances to "Try it"; Back returns
    /// to the connect cards. The demo pane stays on the connect scene throughout.
    @State private var pasting = false

    /// Paste-step fields. Default to whatever provider Settings has selected (so a
    /// returning user sees their pick), but never OpenRouter — that's the Connect
    /// card's job, so the paste field starts on OpenAI when nothing else is chosen.
    @State private var pasteProvider: Provider = APIKeyStore.selectedProvider == .openrouter
        ? .openai : APIKeyStore.selectedProvider
    @State private var pasteKeyText: String = ""
    /// Set when Save is pressed on an empty/whitespace field — clears as the user types.
    @State private var pasteInvalid = false

    private let lastStep = 2

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            leftColumn
                .frame(width: 372, alignment: .leading)

            // The demo pane fills the column it sits beside — its height tracks the
            // controls rather than forcing a fixed square, so the panel is exactly as
            // tall as the step's copy needs (an empty placeholder no longer pads it
            // out). Width stays fixed; height follows the left column.
            demoPane(for: step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        // When the OpenRouter sign-in completes while the user is on the connect
        // step, hold on the green checkmark for a short beat so the success is
        // legible, then advance to "you're set" on its own — no Next to press.
        // (The manual-paste path lives in `pasteStep` and advances on Save; this
        // only handles the in-guide Connect path.)
        .onChange(of: orAuth.phase) { _, phase in
            if phase == .connected, step == 1, !pasting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    guard step == 1 else { return }
                    orAuth.acknowledge()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        step = lastStep
                    }
                }
            }
        }
    }

    // MARK: - Left column (controls)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if pasting {
                    pasteStep
                } else {
                    switch step {
                    case 0:  welcomeStep
                    case 1:  connectStep
                    default: tryItStep
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.22), value: step)
            .animation(.easeOut(duration: 0.22), value: pasting)

            Spacer(minLength: 18)
                .frame(height: 18)

            footer
        }
    }

    // MARK: - Step 1 · Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("onboarding.welcome.headline"))
                .font(.sf(22, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            Text(L("onboarding.welcome.sub"))
                .font(.sf(13.5))
                .lineSpacing(3)
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            modeLine(name: L("hint.ask"), desc: L("onboarding.welcome.ask"))
            modeLine(name: L("hint.note"), desc: L("onboarding.welcome.note"))
            modeLine(name: L("hint.remind"), desc: L("onboarding.welcome.remind"))
        }
    }

    /// One "Ask / Note / Remind" row: the mode name in a fixed gutter, its one-line
    /// description beside it. No icons — the names carry it, matching the app's
    /// restraint.
    private func modeLine(name: String, desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name)
                .font(.sf(14, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .frame(width: 56, alignment: .leading)
            Text(desc)
                .font(.sf(13))
                .lineSpacing(2)
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 13)
    }

    // MARK: - Step 2 · Connect a model

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("onboarding.connect.title"))
                .font(.sf(19, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .padding(.bottom, 8)

            Text(L("onboarding.connect.lead"))
                .font(.sf(13))
                .lineSpacing(3)
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            // Two equal-width tinted choices side by side: connect OpenRouter
            // (the blue primary path) or paste your own key (neutral glass). Both
            // collapse into a single progress / connected line while signing in.
            connectAction
                .padding(.bottom, 16)

            // The privacy note carries the quiet "Skip" inline at its end — built as
            // one wrapping paragraph so "Skip" trails the sentence like a footnote
            // aside, not a competing button. Only the underlined "Skip" is tappable:
            // it's a markdown link routed through `openURL` to `advance()`.
            privacyWithSkip
        }
    }

    /// The privacy footnote with a trailing, underlined "Skip" that flows on the
    /// same wrapping line. "Skip" is a markdown link (`notch://skip`); the
    /// `openURL` handler intercepts only that scheme and advances the step, so the
    /// rest of the note stays plain, non-tappable text.
    private var privacyWithSkip: some View {
        let privacy = L("onboarding.connect.privacy")
        let skip = L("onboarding.skip")
        let prefix = privacy.isEmpty ? "" : "\(privacy)   "
        let md = (try? AttributedString(
            markdown: "\(prefix)[\(skip)](notch://skip)")) ?? AttributedString(privacy)
        return Text(md)
            .font(.sf(11.5))
            .lineSpacing(2)
            .foregroundStyle(Tokens.text4)
            .tint(Tokens.text3)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "notch", url.host == "skip" {
                    advance()
                    return .handled
                }
                return .systemAction
            })
    }

    /// The connect row: two equal-width tinted cards (OpenRouter / paste key); a
    /// single progress line while a browser sign-in is in flight; or a brief green
    /// checkmark the moment the key lands before the step advances.
    @ViewBuilder
    private var connectAction: some View {
        switch orAuth.phase {
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.sf(15, weight: .semibold))
                    .foregroundStyle(Tokens.success)
                Text(L("onboarding.connect.connected"))
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text1)
                Spacer(minLength: 0)
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity)
        case .waiting, .exchanging:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(orAuth.phase == .exchanging
                     ? L("model.connecting")
                     : L("model.finishSignIn"))
                    .font(.sf(12.5))
                    .foregroundStyle(Tokens.text2)
                Spacer(minLength: 0)
                Button(L("model.cancel")) { orAuth.cancel() }
                    .buttonStyle(.plain)
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .frame(height: 40)
        default:
            HStack(spacing: 10) {
                TintedConnectButton(title: L("onboarding.connect.or.short"),
                                    subtitle: L("onboarding.connect.or.subtitle"),
                                    icon: "link",
                                    tint: Tokens.accent) {
                    orAuth.connect()
                }
                TintedConnectButton(title: L("onboarding.connect.byok.short"),
                                    subtitle: L("onboarding.connect.byok.subtitle"),
                                    icon: "key",
                                    tint: nil) {
                    pasteKey()
                }
            }
        }
    }

    // The two connect cards are `TintedConnectButton` (defined below) — they own a
    // hover state, so they live as their own `View` rather than a method here.

    // MARK: - Step 2b · Paste a key (in-guide)

    /// The bring-your-own-key screen, shown in place of the connect cards rather than
    /// in Settings — so pasting a key keeps the user inside the guide and lands them
    /// on "Try it" instead of dumping them out. A provider dropdown, a key field with
    /// a "Get a key" link, and (via the footer) Save & continue / Back.
    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("onboarding.paste.title"))
                .font(.sf(19, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .padding(.bottom, 8)

            Text(L("onboarding.paste.lead"))
                .font(.sf(13))
                .lineSpacing(3)
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            // Provider picker — a quiet glass dropdown, every backend except OpenRouter
            // (that one has its own one-click Connect card on the prior screen).
            providerPicker
                .padding(.bottom, 12)

            // The key field. A plain (not secure) field so a pasted key is visible to
            // confirm it landed — same choice Settings makes.
            keyField

            if pasteInvalid {
                Text(L("onboarding.paste.invalid"))
                    .font(.sf(11.5))
                    .foregroundStyle(Tokens.danger)
                    .padding(.top, 8)
                    .transition(.opacity)
            }

            // "Get a key" — opens the selected provider's API-keys page.
            Button {
                NSWorkspace.shared.open(pasteProvider.signupURL)
            } label: {
                HStack(spacing: 4) {
                    Text(L("onboarding.paste.get"))
                    Image(systemName: "arrow.up.right")
                        .font(.sf(9, weight: .semibold))
                }
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(Tokens.text3)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    /// The provider dropdown for the paste step — a glass pill that opens a menu of
    /// every backend that takes a pasted key (all but OpenRouter).
    private var providerPicker: some View {
        Menu {
            ForEach(Provider.allCases.filter { $0 != .openrouter }) { p in
                Button(p.displayName) { selectPasteProvider(p) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(pasteProvider.displayName)
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The key text field, styled to match the connect cards' glass.
    private var keyField: some View {
        TextField("", text: $pasteKeyText, prompt:
            Text(L("onboarding.paste.field", pasteProvider.displayName))
                .foregroundColor(Tokens.text4))
            .textFieldStyle(.plain)
            .font(.sf(13))
            .foregroundStyle(Tokens.text1)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder((pasteInvalid ? Tokens.danger : .white).opacity(pasteInvalid ? 0.5 : 0.14),
                                  lineWidth: 0.5)
            )
            .onChange(of: pasteKeyText) { pasteInvalid = false }
            .onSubmit { savePastedKey() }
    }

    // MARK: - Step 3 · Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("onboarding.try.title"))
                .font(.sf(19, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .padding(.bottom, 8)

            Text(L("onboarding.try.lead"))
                .font(.sf(13))
                .lineSpacing(3)
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            // The worked example, shown as the prompt the user is about to send —
            // quotes, sized like a real Ask. There's no separate "tap to fill" card
            // and no plain "Done": the single footer button on the last step IS this
            // question (see `footer`), so the only way out is to actually ask it.
            // First action = a real answer on screen.
            Text("“\(L("onboarding.try.example"))”")
                .font(.sf(17, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer (Back / dots / Next-or-Done)

    private var footer: some View {
        HStack(spacing: 12) {
            // Back. On the paste sub-step it returns to the connect cards (not a step
            // change); otherwise it walks the steps back. Hidden only on the very
            // first step, where there's nowhere to go back to.
            PanelBackButton {
                if pasting {
                    closePaste()
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        step = max(0, step - 1)
                    }
                }
            }
            .opacity(backHidden ? 0 : 1)
            .allowsHitTesting(!backHidden)
            // On the first step the hidden Back button must not reserve space —
            // otherwise it shoves the dots right, off the headline's left edge.
            .frame(width: backHidden ? 0 : nil)
            .clipped()

            stepDots

            Spacer()

            // On the last step the single primary button IS the Ask — it sends the
            // example question (and closes the guide on the way), so finishing the
            // onboarding and asking the first real question are one and the same act.
            // The connect step has no forward button here at all — its "Skip" lives
            // quietly inline at the end of the privacy note. The welcome step keeps
            // the prominent "Next". The paste sub-step's forward button saves the key.
            if pasting {
                primaryButton(label: L("onboarding.paste.save"), wide: false) {
                    savePastedKey()
                }
            } else if step == lastStep {
                primaryButton(label: L("onboarding.try.ask"), icon: "arrow.up", wide: false) {
                    tryExample()
                }
            } else if step != 1 {
                primaryButton(label: L("onboarding.next"), wide: false) {
                    advance()
                }
            }
        }
    }

    /// Back hides only on the welcome step. On the paste sub-step (conceptually still
    /// step 1) Back is shown — it returns to the connect cards.
    private var backHidden: Bool { step == 0 && !pasting }

    private var stepDots: some View {
        HStack(spacing: 7) {
            ForEach(0...lastStep, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Tokens.text2 : Tokens.text4.opacity(0.5))
                    .frame(width: i == step ? 16 : 6, height: 6)
                    .animation(.spring(response: 0.34, dampingFraction: 0.8), value: step)
            }
        }
        // Step 0 collapses Back to width 0, but the HStack's 12pt spacing still
        // sits before the dots — pull them back so they line up with the headline.
        .padding(.leading, step == 0 ? -12 : 0)
    }

    // MARK: - Right column (demo pane)

    /// The right-hand demo pane — a native, per-step micro-demo drawn in SwiftUI
    /// (no video) that mirrors the step's copy. Step 2 (try it) animates a prompt →
    /// streamed answer loop so the user sees what an answer looks like before they
    /// ask. The `orAuth.phase` binding lets the connect scene light up live when
    /// sign-in lands.
    ///
    /// No outer card frame: each scene's own elements (the mode rows, the model
    /// card, the prompt/answer bubbles) already sit on glass, so wrapping them in a
    /// second rounded panel read as awkward card-in-card nesting. The scene floats
    /// directly on the panel glass instead.
    private func demoPane(for step: Int) -> some View {
        Group {
            switch step {
            case 0:  WelcomeDemo()
            case 1:  ConnectDemo(connected: orAuth.phase == .connected)
            default: TryItDemo()
            }
        }
        .padding(18)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.28), value: step)
    }

    // MARK: - Actions

    /// The ONE action-button style in the whole guide — used by both the connect
    /// step and the footer's Next/Done, so every forward action looks identical.
    /// `wide` fills the column (the connect CTA); compact hugs its label (the
    /// footer). One look, one meaning: "this moves you forward."
    private func primaryButton(label: String,
                               icon: String? = nil,
                               wide: Bool = true,
                               action: @escaping () -> Void) -> some View {
        PrimaryOnboardingButton(label: label, icon: icon, wide: wide, action: action)
    }

    private func advance() {
        if step == lastStep {
            finish()
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                step += 1
            }
        }
    }

    /// Bring-your-own-key: open the in-guide paste sub-step (not Settings). Routing
    /// to Settings used to `finish()` the guide, so after pasting there was no way
    /// back to the last step — the trap this fixes. Here the user stays in the flow.
    private func pasteKey() {
        pasteKeyText = APIKeyStore.stored(for: pasteProvider)
        pasteInvalid = false
        withAnimation(.easeOut(duration: 0.22)) { pasting = true }
    }

    /// Switch the paste step's provider, seeding the field from any key already
    /// stored for it so a returning user sees what's saved.
    private func selectPasteProvider(_ p: Provider) {
        pasteProvider = p
        pasteKeyText = APIKeyStore.stored(for: p)
        pasteInvalid = false
    }

    /// Save the pasted key for the chosen provider, make it the active backend, and
    /// advance to "Try it" — the whole point: pasting lands you on the last step
    /// inside the guide rather than dumping you into Settings. An empty field flags
    /// invalid instead of saving.
    private func savePastedKey() {
        let trimmed = pasteKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.easeOut(duration: 0.18)) { pasteInvalid = true }
            return
        }
        APIKeyStore.save(trimmed, for: pasteProvider)
        APIKeyStore.selectedProvider = pasteProvider
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            pasting = false
            step = lastStep
        }
    }

    /// Leave the paste sub-step and return to the connect cards (the Back affordance).
    private func closePaste() {
        withAnimation(.easeOut(duration: 0.22)) {
            pasting = false
            pasteInvalid = false
        }
    }

    /// Send the worked example as a real question — this is the only way off the
    /// last step, so finishing the guide and asking the first question are one act.
    /// Close the guide (returns the body to the prompt), set the text, and submit it
    /// so an answer streams in immediately rather than just pre-filling the field.
    private func tryExample() {
        finish()
        model.text = L("onboarding.try.example")
        model.submit()
    }

    /// Leave the guide and return to the prompt; records it done so it never leads
    /// again (see `NotchModel.closeOnboarding`).
    private func finish() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            model.closeOnboarding()
        }
    }
}

/// One of the two side-by-side connect cards (OpenRouter / paste a key). Two lines:
/// icon + title on top, a quieter subtitle below.
///
/// Both cards are identical neutral glass — same fill, border and white title — so
/// neither reads as "already selected." The only hover feedback is a faint fill/border
/// brighten plus the pointing-hand cursor; no colour bloom, no scaling. (The `tint`
/// argument is kept for call-site compatibility but no longer changes the look.)
/// The guide's forward action — the connect CTA and the footer's Next/Ask, one
/// look for "this moves you forward". Wears the shared *prominent* surface, and
/// (new) actually answers a hover and gives on press: it used to be the app's
/// most important button and the only one that did neither.
private struct PrimaryOnboardingButton: View {
    let label: String
    var icon: String? = nil
    var wide: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.sf(11, weight: .semibold))
                }
                Text(label)
                    .font(.sf(13, weight: .medium))
            }
            .foregroundStyle(Tokens.text1)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .frame(maxWidth: wide ? .infinity : nil)
            .prominentSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                              lit: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

private struct TintedConnectButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.sf(12, weight: .semibold))
                    Text(title)
                        .font(.sf(13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Tokens.text1)

                Text(subtitle)
                    .font(.sf(11))
                    .lineLimit(1)
                    .foregroundStyle(Tokens.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .recessedSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                             lit: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) { hovering = h }
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Demo scenes (right column)
//
// Three native micro-demos, one per step — drawn in SwiftUI rather than shipped as
// video so they cost nothing in bundle size, follow the glass theme, and need no
// localization (all the words live in the left column; these scenes show *shape*,
// not copy). Each frames its content in the demo card the parent already drew.

/// Step 1 · Welcome — a miniature of the three modes, each row fading in on a
/// stagger so the right side visibly echoes the "Ask / Note / Remind" lines on the
/// left. Static once settled; the entrance is the whole show.
private struct WelcomeDemo: View {
    @State private var shown = 0

    private let rows: [(String, Color)] = [
        ("text.bubble",        Tokens.accent),
        ("note.text",          Tokens.text2),
        ("bell",               Tokens.text2),
    ]
    private let labels = [L("hint.ask"), L("hint.note"), L("hint.remind")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<rows.count, id: \.self) { i in
                HStack(spacing: 11) {
                    Image(systemName: rows[i].0)
                        .font(.sf(14, weight: .medium))
                        .foregroundStyle(rows[i].1)
                        .frame(width: 22)
                    Text(labels[i])
                        .font(.sf(14, weight: .medium))
                        .foregroundStyle(Tokens.text1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(.white.opacity(0.05))
                )
                .opacity(i < shown ? 1 : 0)
                .offset(y: i < shown ? 0 : 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            for i in 0..<rows.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 + Double(i) * 0.16) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        shown = i + 1
                    }
                }
            }
        }
    }
}

/// Step 2 · Connect — two nodes (Notch ↔ the model) wired together, with a packet
/// of light shuttling back and forth along the link so the scene reads as *two
/// things actively talking*, not one static icon. The instant `connected` flips,
/// the link locks to green, the model node lights up, and a check seals it.
/// Bound to the real `orAuth.phase` by the parent, so the right side *is* the
/// thing the user just did.
private struct ConnectDemo: View {
    let connected: Bool

    private let wireWidth: CGFloat = 132
    private let nodeSize: CGFloat = 46
    // Three packets evenly phased, so the stream looks continuous rather than blinky.
    private let packetPhases: [Double] = [0, 0.34, 0.67]

    private var linkColor: Color { connected ? Tokens.success : Tokens.accent }

    var body: some View {
        // One clock drives everything — packets, glow, breathing — so the scene
        // shares a single continuous rhythm instead of several fighting timers.
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 0…1 sawtooth, ~1.6s period, for packets sliding left→right.
            let flow = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            // Slow 0…1…0 breathing for the endpoint halos.
            let breath = (sin(t * 1.7) + 1) / 2

            VStack(spacing: 16) {
                ZStack {
                    wire(flow: flow)
                    HStack {
                        node(icon: "macwindow", active: true, breath: breath)
                        Spacer(minLength: 0)
                        node(icon: connected ? "checkmark" : "cpu",
                             active: connected, breath: breath)
                    }
                    .frame(width: wireWidth + nodeSize)
                }
                .frame(height: nodeSize)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: connected)

                statusPill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: wire + travelling light

    private func wire(flow: Double) -> some View {
        ZStack(alignment: .leading) {
            // Base track.
            Capsule()
                .fill(.white.opacity(0.08))
                .frame(width: wireWidth, height: 2.5)

            if connected {
                // Solid, gently glowing link once connected.
                Capsule()
                    .fill(linkColor.opacity(0.9))
                    .frame(width: wireWidth, height: 2.5)
                    .shadow(color: linkColor.opacity(0.7), radius: 5)
            } else {
                // A faint always-lit channel, so the wire reads as "live".
                Capsule()
                    .fill(linkColor.opacity(0.22))
                    .frame(width: wireWidth, height: 2.5)
                // Several soft comet-like packets flowing along it.
                ForEach(packetPhases.indices, id: \.self) { i in
                    let p = (flow + packetPhases[i]).truncatingRemainder(dividingBy: 1)
                    // Ease packets in/out near the ends so they don't pop at the edges.
                    let fade = min(1, max(0, min(p, 1 - p) * 4))
                    packet(at: p, fade: fade)
                }
            }
        }
        .frame(width: wireWidth, height: nodeSize)
    }

    private func packet(at p: Double, fade: Double) -> some View {
        ZStack(alignment: .trailing) {
            // Soft comet tail, brightest just behind the head.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [linkColor.opacity(0), linkColor.opacity(0.55)],
                        startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: 24, height: 2.5)
            // The bright head with a soft bloom.
            Circle()
                .fill(linkColor)
                .frame(width: 6, height: 6)
                .shadow(color: linkColor.opacity(0.95), radius: 4)
                .offset(x: 3)
        }
        .opacity(fade)
        .offset(x: (wireWidth - 6) * p - 21)
    }

    // MARK: endpoints

    private func node(icon: String, active: Bool, breath: Double) -> some View {
        let tint = connected ? Tokens.success : (active ? Tokens.accent : Tokens.text3)
        // Halos breathe only while connecting; once connected they settle.
        let halo = connected ? 1.0 : (active ? 1 + breath * 0.16 : 1)
        let glow = connected ? 6.0 : (active ? 3 + breath * 6 : 0)
        return ZStack {
            // Outer breathing glow ring.
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: nodeSize, height: nodeSize)
                .scaleEffect(halo)
                .blur(radius: 2)
            Circle()
                .fill(tint.opacity(0.20))
                .frame(width: nodeSize, height: nodeSize)
            Circle()
                .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                .frame(width: nodeSize, height: nodeSize)
                .shadow(color: tint.opacity(0.6), radius: glow)
            Image(systemName: icon)
                .font(.sf(18, weight: .semibold))
                .foregroundStyle(active ? tint : Tokens.text3)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: connected)
    }

    // MARK: status pill

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Tokens.success : Tokens.accent)
                .frame(width: 7, height: 7)
            Text(connected ? L("onboarding.connect.connected") : L("onboarding.connect.connecting"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    (connected ? Tokens.success : .white).opacity(connected ? 0.4 : 0.14),
                    lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.3), value: connected)
    }
}

/// Step 3 · Try it — the persuasive frame: a prompt bubble, then a streamed answer
/// typed in character by character with a blinking caret, looping forever. Shows
/// the user what an answer *looks like* before they send their first one. Pure
/// timer-driven text reveal — no model call, no network; the demo "answer" is a
/// fixed line so it never depends on a connected key.
private struct TryItDemo: View {
    // A pool of self-contained demo Q&A pairs the scene rotates through, one per loop.
    // English-only on purpose: the scene shows the *motion* of an answer streaming in;
    // the real localized example lives on the left.
    private static let pairs: [(q: String, a: String)] = [
        ("How long does caffeine take to kick in?", "Usually 15–45 minutes, peaking around 30–60."),
        ("What's a synonym for \"meticulous\"?", "Thorough, precise, painstaking, or scrupulous."),
        ("How many tablespoons in a cup?", "16 tablespoons make one US cup."),
        ("Convert 72°F to Celsius.", "72°F is about 22.2°C."),
        ("What does \"ephemeral\" mean?", "Lasting a very short time; fleeting."),
        ("How do I center a div?", "Use a flex parent: display:flex; justify-content & align-items center."),
        ("What's the capital of Australia?", "Canberra — not Sydney, a common mix-up."),
        ("How long to boil an egg soft?", "About 6 minutes for a runny yolk, 9–10 for firm."),
        ("Tip on $48 at 18%?", "Around $8.64, for a total of $56.64."),
        ("What's the boiling point of water?", "100°C (212°F) at sea level."),
        ("Spell \"necessary\" for me.", "N-E-C-E-S-S-A-R-Y — one C, two S's."),
        ("How many ounces in a liter?", "About 33.8 fluid ounces in one liter."),
    ]

    @State private var index = 0       // which pair is currently playing
    @State private var typed = ""      // characters of the current answer revealed so far
    @State private var caretOn = true
    @State private var phase: Phase = .asking
    // Drives the crossfade between pairs: the old pair fades out, the text swaps
    // while invisible, then the new question fades in — no blank-pane gap.
    @State private var visible = false

    private var question: String { Self.pairs[index].q }
    private var answer: String { Self.pairs[index].a }

    private enum Phase { case asking, typing, holding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The question, as a right-aligned prompt echo.
            HStack {
                Spacer(minLength: 24)
                Text(question)
                    .font(.sf(12.5, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white.opacity(0.06))
                    )
            }
            .opacity(visible ? 1 : 0)

            // The streamed answer with a blinking caret while it types.
            HStack(alignment: .top, spacing: 0) {
                (Text(typed)
                    .font(.sf(14, weight: .regular))
                    .foregroundColor(Tokens.text1)
                 + Text(caretOn && phase != .holding ? "▌" : "")
                    .font(.sf(14))
                    .foregroundColor(Tokens.accent))
                    .lineSpacing(3)
                Spacer(minLength: 0)
            }
            .opacity(visible ? 1 : 0)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: visible)
        .onAppear { runLoop() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            caretOn.toggle()
        }
    }

    /// One pass of the loop for the *current* `index`: bring the question in, type
    /// the answer, hold, then hand off to `advance()` which crossfades to the next.
    /// `visible` is already false here (start, or after `advance`'s fade-out), so the
    /// empty pane swap happened off-screen — the question fades straight in.
    private func runLoop() {
        typed = ""
        phase = .asking
        // Beat 1: fade the (new) question in, then type its answer.
        visible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { phase = .typing }
            typeNext(at: 0)
        }
    }

    /// Fade the finished pair out, swap to the next pair *while invisible*, then run
    /// it. The fade-out and the next fade-in overlap into one continuous crossfade,
    /// so there's never a frame of blank pane between questions.
    private func advance() {
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            index = (index + 1) % Self.pairs.count
            runLoop()
        }
    }

    /// Reveal `answer` one character at a time on a short timer, then hold the full
    /// answer briefly before looping back to the start.
    private func typeNext(at i: Int) {
        guard phase == .typing else { return }
        if i >= answer.count {
            phase = .holding
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                advance()   // crossfade to the next Q&A
            }
            return
        }
        let idx = answer.index(answer.startIndex, offsetBy: i)
        typed.append(answer[idx])
        // Slightly irregular cadence reads more like real streaming than a metronome.
        let delay = answer[idx] == " " ? 0.045 : 0.028
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { typeNext(at: i + 1) }
    }
}
