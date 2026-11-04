import AppKit
@preconcurrency import IOSurface
import ScreenCaptureKit
import SwiftUI

/// A live picture of the Chrome window that holds a Google Meet call, so the notch shows the shared
/// screen and the cameras. Meet's video lives in Chrome's WebRTC streams, which no other app can
/// play, so the window itself is recorded with ScreenCaptureKit, without Chrome's tab strip and
/// toolbar. It needs the Screen Recording permission, the Meet tab must be the one showing in its
/// window, and the window must not be minimized.
final class MeetWindowCapture: NSObject {
    enum Problem: Equatable {
        case noPermission
        case windowNotFound
        case failed(String)
    }

    /// Shows the frames, scaled to fit.
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }()

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "MeetWindowCapture")

    private static let maxPixelWidth: CGFloat = 1280
    private static let framesPerSecond: Int32 = 15

    /// Starts recording the Chrome window whose title starts with `tabTitle`.
    func start(tabTitle: String, browserBarHeight: Double) async -> Problem? {
        guard CGPreflightScreenCaptureAccess() else { return .noPermission }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            return .noPermission
        }
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == MediaPlayerApp.chrome.rawValue
                && ($0.title ?? "").hasPrefix(tabTitle) && $0.frame.width > 200 && $0.frame.height > 200
        }) else { return .windowNotFound }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // Only the page: Chrome's tab strip and toolbar are cut off the top.
        let bar = min(CGFloat(browserBarHeight), window.frame.height / 2)
        let source = CGRect(x: 0, y: bar, width: window.frame.width, height: window.frame.height - bar)
        let scale = min(CGFloat(filter.pointPixelScale), Self.maxPixelWidth / source.width)
        configuration.sourceRect = source
        configuration.width = Int(source.width * scale)
        configuration.height = Int(source.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.showsCursor = false
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            return .failed(error.localizedDescription)
        }
        self.stream = stream
        return nil
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
        layer.contents = nil
    }
}

extension MeetWindowCapture: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames carry a picture; idle ones repeat the last frame.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, rawStatus == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.layer.contents = surface
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
        }
    }
}

/// The Meet window's live picture. `onProblem` reports why it can't show (nil once it does).
struct MeetWindowView: NSViewRepresentable {
    let tabTitle: String
    let browserBarHeight: Double
    let onProblem: (MeetWindowCapture.Problem?) -> Void

    final class Coordinator {
        let capture = MeetWindowCapture()
        var startedFor: String?
        var startTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        CaptureView(captureLayer: context.coordinator.capture.layer)
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Started once per tab title: switching to another tab in that window changes the title.
        let key = "\(tabTitle)|\(Int(browserBarHeight))"
        let coordinator = context.coordinator
        guard coordinator.startedFor != key else { return }
        coordinator.startedFor = key
        coordinator.startTask?.cancel()
        coordinator.capture.stop()
        let (tabTitle, browserBarHeight, onProblem) = (tabTitle, browserBarHeight, onProblem)
        coordinator.startTask = Task {
            // Tries again while the window is hidden or the permission is missing.
            while !Task.isCancelled {
                let problem = await coordinator.capture.start(tabTitle: tabTitle, browserBarHeight: browserBarHeight)
                guard !Task.isCancelled else {
                    coordinator.capture.stop()
                    return
                }
                onProblem(problem)
                guard problem == .windowNotFound || problem == .noPermission else { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.startTask?.cancel()
        coordinator.capture.stop()
    }
}

/// Holds the capture's layer at its own size, and lets clicks through to the island's views.
private final class CaptureView: NSView {
    private let captureLayer: CALayer

    init(captureLayer: CALayer) {
        self.captureLayer = captureLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(captureLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captureLayer.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
