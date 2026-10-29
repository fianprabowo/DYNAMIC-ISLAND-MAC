import AppKit
import AudioToolbox
import Combine
import CoreAudio

/// Volume and brightness on the notch while they change. macOS's own indicator still shows too:
/// hiding it would mean taking over the volume and brightness keys.
///
/// Volume changes are watched through Core Audio, so the menu bar slider and other apps count too.
/// Brightness has no public API: it's read through the private DisplayServices framework when a
/// brightness key is pressed (seen with the Accessibility access the Dock badge watcher has).
class HUDMonitor: ObservableObject {
    enum Kind {
        case volume, brightness
    }

    struct Level: Equatable {
        var kind: Kind
        var value: Double
        var isMuted = false
    }

    @Published private(set) var level: Level?
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                level = nil
            }
        }
    }

    private static let enabledKey = "hudEnabled"
    private static let visibleDuration: TimeInterval = 1.5
    /// A new output device brings its own volume; that isn't a change worth showing.
    private static let deviceSwitchGrace: TimeInterval = 1

    private var outputListener: AudioPropertyListener?
    private var volumeListeners: [AudioPropertyListener] = []
    private var outputSwitchDate = Date.distantPast
    private var keyMonitors: [Any] = []
    private var hideTask: Task<Void, Never>?
    private var brightnessTask: Task<Void, Never>?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        outputListener = AudioPropertyListener(AudioDevice.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.watchOutputVolume()
        }
        watchOutputVolume()

        // Volume and brightness keys arrive as system-defined events: global while other apps are
        // active, local while the island is.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { [weak self] event in
            self?.handleKey(event)
        }) {
            keyMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { [weak self] event in
            self?.handleKey(event)
            return event
        }) {
            keyMonitors.append(monitor)
        }
    }

    deinit {
        keyMonitors.forEach(NSEvent.removeMonitor)
        hideTask?.cancel()
        brightnessTask?.cancel()
    }

    private func watchOutputVolume() {
        outputSwitchDate = Date()
        volumeListeners = []
        guard let device = AudioDevice.defaultOutput else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            if let listener = AudioPropertyListener(device, selector, scope: kAudioDevicePropertyScopeOutput, handler: { [weak self] in
                guard let self, Date().timeIntervalSince(self.outputSwitchDate) > Self.deviceSwitchGrace else { return }
                self.showVolume()
            }) {
                volumeListeners.append(listener)
            }
        }
    }

    private func showVolume() {
        guard let device = AudioDevice.defaultOutput, let volume = AudioDevice.volume(of: device) else { return }
        show(Level(kind: .volume, value: Double(volume), isMuted: AudioDevice.isMuted(device)))
    }

    // From IOKit's ev_keymap.h.
    private static let auxControlButtons: Int16 = 8
    private static let soundKeys: Set<Int> = [0, 1, 7] // NX_KEYTYPE_SOUND_UP, _SOUND_DOWN, _MUTE
    private static let brightnessKeys: Set<Int> = [2, 3] // NX_KEYTYPE_BRIGHTNESS_UP, _DOWN

    private func handleKey(_ event: NSEvent) {
        guard event.subtype.rawValue == Self.auxControlButtons else { return }
        let key = (event.data1 & 0xFFFF0000) >> 16
        let isKeyDown = (event.data1 & 0xFF00) >> 8 == 0x0A
        guard isKeyDown else { return }

        if Self.soundKeys.contains(key) {
            // Shows the level even when it can't go further (already at full or zero).
            showVolume()
        } else if Self.brightnessKeys.contains(key) {
            followBrightness()
        }
    }

    /// macOS fades brightness to its new level, so it's read a few times after the key press.
    private func followBrightness() {
        brightnessTask?.cancel()
        brightnessTask = Task { [weak self] in
            for _ in 0..<6 {
                if let brightness = Brightness.builtInDisplay {
                    self?.show(Level(kind: .brightness, value: Double(brightness)))
                }
                try? await Task.sleep(for: .seconds(0.08))
                if Task.isCancelled { return }
            }
        }
    }

    private func show(_ newLevel: Level) {
        guard isEnabled else { return }
        level = newLevel
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleDuration))
            guard !Task.isCancelled else { return }
            self?.level = nil
        }
    }
}

/// The built-in display's brightness through the private DisplayServices framework (loaded at run
/// time, so a macOS without it only loses the brightness indicator).
nonisolated enum Brightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let getBrightness: GetBrightness? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    /// 0…1, or nil without a built-in display (like a closed MacBook on an external one).
    static var builtInDisplay: Float? {
        guard let getBrightness else { return nil }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        var brightness: Float = 0
        guard getBrightness(display, &brightness) == 0 else { return nil }
        return brightness
    }
}
