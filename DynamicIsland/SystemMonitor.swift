import Foundation
import Combine
import Darwin
import IOKit.ps
import Network

/// Samples battery, CPU, memory and network state every 2 seconds.
class SystemMonitor: ObservableObject {
    @Published var batteryLevel: Int = 0
    @Published var isCharging = false
    @Published var cpuUsage: Int = 0
    @Published var memoryUsage: Int = 0
    @Published var networkConnected = true

    private let host = mach_host_self()
    private var previousCPUTicks: (busy: UInt64, total: UInt64)?
    private var updateTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var lowBatteryNotified = false

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkChange(connected: path.status == .satisfied)
        }
        pathMonitor.start(queue: .main)

        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateSystemStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit {
        updateTask?.cancel()
        pathMonitor.cancel()
    }

    func updateSystemStats() {
        updateBattery()
        updateCPU()
        updateMemory()
    }

    private func handleNetworkChange(connected: Bool) {
        guard connected != networkConnected else { return }
        networkConnected = connected
        NotificationManager.shared.post(
            .network,
            title: connected ? "Back Online" : "Network Offline",
            body: connected ? "Internet connection restored" : "Internet connection lost"
        )
    }

    private func updateBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }

            batteryLevel = current * 100 / max
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        }

        if batteryLevel <= 20 && !isCharging {
            if !lowBatteryNotified {
                lowBatteryNotified = true
                NotificationManager.shared.post(.warning, title: "Low Battery", body: "Battery at \(batteryLevel)%")
            }
        } else {
            lowBatteryNotified = false
        }
    }

    private func updateCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        // Ticks are cumulative since boot, so usage is the delta between two samples.
        if let previous = previousCPUTicks, total > previous.total {
            cpuUsage = Int((Double(busy - previous.busy) / Double(total - previous.total) * 100).rounded())
        }
        previousCPUTicks = (busy, total)
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let pageSize = UInt64(getpagesize())
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        memoryUsage = Int((Double(usedPages * pageSize) / Double(total) * 100).rounded())
    }
}
