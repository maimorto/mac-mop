import Foundation
import Darwin
import IOKit
import IOKit.ps
import Network
import SystemConfiguration
import AppKit

// Detailed collectors for the menu-bar panel: memory breakdown, disk I/O,
// per-process usage, latency and interface info. All of them are cheap system
// calls that run on the polling task, never on the main thread.

// MARK: - Memory

struct MemoryBreakdown: Sendable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var pressureLevel: Int = 1
    /// 0–100, the share of memory macOS considers under pressure.
    var pressurePercent: Double = 0

    var used: UInt64 { app &+ wired &+ compressed }
    var usedFraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }

    static func read() -> MemoryBreakdown {
        var m = MemoryBreakdown()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        } == KERN_SUCCESS
        if ok {
            let page = UInt64(getpagesize())
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.free = UInt64(stats.free_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = swap.xsu_used }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressureLevel = Int(level) }
        var freePct: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &freePct, &size, nil, 0) == 0 { m.pressurePercent = Double(100 - freePct) }
        return m
    }
}

// MARK: - Disk I/O

struct DiskIO: Sendable {
    var readPerSecond: Double = 0
    var writePerSecond: Double = 0
}

final class DiskIOMonitor: @unchecked Sendable {
    private var last: (read: UInt64, write: UInt64, at: Date)?

    func measure() -> DiskIO {
        let (r, w) = Self.totals()
        let now = Date()
        defer { last = (r, w, now) }
        guard let last, now > last.at else { return DiskIO() }
        let dt = now.timeIntervalSince(last.at)
        return DiskIO(readPerSecond: Double(r &- last.read) / dt, writePerSecond: Double(w &- last.write) / dt)
    }

    private static func totals() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read &+= (props["Bytes (Read)"] as? UInt64) ?? 0
                write &+= (props["Bytes (Write)"] as? UInt64) ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}

// MARK: - Processes

struct ProcessUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let memory: UInt64
    let cpu: Double
    let diskRead: Double
    let diskWrite: Double
    var id: Int32 { pid }
}

/// Per-process CPU, memory and disk I/O from proc_pid_rusage. Only processes
/// of the current user are readable without privileges, which covers the apps
/// people care about.
final class ProcessMonitor: @unchecked Sendable {
    private var last: [Int32: (cpu: UInt64, read: UInt64, write: UInt64)] = [:]
    private var lastAt: Date?
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// True when the next sample has no recent baseline (CPU/disk rates will read 0).
    var needsPriming: Bool { lastAt.map { Date().timeIntervalSince($0) > 8 } ?? true }

    func sample() -> [ProcessUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let now = Date()
        // A baseline older than a few seconds (the panel was closed) would
        // average CPU over minutes: treat it as a fresh start instead.
        let dt = lastAt.map { now.timeIntervalSince($0) }.flatMap { $0 <= 8 ? $0 : nil } ?? 0
        var next: [Int32: (UInt64, UInt64, UInt64)] = [:]
        var out: [ProcessUsage] = []
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard r == 0 else { continue }
            let cpuNs = UInt64(Double(info.ri_user_time + info.ri_system_time) * Self.timebase)
            next[pid] = (cpuNs, info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
            var cpu = 0.0, dr = 0.0, dw = 0.0
            if dt > 0, let prev = last[pid] {
                cpu = Double(cpuNs &- prev.cpu) / (dt * 1e9) * 100
                dr = Double(info.ri_diskio_bytesread &- prev.read) / dt
                dw = Double(info.ri_diskio_byteswritten &- prev.write) / dt
            }
            out.append(ProcessUsage(pid: pid, name: Self.name(pid), memory: info.ri_phys_footprint, cpu: cpu, diskRead: dr, diskWrite: dw))
        }
        last = next.mapValues { (cpu: $0.0, read: $0.1, write: $0.2) }
        lastAt = now
        return out
    }

    private static func name(_ pid: Int32) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }
}

// MARK: - Network details

struct NetworkDetails: Sendable {
    var interfaceName = "—"
    var interfaceKind = "—"
    var localIP = "—"
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
    var latencyMs: Double?
    var jitterMs: Double?
    var online = true
}

final class NetworkDetailsMonitor: @unchecked Sendable {
    private var latencies: [Double] = []
    private(set) var connectivity: [Bool] = []

    func collect(totalIn: UInt64, totalOut: UInt64, probe: Bool) async -> NetworkDetails {
        var d = NetworkDetails()
        d.totalIn = totalIn
        d.totalOut = totalOut
        if let primary = Self.primaryInterface() {
            d.interfaceName = primary
            d.interfaceKind = Self.kind(of: primary)
            d.localIP = Self.ipv4(of: primary) ?? "—"
        }
        if probe {
            let ms = await Self.tcpLatency()
            connectivity.append(ms != nil)
            if connectivity.count > 60 { connectivity.removeFirst(connectivity.count - 60) }
            if let ms { latencies.append(ms); if latencies.count > 10 { latencies.removeFirst() } }
        }
        d.online = connectivity.last ?? true
        d.latencyMs = latencies.last
        if latencies.count > 1 {
            let diffs = zip(latencies.dropFirst(), latencies).map { abs($0 - $1) }
            d.jitterMs = diffs.reduce(0, +) / Double(diffs.count)
        }
        return d
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacCleanerMenu" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    private static func kind(of bsd: String) -> String {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return bsd }
        for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsd {
            return (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
        }
        return bsd
    }

    private static func ipv4(of bsd: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if String(cString: ifa.ifa_name) == bsd, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            p = ifa.ifa_next
        }
        return nil
    }

    /// Time to open a TCP connection to a public anycast DNS resolver. Sends no
    /// data beyond the TCP handshake.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    private static func tcpLatency() async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
            let start = DispatchTime.now().uptimeNanoseconds
            let once = Once()
            let finish: @Sendable (Double?) -> Void = { v in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}

// MARK: - Per-process network (nettop)

enum ProcessNetwork {
    /// Bytes in/out per process over one second, from `nettop` (no privileges
    /// needed). Only run while the Network tab is visible.
    static func sample() async -> [(name: String, down: Double, up: Double)] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                p.arguments = ["-P", "-L", "2", "-s", "1", "-d", "-x", "-J", "bytes_in,bytes_out"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: []); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p.isRunning { p.terminate() } }
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                // Two samples; the second block holds the deltas for the last second.
                let lines = text.split(separator: "\n").map(String.init)
                let headers = lines.indices.filter { lines[$0].hasPrefix("time,") || lines[$0].hasPrefix(",bytes_in") || lines[$0].contains("bytes_in,bytes_out") }
                let start = (headers.last.map { $0 + 1 }) ?? 0
                var out: [(String, Double, Double)] = []
                for line in lines[start...] {
                    // "Name.pid,bytes_in,bytes_out,"
                    let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 3, let down = Double(f[1]), let up = Double(f[2]), down + up > 0 else { continue }
                    let parts = f[0].split(separator: ".")
                    let name = parts.count > 1 ? parts.dropLast().joined(separator: ".") : f[0]
                    out.append((name, down, up))
                }
                cont.resume(returning: out.sorted { $0.1 + $0.2 > $1.1 + $1.2 })
            }
        }
    }
}

// MARK: - CPU (per core, clusters, load)

struct CPUDetails: Sendable {
    var user = 0.0
    var system = 0.0
    var idle = 1.0
    /// Active fraction per logical CPU, in host_processor_info order.
    var cores: [Double] = []
    /// On Apple silicon the efficiency cores come first (hw.perflevel1 =
    /// efficiency, hw.perflevel0 = performance); 0 on single-cluster Macs.
    var efficiencyCount = 0
    var loadAverage: [Double] = [0, 0, 0]

    var total: Double { min(max(user + system, 0), 1) }
    var efficiencyCores: ArraySlice<Double> { efficiencyCount > 0 ? cores.prefix(efficiencyCount) : [] }
    var performanceCores: ArraySlice<Double> { efficiencyCount > 0 ? cores.dropFirst(efficiencyCount) : cores[...] }
    var efficiency: Double? { Self.mean(efficiencyCores) }
    var performance: Double? { efficiencyCount > 0 ? Self.mean(performanceCores) : nil }

    private static func mean(_ s: ArraySlice<Double>) -> Double? { s.isEmpty ? nil : s.reduce(0, +) / Double(s.count) }
}

/// Per-core load from host_processor_info: one cheap mach call, safe to run
/// on every tick (it also feeds the CPU menu-bar item).
final class CPUDetailMonitor: @unchecked Sendable {
    private var last: [UInt32] = []
    private var lastDetails = CPUDetails()

    static let efficiencyCount: Int = {
        var levels: Int32 = 0, n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0, levels > 1 else { return 0 }
        size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0 ? Int(n) : 0
    }()

    func sample() -> CPUDetails {
        var d = lastDetails
        d.efficiencyCount = Self.efficiencyCount
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { d.loadAverage = loads }

        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count) == KERN_SUCCESS,
              let info else { return d }
        let raw = UnsafeBufferPointer(start: info, count: Int(count)).map { UInt32(bitPattern: $0) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        defer { last = raw }
        let n = Int(numCPUs)
        guard last.count == raw.count, raw.count >= n * 4 else { return d }

        // CPU_STATE_USER 0, SYSTEM 1, IDLE 2, NICE 3. Counters wrap, so subtract with &-.
        var cores: [Double] = []
        var tu: UInt64 = 0, ts: UInt64 = 0, ti: UInt64 = 0
        for c in 0..<n {
            let b = c * 4
            let u = UInt64(raw[b] &- last[b]) + UInt64(raw[b + 3] &- last[b + 3])
            let s = UInt64(raw[b + 1] &- last[b + 1])
            let i = UInt64(raw[b + 2] &- last[b + 2])
            let t = u + s + i
            cores.append(t > 0 ? Double(u + s) / Double(t) : 0)
            tu += u; ts += s; ti += i
        }
        let total = Double(tu + ts + ti)
        if total > 0 {
            d.user = Double(tu) / total
            d.system = Double(ts) / total
            d.idle = Double(ti) / total
        }
        d.cores = cores
        lastDetails = d
        return d
    }
}

// MARK: - Battery

struct BatteryInfo: Sendable {
    var present = false
    var level = 0.0
    var isCharging = false
    var isCharged = false
    var onAC = false
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is estimating.
    var minutesRemaining: Int?
    // AppleSmartBattery details, read only while the Battery tab is open.
    var rawMaxCapacity: Int?
    var designCapacity: Int?
    var cycleCount: Int?
    var temperature: Double?
    var voltage: Double?
    var amperage: Int?
    var adapterWatts: Int?

    var health: Double? {
        guard let m = rawMaxCapacity, let d = designCapacity, d > 0 else { return nil }
        return Double(m) / Double(d)
    }
    /// Instantaneous power in watts (V × A); negative while discharging.
    var watts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * Double(a) / 1000
    }

    static let hasBattery: Bool = quick().present

    /// IOPS power-source snapshot: cheap, fine for every tick.
    static func quick() -> BatteryInfo {
        var b = BatteryInfo()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return b }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (desc[kIOPSIsPresentKey] as? Bool) ?? true else { continue }
            b.present = true
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            b.level = max > 0 ? min(Double(cur) / Double(max), 1) : 0
            b.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            b.isCharged = desc[kIOPSIsChargedKey] as? Bool ?? false
            b.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = b.isCharging ? desc[kIOPSTimeToFullChargeKey] as? Int : desc[kIOPSTimeToEmptyKey] as? Int
            if let minutes, minutes > 0 {
                b.minutesRemaining = minutes
            } else if !b.onAC {
                let s = IOPSGetTimeRemainingEstimate()
                if s > 0 { b.minutesRemaining = Int(s / 60) }
            }
            break
        }
        return b
    }

    /// Adds the AppleSmartBattery registry values. On recent macOS several
    /// of them moved into the "BatteryData" dictionary, so look there too.
    mutating func readDetails() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let data = prop("BatteryData") as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            ((prop(key) ?? data[key]) as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        }
        rawMaxCapacity = int("AppleRawMaxCapacity")
        designCapacity = int("DesignCapacity")
        cycleCount = int("CycleCount")
        if let t = int("Temperature"), t > 0 { temperature = Double(t) / 100 }
        if let v = int("Voltage") { voltage = Double(v) / 1000 }
        amperage = int("Amperage")
        if onAC, let adapter = prop("AdapterDetails") as? [String: Any], let w = adapter["Watts"] as? Int, w > 0 {
            adapterWatts = w
        }
    }
}
