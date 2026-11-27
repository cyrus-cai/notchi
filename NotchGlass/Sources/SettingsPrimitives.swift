import AppKit
import SwiftUI

// MARK: - Settings Primitives (Notchi Capsule Language + shadcn Structure)

/// Shared sizing tokens for Settings controls, keeping Notchi's native
/// full-capsule (`Capsule`) form factor and borderless glass surfaces while
/// unifying button/badge/input/step structure across panes.
enum SettingsUI {
    /// Standard heights matching shadcn `sm` / `default`.
    static let heightSM: CGFloat = 28
    static let heightMD: CGFloat = 30

    /// Subtle focus border for text inputs — hairline, never a heavy box.
    static let focusBorder = Tokens.ink.opacity(0.20)
}

// MARK: - SettingsButton

/// Unified Settings button wearing Notchi's `Capsule` shape with consistent
/// shadcn semantic variants and sizes.
struct SettingsButton: View {
    enum Variant {
        /// Primary CTA on the glass (`prominentSurface` capsule).
        case primary
        /// Standard recessed action (`recessedSurface` capsule).
        case secondary
        /// Subtle hairline outline capsule (Cancel, Allow, About social).
        case outline
        /// Borderless at rest, faint capsule wash on hover (Test, Change, Retry).
        case ghost
        /// Low-saturation danger capsule (Forget, Delete, Clear all).
        case destructive
        /// Inline text link: clean at rest, underlined on hover.
        case link
    }

    enum Size {
        case sm
        case md
        case icon

        var height: CGFloat {
            switch self {
            case .sm, .icon: return SettingsUI.heightSM
            case .md:        return SettingsUI.heightMD
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .sm, .icon: return Tokens.TypeSize.meta
            case .md:        return Tokens.TypeSize.label
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .sm:   return 11
            case .md:   return 13
            case .icon: return 0
            }
        }
    }

    var title: String
    var variant: Variant = .secondary
    var size: Size = .sm
    var systemImage: String? = nil
    var external: Bool = false
    var loading: Bool = false
    var fullWidth: Bool = false
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, variant == .link ? 0 : size.horizontalPadding)
                .frame(width: size == .icon ? size.height : nil,
                       height: variant == .link ? nil : size.height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(backgroundView)
                .overlay(borderView)
                .contentShape(shape)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            } else if let systemImage {
                Image(icon: systemImage)
                    .font(.sf(size.fontSize, weight: .regular))
            }
            if !title.isEmpty {
                Text(title)
                    .font(.sf(size.fontSize, weight: .regular))
                    .underline(variant == .link && hovering)
                    .lineLimit(1)
            }
            if external {
                Image(icon: "arrow.up.right")
                    .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(foregroundColor)
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return Tokens.text1
        case .secondary:
            return hovering ? Tokens.text1 : Tokens.text1.opacity(0.92)
        case .outline:
            return hovering ? Tokens.text1 : Tokens.text2
        case .ghost:
            return hovering ? Tokens.text1 : Tokens.text2
        case .destructive:
            return Tokens.danger.opacity(hovering ? 1.0 : 0.88)
        case .link:
            return hovering ? Tokens.text1 : Tokens.text3
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .primary:
            shape.fill(hovering && isEnabled ? Tokens.prominentFillLit : Tokens.prominentFill)
        case .secondary:
            shape.fill(hovering && isEnabled ? Tokens.recessFillLit : Tokens.recessFill)
        case .outline:
            shape.fill(hovering && isEnabled ? Tokens.ink.opacity(0.06) : Color.clear)
        case .ghost:
            shape.fill(hovering && isEnabled ? Tokens.ink.opacity(0.08) : Color.clear)
        case .destructive:
            shape.fill(Tokens.danger.opacity(hovering && isEnabled ? 0.16 : 0.10))
        case .link:
            Color.clear
        }
    }

    @ViewBuilder
    private var borderView: some View {
        switch variant {
        case .primary:
            shape.strokeBorder(hovering && isEnabled ? Tokens.prominentRimLit : Tokens.prominentRim, lineWidth: 0.5)
        case .secondary:
            shape.strokeBorder(hovering && isEnabled ? Tokens.recessRimLit : Tokens.recessRim, lineWidth: 0.5)
        case .outline:
            shape.strokeBorder(hovering && isEnabled ? Tokens.ink.opacity(0.24) : Tokens.ink.opacity(0.14), lineWidth: 0.5)
        case .destructive:
            shape.strokeBorder(Tokens.danger.opacity(hovering && isEnabled ? 0.34 : 0.22), lineWidth: 0.5)
        case .ghost, .link:
            EmptyView()
        }
    }
}

// MARK: - SettingsBadge

/// Unified non-interactive capsule badge for Settings metadata and status.
struct SettingsBadge: View {
    enum Variant {
        case `default`
        case secondary
        case outline
        case destructive
        case accent
        case sale
    }

    var text: String
    var variant: Variant = .secondary

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Text(text)
            .font(.sf(Tokens.TypeSize.caption, weight: .regular))
            .tracking(0.2)
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(fillColor, in: shape)
            .overlay(borderView)
    }

    private var foregroundColor: Color {
        switch variant {
        case .default:     return Tokens.text1
        case .secondary:   return Tokens.text2
        case .outline:     return Tokens.text2
        case .destructive: return Tokens.danger.opacity(0.92)
        case .accent:      return Tokens.accent
        case .sale:        return Tokens.sale
        }
    }

    private var fillColor: Color {
        switch variant {
        case .default:     return Tokens.prominentFill
        case .secondary:   return Tokens.ink.opacity(0.07)
        case .outline:     return Color.clear
        case .destructive: return Tokens.danger.opacity(0.10)
        case .accent:      return Tokens.accent.opacity(0.16)
        case .sale:        return Tokens.sale.opacity(0.12)
        }
    }

    @ViewBuilder
    private var borderView: some View {
        switch variant {
        case .outline:
            shape.strokeBorder(Tokens.ink.opacity(0.16), lineWidth: 0.5)
        case .destructive:
            shape.strokeBorder(Tokens.danger.opacity(0.22), lineWidth: 0.5)
        case .sale:
            shape.strokeBorder(Tokens.sale.opacity(0.26), lineWidth: 0.5)
        case .default, .secondary, .accent:
            EmptyView()
        }
    }
}

// MARK: - SettingsInputBox & SettingsTextField

/// Clean recessed text field surface with a crisp focus border (no outer halo).
struct SettingsInputBox: ViewModifier {
    var focused: Bool
    var invalid: Bool = false
    var height: CGFloat? = 34

    private var shape: RoundedRectangle { RoundedRectangle.control }

    func body(content: Content) -> some View {
        let borderColor: Color = invalid
            ? Tokens.danger.opacity(focused ? 0.70 : 0.45)
            : (focused ? SettingsUI.focusBorder : Tokens.ink.opacity(0.10))

        return content
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Tokens.ink.opacity(focused ? 0.08 : 0.045)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

extension View {
    func settingsInputBox(focused: Bool, invalid: Bool = false, height: CGFloat? = 34) -> some View {
        modifier(SettingsInputBox(focused: focused, invalid: invalid, height: height))
    }
}

/// Self-focus-tracking single-line or multi-line input field with unified placeholder & focus rim.
struct SettingsTextField: View {
    var placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var monospaced: Bool = false
    var lines: ClosedRange<Int>? = nil
    var disabled: Bool = false
    var invalid: Bool = false
    var onSubmit: (() -> Void)? = nil
    var onChange: ((String) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: lines == nil ? .leading : .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(fieldFont)
                    .foregroundStyle(Tokens.placeholder)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .padding(.vertical, lines == nil ? 0 : 8)
            }
            Group {
                if secure {
                    SecureField("", text: $text)
                } else if let lines {
                    TextField("", text: $text, axis: .vertical)
                        .lineLimit(lines)
                        .padding(.vertical, 8)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(fieldFont)
            .foregroundStyle(Tokens.text1)
            .disabled(disabled)
            .focused($isFocused)
            .onSubmit { onSubmit?() }
            .onChange(of: text) { _, newValue in onChange?(newValue) }
        }
        .settingsInputBox(focused: isFocused, invalid: invalid, height: lines == nil ? 34 : nil)
        .opacity(disabled ? 0.5 : 1)
    }

    private var fieldFont: Font {
        monospaced
            ? .system(size: Tokens.TypeSize.label, design: .monospaced)
            : .sf(Tokens.TypeSize.form)
    }
}

// MARK: - SettingsCollapsible (Borderless Full-Width Disclosure)

/// Borderless full-width disclosure row with a quiet hover wash, trailing summary,
/// and rotating chevron — no heavy card box painted around the section.
struct SettingsCollapsible<Content: View>: View {
    var title: String
    var summary: String? = nil
    @Binding var isOpen: Bool
    var onToggle: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    NotchPanel.exemptNextDoubleClick()
                    if let onToggle {
                        onToggle()
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) { isOpen.toggle() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(icon: "chevron.right")
                            .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(title)
                            .font(.sf(Tokens.TypeSize.label, weight: .regular))
                            .foregroundStyle(Tokens.text1)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: SettingsUI.heightSM)
                    .recessedSurface(in: Capsule(style: .continuous), lit: hovering)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain).exemptsDoubleClickPin()
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)

                Spacer(minLength: 8)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: isOpen)
    }
}

// MARK: - SettingsPlanSteps (Borderless Trace / Plan)

/// Borderless collapsible step list modelled on shadcn/ui AI Elements `Trace` / `Plan`:
/// a quiet trigger line summarizing progress (`X / Y`) over an indented status-tracked
/// step list, with no extra card box painted behind it.
struct SettingsPlanSteps<Content: View>: View {
    var title: String
    var completedCount: Int
    var totalCount: Int
    @State private var expanded: Bool = true
    @ViewBuilder var content: () -> Content

    @State private var hoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                NotchPanel.exemptNextDoubleClick()
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(icon: "chevron.right")
                        .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                        .foregroundStyle(hoveringHeader ? Tokens.text2 : Tokens.text4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                    Text("\(completedCount) / \(totalCount)")
                        .font(.sf(Tokens.TypeSize.caption, weight: .regular).monospacedDigit())
                        .foregroundStyle(Tokens.text4)
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .onHover { hoveringHeader = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hoveringHeader)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsPlanStepStatus {
    case done, running, pending
}

/// One step inside `SettingsPlanSteps`, with `done` / `running` / `pending` status indicator.
struct SettingsPlanStep<Action: View, Detail: View>: View {
    var title: String
    var status: SettingsPlanStepStatus
    var isLast: Bool = false
    @ViewBuilder var action: () -> Action
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                statusGlyph
                    .frame(width: 16, height: 22)
                if !isLast {
                    Rectangle()
                        .fill(status == .done ? Tokens.ink.opacity(0.22) : Tokens.ink.opacity(0.09))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.sf(Tokens.TypeSize.label, weight: .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if status == .running {
                        action()
                    }
                }
                .frame(minHeight: 22)

                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .done:
            Image(icon: "checkmark.circle.fill")
                .font(.sf(13, weight: .regular))
                .foregroundStyle(Tokens.text2)
        case .running:
            ZStack {
                Circle()
                    .strokeBorder(Tokens.text1.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 13, height: 13)
                Circle()
                    .fill(Tokens.text1)
                    .frame(width: 5, height: 5)
            }
        case .pending:
            Circle()
                .strokeBorder(Tokens.text4.opacity(0.65), lineWidth: 1.2)
                .frame(width: 12, height: 12)
        }
    }

    private var titleColor: Color {
        switch status {
        case .done:    return Tokens.text3
        case .running: return Tokens.text1
        case .pending: return Tokens.text4
        }
    }
}

extension SettingsPlanStep where Detail == EmptyView {
    init(title: String, status: SettingsPlanStepStatus, isLast: Bool = false, @ViewBuilder action: @escaping () -> Action) {
        self.title = title
        self.status = status
        self.isLast = isLast
        self.action = action
        self.detail = { EmptyView() }
    }
}

// MARK: - SettingsTabs (Capsule Track + Sliding Capsule Pill)

/// Segmented capsule tabs with a shared subtle track and sliding active capsule.
struct SettingsTabs<Item: Hashable>: View {
    let items: [Item]
    let selection: Item
    let title: (Item) -> String
    let onSelect: (Item) -> Void

    @Namespace private var activeTab
    @State private var hovered: Item?

    private var capsule: Capsule { Capsule(style: .continuous) }

    var body: some View {
        if #available(macOS 26.0, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(items, id: \.self) { item in
                            let active = item == selection
                            let isHover = hovered == item
                            Button {
                                NotchPanel.exemptNextDoubleClick()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    onSelect(item)
                                }
                            } label: {
                                Text(title(item))
                                    .font(.sf(Tokens.TypeSize.meta, weight: active ? .medium : .regular))
                                    .foregroundStyle(active ? Tokens.text1 : (isHover ? Tokens.text1 : Tokens.text3))
                                    .lineLimit(1)
                                    .padding(.horizontal, 11)
                                    .frame(height: 24)
                                    .background {
                                        if active {
                                            capsule
                                                .fill(.clear)
                                                .glassEffect(.regular.interactive(), in: capsule)
                                                .glassEffectID("settingsActiveTab", in: activeTab)
                                        }
                                    }
                                    .contentShape(capsule)
                            }
                            .buttonStyle(.plain).exemptsDoubleClickPin()
                            .onHover { inside in
                                if inside { hovered = item }
                                else if hovered == item { hovered = nil }
                            }
                        }
                    }
                    .padding(3)
                    .glassEffect(.regular, in: capsule)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        let active = item == selection
                        let isHover = hovered == item
                        Button {
                            NotchPanel.exemptNextDoubleClick()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                onSelect(item)
                            }
                        } label: {
                            Text(title(item))
                                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                                .foregroundStyle(active ? Tokens.text1 : (isHover ? Tokens.text1 : Tokens.text3))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .frame(height: 24)
                                .background {
                                    if active {
                                        capsule
                                            .fill(Tokens.ink.opacity(0.12))
                                            .overlay(capsule.strokeBorder(Tokens.ink.opacity(0.14), lineWidth: 0.5))
                                            .matchedGeometryEffect(id: "settingsActiveTab", in: activeTab)
                                    }
                                }
                                .contentShape(capsule)
                        }
                        .buttonStyle(.plain).exemptsDoubleClickPin()
                        .onHover { inside in
                            if inside { hovered = item }
                            else if hovered == item { hovered = nil }
                        }
                    }
                }
                .padding(3)
                .background(capsule.fill(Tokens.ink.opacity(0.045)))
                .overlay(capsule.strokeBorder(Tokens.ink.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}

// MARK: - SettingsChoiceChip (Capsule Radio vs Checkbox)

/// Capsule choice chip that distinguishes single-select (radio) from multi-select (checkbox).
struct SettingsChoiceChip: View {
    enum Mode { case radio, checkbox }

    var title: String
    var active: Bool
    var mode: Mode
    var action: () -> Void

    @State private var hovering = false

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Button {
            NotchPanel.exemptNextDoubleClick()
            action()
        } label: {
            HStack(spacing: 6) {
                indicator
                Text(title)
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(active ? Tokens.text1 : (hovering ? Tokens.text1 : Tokens.text2))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: SettingsUI.heightSM)
            .background(shape.fill(Tokens.ink.opacity(active ? 0.14 : (hovering ? 0.09 : 0.05))))
            .overlay(shape.strokeBorder(Tokens.ink.opacity(active ? 0.28 : (hovering ? 0.18 : 0.11)),
                                        lineWidth: active ? 0.8 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(.easeOut(duration: 0.14), value: active)
    }

    @ViewBuilder
    private var indicator: some View {
        switch mode {
        case .radio:
            ZStack {
                Circle()
                    .strokeBorder(active ? Tokens.text1 : Tokens.text3.opacity(0.7), lineWidth: 1.1)
                    .frame(width: 11, height: 11)
                if active {
                    Circle()
                        .fill(Tokens.text1)
                        .frame(width: 5, height: 5)
                }
            }
        case .checkbox:
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(active ? Tokens.text1 : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(active ? Color.clear : Tokens.text3.opacity(0.7), lineWidth: 1.1)
                    )
                    .frame(width: 11, height: 11)
                if active {
                    Image(icon: "checkmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Tokens.adaptive(dark: .black, light: .white))
                }
            }
        }
    }
}

// MARK: - SettingsAlertDialog

/// Left-aligned confirmation dialog content with Title + Description and
/// bottom-right Cancel (outline capsule) + Confirm (destructive/primary capsule).
struct SettingsAlertDialog<Extra: View>: View {
    var title: String
    var description: String? = nil
    var confirmTitle: String
    var cancelTitle: String
    var destructive: Bool = true
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.sf(Tokens.TypeSize.reading, weight: .medium))
                    .foregroundStyle(Tokens.text1)
                    .fixedSize(horizontal: false, vertical: true)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.sf(Tokens.TypeSize.label, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            extra()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SettingsButton(title: cancelTitle, variant: .outline, size: .md, action: onCancel)
                SettingsButton(title: confirmTitle,
                               variant: destructive ? .destructive : .primary,
                               size: .md,
                               action: onConfirm)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

extension SettingsAlertDialog where Extra == EmptyView {
    init(
        title: String,
        description: String? = nil,
        confirmTitle: String,
        cancelTitle: String,
        destructive: Bool = true,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.destructive = destructive
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.extra = { EmptyView() }
    }
}
