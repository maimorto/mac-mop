import Foundation
import IOKit
import MacCleanerKit

// MARK: - Live CPU / memory samples for the Overview tiles

/// Samples CPU and memory every 2 s, only while the Overview is on screen and
/// the app is frontmost. Two `host_statistics` calls per tick: negligible.
@MainActor
@Observable
final class OverviewLiveStats {
    static let shared = OverviewLiveStats()
    static let points = 40

    private(set) var cpu: Double = 0
    private(set) var memory: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var pressureLevel = 1   // 1 normal, 2 warning, 4 critical

    private var previous: host_cpu_load_info?
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { OverviewLiveStats.shared.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        if let load = Self.cpuLoad() {
            if let prev = previous {
                let user = Double(load.cpu_ticks.0 &- prev.cpu_ticks.0)
                let system = Double(load.cpu_ticks.1 &- prev.cpu_ticks.1)
                let idle = Double(load.cpu_ticks.2 &- prev.cpu_ticks.2)
                let nice = Double(load.cpu_ticks.3 &- prev.cpu_ticks.3)
                let total = user + system + idle + nice
                if total > 0 { cpu = (user + system + nice) / total }
            }
            previous = load
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        if let used = Self.memoryUsed(), total > 0 { memory = min(1, Double(used) / total) }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { pressureLevel = Int(level) }

        Self.push(cpu, &cpuHistory)
        Self.push(memory, &memoryHistory)
    }

    private static func push(_ v: Double, _ a: inout [Double]) {
        if a.isEmpty { a = Array(repeating: v, count: 2) }
        a.append(v)
        if a.count > points { a.removeFirst(a.count - points) }
    }

    private static func cpuLoad() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return r == KERN_SUCCESS ? info : nil
    }

    private static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }
}

// MARK: - Battery health

struct BatteryHealth: Sendable {
    let cycles: Int?
    /// Current full-charge capacity as a fraction of the design capacity.
    let capacity: Double?

    static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        let design = int("DesignCapacity")
        let raw = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        var capacity: Double?
        if let design, let raw, design > 0 { capacity = min(1, Double(raw) / Double(design)) }
        return BatteryHealth(cycles: int("CycleCount"), capacity: capacity)
    }
}

// MARK: - Space you can reclaim right now

/// Sizes of the usual suspects, measured off the main thread and cached for
/// five minutes. `nil` means "not measurable" (e.g. no Full Disk Access).
@MainActor
@Observable
final class QuickReclaim {
    static let shared = QuickReclaim()

    private(set) var trash: UInt64? { didSet { save("trash", trash) } }
    private(set) var downloads: UInt64? { didSet { save("downloads", downloads) } }
    private(set) var caches: UInt64? { didSet { save("caches", caches) } }
    private(set) var installers: (count: Int, bytes: UInt64)? {
        didSet { save("installerBytes", installers?.bytes); save("installerCount", installers.map { UInt64($0.count) }) }
    }
    private(set) var measuring = false
    private var measuredAt: Date? { didSet { defaults.set(measuredAt, forKey: "kmr.reclaim.date") } }
    private let defaults = UserDefaults.standard

    /// Last results are shown instantly on launch; the walk (Downloads can be
    /// hundreds of GB) reruns at most once an hour.
    private init() {
        func load(_ k: String) -> UInt64? { (defaults.object(forKey: "kmr.reclaim.\(k)") as? Double).map { UInt64($0) } }
        trash = load("trash"); downloads = load("downloads"); caches = load("caches")
        if let b = load("installerBytes"), let c = load("installerCount") { installers = (Int(c), b) }
        measuredAt = defaults.object(forKey: "kmr.reclaim.date") as? Date
    }

    private func save(_ key: String, _ v: UInt64?) {
        if let v { defaults.set(Double(v), forKey: "kmr.reclaim.\(key)") } else { defaults.removeObject(forKey: "kmr.reclaim.\(key)") }
    }

    func refreshIfStale() {
        if measuring { return }
        if let measuredAt, Date().timeIntervalSince(measuredAt) < 6 * 3600 { return }
        measuring = true
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Each value lands as soon as it is measured (Downloads can be slow).
        // Background, one thread each: Downloads can hold millions of files and
        // a parallel walk would load every core while the user just looks at
        // the Overview.
        Task { trash = await Task.detached(priority: .background) { Self.size("\(home)/.Trash") }.value; settle() }
        Task { caches = await Task.detached(priority: .background) { Self.size("\(home)/Library/Caches") }.value; settle() }
        Task { installers = await Task.detached(priority: .background) { Self.installers(in: "\(home)/Downloads") }.value; settle() }
        Task { downloads = await Task.detached(priority: .background) { Self.size("\(home)/Downloads") }.value; settle() }
    }

    var measuredAtText: String? { measuredAt?.formatted(.relative(presentation: .named).locale(UIText.locale)) }

    private var pending = 0
    private func settle() {
        pending += 1
        if pending >= 4 { pending = 0; measuredAt = Date(); measuring = false }
    }

    /// getattrlistbulk walk (same engine as Space Lens): several times
    /// cheaper than a FileManager enumerator on big folders.
    nonisolated private static func size(_ path: String) -> UInt64? {
        // Unreadable (TCC) folders fail here instead of silently reporting 0.
        guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else { return nil }
        let scanner = FastDiskScanner()
        _ = scanner.scan(root: URL(fileURLWithPath: path), parallel: false)
        return scanner.progress.bytes
    }

    nonisolated private static func installers(in path: String) -> (count: Int, bytes: UInt64)? {
        let exts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        var count = 0
        var bytes: UInt64 = 0
        for name in names where exts.contains((name as NSString).pathExtension.lowercased()) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            count += 1
            bytes &+= UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return (count, bytes)
    }
}
