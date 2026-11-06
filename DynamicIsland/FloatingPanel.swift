import AppKit
import Combine
import OSLog
import SwiftUI

/// Tabs of the expanded notch panel, modeled after NotchNook.
enum NotchTab: String, CaseIterable {
    case nook = "Nook"
    case media = "Media"
    case alerts = "Alerts"
    case poke = "Poke"
    case timer = "Timer"
    case todo = "Todo"
    case vpn = "VPN"

    var icon: String {
        switch self {
        case .nook: return "sparkles"
        case .media: return "music.note"
        case .alerts: return "bell.fill"
        case .poke: return "hand.point.right.fill"
        case .timer: return "timer"
        case .todo: return "checklist"
        case .vpn: return "lock.shield.fill"
        }
    }

    /// Beside the pin and settings, right of the notch: the left side is full.
    var isBesideSettings: Bool {
        self == .todo || self == .vpn
    }
}

/// Where the island lives (attached to the MacBook notch, or floating freely) and whether it is open.
class IslandLayout: ObservableObject {
    @Published var isPinnedToNotch: Bool {
        didSet { UserDefaults.standard.set(isPinnedToNotch, forKey: Self.pinnedKey) }
    }
    /// Open the notch when the pointer rests on it, close it when the pointer leaves.
    @Published var openOnHover: Bool {
        didSet { UserDefaults.standard.set(openOnHover, forKey: Self.openOnHoverKey) }
    }
    /// Eyes in the wings beside the notch while nothing is live (gear menu → Animations).
    @Published var showsEyes: Bool {
        didSet { UserDefaults.standard.set(showsEyes, forKey: Self.showsEyesKey) }
    }
    /// A friend's poke shakes the notch and rains emoji.
    @Published var pokeEffects: Bool {
        didSet { UserDefaults.standard.set(pokeEffects, forKey: Self.pokeEffectsKey) }
    }
    /// A springier, jelly-like opening, and a little squish when a notification comes in.
    @Published var bouncyOpen: Bool {
        didSet { UserDefaults.standard.set(bouncyOpen, forKey: Self.bouncyOpenKey) }
    }
    @Published var isExpanded = false
    /// Pinned open: the open notch doesn't close when the pointer leaves it or on a click elsewhere.
    @Published var staysOpen = false
    @Published var selectedTab: NotchTab = .nook
    /// Size of the floating island as laid out by SwiftUI; the floating window follows it.
    @Published var floatingContentSize: CGSize = .zero
    /// Whether the collapsed island shows its wings (music playing / unread notifications).
    /// When idle it is exactly as wide as the physical notch, like the iPhone's Dynamic Island.
    @Published private(set) var showsWings = false
    /// Whether the collapsed island shows another app's notification below the notch.
    @Published private(set) var showsBanner = false
    /// Whether the collapsed island shows the volume or brightness level beside the notch.
    @Published private(set) var showsHUD = false
    @Published private(set) var notchSize: CGSize
    /// How big the open panel is: YouTube in the Media tab takes more room.
    @Published private(set) var panelStyle = PanelStyle.regular

    enum PanelStyle {
        /// 640×180.
        case regular
        /// Taller for a YouTube video; below the tab bar it narrows to the video.
        case video
    }

    /// Width of the black "wings" shown beside the physical notch while collapsed.
    static let notchWing: CGFloat = 40
    /// The volume and brightness levels take wider wings.
    static let notchHUDWing: CGFloat = 76
    static let notchExpandedWidth: CGFloat = 640
    static let notchExpandedHeight: CGFloat = 180
    /// Room around the open panel's content, below the tab bar.
    static let expandedHorizontalPadding: CGFloat = 20
    static let expandedTopPadding: CGFloat = 6
    static let expandedBottomPadding: CGFloat = 14
    /// Height of the YouTube video in the Media tab; it is 16:9, centered in the panel.
    static let videoHeight: CGFloat = 200
    /// Below the tab bar the video panel narrows to the video plus this margin on each side, so
    /// there is no black beside the video.
    static let videoBodyMargin: CGFloat = 10
    static var videoBodyWidth: CGFloat {
        (videoHeight * 16 / 9).rounded(.up) + videoBodyMargin * 2
    }
    /// Opening overshoots slightly, like the iPhone's Dynamic Island; closing settles smoothly.
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// The bouncy opening: it overshoots further and wobbles before it settles.
    static let bouncyAnimation = Animation.spring(response: 0.5, dampingFraction: 0.6)

    /// How the island grows, as set in Animations.
    var growAnimation: Animation {
        bouncyOpen ? Self.bouncyAnimation : Self.expandAnimation
    }
    static let collapseAnimation = Animation.spring(response: 0.36, dampingFraction: 0.9)

    /// Set by the notch window: enlarges it to the given size before a growing animation starts,
    /// so the first animated frame still has the old size instead of jumping to the new one.
    var prepareToGrow: ((CGSize) -> Void)?

    private static let pinnedKey = "islandPinnedToNotch"
    private static let openOnHoverKey = "islandOpenOnHover"
    private static let showsEyesKey = "islandShowsEyes"
    private static let pokeEffectsKey = "islandPokeEffects"
    private static let bouncyOpenKey = "islandBouncyOpen"

    init() {
        isPinnedToNotch = UserDefaults.standard.object(forKey: Self.pinnedKey) as? Bool ?? true
        openOnHover = UserDefaults.standard.object(forKey: Self.openOnHoverKey) as? Bool ?? true
        showsEyes = UserDefaults.standard.object(forKey: Self.showsEyesKey) as? Bool ?? true
        pokeEffects = UserDefaults.standard.object(forKey: Self.pokeEffectsKey) as? Bool ?? true
        bouncyOpen = UserDefaults.standard.object(forKey: Self.bouncyOpenKey) as? Bool ?? true
        notchSize = Self.measureNotch()
    }

    var notchCollapsedSize: CGSize {
        CGSize(width: notchSize.width + (showsWings ? Self.notchWing * 2 : 0), height: notchSize.height)
    }

    /// Transparent room around the open island so the opening spring's overshoot isn't clipped,
    /// the bouncy one's and a poke's shake included.
    static let overshootMargin: CGFloat = 24

    var notchBannerSize: CGSize {
        CGSize(width: 380, height: notchSize.height + 60)
    }

    var notchHUDSize: CGSize {
        CGSize(width: notchSize.width + Self.notchHUDWing * 2, height: notchSize.height)
    }

    var notchExpandedSize: CGSize {
        size(of: panelStyle)
    }

    /// The usual width and tab bar, with room below for the video.
    private func size(of style: PanelStyle) -> CGSize {
        switch style {
        case .regular:
            return CGSize(width: Self.notchExpandedWidth, height: Self.notchExpandedHeight)
        case .video:
            return CGSize(width: Self.notchExpandedWidth,
                          height: notchSize.height + Self.expandedTopPadding + Self.videoHeight + Self.expandedBottomPadding)
        }
    }

    var notchWindowSize: CGSize {
        if isExpanded {
            return notchExpandedWindowSize
        }
        // The level shows over a banner for a moment; the window keeps room for the banner.
        let base = showsBanner ? notchBannerWindowSize : notchCollapsedSize
        guard showsHUD else { return base }
        return CGSize(width: max(base.width, notchHUDSize.width), height: max(base.height, notchHUDSize.height))
    }

    private var notchBannerWindowSize: CGSize {
        CGSize(width: notchBannerSize.width + Self.overshootMargin * 2, height: notchBannerSize.height + Self.overshootMargin)
    }

    var notchExpandedWindowSize: CGSize {
        Self.windowSize(for: notchExpandedSize)
    }

    /// The largest the open island gets, for the island view's fixed size inside the window.
    var notchLargestWindowSize: CGSize {
        let sizes = [PanelStyle.regular, .video].map(size(of:))
        return Self.windowSize(for: CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0))
    }

    private static func windowSize(for islandSize: CGSize) -> CGSize {
        CGSize(width: islandSize.width + overshootMargin * 2, height: islandSize.height + overshootMargin)
    }

    func toggleExpanded() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    func expand() {
        guard !isExpanded else { return }
        grow(to: notchExpandedWindowSize) {
            self.isExpanded = true
        }
    }

    func setPanelStyle(_ style: PanelStyle) {
        guard style != panelStyle else { return }
        let size = size(of: style)
        if size.height >= notchExpandedSize.height {
            grow(to: Self.windowSize(for: size)) {
                self.panelStyle = style
            }
        } else {
            withAnimation(Self.collapseAnimation) {
                panelStyle = style
            }
        }
    }

    /// Back to the regular panel, unless another view has set its own style in the meantime
    /// (a view's disappearing can come after the next one appears).
    func resetPanelStyle(from style: PanelStyle) {
        if panelStyle == style {
            setPanelStyle(.regular)
        }
    }

    func collapse() {
        guard isExpanded else { return }
        staysOpen = false
        withAnimation(Self.collapseAnimation) {
            isExpanded = false
        }
    }

    func setShowsWings(_ show: Bool) {
        guard show != showsWings else { return }
        if show {
            let size = CGSize(width: notchSize.width + Self.notchWing * 2, height: notchSize.height)
            grow(to: size) {
                self.showsWings = true
            }
        } else {
            withAnimation(Self.collapseAnimation) {
                showsWings = false
            }
        }
    }

    func setShowsBanner(_ show: Bool) {
        guard show != showsBanner else { return }
        if show {
            grow(to: notchBannerWindowSize) {
                self.showsBanner = true
            }
        } else {
            withAnimation(Self.collapseAnimation) {
                showsBanner = false
            }
        }
    }

    func setShowsHUD(_ show: Bool) {
        guard show != showsHUD else { return }
        if show {
            grow(to: notchHUDSize) {
                self.showsHUD = true
            }
        } else {
            withAnimation(Self.collapseAnimation) {
                showsHUD = false
            }
        }
    }

    private func grow(to size: CGSize, _ change: @escaping () -> Void) {
        guard let prepareToGrow else {
            withAnimation(growAnimation, change)
            return
        }
        prepareToGrow(size)
        DispatchQueue.main.async {
            withAnimation(self.growAnimation, change)
        }
    }

    func refreshNotch() {
        notchSize = Self.measureNotch()
    }

    /// The built-in display with a notch, or the main display on Macs without one.
    static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Without a real notch, a menu-bar-height "virtual notch" is used instead.
    private static func measureNotch() -> CGSize {
        guard let screen = notchScreen else { return CGSize(width: 185, height: 32) }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 185, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
    }
}

/// Borderless always-on-top panel that hosts the island and stays visible on every Space.
///
/// The window size is always set here, never by SwiftUI. (When SwiftUI also sized the window,
/// the two fought over it and AppKit crashed with "more Update Constraints in Window passes than
/// there are views in the window".)
/// Floating mode: the window follows the size the floating island reports. Notch mode: the window
/// grows *before* the expand animation and shrinks *after* the collapse one, so the island
/// animates smoothly and the empty area never blocks clicks on the menu bar.
class FloatingPanel: NSPanel {
    private let layout: IslandLayout
    private let container = IslandContainerView()
    private var cancellables = Set<AnyCancellable>()
    private var shrinkWorkItem: DispatchWorkItem?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var hoverCloseWorkItem: DispatchWorkItem?
    private var mouseMonitors: [Any] = []
    private var isMouseInside = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "Panel")

    private static let floatingPositionKey = "islandFloatingTopLeft"

    var isDraggable: Bool { !layout.isPinnedToNotch }

    init(hostingView: NSHostingView<AnyView>, layout: IslandLayout) {
        self.layout = layout
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // The hosting view sits inside a plain container instead of being the content view itself:
        // as a window's content view, NSHostingView keeps setting the window's min/max size from
        // the SwiftUI content, even with empty sizingOptions.
        hostingView.sizingOptions = []
        container.addSubview(hostingView)
        contentView = container
        hostingView.frame = container.bounds

        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false

        // Hover-to-open watches the pointer with event monitors, which see it even while this
        // panel is inactive. Global: pointer over other apps' windows. Local: over this panel.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.pointerMoved()
        }) {
            mouseMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) {
            mouseMonitors.append(monitor)
        }

        // In floating mode the window resizes itself with the content; re-anchor it every time.
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSWindow.didResizeNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        layout.$isPinnedToNotch
            .sink { [weak self] pinned in self?.applyMode(pinnedToNotch: pinned) }
            .store(in: &cancellables)
        layout.$floatingContentSize
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitFloatingContent() } }
            .store(in: &cancellables)
        Publishers.CombineLatest4(layout.$isExpanded, layout.$showsWings, layout.$showsBanner, layout.$showsHUD)
            .dropFirst()
            // @Published emits before the stored value changes, so read the new state on the next pass.
            .sink { [weak self] _ in DispatchQueue.main.async { self?.notchStateChanged() } }
            .store(in: &cancellables)
        layout.$panelStyle
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.notchStateChanged() } }
            .store(in: &cancellables)

        layout.prepareToGrow = { [weak self] size in
            guard let self, self.layout.isPinnedToNotch else { return }
            self.shrinkWorkItem?.cancel()
            self.setNotchSize(CGSize(width: max(self.frame.width, size.width), height: max(self.frame.height, size.height)))
        }
    }

    // Becoming key lets the first click reach SwiftUI buttons, and lets us notice clicks outside.
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        // Clicking anywhere else closes the notch island, like the real Dynamic Island.
        guard layout.isPinnedToNotch && !layout.staysOpen && layout.isExpanded else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let location = NSEvent.mouseLocation
        // Pritunl coming to the front while a VPN connects or disconnects from the notch isn't a click
        // elsewhere: with the pointer still on the panel, it stays, and closes once the pointer
        // leaves. Other apps coming forward, like one a notification or the artwork opens, close it.
        if layout.openOnHover && VPNManager.shared.mayTakeFocus && containsPointer(location) {
            log.info("Lost the focus to \(app, privacy: .public) with the pointer on the panel at \(Int(location.x)), \(Int(location.y)); staying open")
            return
        }
        log.info("Lost the focus to \(app, privacy: .public), pointer at \(Int(location.x)), \(Int(location.y)) (panel \(Int(self.frame.minX))...\(Int(self.frame.maxX)), \(Int(self.frame.minY))...\(Int(self.frame.maxY))); closing")
        layout.collapse()
    }

    /// Whether the point is on the panel, its edges included: the pointer pushed against the top of
    /// the screen sits on the panel's top edge, which `NSRect.contains` leaves out.
    private func containsPointer(_ point: NSPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    // MARK: Hover

    private func pointerMoved() {
        guard layout.isPinnedToNotch, layout.openOnHover, isVisible else { return }
        let location = NSEvent.mouseLocation
        let inside = layout.isExpanded ? containsPointer(location) : notchHoverRect.contains(location)
        guard inside != isMouseInside else { return }
        isMouseInside = inside
        if inside {
            pointerEntered()
        } else {
            pointerExited()
        }
    }

    private func pointerEntered() {
        hoverCloseWorkItem?.cancel()
        // Pointing at a notification banner (to read it) shouldn't cover it with the open panel.
        guard layout.isPinnedToNotch, layout.openOnHover, !layout.isExpanded, !layout.showsBanner else { return }

        // A short delay so sweeping past the notch on the way to the menu bar doesn't open it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.layout.isExpanded, !self.layout.showsBanner, self.notchHoverRect.contains(NSEvent.mouseLocation) else { return }
            self.layout.expand()
        }
        hoverOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func pointerExited() {
        hoverOpenWorkItem?.cancel()
        guard layout.isPinnedToNotch, layout.openOnHover, layout.isExpanded, !layout.staysOpen else { return }
        scheduleHoverClose()
    }

    private func scheduleHoverClose() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.layout.isExpanded, !self.layout.staysOpen else { return }
            // A menu (like the gear menu) is open and tracking the mouse: check again once it closes.
            if RunLoop.current.currentMode == .eventTracking {
                self.scheduleHoverClose()
                return
            }
            let location = NSEvent.mouseLocation
            guard !self.containsPointer(location) else { return }
            // Text being typed, like a reply to a poke, isn't lost when the pointer wanders off;
            // a click elsewhere still closes it.
            if self.isKeyWindow, let editor = self.firstResponder as? NSTextView, !editor.string.isEmpty {
                return
            }
            self.log.info("Pointer left the panel at \(Int(location.x)), \(Int(location.y)) (panel \(Int(self.frame.minX))...\(Int(self.frame.maxX)), \(Int(self.frame.minY))...\(Int(self.frame.maxY))); closing")
            self.layout.collapse()
        }
        hoverCloseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The collapsed island on screen, slightly enlarged so the very edge of the notch counts.
    private var notchHoverRect: NSRect {
        guard let screen = IslandLayout.notchScreen else { return .zero }
        let size = layout.notchCollapsedSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
            .insetBy(dx: -4, dy: -4)
    }

    // Allow sitting on top of the menu bar, where AppKit would normally push windows down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    private func applyMode(pinnedToNotch: Bool) {
        level = pinnedToNotch ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) : .floating
        hasShadow = !pinnedToNotch
        // Dark appearance so system colors stay readable against the black notch. Menus (like
        // Settings) follow the app's appearance, not the window's, so the app goes dark too.
        appearance = pinnedToNotch ? NSAppearance(named: .darkAqua) : nil
        NSApp.appearance = appearance
        container.fixedContentSize = pinnedToNotch ? layout.notchLargestWindowSize : nil

        // @Published emits before the stored value changes, so update on the next run loop pass.
        DispatchQueue.main.async {
            if pinnedToNotch {
                self.setNotchSize(self.layout.notchWindowSize)
            } else {
                self.fitFloatingContent()
            }
        }
    }

    /// Floating mode: size the window to the island (which reports its size) and keep it in place.
    private func fitFloatingContent() {
        let size = layout.floatingContentSize
        guard !layout.isPinnedToNotch, size.width > 0, size.height > 0 else { return }
        if frame.size != size {
            setContentSize(size)
        }
        reposition()
    }

    private func notchStateChanged() {
        guard layout.isPinnedToNotch else { return }
        shrinkWorkItem?.cancel()

        let target = layout.notchWindowSize
        if target.width >= frame.width && target.height >= frame.height {
            setNotchSize(target)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.setNotchSize(self.layout.notchWindowSize)
            }
            shrinkWorkItem = work
            // Wait for the shrinking spring to settle before making the window smaller.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    /// Sizes the window and centers it under the top edge of the notch screen.
    private func setNotchSize(_ size: CGSize) {
        guard let screen = IslandLayout.notchScreen else { return }
        let rect = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        if rect != frame {
            setFrame(rect, display: true)
        }
    }

    @objc private func screensChanged() {
        layout.refreshNotch()
        if layout.isPinnedToNotch {
            container.fixedContentSize = layout.notchLargestWindowSize
            setNotchSize(layout.notchWindowSize)
        } else {
            reposition()
        }
    }

    /// Keeps the floating island's top-left corner where the user left it.
    @objc func reposition() {
        guard !layout.isPinnedToNotch, frame.width > 0 else { return }
        let topLeft = savedFloatingTopLeft ?? defaultFloatingTopLeft
        let origin = NSPoint(x: topLeft.x, y: topLeft.y - frame.height)
        if origin != frame.origin {
            setFrameOrigin(origin)
        }
    }

    /// Called after the user finishes dragging the floating island.
    func saveFloatingPosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.floatingPositionKey)
    }

    private var savedFloatingTopLeft: NSPoint? {
        UserDefaults.standard.string(forKey: Self.floatingPositionKey).map(NSPointFromString)
    }

    private var defaultFloatingTopLeft: NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - 8)
    }
}

/// The panel's content view. In notch mode the island's SwiftUI view keeps one fixed size,
/// centered at the top, and the window only shows the part of it that fits. SwiftUI then never
/// sees the window resize: when it did, the resize could land in the same pass as the opening
/// animation, and the island slid in from the left instead of growing out of the notch.
private final class IslandContainerView: NSView {
    /// Nil: the SwiftUI view fills the window (floating mode).
    var fixedContentSize: CGSize? {
        didSet { resizeSubviews(withOldSize: bounds.size) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard let content = subviews.first else { return }
        guard let size = fixedContentSize else {
            content.frame = bounds
            return
        }
        content.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height, width: size.width, height: size.height)
    }
}

/// Transparent overlay that drags its window, and reports a click when the mouse didn't move.
struct WindowDragArea: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onClick = onClick
    }

    class DragView: NSView {
        var onClick: (() -> Void)?
        private var mouseDownLocation: NSPoint?
        private var windowOriginAtMouseDown: NSPoint?
        private var didDrag = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = NSEvent.mouseLocation
            windowOriginAtMouseDown = window?.frame.origin
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = window as? FloatingPanel, panel.isDraggable,
                  let start = mouseDownLocation, let origin = windowOriginAtMouseDown else { return }
            let current = NSEvent.mouseLocation
            let dx = current.x - start.x
            let dy = current.y - start.y
            if !didDrag && hypot(dx, dy) < 3 { return }
            didDrag = true
            panel.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            if didDrag {
                (window as? FloatingPanel)?.saveFloatingPosition()
            } else {
                onClick?()
            }
            mouseDownLocation = nil
            windowOriginAtMouseDown = nil
        }
    }
}
