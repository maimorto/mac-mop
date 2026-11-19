import SwiftUI
import Charts
import AppKit
import IOKit
import IOKit.ps
import MacCleanerKit

// MARK: - Data

/// Cheap, real system facts for the Overview page. Everything here is either
/// a constant-time system call or a cached background computation, so the
/// page never blocks the main thread.
@MainActor
@Observable
final class SystemOverview {
    static let shared = SystemOverview()

    // Static hardware facts.
    let modelName: String
    let modelDetail: String
    let chip: String
    let cores: Int
    let memoryBytes: UInt64
    let osVersion: String

    // Storage.
    private(set) var volumeName = "Macintosh HD"
    private(set) var volumeFormat = "APFS"
    private(set) var totalBytes: UInt64 = 0
    private(set) var availableBytes: UInt64 = 0
    private(set) var systemBytes: UInt64 = 0
    private(set) var appsBytes: UInt64?
    private(set) var reclaimableBytes: UInt64?
    private(set) var reclaimableDate: Date?

    // Live status.
    private(set) var memoryUsedBytes: UInt64 = 0
    private(set) var batteryPercent: Int?
    private(set) var batteryCharging = false
    private(set) var uptime: TimeInterval = 0
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    // Activity.
    private(set) var recentSessions: [CleanHistorySession] = []
    private(set) var chartSessions: [CleanHistorySession] = []
    private(set) var lifetimeFreed: UInt64 = 0
    private(set) var lifetimeCleanups = 0

    private var appsTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var freeFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 1 }
    /// Everything that is neither apps nor the system volume.
    var dataBytes: UInt64 {
        let known = systemBytes &+ (appsBytes ?? 0)
        return usedBytes > known ? usedBytes - known : 0
    }

    private init() {
        let product = Self.productName() ?? Host.current().localizedName ?? "Mac"
        if let open = product.firstIndex(of: "(") {
            modelName = product[..<open].trimmingCharacters(in: .whitespaces)
            let inside = product[product.index(after: open)...].dropLast()
            modelDetail = inside.split(separator: ",").first.map {
                $0.replacingOccurrences(of: "-inch", with: "″").trimmingCharacters(in: .whitespaces)
            } ?? ""
        } else {
            modelName = product
            modelDetail = ""
        }
        chip = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        cores = ProcessInfo.processInfo.activeProcessorCount
        memoryBytes = ProcessInfo.processInfo.physicalMemory
        let v = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "macOS \(v.majorVersion).\(v.minorVersion)"

        if let cachedApps = defaults.object(forKey: "kmr.appsBytes") as? Double { appsBytes = UInt64(cachedApps) }
        if let r = defaults.object(forKey: "kmr.reclaimableBytes") as? Double {
            reclaimableBytes = UInt64(r)
            reclaimableDate = defaults.object(forKey: "kmr.reclaimableDate") as? Date
        }
        refresh(includeSlow: true)
    }

    func rememberReclaimable(_ bytes: UInt64) {
        reclaimableBytes = bytes
        reclaimableDate = Date()
        defaults.set(Double(bytes), forKey: "kmr.reclaimableBytes")
        defaults.set(reclaimableDate, forKey: "kmr.reclaimableDate")
    }

    /// Fast refresh (a few syscalls). `includeSlow` also reloads the clean
    /// history and, at most once a day, re-measures /Applications off the
    /// main thread.
    func refresh(includeSlow: Bool = false) {
        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey,
        ]) {
            volumeName = values.volumeName ?? volumeName
            totalBytes = UInt64(values.volumeTotalCapacity ?? 0)
            availableBytes = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
            volumeFormat = values.volumeLocalizedFormatDescription ?? volumeFormat
        }
        systemBytes = ["/", "/System/Volumes/VM", "/System/Volumes/Preboot"].reduce(0) { $0 &+ Self.volumeUsed($1) }
        memoryUsedBytes = Self.memoryUsed() ?? memoryUsedBytes
        uptime = ProcessInfo.processInfo.systemUptime
        thermalState = ProcessInfo.processInfo.thermalState
        (batteryPercent, batteryCharging) = Self.battery()

        guard includeSlow else { return }
        let all = CleanHistoryRecorder.load().sorted { $0.date > $1.date }
        recentSessions = Array(all.prefix(3))
        chartSessions = Array(all.prefix(10).reversed())
        lifetimeFreed = all.reduce(0) { $0 &+ $1.totalBytes }
        lifetimeCleanups = all.count

        let last = defaults.object(forKey: "kmr.appsBytesDate") as? Date ?? .distantPast
        guard appsTask == nil, Date().timeIntervalSince(last) > 86_400 || appsBytes == nil else { return }
        appsTask = Task { [weak self] in
            let size = await Task.detached(priority: .utility) { Self.directorySize("/Applications") }.value
            guard let self else { return }
            self.appsBytes = size
            self.defaults.set(Double(size), forKey: "kmr.appsBytes")
            self.defaults.set(Date(), forKey: "kmr.appsBytesDate")
            self.appsTask = nil
        }
    }

    // MARK: System calls

    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Space used by one APFS volume. `statfs` reports the whole container,
    /// so ask the volume itself via ATTR_VOL_SPACEUSED.
    private static func volumeUsed(_ path: String) -> UInt64 {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = 0x8000_0000 | 0x0080_0000   // ATTR_VOL_INFO | ATTR_VOL_SPACEUSED
        var buffer = [UInt8](repeating: 0, count: 16) // u32 length + off_t
        guard getattrlist(path, &attrs, &buffer, buffer.count, 0) == 0 else { return 0 }
        let used = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return used > 0 ? UInt64(used) : 0
    }

    private static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private static func battery() -> (Int?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (Int((Double(current) / Double(max) * 100).rounded()), d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }

    nonisolated private static func directorySize(_ path: String) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                     includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total &+= UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Page
//
// A dashboard built from system surfaces (grouped-box fill, SF Symbols,
// system colours and type). Cards enter with a short staggered rise; numbers
// roll with numericText; nothing animates in the background except the live
// sparklines, which only tick while the page is visible.

struct OverviewDashboard: View {
    let onScan: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.moduleIsSelected) private var isSelected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var overview = SystemOverview.shared
    private var live = OverviewLiveStats.shared
    private var reclaim = QuickReclaim.shared
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var appeared = false
    @State private var security: [SecurityCheck] = []
    @State private var battery: BatteryHealth?

    init(onScan: @escaping () -> Void) { self.onScan = onScan }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero.entrance(0, appeared).id("overview-top")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    cpuTile.entrance(1, appeared)
                    memoryTile.entrance(2, appeared)
                    diskTile.entrance(3, appeared)
                    batteryOrUptimeTile.entrance(4, appeared)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], spacing: 12) {
                    storageCard.entrance(5, appeared)
                    reclaimCard.entrance(6, appeared)
                    securityCard.entrance(7, appeared)
                    activityCard.entrance(8, appeared)
                }
                Text(KMR.t("Strumenti", "Tools"))
                    .font(.title3.weight(.semibold))
                    .padding(.top, 6)
                    .entrance(9, appeared)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array(Self.tools.enumerated()), id: \.offset) { i, tool in
                        ToolTile(item: tool.0, detail: tool.1) { go(tool.0) }
                            .entrance(10 + i, appeared)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["KMR_SCROLL_BOTTOM"] != nil ? .bottom : .top)
        .onAppear {
            // Always open at the top (window restoration could leave it mid-page).
            if ProcessInfo.processInfo.environment["KMR_SCROLL_BOTTOM"] == nil {
                DispatchQueue.main.async { proxy.scrollTo("overview-top", anchor: .top) }
            }
        }
        .onChange(of: isSelected) { _, now in
            if now, ProcessInfo.processInfo.environment["KMR_SCROLL_BOTTOM"] == nil { proxy.scrollTo("overview-top", anchor: .top) }
        }
        }
        .task { security = await SecurityCheck.runAll() }
        .task { battery = await Task.detached { BatteryHealth.read() }.value }
        .onAppear {
            // Pages stay alive while hidden: do the disk work only when shown.
            overview.refresh(includeSlow: isSelected)
            if isSelected { reclaim.refreshIfStale(); live.start() }
            if reduceMotion { appeared = true } else { withAnimation(.smooth(duration: 0.55)) { appeared = true } }
        }
        .onDisappear { live.stop() }
        .onChange(of: isSelected) { _, now in
            if now { overview.refresh(includeSlow: true); reclaim.refreshIfStale(); live.start() } else { live.stop() }
        }
        .onReceive(ticker) { _ in
            if isSelected, NSApp.isActive { overview.refresh() }
        }
    }

    private func go(_ item: SidebarItem) { appState.selectedSidebarItem = item }

    private static var tools: [(SidebarItem, String)] { [
        (.systemJunk, KMR.t("Cache e registri", "Caches and logs")),
        (.malwareRemoval, KMR.t("Software dannoso", "Malicious software")),
        (.uninstaller, KMR.t("App e residui", "Apps and leftovers")),
        (.spaceLens, KMR.t("Mappa del disco", "Disk map")),
        (.largeOldFiles, KMR.t("Da rivedere o archiviare", "To review or archive")),
        (.duplicates, KMR.t("Copie identiche", "Identical copies")),
        (.optimization, KMR.t("Avvio e processi", "Startup and processes")),
        (.privacy, KMR.t("Tracce dei browser", "Browser traces")),
    ] }

    // MARK: Health

    private struct Factor: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let penalty: Int
    }

    private var factors: [Factor] {
        var f: [Factor] = []
        let free = overview.freeFraction
        if free < 0.25 {
            f.append(Factor(id: "disk", symbol: "internaldrive.fill",
                            text: KMR.t("Disco quasi pieno (\(Int(free * 100))% libero)", "Disk almost full (\(Int(free * 100))% free)"),
                            penalty: Int(((0.25 - free) * 160).rounded())))
        }
        // The 5 s system figure, not the 2 s live sample: reading the live
        // stats here would rebuild the whole page on every sparkline tick.
        let mem = overview.memoryBytes > 0 && overview.memoryUsedBytes > 0
            ? Double(overview.memoryUsedBytes) / Double(overview.memoryBytes) : live.memory
        if mem > 0.75 {
            f.append(Factor(id: "mem", symbol: "memorychip.fill",
                            text: KMR.t("Memoria molto occupata", "Memory heavily used"),
                            penalty: Int(((mem - 0.75) * 80).rounded())))
        }
        if overview.thermalState == .serious || overview.thermalState == .critical {
            f.append(Factor(id: "heat", symbol: "thermometer.high", text: KMR.t("Mac caldo", "Mac running hot"), penalty: 10))
        }
        for check in security where check.known && !check.ok {
            f.append(Factor(id: check.id, symbol: "lock.open.fill",
                            text: KMR.t("Da attivare: \(check.title)", "Turn on: \(check.title)"), penalty: 7))
        }
        return f.filter { $0.penalty > 0 }.sorted { $0.penalty > $1.penalty }
    }

    private var healthScore: Int { max(0, min(100, 100 - factors.reduce(0) { $0 + $1.penalty })) }

    private var healthColor: Color { healthScore >= 80 ? KMR.green : healthScore >= 55 ? KMR.orange : KMR.red }

    private var healthLabel: String {
        healthScore >= 80 ? KMR.t("In ottima forma", "In great shape")
            : healthScore >= 55 ? KMR.t("Può andare meglio", "Could be better") : KMR.t("Richiede attenzione", "Needs attention")
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 22) {
                if let computer = NSImage(named: NSImage.computerName) {
                    Image(nsImage: computer)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(overview.modelName)
                        .font(.largeTitle.weight(.bold))
                    Text([overview.modelDetail,
                          overview.chip.replacingOccurrences(of: "Apple ", with: "chip "),
                          Int64(overview.memoryBytes).formatted(.byteCount(style: .memory).locale(UIText.locale)),
                          overview.osVersion].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Chip(symbol: "clock", text: KMR.t("Acceso da \(Self.uptimeText(overview.uptime))", "Up \(Self.uptimeText(overview.uptime))"))
                        Chip(symbol: "cpu", text: KMR.t("Core: \(overview.cores)", "Cores: \(overview.cores)"))
                        Chip(symbol: thermalSymbol, text: thermalText)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 12)
                HealthRing(score: healthScore, color: healthColor)
                    .frame(width: 128, height: 128)
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(KMR.t("Salute del Mac", "Mac health")).font(.headline)
                        Text("· \(healthLabel)").font(.headline).foregroundStyle(healthColor)
                    }
                    if factors.isEmpty {
                        Label(KMR.t("Niente da segnalare: spazio, memoria e sicurezza sono a posto.",
                                    "Nothing to report: space, memory and security are fine."),
                              systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                    } else {
                        ForEach(factors.prefix(3)) { f in
                            HStack(spacing: 8) {
                                Image(systemName: f.symbol)
                                    .foregroundStyle(healthColor)
                                    .frame(width: 18)
                                Text(f.text)
                                Text("−\(f.penalty)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                }
                .animation(.smooth, value: factors.map(\.id))
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Button(action: onScan) {
                        Label(KMR.t("Scansione intelligente", "Smart Scan"), systemImage: "sparkles")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text(lastScanText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.fill.quaternary)
            // A faint wash of the health colour, like the tinted header of a
            // Settings pane. Static: it only changes with the score.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RadialGradient(colors: [healthColor.opacity(0.09), .clear],
                                     center: .topTrailing, startRadius: 10, endRadius: 420))
                .animation(.smooth(duration: 0.8), value: healthScore)
        }
    }

    private var lastScanText: String {
        if let bytes = overview.reclaimableBytes, let date = overview.reclaimableDate {
            return KMR.t("Ultima analisi \(date.formatted(.relative(presentation: .named).locale(UIText.locale))): \(FileSizeFormatter.format(bytes)) recuperabili",
                         "Last scan \(date.formatted(.relative(presentation: .named).locale(UIText.locale))): \(FileSizeFormatter.format(bytes)) reclaimable")
        }
        return KMR.t("Pulisce, protegge e ottimizza in un passaggio", "Clean, protect and optimize in one pass")
    }

    private var thermalSymbol: String {
        switch overview.thermalState {
        case .serious, .critical: "thermometer.high"
        case .fair: "thermometer.medium"
        default: "thermometer.low"
        }
    }

    private var thermalText: String {
        switch overview.thermalState {
        case .serious, .critical: KMR.t("Caldo", "Hot")
        case .fair: KMR.t("Tiepido", "Warm")
        default: KMR.t("Fresco", "Cool")
        }
    }

    // MARK: Live tiles

    // Own views, so the 2 s live samples redraw these two tiles only.
    private var cpuTile: some View { LiveTile(memory: false) }
    private var memoryTile: some View { LiveTile(memory: true) }

    private var diskTile: some View {
        StatTile(symbol: "internaldrive", color: overview.freeFraction < 0.1 ? KMR.orange : Color(nsColor: .systemTeal),
                 title: KMR.t("Disco libero", "Free disk"),
                 value: FileSizeFormatter.format(overview.availableBytes),
                 detail: KMR.t("su \(FileSizeFormatter.format(overview.totalBytes))", "of \(FileSizeFormatter.format(overview.totalBytes))"),
                 fraction: 1 - overview.freeFraction)
    }

    @ViewBuilder
    private var batteryOrUptimeTile: some View {
        if let pct = overview.batteryPercent {
            let symbol = overview.batteryCharging ? "battery.100.bolt"
                : pct > 75 ? "battery.100" : pct > 50 ? "battery.75" : pct > 25 ? "battery.50" : "battery.25"
            var parts: [String] = []
            if let cap = battery?.capacity { parts.append(KMR.t("Salute \(Int((cap * 100).rounded()))%", "Health \(Int((cap * 100).rounded()))%")) }
            if let cycles = battery?.cycles { parts.append(KMR.t("\(cycles) cicli", "\(cycles) cycles")) }
            if overview.batteryCharging { parts.insert(KMR.t("In carica", "Charging"), at: 0) }
            return StatTile(symbol: symbol, color: pct <= 20 ? KMR.red : KMR.green, title: KMR.t("Batteria", "Battery"),
                            value: "\(pct)%", detail: parts.joined(separator: " · "), fraction: Double(pct) / 100)
        } else {
            return StatTile(symbol: "clock", color: KMR.gray, title: KMR.t("Acceso da", "Uptime"),
                            value: Self.uptimeText(overview.uptime), detail: overview.osVersion)
        }
    }

    // MARK: Storage

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: UInt64
        let color: Color
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if let apps = overview.appsBytes {
            result.append(Segment(id: "apps", label: KMR.t("App", "Apps"), bytes: apps, color: Color(nsColor: .systemBlue)))
        }
        result.append(Segment(id: "data", label: KMR.t("File e dati", "Files & data"), bytes: overview.dataBytes, color: KMR.purple))
        result.append(Segment(id: "system", label: KMR.t("Sistema", "System"), bytes: overview.systemBytes, color: KMR.orange))
        return result
    }

    private var storageCard: some View {
        Card(title: KMR.t("Archiviazione", "Storage"), subtitle: "\(overview.volumeName) · \(overview.volumeFormat)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(FileSizeFormatter.format(overview.usedBytes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(KMR.t("usati su \(FileSizeFormatter.format(overview.totalBytes))", "used of \(FileSizeFormatter.format(overview.totalBytes))"))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let total = max(Double(overview.totalBytes), 1)
                    HStack(spacing: 2) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(seg.color.gradient)
                                .frame(width: max(3, geo.size.width * min(Double(seg.bytes) / total, 1) * (appeared ? 1 : 0)))
                                .animation(.spring(duration: 0.9, bounce: 0.15).delay(0.25 + Double(i) * 0.08), value: appeared)
                                .help("\(seg.label): \(FileSizeFormatter.format(seg.bytes))")
                        }
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.fill.tertiary)
                    }
                }
                .frame(height: 16)
                VStack(spacing: 8) {
                    ForEach(segments) { seg in
                        legendRow(seg.color, seg.label, FileSizeFormatter.format(seg.bytes))
                    }
                    legendRow(Color.secondary.opacity(0.35), KMR.t("Disponibile", "Available"), FileSizeFormatter.format(overview.availableBytes))
                }
                .font(.callout)
            }
        }
    }

    private func legendRow(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: Reclaim now

    private var reclaimCard: some View {
        Card(title: KMR.t("Da liberare subito", "Free up now"),
             subtitle: reclaim.measuring ? KMR.t("Aggiornamento…", "Updating…")
                : reclaim.measuredAtText.map { KMR.t("Misurato \($0)", "Measured \($0)") } ?? "") {
            VStack(spacing: 2) {
                ReclaimRow(symbol: "trash.fill", color: KMR.gray, title: KMR.t("Cestino", "Trash"),
                           detail: KMR.t("File già eliminati che occupano ancora spazio", "Deleted files still using space"),
                           bytes: reclaim.trash, measuring: reclaim.measuring && reclaim.trash == nil) { go(.trashBins) }
                ReclaimRow(symbol: "archivebox.fill", color: Color(nsColor: .systemBrown), title: KMR.t("Cache delle app", "App caches"),
                           detail: KMR.t("Si ricreano da sole quando servono", "Rebuilt automatically when needed"),
                           bytes: reclaim.caches, measuring: reclaim.measuring && reclaim.caches == nil) { go(.systemJunk) }
                ReclaimRow(symbol: "shippingbox.fill", color: KMR.orange, title: KMR.t("Installer", "Installers"),
                           detail: reclaim.installers.map { KMR.t("\($0.count) file .dmg / .pkg nei Download", "\($0.count) .dmg / .pkg files in Downloads") }
                               ?? KMR.t("File .dmg e .pkg già usati", "Used .dmg and .pkg files"),
                           bytes: reclaim.installers?.bytes, measuring: reclaim.measuring && reclaim.installers == nil) { go(.storageExtras) }
                ReclaimRow(symbol: "arrow.down.circle.fill", color: Color(nsColor: .systemBlue), title: KMR.t("Download", "Downloads"),
                           detail: KMR.t("Controlla cosa tenere", "Review what to keep"),
                           bytes: reclaim.downloads, measuring: reclaim.measuring && reclaim.downloads == nil) { go(.largeOldFiles) }
            }
        }
    }

    // MARK: Security

    private var securityCard: some View {
        Card(title: KMR.t("Sicurezza", "Security"),
             subtitle: security.isEmpty ? KMR.t("Controllo in corso…", "Checking…")
                : security.allSatisfy(\.ok) ? KMR.t("Tutte le difese sono attive", "All defences are on")
                : KMR.t("\(security.filter { !$0.ok }.count) da sistemare", "\(security.filter { !$0.ok }.count) to fix")) {
            VStack(spacing: 10) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { col in
                                let i = row * 2 + col
                                if i < security.count { SecurityCell(check: security[i]) } else { SecurityCell(check: nil) }
                            }
                        }
                    }
                }
                ForEach(security.filter { $0.known && !$0.ok }) { check in
                    SecurityFix(check: check)
                }
            }
            .animation(.smooth, value: security.count)
        }
    }

    // MARK: Activity

    private var activityCard: some View {
        let sessions = overview.recentSessions
        let total = overview.lifetimeFreed
        return Card(title: KMR.t("Attività", "Activity"),
                    subtitle: overview.lifetimeCleanups == 0 ? KMR.t("Ancora nessuna pulizia", "No cleanups yet")
                        : KMR.t("\(overview.lifetimeCleanups) pulizie in totale", "\(overview.lifetimeCleanups) cleanups in total")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(FileSizeFormatter.format(total))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(total > 0 ? KMR.green : .primary)
                    Text(KMR.t("liberati con Mac Mop", "freed with Mac Mop")).foregroundStyle(.secondary)
                }
                if !overview.chartSessions.isEmpty {
                    Chart(overview.chartSessions) { s in
                        BarMark(x: .value("Data", s.date, unit: .day), y: .value("Byte", Double(s.totalBytes)))
                            .foregroundStyle(KMR.green.gradient)
                            .cornerRadius(3)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(UIText.locale)) } }
                    .frame(height: 70)
                }
                ForEach(sessions.prefix(2)) { session in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(KMR.green)
                        Text(session.date.formatted(.relative(presentation: .named).locale(UIText.locale)))
                        Spacer()
                        Text(FileSizeFormatter.format(session.totalBytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
                if sessions.isEmpty {
                    let days = UserDefaults.standard.integer(forKey: AutoCleaner.intervalKey)
                    legendRow(days > 0 ? KMR.green : Color.secondary.opacity(0.4), KMR.t("Pulizia automatica", "Automatic cleanup"),
                              days == 0 ? KMR.t("Disattivata", "Off") : days == 1 ? KMR.t("Ogni giorno", "Daily") : KMR.t("Ogni settimana", "Weekly"))
                        .font(.callout)
                    legendRow(KMR.accent, KMR.t("Ultima analisi", "Last scan"),
                              overview.reclaimableDate?.formatted(.relative(presentation: .named).locale(UIText.locale)) ?? KMR.t("Mai", "Never"))
                        .font(.callout)
                    Text(KMR.t("Ogni pulizia finisce nel Cestino e può essere annullata da qui.",
                               "Every cleanup goes to the Trash and can be undone from here."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(KMR.t("Cronologia e ripristino", "History and restore")) { go(.cleanHistory) }
                    .buttonStyle(.link)
            }
        }
    }

    fileprivate static func uptimeText(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = UIText.locale
        f.calendar = calendar
        return f.string(from: t) ?? "—"
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: Capsule())
    }
}

/// CPU or memory tile fed by `OverviewLiveStats`.
private struct LiveTile: View {
    let memory: Bool
    private var live = OverviewLiveStats.shared

    init(memory: Bool) { self.memory = memory }

    var body: some View {
        if memory {
            let used = UInt64(live.memory * Double(SystemOverview.shared.memoryBytes))
            let pressure: String = switch live.pressureLevel {
            case 4: KMR.t("Pressione critica", "Critical pressure")
            case 2: KMR.t("Pressione alta", "High pressure")
            default: KMR.t("Pressione normale", "Normal pressure")
            }
            StatTile(symbol: "memorychip", color: Color(nsColor: .systemPurple), title: KMR.t("Memoria", "Memory"),
                     value: Int64(used).formatted(.byteCount(style: .memory).locale(UIText.locale)),
                     detail: pressure, history: live.memoryHistory, rollsValue: false)
        } else {
            StatTile(symbol: "cpu", color: Color(nsColor: .systemBlue), title: "CPU",
                     value: "\(Int((live.cpu * 100).rounded()))%",
                     detail: live.cpu > 0.8 ? KMR.t("Molto impegnata", "Very busy") : live.cpu > 0.4 ? KMR.t("Al lavoro", "Working") : KMR.t("Tranquilla", "Relaxed"),
                     history: live.cpuHistory, rollsValue: false)
        }
    }
}

private struct StatTile: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let detail: String
    var history: [Double]? = nil
    var fraction: Double? = nil
    /// Roll the number when it changes. Off for the 2 s live tiles: the
    /// rolling digits are re-rendered on the CPU every frame, which kept
    /// the idle app at ~25% CPU on the Overview.
    var rollsValue = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconTile(symbol: symbol, color: color, size: 22)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(rollsValue ? .numericText() : .identity)
                .animation(rollsValue ? .smooth : nil, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Group {
                if let history {
                    let offset = OverviewLiveStats.points - history.count
                    Chart(Array(history.enumerated()).map { ($0.offset + offset, $0.element) }, id: \.0) { i, v in
                        AreaMark(x: .value("t", i), y: .value("v", v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("t", i), y: .value("v", v))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .interpolationMethod(.catmullRom)
                    }
                    .chartXScale(domain: 0...(OverviewLiveStats.points - 1))
                    .chartYScale(domain: 0...1)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                } else if let fraction {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.fill.tertiary)
                                Capsule().fill(color.gradient)
                                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                            }
                        }
                        .frame(height: 6)
                        .animation(.smooth, value: fraction)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(height: 34)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ReclaimRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let bytes: UInt64?
    let measuring: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Group {
                    if let bytes {
                        Text(FileSizeFormatter.format(bytes))
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else if measuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: hover ? 2 : 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(hover ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.smooth(duration: 0.18)) { hover = h } }
        .padding(.horizontal, -8)
    }
}

private struct SecurityCell: View {
    let check: SecurityCheck?

    var body: some View {
        HStack(spacing: 9) {
            if let check {
                Image(systemName: check.ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(check.ok ? KMR.green : KMR.orange)
                    .symbolEffect(.bounce, value: check.ok)
                    .transition(.scale.combined(with: .opacity))
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.title).font(.callout).lineLimit(2).minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(check.ok ? KMR.t("In funzione", "On") : check.known ? KMR.t("Non in funzione", "Off") : KMR.t("Sconosciuto", "Unknown"))
                        .font(.caption)
                        .foregroundStyle(check.ok ? Color.secondary : KMR.orange)
                }
            } else {
                Image(systemName: "shield").font(.title3).foregroundStyle(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(.fill.tertiary).frame(width: 70, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(check?.detail ?? "")
    }
}

private struct ToolTile: View {
    let item: SidebarItem
    let detail: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                IconTile(symbol: item.tileSymbol, color: item.tileColor, size: 34)
                    .scaleEffect(hover ? 1.06 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.callout.weight(.medium)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hover = h } }
    }
}

/// Activity-ring style health dial: angular gradient arc with a soft glow,
/// springs to the score the first time it is shown.
private struct HealthRing: View {
    let score: Int
    let color: Color
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: 13)
            Circle()
                .trim(from: 0, to: shown / 100)
                .stroke(AngularGradient(colors: [color.opacity(0.65), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 1) / 100)),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 6)
            VStack(spacing: 0) {
                Text("\(Int(shown.rounded()))")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown))
                Text(KMR.t("su 100", "of 100"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { withAnimation(.spring(duration: 1.3, bounce: 0.18).delay(0.25)) { shown = Double(score) } }
        .onChange(of: score) { _, v in withAnimation(.spring(duration: 0.8, bounce: 0.15)) { shown = Double(v) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(KMR.t("Salute del Mac \(score) su 100", "Mac health \(score) out of 100"))
    }
}

private extension View {
    /// Staggered rise-in for dashboard cards (first appearance only).
    func entrance(_ index: Int, _ shown: Bool) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .blur(radius: shown ? 0 : 5)
            .animation(.spring(duration: 0.6, bounce: 0.12).delay(Double(min(index, 14)) * 0.045), value: shown)
    }
}


// MARK: - How to fix a disabled protection

/// Plain-language "why it matters + exactly what to do" for one protection
/// that is off, with a button to the right Settings pane (or, for SIP, the
/// Recovery steps and a copyable command, since Settings can't change it).
private struct SecurityFix: View {
    let check: SecurityCheck
    @State private var copied = false

    /// The full Security Check's guide for this protection (same text,
    /// pane and command as the Security Check module).
    private var fix: SecurityCheckGuide {
        SecurityChecklist.guide(for: SecurityCheckKind(rawValue: check.id) ?? .sip)
    }

    var body: some View {
        let fix = fix
        VStack(alignment: .leading, spacing: 8) {
            Label(KMR.t("Come attivare: \(check.title)", "How to turn on: \(check.title)"), systemImage: "wrench.and.screwdriver.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(KMR.orange)
            // Inside the page's ScrollView, so letting text take its full
            // height is safe (and needed: long languages wrap to 3+ lines).
            Text(fix.why)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(fix.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            HStack(spacing: 8) {
                if let command = fix.command {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button(copied ? KMR.t("Copiato", "Copied") : KMR.t("Copia", "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                if let pane = fix.paneURL, let url = URL(string: pane) {
                    Button(KMR.t("Apri Impostazioni", "Open Settings")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KMR.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Security checks

struct SecurityCheck: Identifiable {
    let id: String
    let title: String
    let detail: String
    let ok: Bool
    let known: Bool

    /// The dashboard's four core protections, read with the Security Check
    /// module's probe (read-only, no password). `id` is the
    /// `SecurityCheckKind` raw value.
    static func runAll() async -> [SecurityCheck] {
        let results = await Task.detached(priority: .utility) { await SecurityChecklistProbe.evaluate() }.value
        let details: [(SecurityCheckKind, String)] = [
            (.gatekeeper, KMR.t("Blocca le app non verificate da Apple", "Blocks apps Apple has not checked")),
            (.fileVault, KMR.t("Cifra il disco se il Mac viene rubato", "Encrypts the disk if your Mac is stolen")),
            (.sip, KMR.t("Impedisce di modificare i file di macOS", "Stops changes to macOS system files")),
            (.firewall, KMR.t("Blocca le connessioni in entrata non richieste", "Blocks unwanted incoming connections")),
        ]
        return details.map { kind, detail in
            let result = results.first { $0.kind == kind }
            return SecurityCheck(id: kind.rawValue,
                                 title: kind == .sip ? KMR.t("Integrità di sistema", "System Integrity") : kind.title,
                                 detail: detail,
                                 ok: result?.state == .pass,
                                 known: result.map { $0.state != .unknown } ?? false)
        }
    }
}
