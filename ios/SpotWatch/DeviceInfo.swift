import Foundation
import UIKit

// Readings of the phone itself: CPU, memory, heat, battery.

enum DeviceInfo {
    /// The hardware model, e.g. "iPhone8,1" for an iPhone 6s.
    static let model: String = {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    static let cores = ProcessInfo.processInfo.activeProcessorCount

    /// This app's CPU use, summed over its threads (task_threads), as a percent
    /// of one core: two busy cores read 200%. Each thread's figure is the
    /// kernel's recent average, so this is a smoothed reading.
    static func cpuPercent() -> Double? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let list = threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
            mach_port_deallocate(mach_task_self_, list[i])
        }
        return total
    }

    /// Memory charged to the app (what iOS counts toward killing it), in MB.
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    /// How much more memory the app may use before iOS stops it, in MB, or
    /// nil where iOS doesn't say (the Simulator returns 0).
    static func headroomMB() -> Double? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1_048_576 : nil
    }

    static func thermalText(_ s: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// "64% charging". Needs battery monitoring on; the Simulator has no battery.
    static func batteryText(level: Float, state: UIDevice.BatteryState) -> String {
        let pct = level < 0 ? "level unknown" : "\(Int((level * 100).rounded()))%"
        switch state {
        case .charging: return pct + " charging"
        case .full: return pct + " full"
        case .unplugged: return pct + " on battery"
        case .unknown: return pct + " (state unknown)"
        @unknown default: return pct
        }
    }
}
