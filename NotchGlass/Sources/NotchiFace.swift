import SwiftUI

/// Notchi's face: two eyes at the outer edge of the resting notch's left ear.
/// The camera housing has no pixels, so the face never sits in the middle; it
/// rides the ear that grows out of the housing's left side and slides back
/// behind it when the ear folds. It shows only while the panel is closed and
/// the ears are out (background work, copy sense). With the panel open the
/// panel's own content says what is happening, so there is no face.
///
/// Redraws only on expression changes, gaze steps and blinks. Nothing runs
/// per frame.
struct NotchiFace: View {
    enum Expression: Equatable {
        /// Looking toward the offer in the right ear ("⌘C").
        case offer
        /// Background work under way: glancing up and to the right, one eye
        /// narrowed, the gaze stepping between a few spots.
        case think
        /// A write landed: eyes shut while the head dips once.
        case saved
        /// Something failed: round eyes, one short shake.
        case alert
    }

    let expression: Expression

    /// The face's slot width at the ear's outer edge.
    static let slotWidth: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pose = Pose.base
    @State private var lid: CGFloat = 1
    @State private var shake: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            eye(squint: 0)
            eye(squint: pose.squint)
                .padding(.leading, 11 * pose.spread - Pose.eyeBox)
        }
        .offset(x: pose.lookX * 3.6 + shake, y: pose.lookY * 2.6)
        .frame(width: Self.slotWidth)
        .task(id: expression) { await run(expression) }
    }

    private func eye(squint: CGFloat) -> some View {
        EyeStroke(dx: pose.dx, dy: pose.dy * (1 - squint), bend: pose.bend, width: pose.sw)
            .fill(Pose.ink)
            .frame(width: Pose.eyeBox, height: Pose.eyeBox * 1.6)
            .scaleEffect(x: 1, y: lid, anchor: .center)
    }

    // MARK: - Driving the expressions

    private func set(_ p: Pose, _ animation: Animation = .spring(response: 0.42, dampingFraction: 0.86)) {
        if reduceMotion { pose = p } else { withAnimation(animation) { pose = p } }
    }

    private func run(_ e: Expression) async {
        switch e {
        case .offer:
            set(Pose(dy: 8.5, lookX: 1.2, lookY: 0.1))
            await blinkLoop()
        case .think:
            // Fast saccade to a spot, hold, then the next: how eyes move, not a
            // continuous drift.
            let spots: [CGFloat] = [0.9, 1.1, 0.9, 0.7]
            var i = 0
            async let blinking: Void = blinkLoop()
            while !Task.isCancelled {
                set(Pose(dy: 6.5, lookX: spots[i % spots.count], lookY: -0.9, squint: 0.3),
                    .spring(response: 0.16, dampingFraction: 0.95))
                i += 1
                try? await Task.sleep(for: .seconds(1.8))
                if reduceMotion { break }
            }
            await blinking
        case .saved:
            lid = 1
            set(Pose(dx: 5, dy: 0, bend: -2.4, sw: 3.4, lookY: 1), .easeOut(duration: 0.18))
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            set(Pose(lookY: 0.3), .spring(response: 0.5, dampingFraction: 0.9))
        case .alert:
            lid = 1
            set(Pose(dx: 0, dy: 0, sw: 9.5, spread: 1.12), .spring(response: 0.26, dampingFraction: 0.9))
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
            withAnimation(.easeIn(duration: 0.07)) { lid = 0.05 }
            try? await Task.sleep(for: .seconds(0.07))
            withAnimation(.easeOut(duration: 0.13)) { lid = 1 }
            wait = Double.random(in: 0..<1) < 0.2 ? 0.3 : .random(in: 3...6.5)
        }
        lid = 1
    }
}

/// One expression's eye parameters, in the character study's units.
private struct Pose: Equatable {
    var dx: CGFloat = 0
    var dy: CGFloat = 8
    var bend: CGFloat = 0
    var sw: CGFloat = 9
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    var squint: CGFloat = 0
    var spread: CGFloat = 1

    static let base = Pose()
    static let eyeBox: CGFloat = 8
    /// Warm off-white, softer on black than pure white.
    static let ink = Color(red: 0xEC / 255, green: 0xEB / 255, blue: 0xE6 / 255)
}

/// A single eye: a round-capped stroke from (−dx, −dy) to (dx, dy) bowed by
/// `bend`. A vertical stroke is the open eye, a flat one a closed eye, an
/// upward bow "^", a zero-length stroke a round dot. Filled as an outline so
/// every parameter, stroke width included, animates.
private struct EyeStroke: Shape {
    var dx: CGFloat
    var dy: CGFloat
    var bend: CGFloat
    var width: CGFloat

    /// Study units to points: the study draws the notch 26 units tall.
    private static let unit: CGFloat = 0.37

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(dx, dy), .init(bend, width)) }
        set { dx = newValue.first.first; dy = newValue.first.second
              bend = newValue.second.first; width = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let u = Self.unit
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let x = dx * u, y = max(0, dy) * u * 0.5, b = bend * u
        var p = Path()
        p.move(to: CGPoint(x: c.x - x, y: c.y - y))
        p.addQuadCurve(to: CGPoint(x: c.x + x, y: c.y + y),
                       control: CGPoint(x: c.x, y: c.y - 2 * b))
        return p.strokedPath(StrokeStyle(lineWidth: max(0.5, width * u), lineCap: .round))
    }
}
