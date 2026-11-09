import SwiftUI

// Christmas (gear menu → Animations): snow drifting down behind the open notch's tab and a little
// snow piled along the bottom; beside the closed notch the face becomes a snowman (see NotchEyes).
// Unless it was switched on or off by hand, it is on through December.

/// Flakes falling behind the tab's content and swaying a little. One Canvas draws them all, at
/// most 30 times a second, so the rest of the panel isn't redrawn; it stops while the notch
/// changes size.
struct ChristmasSnowfall: View {
    var isPaused: Bool

    private struct Flake {
        let x: Double
        let phase: Double
        let speed: Double
        let size: Double
        let sway: Double
        let swaySpeed: Double
        let opacity: Double
    }

    /// The same flakes every time, so the snow doesn't jump when the notch reopens.
    private static let flakes: [Flake] = {
        var random = SeededRandom(seed: 1225)
        return (0..<110).map { _ in
            Flake(x: .random(in: 0...1, using: &random),
                  phase: .random(in: 0...1, using: &random),
                  speed: .random(in: 9...24, using: &random),
                  size: .random(in: 1.4...3.2, using: &random),
                  sway: .random(in: 4...12, using: &random),
                  swaySpeed: .random(in: 0.4...1.1, using: &random),
                  opacity: .random(in: 0.25...0.7, using: &random))
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                // About one flake for every 8 points of width, so the wide notch isn't sparser.
                let count = min(Self.flakes.count, Int(size.width / 8))
                let fall = size.height + 12
                for flake in Self.flakes.prefix(count) {
                    // Slower, smaller flakes look farther away.
                    let y = (time * flake.speed + flake.phase * fall).truncatingRemainder(dividingBy: fall) - 6
                    let x = flake.x * size.width + sin(time * flake.swaySpeed + flake.phase * 2 * .pi) * flake.sway
                    let rect = CGRect(x: x - flake.size / 2, y: y - flake.size / 2, width: flake.size, height: flake.size)
                    canvas.fill(Path(ellipseIn: rect), with: .color(.white.opacity(flake.opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Snow lying along the bottom of the panel, in soft heaps.
struct SnowDrift: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let heaps = max(3, Int(rect.width / 90))
        let step = rect.width / CGFloat(heaps)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.45))
        for index in 0..<heaps {
            let start = rect.minX + CGFloat(index) * step
            // Heaps of a few heights, the same each time.
            let height = rect.height * [1, 0.7, 0.9, 0.6, 0.8][index % 5]
            path.addQuadCurve(to: CGPoint(x: start + step, y: rect.maxY - rect.height * 0.45),
                              control: CGPoint(x: start + step / 2, y: rect.maxY - height * 1.5))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Everything behind the tab: the falling snow and the snow on the ground.
struct ChristmasBackdrop: View {
    var isPaused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            ChristmasSnowfall(isPaused: isPaused)
            SnowDrift()
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                .frame(height: 9)
        }
        .allowsHitTesting(false)
    }
}

/// A small fixed-seed generator (SplitMix64), so the flakes come out the same on every launch.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
