import SwiftUI
import WebKit

/// The YouTube video playing in Chrome, muted and kept at the tab's position and play state, so the
/// notch shows the picture while the sound and the controls stay with the tab. It uses YouTube's
/// embed player, which some videos don't allow.
struct YouTubeMirrorView: NSViewRepresentable {
    let videoID: String
    let position: Double
    let isPlaying: Bool
    /// Called with true when YouTube won't play the video embedded.
    let onBlocked: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MirrorContainer {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .black
        context.coordinator.webView = webView
        return MirrorContainer(webView: webView)
    }

    func updateNSView(_ container: MirrorContainer, context: Context) {
        context.coordinator.update(videoID: videoID, position: position, isPlaying: isPlaying, onBlocked: onBlocked)
    }

    static func dismantleNSView(_ container: MirrorContainer, coordinator: Coordinator) {
        // Stop the video when the Media tab closes rather than when the web view is freed.
        coordinator.webView?.pauseAllMediaPlayback()
        coordinator.webView?.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator {
        weak var webView: WKWebView?
        private var loadedID: String?
        private var lastSync = Date.distantPast

        func update(videoID: String, position: Double, isPlaying: Bool, onBlocked: @escaping (Bool) -> Void) {
            guard let webView else { return }
            if loadedID != videoID {
                loadedID = videoID
                lastSync = Date()
                webView.loadHTMLString(YouTubeMirrorView.page(videoID: videoID, start: position), baseURL: YouTubeMirrorView.origin)
                return
            }
            // The tab's position is read every 1.5 seconds; nudging more often only makes it stutter.
            guard Date().timeIntervalSince(lastSync) >= 1 else { return }
            lastSync = Date()
            webView.evaluateJavaScript("sync(\(position), \(isPlaying))") { result, _ in
                let blocked = (result as? String) == "error"
                DispatchQueue.main.async { onBlocked(blocked) }
            }
        }
    }

    /// YouTube refuses embeds from a page with no origin, so the page gets one.
    private static let origin = URL(string: "https://localhost/")!

    /// A page with YouTube's IFrame Player API. `sync` keeps the video muted and within a second
    /// and a half of the tab, and returns "error" when YouTube won't play it embedded.
    private static func page(videoID: String, start: Double) -> String {
        let id = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <html><head><style>html, body { margin: 0; height: 100%; background: #000; overflow: hidden; } #player { width: 100%; height: 100%; }</style></head>
        <body><div id="player"></div>
        <script>
        var player, ready = false, failed = false;
        function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
                videoId: '\(id)',
                playerVars: { autoplay: 1, mute: 1, controls: 0, playsinline: 1, rel: 0, iv_load_policy: 3, disablekb: 1, start: \(Int(start)), origin: 'https://localhost' },
                events: {
                    onReady: function (event) { ready = true; event.target.mute(); event.target.playVideo(); },
                    onError: function () { failed = true; }
                }
            });
        }
        function sync(time, playing) {
            if (failed) { return 'error'; }
            if (!ready) { return 'loading'; }
            player.mute();
            if (Math.abs(player.getCurrentTime() - time) > 1.5) { player.seekTo(time, true); }
            var state = player.getPlayerState();
            if (playing && state !== 1 && state !== 3) { player.playVideo(); }
            if (!playing && state === 1) { player.pauseVideo(); }
            return 'ok';
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}

/// Holds the web view with rounded corners and lets clicks and hovers through to the island. The
/// video fills the box: a box wider than 16:9 crops the top and bottom instead of showing bars.
final class MirrorContainer: NSView {
    private static let videoAspect: CGFloat = 16 / 9

    init(webView: WKWebView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(webView)
    }

    override func layout() {
        super.layout()
        guard let webView = subviews.first, bounds.width > 0, bounds.height > 0 else { return }
        var size = bounds.size
        if size.width / size.height > Self.videoAspect {
            size.height = size.width / Self.videoAspect
        } else {
            size.width = size.height * Self.videoAspect
        }
        webView.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
