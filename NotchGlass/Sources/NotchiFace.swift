import SwiftUI

/// Notchi's face: the app icon's two eyes (`NotchiMarkEyes`) at the outer edge
/// of the resting notch's left ear. The camera housing has no pixels, so the
/// face never sits in the middle; it rides the ear that grows out of the
/// housing's left side and slides back behind it when the ear folds. It shows
/// only while the panel is closed and the ears are out (background work, copy
/// sense). With the panel open the panel's own content says what is happening,
/// so there is no face.
///
/// Redraws only on expression changes, gaze steps and blinks. Nothing runs
/// per frame.
struct NotchiFace: View {
    enum Expression: Equatable {
        /// Looking toward the offer in the right ear ("⌘C").
        case offer
        /// Background work under way: glancing up and to the right, the
        /// gaze stepping between a few spots. The same pose as
        /// the panel's `NotchiMark.Mood.composing`.
        case think
        /// A write landed: eyes shut while the head dips once.
        case saved
        /// Something failed: eyes wide apart, one short shake.
        case alert
    }

    let expression: Expression

    /// The face's slot width at the ear's outer edge.
    static let slotWidth: CGFloat = 26
    /// Height of one open eye; the pair is about 14pt wide.
    private static let eyeHeight: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pose = NotchiMarkPose()
    @State private var blink: CGFloat = 1
    @State private var shake: CGFloat = 0

    var body: some View {
        NotchiMarkEyes(pose: pose, blink: blink, eyeHeight: Self.eyeHeight)
            .offset(x: shake)
            .frame(width: Self.slotWidth)
            .task(id: expression) { await run(expression) }
            .accessibilityHidden(true)
    }

    // MARK: - Driving the expressions

    private func set(_ p: NotchiMarkPose, _ animation: Animation = .spring(response: 0.42, dampingFraction: 0.86)) {
        if reduceMotion { pose = p } else { withAnimation(animation) { pose = p } }
    }

    private func run(_ e: Expression) async {
        switch e {
        case .offer:
            set(NotchiMarkPose(lookX: 1.4))
            await blinkLoop()
        case .think:
            // Fast saccade to a spot, hold, then the next: how eyes move, not a
            // continuous drift.
            let spots: [CGFloat] = [0.9, 1.1, 0.9, 0.7]
            var i = 0
            async let blinking: Void = blinkLoop()
            while !Task.isCancelled {
                set(NotchiMarkPose(lookX: spots[i % spots.count], lookY: -0.9),
                    .spring(response: 0.16, dampingFraction: 0.95))
                i += 1
                try? await Task.sleep(for: .seconds(1.8))
                if reduceMotion { break }
            }
            await blinking
        case .saved:
            blink = 1
            set(NotchiMarkPose(lookY: 1, lidL: 0.12, lidR: 0.12), .easeOut(duration: 0.18))
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            set(NotchiMarkPose(lookY: 0.3), .spring(response: 0.5, dampingFraction: 0.9))
        case .alert:
            blink = 1
            set(NotchiMarkPose(spread: 1.18), .spring(response: 0.26, dampingFraction: 0.9))
            guard !reduceMotion else { return }
            for amp in [1.6, -1.3, 1.0, -0.6, 0.3, 0] as [CGFloat] {
                withAnimation(.easeInOut(duration: 0.07)) { shake = amp }
                try? await Task.sleep(for: .seconds(0.07))
                if Task.isCancelled { shake = 0; return }
            }
        }
    }

    /// Blinks every 3–6.5s, sometimes twice in a row. Closes fast, opens slower.
    private func blinkLoop() async {
        guard !reduceMotion else { return }
        var wait = 1.5
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { break }
            withAnimation(.easeIn(duration: 0.07)) { blink = 0.08 }
            try? await Task.sleep(for: .seconds(0.07))
            withAnimation(.easeOut(duration: 0.13)) { blink = 1 }
            wait = Double.random(in: 0..<1) < 0.2 ? 0.3 : .random(in: 3...6.5)
        }
        blink = 1
    }
}
