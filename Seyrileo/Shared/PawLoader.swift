import SwiftUI

/// Seyrileo's loading indicator: four paw prints walking across, one after another, in the
/// icon's teal and cream. With Reduce Motion it is a single, gently pulsing paw.
struct PawLoader: View {
    var size: CGFloat = 28
    var tint: Color = .accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Positions of the four prints of a walk (left/right alternating, moving up-right).
    private let steps: [(x: CGFloat, y: CGFloat, angle: Double)] = [
        (-0.75, 0.55, 20), (-0.2, 0.05, 35), (0.25, 0.3, 20), (0.8, -0.2, 35),
    ]

    var body: some View {
        Group {
            if reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.8)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.8) % 2 == 0
                    paw(opacity: on ? 1 : 0.45)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(steps.indices, id: \.self) { index in
                            let step = steps[index]
                            paw(opacity: opacity(at: t, index: index))
                                .rotationEffect(.degrees(step.angle))
                                .offset(x: step.x * size, y: step.y * size)
                        }
                    }
                    .frame(width: size * 2.6, height: size * 2)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    private func paw(opacity: Double) -> some View {
        Image(systemName: "pawprint.fill")
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(tint)
            .opacity(opacity)
    }

    /// Each print appears in turn and fades, like footsteps (1.6 s per walk).
    private func opacity(at time: TimeInterval, index: Int) -> Double {
        let cycle = 1.6
        let phase = (time.truncatingRemainder(dividingBy: cycle)) / cycle   // 0..<1
        let start = Double(index) / Double(steps.count) * 0.75
        let age = phase - start
        guard age >= 0 else { return 0.12 }
        return max(0.12, 1 - age * 1.6)
    }
}
