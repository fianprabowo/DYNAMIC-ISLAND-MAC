import AppKit
import Combine
import SwiftUI

// Playful touches, each turned on or off in the gear menu's Animations: a lively little face beside
// the notch, a shake and a little weather when a friend pokes, and a bouncier notch.

// MARK: - Eyes beside the notch

/// What the face beside the notch feels: surprised for a moment after a friend's poke, grinning
/// while the pointer comes near, glancing at the badge when a notification comes in, drowsy and
/// then asleep without any input. It only watches the pointer and the idle time while the face is
/// on screen, and publishes only changes.
final class FaceMood: ObservableObject {
    static let shared = FaceMood()

    @Published private(set) var isSurprised = false
    @Published private(set) var isPointerNear = false
    @Published private(set) var isDrowsy = false
    @Published private(set) var isAsleep = false
    @Published private(set) var isLookingAtBadge = false
    /// While the pointer is near, which way it is from the face, -1 (left) to 1 (right), in half
    /// steps, so the eyes follow it without a change on every move.
    @Published private(set) var pointerSide: CGFloat = 0

    /// No keyboard or mouse for this long, and the face gets drowsy, then falls asleep.
    private let drowsyAfter: TimeInterval = 60
    private let sleepAfter: TimeInterval = 120
    /// How long the face stays surprised after a poke, the poke's banner included.
    private let surpriseDuration: TimeInterval = 6
    private var surpriseTask: Task<Void, Never>?
    private var badgeTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var idleTimer: Timer?
    private var watchers = 0
    private var nearRect = CGRect.zero
    /// Where the face is across the screen, in the left wing.
    private var faceX: CGFloat = 0

    func surprise() {
        surpriseTask?.cancel()
        isSurprised = true
        wake()
        surpriseTask = Task { [weak self, surpriseDuration] in
            try? await Task.sleep(for: .seconds(surpriseDuration))
            guard !Task.isCancelled else { return }
            self?.isSurprised = false
        }
    }

    /// A notification came in: a look at its number on the right.
    func lookAtBadge() {
        badgeTask?.cancel()
        isLookingAtBadge = true
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isLookingAtBadge = false
        }
    }

    /// `notchSize` places the area around the notch where the pointer counts as near.
    func startWatching(notchSize: CGSize) {
        watchers += 1
        if let screen = IslandLayout.notchScreen {
            // The island with its wings, and 90 points either side and 70 below it.
            let width = notchSize.width + IslandLayout.notchWing * 2 + 180
            let height = notchSize.height + 70
            nearRect = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
            faceX = screen.frame.midX - notchSize.width / 2 - IslandLayout.notchWing / 2
        }
        guard monitors.isEmpty else { return }
        pointerMoved()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(monitor)
        }
        checkIdle()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Publishes only when the pointer crosses into or out of the area, not on every move.
    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        let near = nearRect.contains(location)
        if near != isPointerNear {
            isPointerNear = near
        }
        if near {
            let side = ((max(-1, min(1, (location.x - faceX) / 80))) * 2).rounded() / 2
            if side != pointerSide {
                pointerSide = side
            }
        }
        wake()
    }

    private func wake() {
        if isDrowsy { isDrowsy = false }
        if isAsleep { isAsleep = false }
    }

    private func checkIdle() {
        // Any input at all: keys, the pointer, the trackpad.
        guard let anyInput = CGEventType(rawValue: ~0), !isSurprised else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let asleep = idle >= sleepAfter
        let drowsy = !asleep && idle >= drowsyAfter
        if asleep != isAsleep { isAsleep = asleep }
        if drowsy != isDrowsy { isDrowsy = drowsy }
    }
}

/// A little face beside the notch. It breathes, blinks (now and then twice, or a wink), glances
/// around, and every so often yawns, looks around, hums or hops; it reacts to `FaceMood`. The
/// mouth only shows with an expression: at rest it's two dots.
struct NotchEyes: View {
    @EnvironmentObject var layout: IslandLayout
    @ObservedObject private var mood = FaceMood.shared
    @State private var isLeftClosed = false
    @State private var isRightClosed = false
    /// Where the eyes look sideways, -1 (left) to 1 (right).
    @State private var look: CGFloat = 0
    @State private var action: Action?
    @State private var isBreathingIn = false
    @State private var isYawnOpen = false
    @State private var hop: CGFloat = 0
    @State private var sway: Double = 0
    /// The snowman's right arm, waving while the pointer is near.
    @State private var wave: Double = 0

    private let size: CGFloat = 7
    private let gap: CGFloat = 5
    /// How far the eyes move when they look aside.
    private let reach: CGFloat = 1.8
    private let color = Color(red: 0.36, green: 0.45, blue: 0.96)

    private enum Action { case yawn, lookAround, hum, hop }
    private enum Expression { case calm, grinning, surprised, yawning, humming, happy, drowsy, asleep }

    private var expression: Expression {
        if mood.isSurprised { return .surprised }
        if mood.isAsleep { return .asleep }
        if action == .yawn { return .yawning }
        if mood.isPointerNear { return .grinning }
        if action == .hum { return .humming }
        if action == .hop { return .happy }
        if mood.isDrowsy { return .drowsy }
        return .calm
    }

    /// Late at night the eyes look a little heavy.
    private var isLateNight: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 23 || hour < 5
    }

    /// Free for a glance or an action: awake, not reacting to anything.
    private var isIdle: Bool {
        action == nil && !mood.isSurprised && !mood.isAsleep && !mood.isLookingAtBadge
    }

    /// Where the eyes look, -1 to 1: at the badge, at the pointer while it's near, or around.
    private var gaze: CGFloat {
        if mood.isAsleep { return 0 }
        if mood.isLookingAtBadge { return 1 }
        if mood.isPointerNear { return mood.pointerSide }
        return look
    }

    var body: some View {
        let expression = expression
        let gaze = gaze
        Group {
            if layout.christmas {
                snowman(expression, gaze: gaze)
            } else {
                ZStack {
                    HStack(spacing: gap) {
                        eye(expression, closed: isLeftClosed)
                        eye(expression, closed: isRightClosed)
                    }
                    .offset(x: gaze * reach)
                    mouth(expression)
                        .offset(y: 8)
                }
                .frame(width: 26, height: 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if expression == .asleep {
                SleepyZ(color: accent).offset(x: 6, y: -2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if expression == .humming {
                FloatingNote(color: accent).offset(x: 7, y: -1)
            }
        }
        .rotationEffect(.degrees(sway), anchor: .bottom)
        .offset(y: hop + (isBreathingIn ? -0.7 : 0.5))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: expression)
        .animation(.easeInOut(duration: 0.25), value: gaze)
        .onAppear { mood.startWatching(notchSize: layout.notchSize) }
        .onDisappear { mood.stopWatching() }
        .task { await breathe() }
        .task { await blink() }
        .task { await glance() }
        .task { await act() }
        .task(id: layout.christmas && mood.isPointerNear && !mood.isAsleep) { await waveWhileNear() }
        .allowsHitTesting(false)
    }

    /// The z and the note: white beside the snowman.
    private var accent: Color {
        layout.christmas ? .white : color
    }

    // MARK: Snowman

    /// At Christmas the face is a snowman's: coal eyes and mouth on a snowball, a carrot nose that
    /// turns where he looks, a top hat that jumps when he's surprised and slips when he's sleepy,
    /// a red scarf, and a stick arm that waves at the pointer.
    private func snowman(_ expression: Expression, gaze: CGFloat) -> some View {
        let snow = Color(white: 0.95)
        let coal = Color(white: 0.1)
        let red = Color(red: 0.9, green: 0.16, blue: 0.2)
        let stick = Color(red: 0.62, green: 0.42, blue: 0.25)
        let hatLift: CGFloat = expression == .surprised ? -4 : 0
        let hatTilt: Double = expression == .asleep ? -18 : expression == .drowsy ? -9 : 0
        return ZStack(alignment: .top) {
            // Arms behind the body: the left one still, the right one waving.
            Capsule()
                .fill(stick)
                .frame(width: 7, height: 1.4)
                .rotationEffect(.degrees(25), anchor: .trailing)
                .offset(x: -8, y: 19)
            Capsule()
                .fill(stick)
                .frame(width: 7, height: 1.4)
                .rotationEffect(.degrees(-25 + wave), anchor: .leading)
                .offset(x: 8, y: 19)
            // The body with two coal buttons.
            Circle()
                .fill(snow)
                .frame(width: 14, height: 14)
                .offset(y: 15)
            VStack(spacing: 2.4) {
                Circle().fill(coal).frame(width: 1.6, height: 1.6)
                Circle().fill(coal).frame(width: 1.6, height: 1.6)
            }
            .offset(y: 20)
            // The head: eyes, mouth and the carrot.
            Circle()
                .fill(snow)
                .frame(width: 13, height: 13)
                .offset(y: 4)
            HStack(spacing: 3) {
                eye(expression, closed: isLeftClosed, size: 2.6, color: coal)
                eye(expression, closed: isRightClosed, size: 2.6, color: coal)
            }
            .offset(x: gaze * 1.4, y: 8)
            Carrot()
                .fill(Color.orange)
                .frame(width: 5, height: 2.4)
                .scaleEffect(x: gaze < 0 ? -1 : 1)
                .offset(x: gaze < 0 ? -2.5 + gaze : 2.5 + gaze, y: 10.4)
            mouth(expression, color: coal)
                .scaleEffect(0.5)
                .offset(y: 11.5)
            // The scarf, an end hanging down.
            Capsule()
                .fill(red)
                .frame(width: 12, height: 2.4)
                .offset(y: 15.6)
            RoundedRectangle(cornerRadius: 0.8)
                .fill(red)
                .frame(width: 2, height: 4.5)
                .offset(x: 3.5, y: 16.5)
            // The hat.
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(coal).frame(width: 7, height: 5)
                    Rectangle().fill(red).frame(width: 7, height: 1.2).offset(y: -0.8)
                }
                Capsule().fill(coal).frame(width: 12, height: 1.6)
            }
            .rotationEffect(.degrees(hatTilt), anchor: .bottom)
            .offset(y: -1.6 + hatLift)
        }
        .frame(width: 26, height: 30, alignment: .top)
    }

    /// Waves a few times when the pointer comes near, then now and then while it stays.
    private func waveWhileNear() async {
        guard layout.christmas && mood.isPointerNear && !mood.isAsleep else {
            withAnimation(.easeOut(duration: 0.2)) { wave = 0 }
            return
        }
        while !Task.isCancelled {
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.16)) { wave = -40 }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.easeInOut(duration: 0.16)) { wave = -10 }
                try? await Task.sleep(for: .milliseconds(160))
            }
            withAnimation(.easeOut(duration: 0.2)) { wave = 0 }
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    private func eye(_ expression: Expression, closed: Bool) -> some View {
        eye(expression, closed: closed, size: size, color: color)
    }

    private func eye(_ expression: Expression, closed: Bool, size: CGFloat, color: Color) -> some View {
        let openness: CGFloat = switch expression {
        case .asleep, .yawning: 0.14
        case .drowsy: 0.5
        case .grinning, .happy: 0.55
        case .humming: 0.7
        case .surprised: 1
        case .calm: isLateNight ? 0.72 : 1
        }
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(expression == .surprised ? 1.25 : 1)
            .scaleEffect(x: 1, y: closed && openness > 0.2 ? 0.12 : openness)
    }

    private func mouth(_ expression: Expression) -> some View {
        mouth(expression, color: color)
    }

    @ViewBuilder
    private func mouth(_ expression: Expression, color: Color) -> some View {
        switch expression {
        case .grinning, .happy:
            Smile()
                .fill(color)
                .frame(width: 11, height: 4.5)
        case .yawning:
            Ellipse()
                .fill(color)
                .frame(width: 5, height: isYawnOpen ? 7 : 2.5)
        case .humming:
            Circle()
                .fill(color)
                .frame(width: 3, height: 3)
        case .asleep:
            Capsule()
                .fill(color)
                .frame(width: 5, height: 1.6)
        case .calm, .drowsy, .surprised:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// A slow rise and fall, slower and deeper while asleep.
    private func breathe() async {
        while !Task.isCancelled {
            let period = mood.isAsleep ? 2.4 : 1.6
            withAnimation(.easeInOut(duration: period)) { isBreathingIn.toggle() }
            try? await Task.sleep(for: .seconds(period))
        }
    }

    /// At random, from under a second to a few seconds apart, in different ways: a quick blink
    /// (the most), two or three in a row, a slow one, or a wink.
    private func blink() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 0.8...4)))
            let roll = Int.random(in: 0..<100)
            switch roll {
            case 0..<12:
                // A wink, either eye.
                let left = Bool.random()
                withAnimation(.easeIn(duration: 0.08)) { if left { isLeftClosed = true } else { isRightClosed = true } }
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeOut(duration: 0.12)) { isLeftClosed = false; isRightClosed = false }
            case 12..<24:
                // Slow, like thinking.
                withAnimation(.easeInOut(duration: 0.25)) { isLeftClosed = true; isRightClosed = true }
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(.easeInOut(duration: 0.3)) { isLeftClosed = false; isRightClosed = false }
            default:
                // Quick: once, twice, or a flutter of three.
                let times = roll < 34 ? 3 : roll < 52 ? 2 : 1
                for _ in 0..<times {
                    withAnimation(.easeIn(duration: 0.06)) { isLeftClosed = true; isRightClosed = true }
                    try? await Task.sleep(for: .milliseconds(90))
                    withAnimation(.easeOut(duration: 0.08)) { isLeftClosed = false; isRightClosed = false }
                    try? await Task.sleep(for: .milliseconds(110))
                }
            }
        }
    }

    /// A look to one side now and then, back to the middle after a moment.
    private func glance() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 1.5...4.5)))
            guard isIdle else { continue }
            look = (Bool.random() ? 1 : -1) * CGFloat.random(in: 0.6...1)
            try? await Task.sleep(for: .seconds(Double.random(in: 0.8...1.6)))
            if action == nil { look = 0 }
        }
    }

    /// Every 4 to 10 seconds, while awake and left alone, one of the little actions.
    private func act() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 4...10)))
            guard isIdle, !mood.isDrowsy, !mood.isPointerNear else { continue }
            switch [Action.yawn, .lookAround, .hum, .hop].randomElement() ?? .hop {
            case .yawn:
                action = .yawn
                withAnimation(.easeInOut(duration: 0.9)) { isYawnOpen = true }
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(.easeInOut(duration: 0.4)) { isYawnOpen = false }
                try? await Task.sleep(for: .seconds(0.4))
            case .lookAround:
                action = .lookAround
                look = -1
                try? await Task.sleep(for: .seconds(0.7))
                look = 1
                try? await Task.sleep(for: .seconds(0.8))
                look = 0
                try? await Task.sleep(for: .seconds(0.3))
            case .hum:
                action = .hum
                for step in 0..<6 {
                    withAnimation(.easeInOut(duration: 0.4)) { sway = step.isMultiple(of: 2) ? 7 : -7 }
                    try? await Task.sleep(for: .seconds(0.4))
                }
                withAnimation(.easeInOut(duration: 0.3)) { sway = 0 }
                try? await Task.sleep(for: .seconds(0.3))
            case .hop:
                action = .hop
                for _ in 0..<2 {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { hop = -3 }
                    try? await Task.sleep(for: .seconds(0.16))
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { hop = 0 }
                    try? await Task.sleep(for: .seconds(0.3))
                }
            }
            action = nil
        }
    }
}

/// A small "z" drifting up and fading, over and over, while the face sleeps.
private struct SleepyZ: View {
    let color: Color
    @State private var isDrifting = false

    var body: some View {
        Text("z")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .offset(x: isDrifting ? 3 : 0, y: isDrifting ? -5 : 0)
            .opacity(isDrifting ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    isDrifting = true
                }
            }
    }
}

/// A music note floating up while the face hums.
private struct FloatingNote: View {
    let color: Color
    @State private var isFloating = false

    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: 6, weight: .bold))
            .foregroundColor(color)
            .offset(x: isFloating ? 2 : 0, y: isFloating ? -5 : 0)
            .opacity(isFloating ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isFloating = true
                }
            }
    }
}

/// A carrot nose pointing right: wide at the face, a point at the tip.
private struct Carrot: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The lower half of a curve, its ends at the top corners.
private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.maxY + rect.height))
        return path
    }
}

// MARK: - Poke effects

/// Shakes a view sideways a few times; each step of `shakes` is one shake.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var amount: CGFloat = 7

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Fades out over each shake, so it settles instead of stopping dead.
        let progress = shakes - shakes.rounded(.down)
        let offset = sin(progress * .pi * 6) * amount * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

/// A little weather over a poke's banner, once, when it appears, by the time of day: sunbeams in
/// the morning, snow during the day, twinkling stars at night.
struct PokeSkyEffect: View {
    enum Sky {
        case sunbeams, snow, stars

        static func now(_ date: Date = Date()) -> Sky {
            switch Calendar.current.component(.hour, from: date) {
            case 5..<11: return .sunbeams
            case 11..<18: return .snow
            default: return .stars
            }
        }
    }

    @State private var sky = Sky.now()

    var body: some View {
        GeometryReader { geometry in
            switch sky {
            case .sunbeams: Sunbeams(size: geometry.size)
            case .snow: Snowfall(size: geometry.size)
            case .stars: Twinkles(size: geometry.size)
            }
        }
        // A backdrop: faint enough that the text in front stays easy to read.
        .opacity(0.45)
        .allowsHitTesting(false)
    }
}

/// Warm rays fanning out from the top left corner, brightening and fading.
private struct Sunbeams: View {
    let size: CGSize
    @State private var isShining = false

    var body: some View {
        let length = hypot(size.width, size.height)
        ZStack(alignment: .topLeading) {
            // A soft glow where the sun is.
            RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.45).opacity(0.45), .clear],
                           center: .topLeading, startRadius: 0, endRadius: size.height * 1.4)
            ForEach(0..<6, id: \.self) { index in
                LinearGradient(colors: [Color(red: 1, green: 0.88, blue: 0.5).opacity(0.5), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: length, height: 5 + CGFloat(index % 3) * 3)
                    .rotationEffect(.degrees(Double(index) * 7 + (isShining ? 8 : 0)), anchor: .leading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(isShining ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { isShining = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeIn(duration: 0.8)) { isShining = false }
            }
        }
    }
}

/// Small flakes drifting down.
private struct Snowfall: View {
    private struct Flake: Identifiable {
        let id = UUID()
        let x: CGFloat
        let drift: CGFloat
        let size: CGFloat
        let delay: Double
        let duration: Double
    }

    let size: CGSize
    @State private var flakes: [Flake] = []
    @State private var hasFallen = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(flakes) { flake in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: flake.size, height: flake.size)
                    .position(x: flake.x * size.width + (hasFallen ? flake.drift : 0),
                              y: hasFallen ? size.height + 6 : -6)
                    .opacity(hasFallen ? 0.2 : 1)
                    .animation(.easeIn(duration: flake.duration).delay(flake.delay), value: hasFallen)
            }
        }
        .onAppear {
            flakes = (0..<22).map { _ in
                Flake(x: .random(in: 0.02...0.98), drift: .random(in: -14...14), size: .random(in: 1.5...3),
                      delay: .random(in: 0...0.6), duration: .random(in: 1.3...2))
            }
            // The flakes are laid out at the top first, then fall.
            DispatchQueue.main.async { hasFallen = true }
        }
    }
}

/// Little stars lighting up here and there, then fading.
private struct Twinkles: View {
    private struct Star: Identifiable {
        let id = UUID()
        let point: CGPoint
        let size: CGFloat
        let delay: Double
    }

    let size: CGSize
    @State private var stars: [Star] = []
    @State private var isLit = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(stars) { star in
                Image(systemName: "sparkle")
                    .font(.system(size: star.size))
                    .foregroundColor(Color(red: 1, green: 0.95, blue: 0.75))
                    .position(x: star.point.x * size.width, y: star.point.y * size.height)
                    .scaleEffect(isLit ? 1 : 0.2)
                    .opacity(isLit ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35).repeatCount(3, autoreverses: true).delay(star.delay), value: isLit)
            }
        }
        .onAppear {
            stars = (0..<12).map { _ in
                Star(point: CGPoint(x: .random(in: 0.04...0.96), y: .random(in: 0.08...0.92)),
                     size: .random(in: 5...8), delay: .random(in: 0...0.7))
            }
            DispatchQueue.main.async { isLit = true }
            // Odd number of twinkles leaves them lit; then they fade out together.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.5)) { isLit = false }
            }
        }
    }
}

/// The poke's hand swinging in from the side, with a little overshoot, when the banner appears.
struct PokeHandEntrance: ViewModifier {
    let isActive: Bool
    @State private var hasArrived = false

    func body(content: Content) -> some View {
        content
            .offset(x: isActive && !hasArrived ? -46 : 0)
            .rotationEffect(.degrees(isActive && !hasArrived ? -35 : 0))
            .onAppear {
                guard isActive else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.45).delay(0.1)) {
                    hasArrived = true
                }
            }
    }
}
