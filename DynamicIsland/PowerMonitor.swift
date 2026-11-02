import Foundation
import IOKit.ps

/// Shows the battery level on the notch the moment a charger is plugged in, like the iPhone.
/// Macs without a battery never show it.
class PowerMonitor {
    private let notificationManager: NotificationManager
    private var runLoopSource: CFRunLoopSource?
    private var isOnPower: Bool?

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
        isOnPower = Self.battery()?.isOnPower

        // Called on the main run loop whenever a power source changes.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().powerSourcesChanged()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    private func powerSourcesChanged() {
        guard let battery = Self.battery() else { return }
        defer { isOnPower = battery.isOnPower }
        guard battery.isOnPower, isOnPower == false else { return }

        // Right after plugging in macOS often doesn't report charging yet; read it again shortly.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let battery = Self.battery(), battery.isOnPower else { return }
            self?.announce(battery)
        }
    }

    private func announce(_ battery: Battery) {
        var body = "\(battery.level)%"
        if let minutes = battery.minutesToFull, minutes > 0 {
            body += minutes >= 60 ? " · \(minutes / 60)h \(minutes % 60)m until full" : " · \(minutes)m until full"
        }
        let notification = AppNotification(
            type: .power,
            // Plugged in but not charging: full, or holding the level (Optimized Battery Charging).
            title: battery.isCharging ? "Charging" : "Connected to Power",
            body: body,
            progress: Double(battery.level) / 100
        )
        notificationManager.postActivity(notification, duringFocus: true)
    }

    private struct Battery {
        let level: Int
        let isCharging: Bool
        let isOnPower: Bool
        /// Nil while macOS is still estimating, right after plugging in.
        let minutesToFull: Int?
    }

    private static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let minutesToFull = description[kIOPSTimeToFullChargeKey] as? Int
            return Battery(
                level: current * 100 / max,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesToFull: minutesToFull.flatMap { $0 >= 0 ? $0 : nil }
            )
        }
        return nil
    }
}
