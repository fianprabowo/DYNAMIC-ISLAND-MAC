import SwiftUI

// The notch dressed up for the season (gear menu → Animations → Season), behind the open notch's
// tab and on the face beside the closed notch (see NotchEyes):
// - Christmas, 1 November to 28 December: falling snow, snow along the bottom, a snowman face.
// - New Year, 29 December to 4 January: a fireworks show with now and then a big one, a party
//   hat that pops confetti.
// - Lebaran, from a week before Eid al-Fitr to four days after: twinkling stars, a crescent moon,
//   a string of ketupat, a peci on the face.

/// A season the notch can dress up for.
enum Season: String, CaseIterable {
    case christmas = "Christmas"
    case newYear = "New Year"
    case lebaran = "Lebaran"

    /// The season on `date`, if any. Each lasts until three or four days after its day.
    static func current(on date: Date) -> Season? {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        // Lebaran first: in some years Eid falls in November or December.
        if isAroundEid(date) { return .lebaran }
        if month == 11 || (month == 12 && day <= 28) { return .christmas }
        if (month == 12 && day >= 29) || (month == 1 && day <= 4) { return .newYear }
        return nil
    }

    /// From a week before Eid al-Fitr (1 Shawwal) to four days after it. The Umm al-Qura
    /// calendar's date can be a day off Indonesia's, which the days after it cover.
    private static func isAroundEid(_ date: Date) -> Bool {
        let hijri = Calendar(identifier: .islamicUmmAlQura)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let year = hijri.component(.year, from: date)
        for hijriYear in [year - 1, year, year + 1] {
            guard let eid = hijri.date(from: DateComponents(year: hijriYear, month: 10, day: 1)),
                  let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: eid)),
                  let end = calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: eid)) else { continue }
            if today >= start && today <= end { return true }
        }
        return false
    }
}

/// The gear menu's choice: the season by the date, none, or one of them all the time.
enum SeasonSetting: String, CaseIterable {
    case byDate, off, christmas, newYear, lebaran

    func season(on date: Date) -> Season? {
        switch self {
        case .byDate: Season.current(on: date)
        case .off: nil
        case .christmas: .christmas
        case .newYear: .newYear
        case .lebaran: .lebaran
        }
    }

    var title: String {
        switch self {
        case .byDate: "By Date"
        case .off: "Off"
        case .christmas: "Always Christmas"
        case .newYear: "Always New Year"
        case .lebaran: "Always Lebaran"
        }
    }
}

/// Behind the open notch's tab, for the season.
struct SeasonalBackdrop: View {
    let season: Season
    var isPaused: Bool

    var body: some View {
        Group {
            switch season {
            case .christmas: ChristmasBackdrop(isPaused: isPaused)
            case .newYear: Fireworks(isPaused: isPaused)
            case .lebaran: LebaranBackdrop(isPaused: isPaused)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Christmas

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

// MARK: - New Year

/// A fireworks show behind the tab: rockets rising from the bottom and bursting in different
/// shapes (round, a ring, a drooping willow, two colors, crackling glitter), several at once
/// across the panel, and every so often a big one over the middle that lights up the panel.
/// Drawn like the snow, in one Canvas. Everything comes from the time, so nothing is stored.
struct Fireworks: View {
    var isPaused: Bool

    fileprivate static let colors: [Color] = [
        Color(red: 1, green: 0.84, blue: 0.3), Color(red: 1, green: 0.38, blue: 0.55), Color(red: 0.4, green: 0.85, blue: 1),
        Color(red: 0.5, green: 1, blue: 0.55), Color(red: 1, green: 0.58, blue: 0.22), Color(red: 0.78, green: 0.55, blue: 1),
        Color(red: 1, green: 0.95, blue: 0.85),
    ]

    /// Each small firework's turn: the rocket rises, bursts, then it's dark for the rest.
    private static let period = 2.6
    private static let rise = 0.55
    private static let burst = 1.6
    /// The big one: once every `bigPeriod`, a slower rocket and a long burst.
    private static let bigPeriod = 9.0
    private static let bigRise = 0.9
    private static let bigBurst = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                drawSmall(in: &canvas, size: size, time: time)
                drawBig(in: &canvas, size: size, time: time)
            }
        }
    }

    /// One launch spot for every 110 points of width, their turns spread out so a few are
    /// always going off.
    private func drawSmall(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let spots = max(3, Int(size.width / 110))
        for spot in 0..<spots {
            let local = time + Double(spot) * Self.period * 0.618
            let round = (local / Self.period).rounded(.down)
            let phase = local - round * Self.period
            var random = SeededRandom(seed: UInt64(bitPattern: Int64(round)) &* 7919 &+ UInt64(spot) &* 104_729)
            let x = (Double(spot) + .random(in: 0.15...0.85, using: &random)) / Double(spots) * size.width
            let y = Double.random(in: 0.18...0.55, using: &random) * size.height
            let radius = Double.random(in: 28...min(60, size.height * 0.35), using: &random)
            let style = BurstStyle.allCases.randomElement(using: &random) ?? .peony
            let first = Self.colors.randomElement(using: &random) ?? .white
            let second = Self.colors.randomElement(using: &random) ?? .white
            let sparks = Int.random(in: 26...36, using: &random)
            let center = CGPoint(x: x, y: y)
            if phase < Self.rise {
                drawRocket(in: &canvas, from: CGPoint(x: x, y: size.height), to: center, progress: phase / Self.rise, color: first)
            } else if phase < Self.rise + Self.burst {
                drawBurst(in: &canvas, at: center, radius: radius, sparks: sparks, style: style,
                          colors: (first, second), progress: (phase - Self.rise) / Self.burst, time: time, seed: round)
            }
        }
    }

    /// The big one goes up from near the middle and fills much of the panel: two rings of
    /// colors, a glittering tail as it fades, and a flash over the panel when it bursts.
    private func drawBig(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let round = (time / Self.bigPeriod).rounded(.down)
        let phase = time - round * Self.bigPeriod
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(round)) &* 31_337 &+ 17)
        let x = size.width * .random(in: 0.35...0.65, using: &random)
        let y = size.height * .random(in: 0.32...0.42, using: &random)
        let radius = min(size.width * 0.32, size.height * 0.62)
        let outer = Self.colors.randomElement(using: &random) ?? .white
        let inner = Self.colors.randomElement(using: &random) ?? .white
        let center = CGPoint(x: x, y: y)
        if phase < Self.bigRise {
            drawRocket(in: &canvas, from: CGPoint(x: x, y: size.height), to: center, progress: phase / Self.bigRise, color: outer, width: 2.2)
        } else if phase < Self.bigRise + Self.bigBurst {
            let progress = (phase - Self.bigRise) / Self.bigBurst
            if progress < 0.15 {
                // The panel lights up for a moment.
                let flash = 1 - progress / 0.15
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(outer.opacity(0.1 * flash)))
                let glow = radius * 0.5 * flash
                canvas.fill(Path(ellipseIn: CGRect(x: x - glow, y: y - glow, width: glow * 2, height: glow * 2)),
                            with: .radialGradient(Gradient(colors: [Color.white.opacity(0.5 * flash), .clear]),
                                                  center: center, startRadius: 0, endRadius: glow))
            }
            drawBurst(in: &canvas, at: center, radius: radius, sparks: 64, style: .peony, colors: (outer, outer),
                      progress: progress, time: time, seed: round, dot: 3.2, glitters: true)
            drawBurst(in: &canvas, at: center, radius: radius * 0.55, sparks: 36, style: .peony, colors: (inner, inner),
                      progress: min(1, progress * 1.15), time: time, seed: round + 0.5, dot: 2.6)
        }
    }

    private func drawRocket(in canvas: inout GraphicsContext, from start: CGPoint, to end: CGPoint,
                            progress: Double, color: Color, width: Double = 1.5) {
        let eased = 1 - pow(1 - progress, 2)
        let head = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
        let tailLength = 16.0
        var trail = Path()
        trail.move(to: head)
        trail.addLine(to: CGPoint(x: head.x, y: head.y + tailLength))
        canvas.stroke(trail, with: .linearGradient(Gradient(colors: [color, .clear]), startPoint: head,
                                                   endPoint: CGPoint(x: head.x, y: head.y + tailLength)), lineWidth: width)
        canvas.fill(Path(ellipseIn: CGRect(x: head.x - width, y: head.y - width, width: width * 2, height: width * 2)), with: .color(.white))
    }

    fileprivate enum BurstStyle: CaseIterable {
        /// A round ball of sparks.
        case peony
        /// Sparks only on a ring.
        case ring
        /// Long trails that droop like a willow and fade slowly.
        case willow
        /// Half the sparks in a second color.
        case twoColor
        /// Sparks that flicker as they spread.
        case crackle
    }

    private func drawBurst(in canvas: inout GraphicsContext, at center: CGPoint, radius: Double, sparks: Int,
                           style: BurstStyle, colors: (Color, Color), progress: Double, time: Double,
                           seed: Double, dot: Double = 2.4, glitters: Bool = false) {
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(seed * 2)) &* 2_654_435_761 &+ UInt64(sparks))
        let fade = style == .willow ? 1 - pow(progress, 2) : 1 - progress
        let gravity = (style == .willow ? 34.0 : 16.0) * progress * progress
        let spread = 1 - pow(1 - progress, 3)
        if progress < 0.1 {
            let flash = 1 - progress / 0.1
            let size = radius * 0.35 * flash
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2)),
                        with: .color(colors.0.opacity(0.35 * flash)))
        }
        for index in 0..<sparks {
            let angle = Double(index) / Double(sparks) * 2 * .pi + .random(in: -0.08...0.08, using: &random)
            // A ring keeps every spark at the edge; the others spread out at different speeds.
            let reach = radius * (style == .ring ? 1 : .random(in: 0.55...1, using: &random)) * spread
            let point = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach + gravity)
            let color = style == .twoColor && index.isMultiple(of: 2) ? colors.1 : colors.0
            var opacity = fade
            if style == .crackle || (glitters && progress > 0.45) {
                // Flickers, each spark at its own pace.
                opacity *= 0.35 + 0.65 * abs(sin(time * 28 + Double(index) * 1.7))
            }
            // A streak behind each spark, longer for the willow.
            let tail = style == .willow ? 0.6 : 0.82
            let from = CGPoint(x: center.x + cos(angle) * reach * tail, y: center.y + sin(angle) * reach * tail + gravity * tail * 0.9)
            var streak = Path()
            streak.move(to: from)
            streak.addLine(to: point)
            canvas.stroke(streak, with: .linearGradient(Gradient(colors: [.clear, color.opacity(opacity * 0.7)]), startPoint: from, endPoint: point),
                          lineWidth: dot * 0.55)
            let size = dot * (1 - progress * 0.45)
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                        with: .color(color.opacity(opacity)))
        }
    }
}

// MARK: - Lebaran

/// Gold stars twinkling, a crescent moon, and a string of ketupat swaying along the bottom.
struct LebaranBackdrop: View {
    var isPaused: Bool

    private static let gold = Color(red: 1, green: 0.84, blue: 0.4)
    private static let green = Color(red: 0.2, green: 0.62, blue: 0.32)

    private struct Star {
        let x: Double
        let y: Double
        let size: Double
        let speed: Double
        let phase: Double
    }

    private static let stars: [Star] = {
        var random = SeededRandom(seed: 1447)
        return (0..<60).map { _ in
            Star(x: .random(in: 0...1, using: &random), y: .random(in: 0.05...0.8, using: &random),
                 size: .random(in: 2...4.5, using: &random), speed: .random(in: 0.6...1.6, using: &random),
                 phase: .random(in: 0...(2 * .pi), using: &random))
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: isPaused)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                // Stars: four-pointed, brightening and dimming.
                let count = min(Self.stars.count, Int(size.width / 12))
                for star in Self.stars.prefix(count) {
                    let glow = max(0, sin(time * star.speed + star.phase))
                    let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
                    let reach = star.size * (0.6 + 0.4 * glow)
                    var sparkle = Path()
                    sparkle.move(to: CGPoint(x: center.x, y: center.y - reach))
                    sparkle.addQuadCurve(to: CGPoint(x: center.x + reach, y: center.y), control: center)
                    sparkle.addQuadCurve(to: CGPoint(x: center.x, y: center.y + reach), control: center)
                    sparkle.addQuadCurve(to: CGPoint(x: center.x - reach, y: center.y), control: center)
                    sparkle.addQuadCurve(to: CGPoint(x: center.x, y: center.y - reach), control: center)
                    canvas.fill(sparkle, with: .color(Self.gold.opacity(0.15 + 0.5 * glow)))
                }

                // The crescent: a gold disc with a second disc cut out of it.
                let moon = CGPoint(x: size.width * 0.86, y: size.height * 0.4)
                canvas.drawLayer { layer in
                    layer.fill(Path(ellipseIn: CGRect(x: moon.x - 15, y: moon.y - 15, width: 30, height: 30)), with: .color(Self.gold.opacity(0.3)))
                    layer.blendMode = .destinationOut
                    layer.fill(Path(ellipseIn: CGRect(x: moon.x - 9, y: moon.y - 19, width: 30, height: 30)), with: .color(.black))
                }

                // The string sags between hooks; a ketupat hangs from each low point.
                let hooks = max(4, Int(size.width / 80))
                let step = size.width / Double(hooks)
                let top = size.height - 15
                var string = Path()
                string.move(to: CGPoint(x: 0, y: top))
                for index in 0..<hooks {
                    let start = Double(index) * step
                    string.addQuadCurve(to: CGPoint(x: start + step, y: top), control: CGPoint(x: start + step / 2, y: top + 6))
                }
                canvas.stroke(string, with: .color(Self.gold.opacity(0.35)), lineWidth: 0.7)
                for index in 0..<hooks {
                    let swing = sin(time * 1.4 + Double(index) * 0.9) * 0.18
                    var hanging = canvas
                    hanging.translateBy(x: (Double(index) + 0.5) * step, y: top + 3)
                    hanging.rotate(by: .radians(swing))
                    Self.drawKetupat(in: &hanging)
                }
            }
        }
    }

    /// A woven green diamond with gold strands across it, and a little tail, hung from the origin.
    private static func drawKetupat(in canvas: inout GraphicsContext) {
        let width = 7.0, height = 8.0, top = 2.0
        var diamond = Path()
        diamond.move(to: CGPoint(x: 0, y: top))
        diamond.addLine(to: CGPoint(x: width / 2, y: top + height / 2))
        diamond.addLine(to: CGPoint(x: 0, y: top + height))
        diamond.addLine(to: CGPoint(x: -width / 2, y: top + height / 2))
        diamond.closeSubpath()
        var hook = Path()
        hook.move(to: .zero)
        hook.addLine(to: CGPoint(x: 0, y: top))
        canvas.stroke(hook, with: .color(gold.opacity(0.4)), lineWidth: 0.6)
        canvas.fill(diamond, with: .color(green.opacity(0.7)))
        var weave = Path()
        weave.move(to: CGPoint(x: -width / 4, y: top + height / 4))
        weave.addLine(to: CGPoint(x: width / 4, y: top + height * 3 / 4))
        weave.move(to: CGPoint(x: width / 4, y: top + height / 4))
        weave.addLine(to: CGPoint(x: -width / 4, y: top + height * 3 / 4))
        canvas.stroke(weave, with: .color(gold.opacity(0.7)), lineWidth: 0.6)
        var tail = Path()
        tail.move(to: CGPoint(x: 0, y: top + height))
        tail.addLine(to: CGPoint(x: 1.2, y: top + height + 3))
        canvas.stroke(tail, with: .color(green.opacity(0.6)), lineWidth: 0.8)
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
