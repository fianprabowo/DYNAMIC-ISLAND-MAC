import AppKit
import OSLog
import QuartzCore

/// Logs how smoothly the notch opens, closes and changes size (log category "Animation"): for a
/// second after each, it counts the screen's frames, notes every frame that came late (the main
/// thread was busy), when the window changed size, and how often heavy views were drawn again.
///
///     /usr/bin/log stream --predicate 'process == "Dynamic Island" AND category == "Animation"'
final class AnimationMonitor: NSObject {
    static let shared = AnimationMonitor()

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "Animation")
    private var link: CADisplayLink?
    private var reason = ""
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var frameInterval: Double = 1.0 / 60
    private var lateFrames: [(at: Double, gap: Double)] = []
    private var bodies: [String: Int] = [:]
    private var finishWork: DispatchWorkItem?

    var isRunning: Bool { link != nil }

    func begin(_ reason: String, duration: TimeInterval = 1.0) {
        if isRunning { finish() }
        guard let screen = IslandLayout.notchScreen else { return }
        self.reason = reason
        frameInterval = 1.0 / Double(max(screen.maximumFramesPerSecond, 60))
        start = CACurrentMediaTime()
        last = start
        frames = 0
        lateFrames = []
        bodies = [:]
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        log.info("▶︎ \(reason, privacy: .public) (\(Int(1 / self.frameInterval)) Hz)")

        let work = DispatchWorkItem { [weak self] in self?.finish() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Something that happened during the animation, with the time since it began.
    func mark(_ event: String) {
        guard isRunning else { return }
        log.info("  +\(self.elapsed) ms \(event, privacy: .public)")
    }

    /// Counts a view's body being drawn again while an animation is watched.
    func body(_ name: String) {
        guard isRunning else { return }
        bodies[name, default: 0] += 1
    }

    private var elapsed: Int {
        Int((CACurrentMediaTime() - start) * 1000)
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let gap = now - last
        if frames > 0 && gap > frameInterval * 1.6 {
            lateFrames.append((at: last - start, gap: gap))
        }
        frames += 1
        last = now
    }

    private func finish() {
        finishWork?.cancel()
        link?.invalidate()
        link = nil
        let duration = last - start
        let expected = Int(duration / frameInterval)
        let worst = lateFrames.map(\.gap).max() ?? 0
        let missed = lateFrames.reduce(0) { $0 + Int(($1.gap / frameInterval).rounded()) - 1 }
        let late = lateFrames.prefix(12)
            .map { "+\(Int($0.at * 1000))ms:\(Int($0.gap * 1000))ms" }
            .joined(separator: " ")
        let drawn = bodies.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        log.info("■ \(self.reason, privacy: .public): \(self.frames)/\(expected) frames, \(missed) missed, worst \(Int(worst * 1000)) ms; late \(late.isEmpty ? "none" : late, privacy: .public); drawn \(drawn.isEmpty ? "-" : drawn, privacy: .public)")
    }
}
