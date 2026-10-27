import AppKit
import Combine
import SwiftUI

/// Tabs of the expanded notch panel, modeled after NotchNook.
enum NotchTab: String, CaseIterable {
    case nook = "Nook"
    case system = "System"

    var icon: String {
        switch self {
        case .nook: return "sparkles"
        case .system: return "chart.bar.fill"
        }
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
    @Published var isExpanded = false
    /// Pinned open: the open notch doesn't close when the pointer leaves it or on a click elsewhere.
    @Published var staysOpen = false
    @Published var selectedTab: NotchTab = .nook
    /// Size of the floating island as laid out by SwiftUI; the floating window follows it.
    @Published var floatingContentSize: CGSize = .zero
    /// Whether the collapsed island shows its wings (music playing / unread notifications).
    /// When idle it is exactly as wide as the physical notch, like the iPhone's Dynamic Island.
    @Published private(set) var showsWings = false
    @Published private(set) var notchSize: CGSize

    /// Width of the black "wings" shown beside the physical notch while collapsed.
    static let notchWing: CGFloat = 40
    static let notchExpandedSize = CGSize(width: 640, height: 180)
    /// Opening overshoots slightly, like the iPhone's Dynamic Island; closing settles smoothly.
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.72)
    static let collapseAnimation = Animation.spring(response: 0.36, dampingFraction: 0.9)

    /// Set by the notch window: enlarges it to the given size before a growing animation starts,
    /// so the first animated frame still has the old size instead of jumping to the new one.
    var prepareToGrow: ((CGSize) -> Void)?

    private static let pinnedKey = "islandPinnedToNotch"
    private static let openOnHoverKey = "islandOpenOnHover"

    init() {
        isPinnedToNotch = UserDefaults.standard.object(forKey: Self.pinnedKey) as? Bool ?? true
        openOnHover = UserDefaults.standard.object(forKey: Self.openOnHoverKey) as? Bool ?? true
        notchSize = Self.measureNotch()
    }

    var notchCollapsedSize: CGSize {
        CGSize(width: notchSize.width + (showsWings ? Self.notchWing * 2 : 0), height: notchSize.height)
    }

    /// Transparent room around the open island so the opening spring's overshoot isn't clipped.
    static let overshootMargin: CGFloat = 16

    var notchWindowSize: CGSize {
        isExpanded ? Self.notchExpandedWindowSize : notchCollapsedSize
    }

    static var notchExpandedWindowSize: CGSize {
        CGSize(width: notchExpandedSize.width + overshootMargin * 2, height: notchExpandedSize.height + overshootMargin)
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
        grow(to: Self.notchExpandedWindowSize) {
            self.isExpanded = true
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

    private func grow(to size: CGSize, _ change: @escaping () -> Void) {
        guard let prepareToGrow else {
            withAnimation(Self.expandAnimation, change)
            return
        }
        prepareToGrow(size)
        DispatchQueue.main.async {
            withAnimation(Self.expandAnimation, change)
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
        Publishers.CombineLatest(layout.$isExpanded, layout.$showsWings)
            .dropFirst()
            // @Published emits before the stored value changes, so read the new state on the next pass.
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
        if layout.isPinnedToNotch && !layout.staysOpen {
            layout.collapse()
        }
    }

    // MARK: Hover

    private func pointerMoved() {
        guard layout.isPinnedToNotch, layout.openOnHover, isVisible else { return }
        let location = NSEvent.mouseLocation
        let inside = layout.isExpanded ? frame.contains(location) : notchHoverRect.contains(location)
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
        guard layout.isPinnedToNotch, layout.openOnHover, !layout.isExpanded else { return }

        // A short delay so sweeping past the notch on the way to the menu bar doesn't open it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.layout.isExpanded, self.notchHoverRect.contains(NSEvent.mouseLocation) else { return }
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
            guard !self.frame.contains(NSEvent.mouseLocation) else { return }
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
        // Dark appearance so system colors stay readable against the black notch.
        appearance = pinnedToNotch ? NSAppearance(named: .darkAqua) : nil
        container.fixedContentSize = pinnedToNotch ? IslandLayout.notchExpandedWindowSize : nil

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
