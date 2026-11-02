import AppKit
import AudioToolbox
import CoreAudio

/// Reads the sound output devices through Core Audio's property API.
nonisolated enum AudioDevice {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static var defaultOutput: AudioObjectID? {
        let id: AudioObjectID? = value(of: system, kAudioHardwarePropertyDefaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    static var all: [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let transport: UInt32? = value(of: device, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The volume as the menu bar and the volume keys set it (0…1); nil for devices without one.
    static func volume(of device: AudioObjectID) -> Float? {
        value(of: device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        let muted: UInt32? = value(of: device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return muted == 1
    }

    private static func value<T>(of object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}

/// Calls `handler` on the main queue whenever a Core Audio property changes, until released.
final class AudioPropertyListener {
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        self.object = object
        self.address = address
        self.block = block
    }

    deinit {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}

/// Shows Bluetooth headphones (like AirPods) on the notch when they connect or disconnect, with
/// their battery levels when macOS reports them. macOS switches the sound output to headphones as
/// they connect, so watching the default output device needs no Bluetooth access.
class HeadphonesWatcher {
    private struct Output {
        let id: AudioObjectID
        let name: String
        let isBluetooth: Bool
    }

    private let notificationManager: NotificationManager
    private var outputListener: AudioPropertyListener?
    private var devicesListener: AudioPropertyListener?
    private var output: Output?
    /// When each device appeared; devices there at launch count as long connected.
    private var deviceAppearances: [AudioObjectID: Date] = [:]

    /// The output switching to a device that appeared within this time is a connection; switching
    /// to one that was there already (picked in the Sound menu, say) isn't.
    private static let connectionWindow: TimeInterval = 15

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
        // Headphones connected before launch aren't announced.
        output = Self.currentOutput()
        for device in AudioDevice.all {
            deviceAppearances[device] = .distantPast
        }
        devicesListener = AudioPropertyListener(AudioDevice.system, kAudioHardwarePropertyDevices) { [weak self] in
            self?.devicesChanged()
        }
        outputListener = AudioPropertyListener(AudioDevice.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputChanged()
        }
    }

    private func devicesChanged() {
        let devices = AudioDevice.all
        deviceAppearances = deviceAppearances.filter { devices.contains($0.key) }
        for device in devices where deviceAppearances[device] == nil {
            deviceAppearances[device] = Date()
        }
    }

    /// The default output may change before the device list does, so an unknown device is new too.
    private func isNewlyConnected(_ device: AudioObjectID) -> Bool {
        guard let appeared = deviceAppearances[device] else { return true }
        return Date().timeIntervalSince(appeared) < Self.connectionWindow
    }

    private static func currentOutput() -> Output? {
        guard let id = AudioDevice.defaultOutput else { return nil }
        return Output(id: id, name: AudioDevice.name(of: id) ?? "Headphones", isBluetooth: AudioDevice.isBluetooth(id))
    }

    private func outputChanged() {
        let previous = output
        output = Self.currentOutput()
        guard output?.id != previous?.id else { return }

        if let output, output.isBluetooth {
            if isNewlyConnected(output.id) {
                connected(output.name)
            }
        } else if let previous, previous.isBluetooth, !AudioDevice.all.contains(previous.id) {
            // Switching to the speakers while the headphones stay connected isn't a disconnect.
            post(AppNotification(type: .audio, title: previous.name, body: "Disconnected", symbol: Self.symbol(for: previous.name)))
        }
    }

    private func connected(_ name: String) {
        let notification = AppNotification(type: .audio, title: name, body: "Connected", symbol: Self.symbol(for: name))
        post(notification)
        Task { [weak self] in
            // AirPods report their battery a moment after connecting.
            for delay in [1.0, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                if let battery = await Self.batteryLevels(of: name) {
                    let updated = AppNotification(id: notification.id, type: .audio, title: name, body: "Connected · \(battery)", date: notification.date, symbol: notification.symbol)
                    self?.notificationManager.updateActivity(updated)
                    return
                }
            }
        }
    }

    private func post(_ notification: AppNotification) {
        notificationManager.postActivity(notification, duringFocus: true)
    }

    private static func symbol(for name: String) -> String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    /// Battery levels of a connected Bluetooth device, like "L 80% · R 82% · Case 60%". Only
    /// system_profiler reports them without private API; nil when it doesn't know them.
    private static func batteryLevels(of name: String) async -> String? {
        guard let data = await CommandRunner.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                guard let info = entry[name] as? [String: Any] else { continue }
                let levels = [("L ", "device_batteryLevelLeft"), ("R ", "device_batteryLevelRight"),
                              ("Case ", "device_batteryLevelCase"), ("", "device_batteryLevelMain")]
                    .compactMap { label, key in (info[key] as? String).map { label + $0 } }
                return levels.isEmpty ? nil : levels.joined(separator: " · ")
            }
        }
        return nil
    }
}
