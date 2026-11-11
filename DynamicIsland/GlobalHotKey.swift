import AppKit
import Carbon.HIToolbox
import OSLog

/// A keyboard shortcut that works from any app, like ⌃⌥P for Poke. It's a Carbon hot key: unlike
/// watching every key press, it needs no Accessibility permission, and only this one key
/// combination ever reaches the app. If another app registered the combination first, it does
/// nothing (and says so in the log).
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    private static var nextID: UInt32 = 1
    /// "DIsl", to tell this app's hot keys from others'.
    nonisolated private static let signature: OSType = 0x4449_736C
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "HotKey")

    /// `keyCode` is a virtual key code (like `kVK_ANSI_P`), `modifiers` Carbon's (like `controlKey | optionKey`).
    init(keyCode: Int, modifiers: Int, name: String, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), Self.handle, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &hotKey)
        if status == noErr {
            Self.log.info("\(name, privacy: .public) is on")
        } else {
            Self.log.error("\(name, privacy: .public) is taken by another app (\(status, privacy: .public))")
        }
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    /// Carbon calls this on the main thread for every hot key of the app; each one only answers its own.
    nonisolated private static let handle: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == signature else { return OSStatus(eventNotHandledErr) }
        return MainActor.assumeIsolated {
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return noErr
        }
    }
}
