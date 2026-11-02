import AppKit
import SwiftUI

// Looping notch animations built on Core Animation. They run in the render server, so they cost
// next to no CPU. SwiftUI's .symbolEffect redraws the symbol on the main thread every frame
// (up to 120 Hz), which kept the app at ~20% CPU while a live activity was showing.

/// An SF Symbol that gently pulses (fades and shrinks a little).
struct PulsingSymbol: NSViewRepresentable {
    let systemName: String
    let color: NSColor
    var pointSize: CGFloat = 13

    func makeNSView(context: Context) -> PulsingSymbolView {
        PulsingSymbolView()
    }

    func updateNSView(_ nsView: PulsingSymbolView, context: Context) {
        nsView.configure(systemName: systemName, color: color, pointSize: pointSize)
    }

    final class PulsingSymbolView: LoopingLayerView {
        private let symbolLayer = CALayer()
        private var imageSize = CGSize.zero

        override func setUpLayers(in root: CALayer) {
            symbolLayer.contentsGravity = .resizeAspect
            root.addSublayer(symbolLayer)
        }

        func configure(systemName: String, color: NSColor, pointSize: CGFloat) {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            imageSize = image.size
            symbolLayer.contents = image
            needsLayout = true
        }

        override func layoutLayers(in bounds: CGRect) {
            symbolLayer.frame = CGRect(x: bounds.midX - imageSize.width / 2, y: bounds.midY - imageSize.height / 2,
                                       width: imageSize.width, height: imageSize.height)
            symbolLayer.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func addAnimations() {
            symbolLayer.add(Self.loop("opacity", from: 1, to: 0.4, duration: 0.9), forKey: "fade")
            symbolLayer.add(Self.loop("transform.scale", from: 1, to: 0.82, duration: 0.9), forKey: "scale")
        }
    }
}

/// Three dots lighting up in turn, like a "typing…" indicator.
struct ThinkingDots: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> DotsView {
        DotsView()
    }

    func updateNSView(_ nsView: DotsView, context: Context) {
        nsView.setColor(color)
    }

    final class DotsView: LoopingLayerView {
        private let dots = (0..<3).map { _ in CALayer() }
        private let dotSize: CGFloat = 4
        private let spacing: CGFloat = 3

        override func setUpLayers(in root: CALayer) {
            dots.forEach(root.addSublayer)
        }

        func setColor(_ color: NSColor) {
            dots.forEach { $0.backgroundColor = color.cgColor }
        }

        override func layoutLayers(in bounds: CGRect) {
            let totalWidth = dotSize * 3 + spacing * 2
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: bounds.midX - totalWidth / 2 + CGFloat(index) * (dotSize + spacing),
                                   y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)
                dot.cornerRadius = dotSize / 2
            }
        }

        override func addAnimations() {
            for (index, dot) in dots.enumerated() {
                dot.add(Self.loop("opacity", from: 1, to: 0.25, duration: 0.5, delay: Double(index) * 0.17), forKey: "fade")
            }
        }
    }
}

/// Small equalizer bars for "music is playing".
struct EqualizerBars: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> BarsView {
        BarsView()
    }

    func updateNSView(_ nsView: BarsView, context: Context) {
        nsView.setColor(color)
    }

    final class BarsView: LoopingLayerView {
        private let bars = (0..<4).map { _ in CALayer() }
        private let barWidth: CGFloat = 2.5
        private let spacing: CGFloat = 2
        /// Different speeds per bar so the movement doesn't look synchronized.
        private let durations = [0.45, 0.62, 0.38, 0.55]

        override func setUpLayers(in root: CALayer) {
            bars.forEach(root.addSublayer)
        }

        func setColor(_ color: NSColor) {
            bars.forEach { $0.backgroundColor = color.cgColor }
        }

        override func layoutLayers(in bounds: CGRect) {
            let totalWidth = barWidth * 4 + spacing * 3
            for (index, bar) in bars.enumerated() {
                bar.frame = CGRect(x: bounds.midX - totalWidth / 2 + CGFloat(index) * (barWidth + spacing),
                                   y: bounds.minY, width: barWidth, height: bounds.height)
                bar.cornerRadius = barWidth / 2
            }
        }

        override func addAnimations() {
            for (index, bar) in bars.enumerated() {
                bar.add(Self.loop("transform.scale.y", from: 1, to: 0.3, duration: durations[index]), forKey: "bounce")
            }
        }
    }
}

/// Base view: a layer tree laid out without implicit animations, with looping animations
/// (re)attached whenever the view lands in a window.
class LoopingLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if let layer {
            setUpLayers(in: layer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUpLayers(in root: CALayer) {}
    func layoutLayers(in bounds: CGRect) {}
    func addAnimations() {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers(in: bounds)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            addAnimations()
        }
    }

    static func loop(_ keyPath: String, from: Double, to: Double, duration: Double, delay: Double = 0) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        return animation
    }
}
