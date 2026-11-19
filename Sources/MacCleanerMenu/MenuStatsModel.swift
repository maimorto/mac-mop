import SwiftUI
import AppKit
import OSLog
import MacCleanerKit

/// Owns the menu-bar widget's live data and polls for it **continuously from
/// app launch**, independent of the popover.
///
/// The previous design started polling from the popover content's `.onAppear`
/// and stopped it on `.onDisappear`. For `MenuBarExtra(.window)` that hook only
/// fires when the popover is opened, and on some setups (e.g. Intel / macOS
/// 14.x) it doesn't fire reliably even then — so collection never started and
/// the panel was stuck on its loading spinner forever. Driving the loop from
/// `applicationDidFinishLaunching` instead removes that dependency entirely:
/// stats are gathered the moment the app launches, the popover shows data the
/// instant it opens, and the menu-bar label is populated from the start.
@MainActor
@Observable
final class MenuStatsModel {
    static let shared = MenuStatsModel()

    private(set) var stats: SystemStatsCollector.SystemStats?
    private(set) var networkSpeed: NetworkSpeedMonitor.NetworkSpeed?
    private(set) var devices: ConnectedDevices?
    private(set) var protection: SharedAppState.ProtectionStatus?
    private(set) var tips: [TipsEngine.Tip] = []

    // Detail panel data.
    private(set) var memory = MemoryBreakdown()
    private(set) var cpu = CPUDetails()
    private(set) var battery = BatteryInfo()
    private(set) var diskIO = DiskIO()
    private(set) var processes: [ProcessUsage] = []
    private(set) var network = NetworkDetails()
    private(set) var processNetwork: [(name: String, down: Double, up: Double)] = []
    private(set) var connectivity: [Bool] = []
    /// Rolling histories for the charts (one point per poll, last ~4 minutes).
    private(set) var netDownHistory: [Double] = []
    private(set) var netUpHistory: [Double] = []
    private(set) var diskReadHistory: [Double] = []
    private(set) var diskWriteHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var cpuHistory: [Double] = []
    private(set) var cpuUserHistory: [Double] = []
    private(set) var cpuSystemHistory: [Double] = []
    private(set) var batteryHistory: [Double] = []
    private(set) var gpu = GPUDetails()
    private(set) var gpuHistory: [Double] = []
    /// Home tab data (trash, security checks, last Smart Scan estimate,
    /// external volumes), collected only while the Home tab is on screen.
    private(set) var home = HomeSnapshot()
    /// True while any dashboard popup is on screen. Expensive collectors
    /// (process list, nettop, battery registry, latency probe) only run then,
    /// and only for the visible tab; the menu-bar items need cheap stats only.
    private(set) var panelVisible = false
    private(set) var selectedTab = MenuTab.cpu.rawValue
    /// Called on the main actor after each poll (refreshes the menu-bar items).
    @ObservationIgnored var onUpdate: (() -> Void)?

    private let statsCollector = SystemStatsCollector()
    private let networkMonitor = NetworkSpeedMonitor()
    private let devicesCollector = ConnectedDevicesCollector()
    private let tipsEngine = TipsEngine()
    private let healthMonitor = HealthMonitor()
    private let diskMonitor = DiskIOMonitor()
    private let processMonitor = ProcessMonitor()
    private let cpuMonitor = CPUDetailMonitor()
    private let netDetails = NetworkDetailsMonitor()
    private let homeCollector = HomeCollector()
    private let gpuMonitor = GPUMonitor()

    private var pollingTask: Task<Void, Never>?
    private var tickCount = 0
    private var openPanels = 0
    /// Set when a popup opens or switches tab: the loop skips the rest of its sleep.
    private var wakeRequested = false
    /// The process sampler had no recent baseline: take the next sample sooner.
    private var primeNext = false

    private static let log = Logger(subsystem: MCConstants.menuBundleIdentifier, category: "SystemStats")

    private init() {}

    /// Begin the continuous polling loop. Idempotent: safe to call more than
    /// once (e.g. if relaunch lifecycle fires twice).
    func start() {
        guard pollingTask == nil else { return }
        Self.log.info("stats polling started")
        pollingTask = Task { await self.run() }
    }

    func dismissTip(id: String) {
        SharedAppState.dismissTip(id: id)
        tips.removeAll { $0.id == id }
    }

    // Several popups can exist (one per menu-bar item), and one may appear
    // before the previous one reports its disappearance: count them.
    func panelAppeared(tab: MenuTab) {
        openPanels += 1
        panelVisible = true
        select(tab)
    }

    func panelDisappeared() {
        openPanels = max(0, openPanels - 1)
        panelVisible = openPanels > 0
    }

    /// Re-reads the external volumes right away (after an eject).
    func refreshHome() {
        wakeRequested = true
    }

    func select(_ tab: MenuTab) {
        selectedTab = tab.rawValue
        wakeRequested = true
    }

    private func run() async {
        while !Task.isCancelled {
            wakeRequested = false
            await tick()
            // ~2 s between ticks (1 s right after the process sampler was
            // primed), cut short when a popup opens or changes tab.
            var slept = 0
            let budget = primeNext ? 4 : 8
            while slept < budget, !wakeRequested, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                slept += 1
            }
        }
    }

    private func tick() async {
        // Assign each metric the moment it's ready, each fenced with a
        // timeout so one wedged syscall can't blank the panel: the loop
        // keeps going and the last-known value stays on screen.
        if let s = await timed("stats", budget: .seconds(2), { await self.statsCollector.collect() }) {
            stats = s
            await healthMonitor.evaluate(stats: s)
        }
        if let n = await timed("network", budget: .seconds(2), { await self.networkMonitor.measure() }) {
            networkSpeed = n
        }
        protection = SharedAppState.protectionStatus
        await collectDetails()
        tickCount += 1
        if tickCount % 15 == 1 {
            if let d = await timed("devices", budget: .seconds(3), { await self.devicesCollector.collect() }) {
                devices = d
            }
            if let t = await timed("tips", budget: .seconds(3), { await self.tipsEngine.generateTips() }) {
                tips = t
            }
        }
    }

    private static func push(_ v: Double, _ a: inout [Double]) {
        a.append(v)
        if a.count > 120 { a.removeFirst(a.count - 120) }
    }

    private func collectDetails() async {
        let tab = MenuTab(rawValue: selectedTab) ?? .cpu
        let visible = panelVisible
        let wantProcesses = visible && tab != .network && tab != .home && tab != .gpu
        let wantGPU = visible && tab == .gpu
        let wantBatteryDetails = visible && tab == .battery && BatteryInfo.hasBattery
        let disk = diskMonitor, procs = processMonitor, cpuMon = cpuMonitor, gpuMon = gpuMonitor
        let priming = wantProcesses && procs.needsPriming
        // Cheap every tick: vm stats, per-core ticks, IOPS, block-storage counters.
        let (mem, cpuNow, bat, io, list, gpuNow) = await Task.detached(priority: .utility) {
            var bat = BatteryInfo.hasBattery ? BatteryInfo.quick() : BatteryInfo()
            if wantBatteryDetails { bat.readDetails() }
            return (MemoryBreakdown.read(), cpuMon.sample(), bat, disk.measure(), wantProcesses ? procs.sample() : nil,
                    wantGPU ? gpuMon.sample(withProcesses: true) : nil)
        }.value
        if let gpuNow { gpu = gpuNow }
        primeNext = priming
        memory = mem
        cpu = cpuNow
        // Keep the last registry details on screen between detail reads.
        var b = bat
        if !wantBatteryDetails {
            b.rawMaxCapacity = battery.rawMaxCapacity; b.designCapacity = battery.designCapacity
            b.cycleCount = battery.cycleCount; b.temperature = battery.temperature
            b.voltage = battery.voltage; b.amperage = battery.amperage; b.adapterWatts = battery.adapterWatts
        }
        battery = b
        diskIO = io
        if let list { processes = list }
        Self.push(mem.usedFraction, &memoryHistory)
        Self.push(io.readPerSecond, &diskReadHistory)
        Self.push(io.writePerSecond, &diskWriteHistory)
        Self.push(cpuNow.total, &cpuHistory)
        Self.push(cpuNow.user, &cpuUserHistory)
        Self.push(cpuNow.system, &cpuSystemHistory)
        if b.present { Self.push(b.level, &batteryHistory) }
        if let g = gpuNow?.device ?? stats?.gpuUsage { Self.push(g, &gpuHistory) }
        if let n = networkSpeed {
            Self.push(n.bytesInPerSecond, &netDownHistory)
            Self.push(n.bytesOutPerSecond, &netUpHistory)
        }
        onUpdate?()
        if visible && tab == .home {
            home = await homeCollector.collect(previous: home)
            return
        }
        guard visible && tab == .network else { return }
        // The TCP latency probe touches the network: only while the user is looking at the Network tab.
        network = await netDetails.collect(totalIn: networkSpeed?.bytesIn ?? 0, totalOut: networkSpeed?.bytesOut ?? 0,
                                           probe: tickCount % 3 == 0)
        connectivity = netDetails.connectivity
        if tickCount % 2 == 0 {
            processNetwork = await ProcessNetwork.sample()
        }
    }

    /// Run one collector step under a timeout, returning nil if it overruns its
    /// budget so the loop keeps going. Slow / timed-out steps are logged so a
    /// hang can be pinned to a specific collector from a user's Console.
    private func timed<T: Sendable>(
        _ label: String,
        budget: Duration,
        _ op: @escaping @Sendable () async -> T
    ) async -> T? {
        let start = ContinuousClock.now
        do {
            let value = try await withTimeout(budget) { await op() }
            let elapsed = ContinuousClock.now - start
            if elapsed > .milliseconds(500) {
                Self.log.warning("stats step '\(label, privacy: .public)' slow: \(elapsed.description, privacy: .public)")
            }
            return value
        } catch {
            Self.log.error("stats step '\(label, privacy: .public)' exceeded its budget; skipping this tick")
            return nil
        }
    }
}

/// Starts continuous stats polling at launch via the AppKit lifecycle, which
/// (unlike the SwiftUI `MenuBarExtra` view hooks) fires reliably regardless of
/// whether the popover is ever opened. `@preconcurrency` keeps the conformance
/// building on CI's older SDK, where the delegate protocol isn't yet annotated
/// `@MainActor`.
@MainActor
final class MenuAppDelegate: NSObject, @preconcurrency NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuStatsModel.shared.start()
        StatusBarController.shared.start()
        ClipboardGuard.shared.start()
        let env = ProcessInfo.processInfo.environment
        if let dir = env["KMR_MENU_LABELS"] { dumpLabels(to: dir) }
        if env["KMR_MENU_SIZING"] != nil { reportSizing() }
        if let path = env["KMR_MENU_SNAPSHOT"] { snapshot(to: path) }
        if let dir = env["KMR_MENU_SELFTEST"] { StatusBarController.shared.selfTest(to: dir) }
    }

    // Debug aids (env vars, never set in normal use):
    //  KMR_MENU_SNAPSHOT=/out.png [KMR_MENU_TAB=0..4]  panel hosted in an NSPanel, captured, then quit.
    //  KMR_MENU_LABELS=/dir   writes every rendered menu-bar label (light + dark), prints what each
    //                         status button actually holds and captures the visible status items.
    //  KMR_MENU_SIZING=1      prints the min / ideal sizes MenuBarExtra can derive from the dashboard
    //                         (the empty-popup regression check: min must equal ideal).
    // The debug panel is the real popup window class, kept off-screen (window
    // server capture by window ID still works) so nothing flashes on screen.
    private var debugPanel: DashboardPanel?
    private var debugHost: NSHostingController<AnyView>?
    private func snapshot(to path: String) {
        let tab = MenuTab.fromEnvironment ?? .cpu
        let host = StatusBarController.makeHost(tab: tab)
        let panel = DashboardPanel()
        panel.setContent(host.view)
        panel.setFrame(NSRect(x: -10_000, y: 200, width: 340, height: 600), display: true)
        panel.orderFrontRegardless()
        MenuStatsModel.shared.panelAppeared(tab: tab)
        debugPanel = panel
        debugHost = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            host.view.layoutSubtreeIfNeeded()
            panel.setFrame(NSRect(origin: NSPoint(x: -10_000, y: 200), size: host.preferredContentSize), display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Self.capture(panel, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// Prints the sizes AppKit would derive from the SwiftUI content, for the
    /// dashboard and for the previous ScrollView-with-maxHeight layout.
    private func reportSizing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            @MainActor func report<V: View>(_ name: String, _ make: () -> V) {
                let host = NSHostingView(rootView: make())
                let controller = NSHostingController(rootView: make())
                controller.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
                _ = controller.view
                controller.view.layoutSubtreeIfNeeded()
                print(name, "intrinsic", host.intrinsicContentSize, "fitting", host.fittingSize,
                      "preferred", controller.preferredContentSize,
                      "ideal", controller.sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)),
                      "min", controller.sizeThatFits(in: .zero))
            }
            report("legacy") {
                VStack(spacing: 10) {
                    Text("header")
                    ScrollView { Color.red.frame(height: 500) }.frame(maxHeight: 620)
                    Text("footer")
                }.padding(14).frame(width: 340)
            }
            for tab in MenuTab.allCases { report("dashboard-\(tab)") { MenuDashboardView(initialTab: tab) } }
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 0)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }

    private static func statusWindows() -> [NSWindow] {
        NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private func dumpLabels(to dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (slot, image) in MenuBarLabelImages.rendered {
                for dark in [false, true] {
                    let size = NSSize(width: image.size.width + 8, height: 24)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                        (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                        NSRect(origin: .zero, size: size).fill()
                        let r = NSRect(x: 4, y: (24 - image.size.height) / 2, width: image.size.width, height: image.size.height)
                        if image.isTemplate {
                            // Tint like the menu bar does with template images.
                            let tinted = NSImage(size: image.size, flipped: false) { b in
                                image.draw(in: b)
                                (dark ? NSColor.white : NSColor.black).setFill()
                                b.fill(using: .sourceAtop)
                                return true
                            }
                            tinted.draw(in: r)
                        } else {
                            image.draw(in: r)
                        }
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(dir)/label-\(slot)-\(dark ? "dark" : "light").png"))
                }
            }
            let ours = Set(MenuBarLabelImages.rendered.values.map(ObjectIdentifier.init))
            for (i, w) in Self.statusWindows().enumerated() {
                for b in Self.buttons(in: w.contentView) {
                    print("status item \(i) frame=\(w.frame) appearance=\(w.effectiveAppearance.name.rawValue) title='\(b.title)'",
                          b.image.map { "image=\($0.size) template=\($0.isTemplate) ours=\(ours.contains(ObjectIdentifier($0)))" } ?? "no image")
                }
                // Items macOS keeps out of the menu bar have a zero-height window.
                if w.frame.height > 0 { Self.capture(w, to: "\(dir)/statusitem-\(i).png") }
            }
            if ProcessInfo.processInfo.environment["KMR_MENU_SNAPSHOT"] == nil { NSApp.terminate(nil) }
        }
    }
}
