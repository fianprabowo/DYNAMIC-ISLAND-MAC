import SwiftUI

// The notch dressed up for the season (gear menu → Animations → Season), behind the open notch's
// tab and on the face beside the closed notch (see NotchEyes):
// - Christmas, 1 November to 28 December: falling snow, snow along the bottom, a snowman face.
// - New Year, 29 December to 4 January: a fireworks show with now and then a big one, a party
//   hat that pops confetti.
// - Lebaran, from a week before Eid al-Fitr to four days after: twinkling stars, a crescent moon,
//   a string of ketupat, a peci on the face.
// - Space, whenever it's picked (never by the date): a trip through space with planets, a
//   satellite, comets and now and then a jump to hyperspace; an astronaut's helmet on the face.

/// A season the notch can dress up for.
enum Season: String, CaseIterable {
    case christmas = "Christmas"
    case newYear = "New Year"
    case lebaran = "Lebaran"
    /// Not a season of the year: only when it's picked in the menu.
    case space = "Space"

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
    case byDate, off, christmas, newYear, lebaran, space

    func season(on date: Date) -> Season? {
        switch self {
        case .byDate: Season.current(on: date)
        case .off: nil
        case .christmas: .christmas
        case .newYear: .newYear
        case .lebaran: .lebaran
        case .space: .space
        }
    }

    var title: String {
        switch self {
        case .byDate: "By Date"
        case .off: "Off"
        case .christmas: "Always Christmas"
        case .newYear: "Always New Year"
        case .lebaran: "Always Lebaran"
        case .space: "Space Travel"
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
            case .space: SpaceBackdrop(isPaused: isPaused)
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

// MARK: - Space

/// A trip through space, flying forward as seen from the cockpit, to the planets one by one:
/// Mercury, Venus, Earth, Mars, Jupiter, Saturn, Uranus, Neptune and Pluto, then around again.
/// Each leg starts with a jump to hyperspace (everything speeds up, the stars stretch into lines,
/// the view lights up); then the next planet shows far ahead and grows as the ship
/// flies at it, until it slides past. Meanwhile the stars come out of the distance and streak
/// past, nebulas glow far off, a rock or two tumbles at the window, and on each leg one visitor
/// comes by across from the planet (an astronaut waving, a rocket overtaking, a satellite or a
/// comet); now and then a meteor rushes past and a shooting star falls far off. Like the
/// fireworks, everything comes from the time, so nothing is stored.
struct SpaceBackdrop: View {
    var isPaused: Bool

    /// A star ahead: its direction from the middle of the view, and where it is in its trip from
    /// the far distance past the window.
    private struct Star {
        let angle: Double
        let reach: Double
        let size: Double
        let phase: Double
        let offset: Double
        let color: Int
    }

    private static let stars: [Star] = {
        var random = SeededRandom(seed: 1969)
        return (0..<160).map { _ in
            Star(angle: .random(in: 0...(2 * .pi), using: &random), reach: .random(in: 0.04...1, using: &random).squareRoot(),
                 size: .random(in: 0.8...2.2, using: &random), phase: .random(in: 0...(2 * .pi), using: &random),
                 offset: .random(in: 0...1, using: &random), color: Int.random(in: 0..<10, using: &random))
        }
    }()
    /// How much of its way toward the window a star comes each second of cruising.
    private static let starSpeed = 0.045

    /// The jump to hyperspace: every `warpPeriod` (one leg, one planet), for `warpLength`, up to
    /// `warpBoost` times faster.
    private static let warpPeriod = 30.0
    private static let warpLength = 4.5
    private static let warpBoost = 22.0

    private static let nebulas: [(x: Double, y: Double, radius: Double, color: Color)] = [
        (0.15, 0.35, 0.9, Color(red: 0.55, green: 0.25, blue: 0.95)),
        (0.55, 0.75, 0.75, Color(red: 0.15, green: 0.55, blue: 0.95)),
        (0.85, 0.25, 0.8, Color(red: 0.95, green: 0.3, blue: 0.55)),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let warp = Self.warp(at: time)
                let travel = Self.distance(at: time)
                drawNebulas(in: &canvas, size: size, time: time)
                drawStars(in: &canvas, size: size, time: time, travel: travel, warp: warp)
                drawJourney(in: &canvas, size: size, time: time)
                drawAsteroids(in: &canvas, size: size, time: time, travel: travel)
                drawSatellite(in: &canvas, size: size, time: time, travel: travel)
                drawAstronaut(in: &canvas, size: size, time: time)
                drawRocket(in: &canvas, size: size, time: time)
                drawMeteor(in: &canvas, size: size, time: time)
                drawShootingStars(in: &canvas, size: size, time: time)
                drawComet(in: &canvas, size: size, time: time)
                if warp > 0.01 {
                    // The jump lights the view up a little, most in the middle.
                    canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.6, green: 0.8, blue: 1).opacity(0.03 * warp)))
                    let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
                    canvas.fill(Path(CGRect(origin: .zero, size: size)),
                                with: .radialGradient(Gradient(colors: [Color.white.opacity(0.06 * warp), .clear]),
                                                      center: center, startRadius: 0, endRadius: size.width * 0.4))
                }
            }
        }
    }

    // MARK: Speed

    /// How far into the jump to hyperspace, 0 (cruising) to 1 (fastest), rising and falling smoothly.
    private static func warp(at time: Double) -> Double {
        let local = time.truncatingRemainder(dividingBy: warpPeriod)
        guard local < warpLength else { return 0 }
        let wave = sin(.pi * local / warpLength)
        return wave * wave
    }

    /// Seconds traveled at cruising speed: the time, plus what the jumps so far added. Everything
    /// moves by this, so it all speeds up together in a jump.
    private static func distance(at time: Double) -> Double {
        let jumps = (time / warpPeriod).rounded(.down)
        let local = time - jumps * warpPeriod
        // The integral of sin² over a whole jump is half its length.
        let perJump = warpBoost * warpLength / 2
        var extra = jumps * perJump
        if local < warpLength {
            let progress = local / warpLength
            extra += warpBoost * warpLength * (progress / 2 - sin(2 * .pi * progress) / (4 * .pi))
        } else {
            extra += perJump
        }
        return time + extra
    }

    /// Something ahead, in perspective: `direction` (points from the middle of the view, where it
    /// would be at depth 0.06) spreads out from the middle as `depth` falls from 1 (far) toward 0
    /// (passing the window), and `spread` is how big it looks compared with at depth 0.06.
    private static func ahead(_ direction: CGPoint, depth: Double, size: CGSize) -> (point: CGPoint, spread: Double) {
        let spread = 0.06 / depth
        return (CGPoint(x: size.width / 2 + direction.x * spread, y: size.height * 0.45 + direction.y * spread), spread)
    }

    /// A direction toward the edge of the view, for something that passes the window.
    private static func edgeDirection(_ angle: Double, size: CGSize) -> CGPoint {
        CGPoint(x: cos(angle) * size.width * 0.42, y: sin(angle) * size.height * 0.45)
    }

    // MARK: Drawing

    /// The nebulas are so far away they hardly move; they only glow a little brighter and dimmer.
    private func drawNebulas(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        for (index, nebula) in Self.nebulas.enumerated() {
            let radius = nebula.radius * size.height * (1 + 0.04 * sin(time * 0.1 + Double(index)))
            let center = CGPoint(x: nebula.x * size.width, y: nebula.y * size.height)
            // A round glow, stretched wide.
            var squashed = canvas
            squashed.translateBy(x: center.x, y: center.y)
            squashed.scaleBy(x: 2, y: 1)
            squashed.translateBy(x: -center.x, y: -center.y)
            squashed.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                          with: .radialGradient(Gradient(colors: [nebula.color.opacity(0.12), nebula.color.opacity(0.04), .clear]),
                                                center: center, startRadius: 0, endRadius: radius))
        }
    }

    /// Flying into the stars: each fades in somewhere ahead and drifts out from the middle,
    /// speeding up and brightening as it nears, streaking out past the edge. In a jump they all
    /// stretch into long lines.
    private func drawStars(in canvas: inout GraphicsContext, size: CGSize, time: Double, travel: Double, warp: Double) {
        // About one star for every 5 points of width, so the wide notch isn't sparser.
        let count = min(Self.stars.count, Int(size.width / 5))
        let colors = [Color.white, Color(red: 0.75, green: 0.85, blue: 1), Color(red: 1, green: 0.88, blue: 0.7)]
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        // How far out a star is, compared with its direction: 0.3 far ahead, 2 passing the window.
        func spread(_ depth: Double) -> Double { 0.3 / depth }
        let lag = Self.starSpeed * 0.85 * (1 + Self.warpBoost * warp) * 0.12
        for star in Self.stars.prefix(count) {
            let cycle = (travel * Self.starSpeed + star.offset).truncatingRemainder(dividingBy: 1)
            let depth = 1 - cycle * 0.85
            let offset = CGPoint(x: cos(star.angle) * star.reach * size.width * 0.5, y: sin(star.angle) * star.reach * size.height * 0.5)
            let head = CGPoint(x: center.x + offset.x * spread(depth), y: center.y + offset.y * spread(depth))
            guard bounds.contains(head) else { continue }
            let back = spread(min(1, depth + lag))
            let tail = CGPoint(x: center.x + offset.x * back, y: center.y + offset.y * back)
            let nearness = cycle
            let twinkle = nearness < 0.4 ? 0.65 + 0.35 * sin(time * 1.7 + star.phase) : 1
            let opacity = min(1, nearness * 3) * twinkle * 0.85
            let width = star.size * (0.45 + nearness * 0.75)
            let color = colors[star.color < 6 ? 0 : star.color < 9 ? 1 : 2]
            if hypot(head.x - tail.x, head.y - tail.y) > 1 {
                var streak = Path()
                streak.move(to: tail)
                streak.addLine(to: head)
                canvas.stroke(streak, with: .linearGradient(Gradient(colors: [.clear, color.opacity(opacity * 0.8)]), startPoint: tail, endPoint: head),
                              style: StrokeStyle(lineWidth: width * 0.8, lineCap: .round))
            }
            canvas.fill(Path(ellipseIn: CGRect(x: head.x - width / 2, y: head.y - width / 2, width: width, height: width)), with: .color(color.opacity(opacity)))
        }
    }

    // MARK: Visitors

    /// What else comes by: one a leg, taking turns, so the view never gets crowded.
    private enum Visitor: Int, CaseIterable { case astronaut, rocket, satellite, comet }

    /// The leg's visit by `visitor`, if it's its turn and its time: how far along (0…1), a
    /// direction across from the planet, and a seed for its looks.
    private static func visit(_ visitor: Visitor, at time: Double, length: Double, size: CGSize) -> (progress: Double, direction: CGPoint, seed: UInt64)? {
        let leg = (time / warpPeriod).rounded(.down)
        let number = Int(leg)
        let turns = Visitor.allCases.count
        guard ((number % turns) + turns) % turns == visitor.rawValue else { return nil }
        // After the jump, once the planet is under way.
        let local = time - leg * warpPeriod - 8
        guard local >= 0, local < length else { return nil }
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(leg)) &* 9_973 &+ 41)
        // The planet slides out to the right on even legs, to the left on odd ones.
        let away = number.isMultiple(of: 2) ? Double.pi : 0
        let angle = away + .random(in: -0.8...0.8, using: &random)
        return (local / length, edgeDirection(angle, size: size), random.next())
    }

    /// Coming at the window from partway out, so it doesn't start on top of the planet.
    private static func approachDepth(_ progress: Double) -> Double {
        0.04 + 0.26 * pow(1 - progress, 1.3)
    }

    // MARK: The planets

    /// The planets visited one by one, from the Sun outward, then Mercury again.
    private enum Planet: Int, CaseIterable {
        case mercury, venus, earth, mars, jupiter, saturn, uranus, neptune, pluto

        /// How big it looks beside the others: not to scale, or Pluto would be a dot.
        var scale: Double {
            switch self {
            case .mercury: 0.6
            case .venus: 0.85
            case .earth: 0.9
            case .mars: 0.72
            case .jupiter: 1.35
            case .saturn: 1.1
            case .uranus: 1
            case .neptune: 1
            case .pluto: 0.5
            }
        }

        /// Lit, middle and dark.
        var palette: [Color] {
            switch self {
            case .mercury: [Color(white: 0.82), Color(white: 0.55), Color(white: 0.22)]
            case .venus: [Color(red: 1, green: 0.93, blue: 0.72), Color(red: 0.9, green: 0.72, blue: 0.42), Color(red: 0.42, green: 0.3, blue: 0.14)]
            case .earth: [Color(red: 0.45, green: 0.75, blue: 1), Color(red: 0.12, green: 0.4, blue: 0.85), Color(red: 0.03, green: 0.1, blue: 0.3)]
            case .mars: [Color(red: 1, green: 0.6, blue: 0.4), Color(red: 0.82, green: 0.33, blue: 0.18), Color(red: 0.32, green: 0.1, blue: 0.06)]
            case .jupiter: [Color(red: 1, green: 0.9, blue: 0.75), Color(red: 0.85, green: 0.62, blue: 0.42), Color(red: 0.38, green: 0.22, blue: 0.12)]
            case .saturn: [Color(red: 1, green: 0.93, blue: 0.7), Color(red: 0.88, green: 0.74, blue: 0.45), Color(red: 0.4, green: 0.3, blue: 0.14)]
            case .uranus: [Color(red: 0.78, green: 0.98, blue: 1), Color(red: 0.45, green: 0.82, blue: 0.88), Color(red: 0.12, green: 0.3, blue: 0.38)]
            case .neptune: [Color(red: 0.5, green: 0.7, blue: 1), Color(red: 0.2, green: 0.36, blue: 0.9), Color(red: 0.05, green: 0.08, blue: 0.35)]
            case .pluto: [Color(red: 0.95, green: 0.86, blue: 0.75), Color(red: 0.72, green: 0.58, blue: 0.45), Color(red: 0.28, green: 0.2, blue: 0.14)]
            }
        }

        var hasAtmosphere: Bool { [.venus, .earth, .uranus, .neptune].contains(self) }
    }

    /// One planet a leg (`warpPeriod`): after the jump to hyperspace it's far ahead, a dot, and
    /// grows as the ship flies toward it, faster and faster, until it slides
    /// past beside the window, like in the films. The next jump then heads for the next one.
    private func drawJourney(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let leg = (time / Self.warpPeriod).rounded(.down)
        let local = time - leg * Self.warpPeriod
        // It comes into view as the jump slows down.
        let arrival = Self.warpLength * 0.75
        guard local > arrival else { return }
        let progress = (local - arrival) / (Self.warpPeriod - arrival)
        let number = Int(leg)
        let planet = Planet.allCases[((number % 9) + 9) % 9]
        let side: Double = number.isMultiple(of: 2) ? 1 : -1
        // How far away it still is: 1 when it appears, almost 0 as it passes.
        let depth = 0.035 + 0.965 * pow(1 - progress, 1.6)
        let radius = size.height * 0.022 * planet.scale / depth
        let center = CGPoint(x: size.width * 0.5 + side * size.width * 0.021 / depth,
                             y: size.height * 0.45 + size.height * 0.011 / depth)
        canvas.drawLayer { layer in
            // Behind the tab's content, so not quite at full strength.
            layer.opacity = 0.9 * min(1, progress / 0.06)
            drawPlanet(planet, in: &layer, center: center, radius: radius, time: time)
        }
    }

    private func drawPlanet(_ planet: Planet, in canvas: inout GraphicsContext, center: CGPoint, radius: Double, time: Double) {
        let palette = planet.palette
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        // The glow of its atmosphere.
        let glow = radius * 1.3
        canvas.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                    with: .radialGradient(Gradient(stops: [.init(color: palette[0].opacity(planet.hasAtmosphere ? 0.4 : 0.15), location: 0.72),
                                                           .init(color: .clear, location: 1)]),
                                          center: center, startRadius: 0, endRadius: glow))

        let saturnRings: [(Double, Double, Double)] = [(1.35, 0.05, 0.45), (1.6, 0.14, 0.8), (1.86, 0.07, 0.5), (2.05, 0.035, 0.35)]
        let uranusRings: [(Double, Double, Double)] = [(1.5, 0.015, 0.4), (1.7, 0.02, 0.5)]
        if planet == .saturn {
            drawRings(in: &canvas, center: center, radius: radius, tilt: -0.32, rings: saturnRings, color: palette[0], front: false)
        } else if planet == .uranus {
            drawRings(in: &canvas, center: center, radius: radius, tilt: -1.35, rings: uranusRings, color: palette[0], front: false)
        }

        // The ball, lit from the upper left.
        let light = CGPoint(x: center.x - radius * 0.4, y: center.y - radius * 0.4)
        canvas.fill(disc, with: .radialGradient(Gradient(colors: palette), center: light, startRadius: 0, endRadius: radius * 1.7))

        var surface = canvas
        surface.clip(to: disc)
        var random = SeededRandom(seed: UInt64(planet.rawValue) &* 2_654_435_761 &+ 97)
        func ellipse(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x + (x - width / 2) * radius, y: center.y + (y - height / 2) * radius,
                                   width: width * radius, height: height * radius))
        }
        func bands(_ count: Int, colors: [Color], opacity: Double) {
            for index in 0..<count {
                let y = -1 + (Double(index) + 0.5) * 2 / Double(count)
                let height = Double.random(in: 0.1...0.24, using: &random)
                let drift = sin(time * 0.3 + Double(index)) * 0.04
                surface.fill(ellipse(drift, y, 2.6, height), with: .color(colors[index % colors.count].opacity(opacity)))
            }
        }
        func craters(_ count: Int, dark: Color, rim: Color) {
            for _ in 0..<count {
                let size = Double.random(in: 0.1...0.26, using: &random)
                let x = Double.random(in: -0.75...0.75, using: &random), y = Double.random(in: -0.75...0.75, using: &random)
                surface.fill(ellipse(x, y, size, size), with: .color(dark.opacity(0.35)))
                surface.stroke(ellipse(x - 0.02, y - 0.02, size, size), with: .color(rim.opacity(0.3)), lineWidth: max(0.5, radius * 0.015))
            }
        }
        // Lands and clouds that turn with the planet, flattening toward its edge.
        func turning(_ spots: [(lon: Double, lat: Double, width: Double, height: Double)], speed: Double, color: Color, opacity: Double) {
            for spot in spots {
                let angle = (spot.lon + time * speed).truncatingRemainder(dividingBy: 2 * .pi) - .pi
                guard abs(angle) < .pi / 2 + 0.3 else { continue }
                let squash = max(0.15, cos(angle))
                surface.fill(ellipse(sin(angle), spot.lat, spot.width * squash, spot.height), with: .color(color.opacity(opacity)))
            }
        }

        switch planet {
        case .mercury:
            craters(12, dark: palette[2], rim: palette[0])
        case .venus:
            bands(6, colors: [palette[0], palette[1]], opacity: 0.25)
        case .earth:
            let lands: [(Double, Double, Double, Double)] = [(0, -0.25, 0.55, 0.5), (0.4, 0.3, 0.35, 0.55), (1.9, -0.35, 0.6, 0.35),
                                                              (2.7, 0.25, 0.42, 0.5), (4.1, 0.05, 0.5, 0.6), (5.1, -0.2, 0.35, 0.4)]
            turning(lands.map { ($0.0, $0.1, $0.2, $0.3) }, speed: 0.08, color: Color(red: 0.25, green: 0.6, blue: 0.3), opacity: 0.9)
            turning(lands.map { ($0.0 + 0.1, $0.1 + 0.08, $0.2 * 0.5, $0.3 * 0.4) }, speed: 0.08, color: Color(red: 0.6, green: 0.5, blue: 0.3), opacity: 0.7)
            let clouds: [(Double, Double, Double, Double)] = [(0.5, -0.5, 0.9, 0.1), (1.6, 0.1, 0.7, 0.08), (2.9, -0.1, 1, 0.1), (3.8, 0.55, 0.8, 0.09), (5.3, 0.35, 0.6, 0.1)]
            turning(clouds.map { ($0.0, $0.1, $0.2, $0.3) }, speed: 0.12, color: .white, opacity: 0.6)
            surface.fill(ellipse(0, -1.02, 1.1, 0.35), with: .color(.white.opacity(0.85)))
            surface.fill(ellipse(0, 1.02, 1, 0.3), with: .color(.white.opacity(0.8)))
        case .mars:
            let plains: [(Double, Double, Double, Double)] = [(0.3, 0.1, 0.6, 0.35), (2.2, -0.25, 0.5, 0.3), (4, 0.3, 0.7, 0.25)]
            turning(plains.map { ($0.0, $0.1, $0.2, $0.3) }, speed: 0.07, color: palette[2], opacity: 0.35)
            craters(6, dark: palette[2], rim: palette[0])
            surface.fill(ellipse(0, -1, 0.7, 0.28), with: .color(.white.opacity(0.85)))
        case .jupiter:
            bands(10, colors: [palette[2], palette[0], palette[1], Color.white], opacity: 0.32)
            // The Great Red Spot, turning with the planet.
            let spot = (0.6 + time * 0.06).truncatingRemainder(dividingBy: 2 * .pi) - .pi
            if abs(spot) < .pi / 2 {
                let squash = cos(spot)
                surface.fill(ellipse(sin(spot) * 0.95, 0.35, 0.42 * squash, 0.24), with: .color(Color(red: 0.8, green: 0.32, blue: 0.2).opacity(0.85)))
                surface.stroke(ellipse(sin(spot) * 0.95, 0.35, 0.42 * squash, 0.24), with: .color(palette[0].opacity(0.6)), lineWidth: max(0.6, radius * 0.02))
            }
        case .saturn:
            bands(7, colors: [palette[0], palette[1]], opacity: 0.3)
        case .uranus:
            bands(4, colors: [palette[0]], opacity: 0.12)
        case .neptune:
            bands(6, colors: [palette[0], palette[2]], opacity: 0.22)
            surface.fill(ellipse(-0.2, 0.25, 0.32, 0.16), with: .color(palette[2].opacity(0.75)))
            surface.fill(ellipse(0.15, -0.35, 0.3, 0.05), with: .color(.white.opacity(0.6)))
        case .pluto:
            craters(5, dark: palette[2], rim: palette[0])
            // Its pale heart.
            surface.fill(ellipse(0.02, 0.18, 0.42, 0.42), with: .color(Color(white: 0.97).opacity(0.85)))
            surface.fill(ellipse(0.32, 0.12, 0.36, 0.38), with: .color(Color(white: 0.97).opacity(0.85)))
            var tip = Path()
            tip.move(to: CGPoint(x: center.x - radius * 0.16, y: center.y + radius * 0.3))
            tip.addLine(to: CGPoint(x: center.x + radius * 0.5, y: center.y + radius * 0.24))
            tip.addLine(to: CGPoint(x: center.x + radius * 0.22, y: center.y + radius * 0.65))
            tip.closeSubpath()
            surface.fill(tip, with: .color(Color(white: 0.97).opacity(0.85)))
        }
        // Night over the far side.
        surface.fill(disc, with: .linearGradient(Gradient(stops: [.init(color: .clear, location: 0.42), .init(color: .black.opacity(0.78), location: 1)]),
                                                 startPoint: light, endPoint: CGPoint(x: center.x + radius, y: center.y + radius)))

        if planet == .saturn {
            drawRings(in: &canvas, center: center, radius: radius, tilt: -0.32, rings: saturnRings, color: palette[0], front: true)
        } else if planet == .uranus {
            drawRings(in: &canvas, center: center, radius: radius, tilt: -1.35, rings: uranusRings, color: palette[0], front: true)
        } else if planet == .earth {
            // The Moon, off to the side.
            let moon = CGPoint(x: center.x + radius * 1.7, y: center.y - radius * 0.9)
            let moonRadius = radius * 0.27
            let moonDisc = Path(ellipseIn: CGRect(x: moon.x - moonRadius, y: moon.y - moonRadius, width: moonRadius * 2, height: moonRadius * 2))
            canvas.fill(moonDisc, with: .radialGradient(Gradient(colors: [Color(white: 0.92), Color(white: 0.6), Color(white: 0.2)]),
                                                        center: CGPoint(x: moon.x - moonRadius * 0.4, y: moon.y - moonRadius * 0.4),
                                                        startRadius: 0, endRadius: moonRadius * 1.7))
        }
    }

    /// Rings, tilted: the back half goes behind the planet, the front half over it. Each ring is
    /// (distance, width, opacity), the first two in the planet's radius.
    private func drawRings(in canvas: inout GraphicsContext, center: CGPoint, radius: Double, tilt: Double,
                           rings: [(Double, Double, Double)], color: Color, front: Bool) {
        var context = canvas
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .radians(tilt))
        // In the rings' own coordinates the front half is the lower one.
        context.clip(to: Path(CGRect(x: -radius * 3, y: front ? 0 : -radius * 3, width: radius * 6, height: radius * 3)))
        for (distance, width, opacity) in rings {
            let rx = radius * distance, ry = rx * 0.24
            context.stroke(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)),
                           with: .color(color.opacity(opacity * (front ? 1 : 0.7))), lineWidth: max(0.6, radius * width))
        }
    }

    /// On its leg, a satellite coming at the window and turning slowly as the ship passes it: a
    /// gold body, two blue solar panels, a dish and an antenna with a blinking red light.
    private func drawSatellite(in canvas: inout GraphicsContext, size: CGSize, time: Double, travel: Double) {
        guard let visit = Self.visit(.satellite, at: time, length: 14, size: size) else { return }
        var random = SeededRandom(seed: visit.seed)
        let (point, spread) = Self.ahead(visit.direction, depth: Self.approachDepth(visit.progress), size: size)
        let spin = Double.random(in: -0.3...0.3, using: &random)
        let turn = Double.random(in: 0...6, using: &random)
        let scale = size.height / 180 * spread * 1.1

        var body = canvas
        body.opacity = 0.9 * min(1, visit.progress * 8)
        body.translateBy(x: point.x, y: point.y)
        body.scaleBy(x: scale, y: scale)
        body.rotate(by: .radians(time * spin + turn))

        let gold = Color(red: 0.95, green: 0.78, blue: 0.35)
        let panelBlue = Color(red: 0.2, green: 0.38, blue: 0.85)
        // The struts and the panels on each side, with their cells.
        var strut = Path()
        strut.move(to: CGPoint(x: -24, y: 0))
        strut.addLine(to: CGPoint(x: 24, y: 0))
        body.stroke(strut, with: .color(Color(white: 0.7)), lineWidth: 1)
        for side in [-1.0, 1.0] {
            let panel = CGRect(x: side < 0 ? -36 : 12, y: -5, width: 24, height: 10)
            body.fill(Path(roundedRect: panel, cornerRadius: 1),
                      with: .linearGradient(Gradient(colors: [panelBlue.opacity(0.95), Color(red: 0.1, green: 0.18, blue: 0.5)]),
                                            startPoint: CGPoint(x: panel.minX, y: panel.minY), endPoint: CGPoint(x: panel.maxX, y: panel.maxY)))
            var cells = Path()
            for step in 1..<4 {
                let cellX = panel.minX + panel.width * Double(step) / 4
                cells.move(to: CGPoint(x: cellX, y: panel.minY))
                cells.addLine(to: CGPoint(x: cellX, y: panel.maxY))
            }
            cells.move(to: CGPoint(x: panel.minX, y: panel.midY))
            cells.addLine(to: CGPoint(x: panel.maxX, y: panel.midY))
            body.stroke(cells, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            body.stroke(Path(roundedRect: panel, cornerRadius: 1), with: .color(Color(white: 0.75).opacity(0.7)), lineWidth: 0.6)
        }
        // The body in gold foil.
        let box = CGRect(x: -7, y: -6, width: 14, height: 12)
        body.fill(Path(roundedRect: box, cornerRadius: 1.5),
                  with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.92, blue: 0.6), gold, Color(red: 0.55, green: 0.38, blue: 0.1)]),
                                        startPoint: CGPoint(x: box.minX, y: box.minY), endPoint: CGPoint(x: box.maxX, y: box.maxY)))
        var foil = Path()
        foil.move(to: CGPoint(x: box.minX, y: box.midY))
        foil.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        body.stroke(foil, with: .color(Color(red: 0.55, green: 0.38, blue: 0.1).opacity(0.6)), lineWidth: 0.5)
        // The dish on top and the antenna below.
        var dish = Path()
        dish.addArc(center: CGPoint(x: 0, y: -9), radius: 5, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
        body.stroke(dish, with: .color(Color(white: 0.92)), lineWidth: 1.4)
        var mast = Path()
        mast.move(to: CGPoint(x: 0, y: -6))
        mast.addLine(to: CGPoint(x: 0, y: -10))
        mast.move(to: CGPoint(x: 2, y: 6))
        mast.addLine(to: CGPoint(x: 4, y: 13))
        body.stroke(mast, with: .color(Color(white: 0.8)), lineWidth: 0.7)
        let blink = sin(time * 3.5) > 0.55
        let light = CGPoint(x: 4, y: 13.5)
        body.fill(Path(ellipseIn: CGRect(x: light.x - 1.3, y: light.y - 1.3, width: 2.6, height: 2.6)),
                  with: .color(blink ? Color(red: 1, green: 0.25, blue: 0.25) : Color(red: 0.4, green: 0.1, blue: 0.1)))
        if blink {
            body.fill(Path(ellipseIn: CGRect(x: light.x - 4, y: light.y - 4, width: 8, height: 8)),
                      with: .radialGradient(Gradient(colors: [Color.red.opacity(0.5), .clear]), center: light, startRadius: 0, endRadius: 4))
        }
    }

    /// On its leg, a comet far ahead, coming slowly nearer, its tail pointing away from the Sun.
    private func drawComet(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        guard let visit = Self.visit(.comet, at: time, length: 16, size: size) else { return }
        var random = SeededRandom(seed: visit.seed)
        let progress = visit.progress
        let (head, spread) = Self.ahead(visit.direction, depth: Self.approachDepth(progress), size: size)
        let away = Double.random(in: -2.6 ... -2.2, using: &random)
        let tailLength = 15 + 45 * spread
        let tail = CGPoint(x: head.x + cos(away) * tailLength, y: head.y + sin(away) * tailLength)
        let fade = min(1, progress * 6) * min(1, (1 - progress) * 8)
        drawStreak(in: &canvas, tail: tail, head: head, color: Color(red: 0.7, green: 0.9, blue: 1),
                   width: 1 + 2 * spread, glow: 2.5 + 4 * spread, opacity: fade)
    }

    /// On its leg, an astronaut floating ahead, turning slowly head over heels and waving as the
    /// ship passes: a white suit with a backpack, and a gold visor that catches the light.
    private func drawAstronaut(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        guard let visit = Self.visit(.astronaut, at: time, length: 16, size: size) else { return }
        var random = SeededRandom(seed: visit.seed)
        let local = visit.progress * 16
        let (point, spread) = Self.ahead(visit.direction, depth: Self.approachDepth(visit.progress), size: size)
        let spin = Double.random(in: 0.12...0.25, using: &random) * (Bool.random(using: &random) ? 1 : -1)
        let scale = size.height / 180 * spread * 1.1

        var body = canvas
        body.opacity = 0.92 * min(1, visit.progress * 8)
        body.translateBy(x: point.x, y: point.y)
        body.scaleBy(x: scale, y: scale)
        body.rotate(by: .radians(local * spin + .random(in: 0...6, using: &random)))

        let suit = Color(white: 0.95)
        let shade = Color(white: 0.7)
        func limb(_ from: CGPoint, _ to: CGPoint, width: Double, color: Color) {
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            body.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        // The backpack behind.
        body.fill(Path(roundedRect: CGRect(x: -9.5, y: -6, width: 19, height: 19), cornerRadius: 3), with: .color(shade))
        // Legs, kicking a little, with grey boots.
        let kick = sin(time * 1.3) * 2
        limb(CGPoint(x: -3.5, y: 12), CGPoint(x: -5 - kick, y: 24), width: 5.5, color: suit)
        limb(CGPoint(x: 3.5, y: 12), CGPoint(x: 6 + kick, y: 23), width: 5.5, color: suit)
        limb(CGPoint(x: -5 - kick, y: 24), CGPoint(x: -5.5 - kick, y: 26), width: 6, color: Color(white: 0.5))
        limb(CGPoint(x: 6 + kick, y: 23), CGPoint(x: 6.5 + kick, y: 25), width: 6, color: Color(white: 0.5))
        // The body with its chest panel.
        body.fill(Path(roundedRect: CGRect(x: -8, y: -4, width: 16, height: 18), cornerRadius: 5),
                  with: .linearGradient(Gradient(colors: [.white, suit, shade]), startPoint: CGPoint(x: -8, y: -4), endPoint: CGPoint(x: 8, y: 14)))
        body.fill(Path(roundedRect: CGRect(x: -4, y: 2, width: 8, height: 5), cornerRadius: 1), with: .color(Color(white: 0.55)))
        body.fill(Path(ellipseIn: CGRect(x: -2.8, y: 3.3, width: 2, height: 2)), with: .color(.red))
        body.fill(Path(ellipseIn: CGRect(x: 0.8, y: 3.3, width: 2, height: 2)), with: .color(Color(red: 0.3, green: 0.6, blue: 1)))
        // One arm floating, the other waving.
        limb(CGPoint(x: -7, y: 0), CGPoint(x: -14, y: 8), width: 5, color: suit)
        let wave = sin(time * 4) * 0.5 - 0.9
        let hand = CGPoint(x: 7 + cos(wave) * 10, y: sin(wave) * 10)
        limb(CGPoint(x: 7, y: 0), hand, width: 5, color: suit)
        body.fill(Path(ellipseIn: CGRect(x: hand.x - 3, y: hand.y - 3, width: 6, height: 6)), with: .color(shade))
        body.fill(Path(ellipseIn: CGRect(x: -17, y: 5.5, width: 6, height: 6)), with: .color(shade))
        // The helmet and its gold visor with a shine.
        body.fill(Path(ellipseIn: CGRect(x: -8.5, y: -20, width: 17, height: 17)), with: .color(suit))
        let visor = CGRect(x: -6, y: -17, width: 12, height: 10)
        body.fill(Path(roundedRect: visor, cornerRadius: 4.5),
                  with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.4), Color(red: 0.8, green: 0.45, blue: 0.1), Color(red: 0.25, green: 0.12, blue: 0.05)]),
                                        startPoint: CGPoint(x: visor.minX, y: visor.minY), endPoint: CGPoint(x: visor.maxX, y: visor.maxY)))
        body.fill(Path(ellipseIn: CGRect(x: -4.5, y: -15.5, width: 3.5, height: 2.2)), with: .color(.white.opacity(0.8)))
    }

    /// On its leg, a rocket overtaking the ship: close beside the window first, then flying on
    /// ahead and shrinking into the distance, its flame flickering and exhaust left behind.
    private func drawRocket(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        guard let visit = Self.visit(.rocket, at: time, length: 7, size: size) else { return }
        let direction = visit.direction
        // Beside the window first, then flying on ahead, not as far as the planet.
        func place(_ progress: Double) -> (point: CGPoint, spread: Double) {
            Self.ahead(direction, depth: 0.05 + 0.3 * pow(progress, 1.4), size: size)
        }
        let progress = visit.progress
        let (head, spread) = place(progress)
        let unit = size.height / 180

        // Puffs of exhaust left behind, nearer the window, growing and fading.
        for index in 1...16 {
            let behind = progress - Double(index) * 0.012
            guard behind > 0 else { break }
            let (puff, puffSpread) = place(behind)
            let radius = (1.5 + Double(index) * 0.5) * puffSpread * unit
            canvas.fill(Path(ellipseIn: CGRect(x: puff.x - radius, y: puff.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(Color(white: 0.85).opacity(0.18 * (1 - Double(index) / 17))))
        }

        // Pointed at the distance ahead, the flame toward the window.
        let vanishing = CGPoint(x: size.width / 2, y: size.height * 0.45)
        var rocket = canvas
        rocket.opacity = min(1, (1 - progress) * 5)
        rocket.translateBy(x: head.x, y: head.y)
        rocket.rotate(by: .radians(atan2(vanishing.y - head.y, vanishing.x - head.x)))
        rocket.scaleBy(x: unit * spread * 1.4, y: unit * spread * 1.4)
        // The flame, flickering.
        let flicker = 0.85 + 0.15 * sin(time * 41) + 0.1 * sin(time * 23)
        var flame = Path()
        flame.move(to: CGPoint(x: -11, y: -3.5))
        flame.addQuadCurve(to: CGPoint(x: -11 - 14 * flicker, y: 0), control: CGPoint(x: -15, y: -3))
        flame.addQuadCurve(to: CGPoint(x: -11, y: 3.5), control: CGPoint(x: -15, y: 3))
        flame.closeSubpath()
        rocket.fill(flame, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.6), .orange, Color.red.opacity(0)]),
                                                 startPoint: CGPoint(x: -11, y: 0), endPoint: CGPoint(x: -11 - 14 * flicker, y: 0)))
        // Fins, the body, the red nose and a round window.
        let red = Color(red: 0.92, green: 0.22, blue: 0.2)
        for sign in [-1.0, 1.0] {
            var fin = Path()
            fin.move(to: CGPoint(x: -10, y: 3.5 * sign))
            fin.addLine(to: CGPoint(x: -3, y: 3.5 * sign))
            fin.addLine(to: CGPoint(x: -13, y: 9 * sign))
            fin.closeSubpath()
            rocket.fill(fin, with: .color(red))
        }
        rocket.fill(Path(roundedRect: CGRect(x: -11, y: -4.2, width: 21, height: 8.4), cornerRadius: 3),
                    with: .linearGradient(Gradient(colors: [.white, Color(white: 0.85), Color(white: 0.55)]),
                                          startPoint: CGPoint(x: 0, y: -4.2), endPoint: CGPoint(x: 0, y: 4.2)))
        var nose = Path()
        nose.move(to: CGPoint(x: 9, y: -4.2))
        nose.addQuadCurve(to: CGPoint(x: 19, y: 0), control: CGPoint(x: 16, y: -4))
        nose.addQuadCurve(to: CGPoint(x: 9, y: 4.2), control: CGPoint(x: 16, y: 4))
        nose.closeSubpath()
        rocket.fill(nose, with: .color(red))
        rocket.fill(Path(ellipseIn: CGRect(x: 0, y: -2.4, width: 4.8, height: 4.8)), with: .color(Color(red: 0.4, green: 0.75, blue: 1)))
        rocket.stroke(Path(ellipseIn: CGRect(x: 0, y: -2.4, width: 4.8, height: 4.8)), with: .color(Color(white: 0.6)), lineWidth: 0.8)
    }

    /// Rocks tumbling ahead, coming at the window and passing it, bigger as they near.
    private func drawAsteroids(in canvas: inout GraphicsContext, size: CGSize, time: Double, travel: Double) {
        let count = max(2, Int(size.width / 220))
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -30, dy: -30)
        for index in 0..<count {
            var random = SeededRandom(seed: UInt64(index) &* 7_777 &+ 99)
            let angle = Double.random(in: 0...(2 * .pi), using: &random)
            let direction = CGPoint(x: cos(angle) * size.width * .random(in: 0.25...0.45, using: &random),
                                    y: sin(angle) * size.height * .random(in: 0.3...0.5, using: &random))
            let cycle = (travel * 0.03 + .random(in: 0...1, using: &random)).truncatingRemainder(dividingBy: 1)
            let depth = 1 - cycle * 0.97
            let (center, spread) = Self.ahead(direction, depth: depth, size: size)
            let spin = Double.random(in: -1.3...1.3, using: &random)
            let radius = Double.random(in: 3...6, using: &random) * spread * size.height / 180
            guard bounds.contains(center), radius > 0.6 else { continue }
            // A lumpy outline, the same for each rock.
            var rock = Path()
            let corners = 9
            for corner in 0..<corners {
                let turn = Double(corner) / Double(corners) * 2 * .pi + time * spin
                let reach = radius * .random(in: 0.7...1.1, using: &random)
                let point = CGPoint(x: center.x + cos(turn) * reach, y: center.y + sin(turn) * reach)
                if corner == 0 { rock.move(to: point) } else { rock.addLine(to: point) }
            }
            rock.closeSubpath()
            let opacity = min(1, (1 - depth) * 2.5)
            canvas.fill(rock, with: .linearGradient(Gradient(colors: [Color(red: 0.7, green: 0.62, blue: 0.55).opacity(opacity), Color(red: 0.25, green: 0.2, blue: 0.18).opacity(opacity)]),
                                                    startPoint: CGPoint(x: center.x - radius, y: center.y - radius), endPoint: CGPoint(x: center.x + radius, y: center.y + radius)))
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius * 0.3, y: center.y - radius * 0.1, width: radius * 0.35, height: radius * 0.35)),
                        with: .color(Color(white: 0.15).opacity(0.5 * opacity)))
        }
    }

    /// A streak with a glowing head, from `tail` to `head`.
    private func drawStreak(in canvas: inout GraphicsContext, tail: CGPoint, head: CGPoint, color: Color, width: Double, glow: Double, opacity: Double) {
        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        canvas.stroke(streak, with: .linearGradient(Gradient(colors: [.clear, color.opacity(0.8 * opacity)]), startPoint: tail, endPoint: head),
                      style: StrokeStyle(lineWidth: width, lineCap: .round))
        canvas.fill(Path(ellipseIn: CGRect(x: head.x - glow, y: head.y - glow, width: glow * 2, height: glow * 2)),
                    with: .radialGradient(Gradient(colors: [Color.white.opacity(0.95 * opacity), color.opacity(0.4 * opacity), .clear]),
                                          center: head, startRadius: 0, endRadius: glow))
    }

    /// Shooting stars: quick thin streaks, one every few seconds somewhere in the window.
    private func drawShootingStars(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let period = 7.0, length = 0.7
        let round = (time / period).rounded(.down)
        let local = time - round * period
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(round)) &* 16_807 &+ 3)
        guard Double.random(in: 0...1, using: &random) < 0.5, local < length else { return }
        let progress = local / length
        let start = CGPoint(x: size.width * .random(in: 0.1...1, using: &random), y: size.height * .random(in: 0...0.5, using: &random))
        let angle = Double.random(in: 0.65...0.85, using: &random) * .pi
        let reach = Double.random(in: 60...120, using: &random)
        let head = CGPoint(x: start.x + cos(angle) * reach * progress, y: start.y + sin(angle) * reach * progress)
        let tailLength = 35 * min(1, progress * 4)
        let tail = CGPoint(x: head.x - cos(angle) * tailLength, y: head.y - sin(angle) * tailLength)
        drawStreak(in: &canvas, tail: tail, head: head, color: .white, width: 1.2, glow: 3, opacity: sin(.pi * progress))
    }

    /// Now and then a meteor: a fireball out of the distance, rushing past the window with a fiery
    /// tail and sparks.
    private func drawMeteor(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let leg = (time / Self.warpPeriod).rounded(.down)
        let local = time - leg * Self.warpPeriod - 25
        guard !Int(leg).isMultiple(of: 2), local >= 0, local < 1.6 else { return }
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(leg)) &* 2_147_483_629 &+ 11)
        let progress = local / 1.6
        // Across from the planet, which slides out to the left on odd legs.
        let direction = Self.edgeDirection(.random(in: -0.8...0.8, using: &random), size: size)
        let depth = 0.04 + 0.3 * pow(1 - progress, 1.4)
        let (head, spread) = Self.ahead(direction, depth: depth, size: size)
        let tail = Self.ahead(direction, depth: depth + 0.12, size: size).point
        let fade = min(1, progress * 5)
        let fire = Color(red: 1, green: 0.55, blue: 0.15)
        drawStreak(in: &canvas, tail: tail, head: head, color: fire, width: 1 + 1.5 * spread, glow: 2 + 4 * spread, opacity: fade)
        // Sparks falling off the tail.
        for index in 0..<6 {
            let along = Double(index + 1) / 7
            let flick = sin(time * 30 + Double(index) * 2)
            let spark = CGPoint(x: head.x + (tail.x - head.x) * along + flick * 2, y: head.y + (tail.y - head.y) * along + flick)
            canvas.fill(Path(ellipseIn: CGRect(x: spark.x - 0.8, y: spark.y - 0.8, width: 1.6, height: 1.6)),
                        with: .color(Color(red: 1, green: 0.85, blue: 0.4).opacity(fade * (1 - along) * 0.9)))
        }
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
