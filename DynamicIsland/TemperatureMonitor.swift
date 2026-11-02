import Foundation
import Combine
import AppKit

/// Reads Apple Silicon temperature sensors through the IOHID event system.
///
/// The IOHIDEventSystemClient functions are not in the public headers, so they are
/// looked up at runtime. Sensor names are the ones exposed on M1-family chips:
/// "PMU tdie*" (CPU die), "PMU TP*g" (GPU) and "gas gauge battery".
class TemperatureMonitor: ObservableObject {
    @Published var cpuTemp: Double = 0
    @Published var gpuTemp: Double = 0
    @Published var batteryTemp: Double = 0
    @Published var systemTemp: String = "—"
    @Published var systemTempColor: NSColor = .systemGreen

    private let sensors = HIDTemperatureSensors()
    private var updateTask: Task<Void, Never>?
    private var lastAlertLevel = ThermalLevel.cool

    init() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateTemperatures()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    deinit {
        updateTask?.cancel()
    }

    func updateTemperatures() {
        let readings = sensors?.read() ?? []

        cpuTemp = average(readings, where: { $0.hasPrefix("PMU tdie") })
        gpuTemp = average(readings, where: { $0.hasPrefix("PMU TP") && $0.hasSuffix("g") })
        batteryTemp = average(readings, where: { $0 == "gas gauge battery" })

        let level = ThermalLevel(temperature: max(cpuTemp, gpuTemp))
        systemTemp = level.label
        systemTempColor = level.color

        if level >= .hot && level > lastAlertLevel {
            NotificationManager.shared.post(.warning, title: "System \(level.label)", body: String(format: "CPU at %.1f°C", cpuTemp))
        }
        lastAlertLevel = level
    }

    private func average(_ readings: [(name: String, value: Double)], where matches: (String) -> Bool) -> Double {
        let values = readings.filter { matches($0.name) && $0.value > 0 && $0.value < 150 }.map(\.value)
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

enum ThermalLevel: Int, Comparable {
    case cool, normal, warm, hot, critical

    init(temperature: Double) {
        switch temperature {
        case ..<50: self = .cool
        case ..<70: self = .normal
        case ..<80: self = .warm
        case ..<90: self = .hot
        default: self = .critical
        }
    }

    var label: String {
        switch self {
        case .cool: return "Cool"
        case .normal: return "Normal"
        case .warm: return "Warm"
        case .hot: return "Hot"
        case .critical: return "Critical"
        }
    }

    var color: NSColor {
        switch self {
        case .cool: return .systemGreen
        case .normal: return .systemBlue
        case .warm: return .systemYellow
        case .hot: return .systemOrange
        case .critical: return .systemRed
        }
    }

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private final class HIDTemperatureSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEventType: Int64 = 15

    private let client: CFTypeRef
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloatValue: GetFloatValueFn

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloatValue = dlsym(handle, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        // Usage page 0xff00 / usage 5 = Apple vendor temperature sensors.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, matching)

        self.client = client
        self.copyServices = unsafeBitCast(copyServices, to: CopyServicesFn.self)
        self.copyProperty = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloatValue = unsafeBitCast(getFloatValue, to: GetFloatValueFn.self)
    }

    func read() -> [(name: String, value: Double)] {
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }

        return services.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { return nil }
            let field = Int32(Self.temperatureEventType << 16)
            return (name, getFloatValue(event, field))
        }
    }
}
