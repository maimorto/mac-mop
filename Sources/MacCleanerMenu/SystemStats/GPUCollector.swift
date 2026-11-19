import Foundation
import Darwin
import IOKit

// GPU details for the GPU tab, from the public IOAccelerator registry
// entries: utilisation counters ("PerformanceStatistics"), model name and
// core count of the accelerator, and per-process GPU time from its user
// clients ("AppUsage" → accumulatedGPUTime, nanoseconds). Read only while
// the GPU tab is on screen.

struct GPUDetails: Sendable {
    var name: String?
    var cores: Int?
    var device: Double?
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: UInt64?
    var memoryAllocated: UInt64?
    /// Share of one GPU's time per process over the last interval (0...1).
    var processes: [(pid: Int32, name: String, share: Double)] = []
}

final class GPUMonitor: @unchecked Sendable {
    private var last: [Int32: UInt64] = [:]
    private var lastAt: UInt64 = 0
    private var staticInfo: (name: String?, cores: Int?)?

    func sample(withProcesses: Bool) -> GPUDetails {
        var d = GPUDetails()
        guard let matching = IOServiceMatching("IOAccelerator") else { return d }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return d }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard d.device == nil,
                  let stats = Self.property(service, "PerformanceStatistics") as? [String: Any] else { continue }
            func pct(_ k: String) -> Double? { (stats[k] as? NSNumber).map { min(max($0.doubleValue / 100, 0), 1) } }
            func bytes(_ k: String) -> UInt64? { (stats[k] as? NSNumber).map { $0.uint64Value } }
            d.device = pct("Device Utilization %") ?? pct("GPU Activity(%)")
            d.renderer = pct("Renderer Utilization %")
            d.tiler = pct("Tiler Utilization %")
            d.memoryInUse = bytes("In use system memory") ?? bytes("vramUsedBytes")
            d.memoryAllocated = bytes("Alloc system memory")
            if withProcesses { d.processes = processShares(of: service) }
            if staticInfo == nil {
                staticInfo = (Self.property(service, "model") as? String,
                              (Self.property(service, "gpu-core-count") as? NSNumber)?.intValue)
            }
        }
        d.name = staticInfo?.name
        d.cores = staticInfo?.cores
        return d
    }

    /// Full executable name (the registry's creator name is cut at 16 characters).
    private static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        // Inside an app bundle, prefer the bundle's executable name as is.
        return (path as NSString).lastPathComponent
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Sums accumulatedGPUTime per creating process across the GPU's user
    /// clients and turns the change since the previous sample into a share.
    private func processShares(of accelerator: io_registry_entry_t) -> [(pid: Int32, name: String, share: Double)] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var totals: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        var client = IOIteratorNext(iterator)
        while client != 0 {
            defer { IOObjectRelease(client); client = IOIteratorNext(iterator) }
            guard let usage = Self.property(client, "AppUsage") as? [[String: Any]], !usage.isEmpty,
                  let creator = Self.property(client, "IOUserClientCreator") as? String else { continue }
            // "pid 599, WindowServer"
            let parts = creator.split(separator: ",", maxSplits: 1)
            guard let pidPart = parts.first, let pid = Int32(pidPart.replacingOccurrences(of: "pid", with: "").trimmingCharacters(in: .whitespaces))
            else { continue }
            let time = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
            totals[pid, default: 0] &+= time
            if names[pid] == nil, parts.count > 1 { names[pid] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { last = totals; lastAt = now }
        guard lastAt > 0, now > lastAt else { return [] }
        let elapsed = Double(now - lastAt)
        return totals.compactMap { pid, total -> (pid: Int32, name: String, share: Double)? in
            guard let before = last[pid], total > before else { return nil }
            return (pid, Self.processName(pid) ?? names[pid] ?? "\(pid)", min(Double(total - before) / elapsed, 1))
        }
        .sorted { $0.share > $1.share }
        .prefix(6)
        .map { $0 }
    }
}
