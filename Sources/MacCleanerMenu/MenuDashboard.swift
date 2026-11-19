import SwiftUI
import AppKit
import Charts
import MacCleanerKit

// Menu-bar panel in the macOS Tahoe style: the system glass of the menu-bar
// window shows through, content sits in grouped sections, one tab per topic.

// Sizes follow the app's interface language, not the system one.
func bytes(_ v: UInt64) -> String { Int64(clamping: v).formatted(.byteCount(style: .memory).locale(UIText.locale)) }
func rate(_ v: Double) -> String {
    Int64(max(v, 0)).formatted(.byteCount(style: .file, spellsOutZero: false).locale(UIText.locale)) + "/s"
}
/// Disk sizes are decimal, like Finder and the menu-bar label.
func diskBytes(_ v: UInt64) -> String { Int64(clamping: v).formatted(.byteCount(style: .file).locale(UIText.locale)) }
func pct(_ v: Double) -> String { "\(Int((min(max(v, 0), 1) * 100).rounded()))%" }
func t(_ it: String, _ en: String) -> String { UIText.t(it, en) }
private func duration(minutes: Int) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute]
    f.unitsStyle = .abbreviated
    return f.string(from: TimeInterval(minutes * 60)) ?? "—"
}

/// Raw values are stable: KMR_MENU_TAB and MenuStatsModel.selectedTab use them.
enum MenuTab: Int, CaseIterable, Identifiable {
    case cpu = 0, network = 1, disk = 2, memory = 3, battery = 4, home = 5, gpu = 6
    var id: Int { rawValue }

    /// KMR_MENU_TAB, used by the snapshot debug hook.
    static var fromEnvironment: MenuTab? {
        ProcessInfo.processInfo.environment["KMR_MENU_TAB"].flatMap(Int.init).flatMap(MenuTab.init(rawValue:))
    }

    /// Picker order; the battery tab only on Macs that have one.
    static var visible: [MenuTab] { [.home, .cpu, .gpu, .memory, .disk, .network] + (BatteryInfo.hasBattery ? [.battery] : []) }

    var title: String {
        switch self {
        case .home: MCConstants.appName
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .network: t("Rete", "Network")
        case .disk: t("Disco", "Disk")
        case .memory: t("Memoria", "Memory")
        case .battery: t("Batteria", "Battery")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .cpu: "cpu"
        case .gpu: "cube.transparent"
        case .network: "network"
        case .disk: "internaldrive"
        case .memory: "memorychip"
        case .battery: "battery.75percent"
        }
    }
}

struct MenuDashboardView: View {
    @State private var model = MenuStatsModel.shared
    @State private var tab: MenuTab
    @State private var contentHeight: CGFloat
    private let initialTab: MenuTab
    /// Last measured panel height per tab, so a reopened popup starts at its final size.
    private static var measuredHeights: [MenuTab: CGFloat] = [:]

    @AppStorage(MenuItemKey.ram, store: SharedAppState.defaults) private var showRAM = true
    @AppStorage(MenuItemKey.battery, store: SharedAppState.defaults) private var showBattery = true
    @AppStorage(MenuItemKey.network, store: SharedAppState.defaults) private var showNetwork = true
    @AppStorage(MenuItemKey.cpu, store: SharedAppState.defaults) private var showCPU = true

    init(initialTab: MenuTab? = nil) {
        var tab = initialTab ?? MenuTab.fromEnvironment ?? .cpu
        if !MenuTab.visible.contains(tab) { tab = .home }
        self.initialTab = tab
        _tab = State(initialValue: tab)
        _contentHeight = State(initialValue: Self.measuredHeights[tab] ?? 0)
    }

    /// The popup may not grow past the screen: header, tabs and footer take ~130 pt.
    private var maxContentHeight: CGFloat {
        max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 160)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Picker("", selection: $tab) {
                ForEach(MenuTab.visible) { tab in
                    Image(systemName: tab.symbol).tag(tab).help(tab.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // A ScrollView's minimum height is 0: with only a maxHeight, a
            // container that sizes from the content's minimum (MenuBarExtra
            // did) collapsed it and the popup showed header, tabs and footer
            // with nothing in between. Measure the panel and give the
            // ScrollView that explicit height (capped to the screen), so
            // min = ideal and it scrolls only when the panel truly doesn't fit.
            ScrollView {
                panel
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        contentHeight = h
                        Self.measuredHeights[tab] = h
                    }
            }
            .scrollIndicators(.never)
            .frame(height: min(max(contentHeight, 60), maxContentHeight))

            footer
        }
        .padding(14)
        .frame(width: tab == .home ? 380 : 340)
        // Visibility (panelAppeared/Disappeared) is reported by the window
        // owner, StatusBarController, which knows when the popup is on screen.
        .onChange(of: tab) { _, v in model.select(v) }
    }

    @ViewBuilder private var panel: some View {
        switch tab {
        case .home: HomePanel(model: model) { tab = $0 }
        case .network: NetworkPanel(model: model)
        case .disk: DiskPanel(model: model)
        case .memory: MemoryPanel(model: model)
        case .battery: BatteryPanel(model: model)
        case .cpu: CPUPanel(model: model)
        case .gpu: GPUPanel(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Monochrome mop glyph in the label colour, like a Tahoe symbol.
            if let mop = MenuAssets.mop {
                Image(nsImage: mop)
                    .renderingMode(.template)
                    .resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(MCConstants.appName).font(.headline)
                Text(t("Stato del Mac in tempo reale", "Live Mac status")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if tab != .home {
                Text(tab.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(t("Apri \(MCConstants.appName)", "Open \(MCConstants.appName)")) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MCConstants.bundleIdentifier) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            Spacer()
            Menu {
                Section(t("Mostra nella barra dei menu", "Show in menu bar")) {
                    Toggle("RAM", isOn: $showRAM)
                    if BatteryInfo.hasBattery { Toggle(t("Batteria", "Battery"), isOn: $showBattery) }
                    Toggle(t("Rete", "Network"), isOn: $showNetwork)
                    Toggle("CPU", isOn: $showCPU)
                }
            } label: {
                Image(systemName: "menubar.rectangle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(t("Elementi nella barra dei menu", "Menu bar items"))
            Button(t("Esci", "Quit")) {
                MenuBarKeepAlive.setUserQuit(true, defaults: SharedAppState.defaults)
                NSApp.terminate(nil)
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Row: View {
    let label: String
    let value: String
    var dot: Color? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().contentTransition(.numericText())
        }
        .font(.callout)
    }
}

private struct StatusPill: View {
    let ok: Bool
    var body: some View {
        Text(ok ? "UP" : "DOWN")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(ok ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed), in: Capsule())
    }
}

/// Usage ring with the value in the middle and a caption underneath.
private struct Ring: View {
    let value: Double
    let text: String
    let caption: String
    var color: Color = .accentColor

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().inset(by: 3.5).stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                Circle().inset(by: 3.5)
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: value)
                Text(text)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
            }
            .frame(width: 70, height: 70)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private func loadColor(_ v: Double) -> Color {
    v > 0.85 ? Color(nsColor: .systemRed) : v > 0.65 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue)
}

/// Semicircular gauge, green → yellow → red, with a needle and the value
/// under the pivot. Same 70 pt box and caption spacing as `Ring`, so the two
/// sit side by side with their captions on one baseline.
private struct PressureGauge: View {
    let value: Double   // 0...1
    let caption: String
    var body: some View {
        let d: CGFloat = 84, lw: CGFloat = 8
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                ZStack {
                    // Round caps reach lw/2 past each end: pull every segment in
                    // by that much plus a small gap, so the joins stay clean and
                    // the outer ends stop exactly at the horizontal.
                    let cap = Double(lw / 2) / (2 * .pi * Double(d / 2 - lw / 2))
                    ForEach(0..<3, id: \.self) { i in
                        Circle().inset(by: lw / 2)
                            .trim(from: 0.5 + Double(i) / 6 + cap + (i == 0 ? 0 : 0.005),
                                  to: 0.5 + Double(i + 1) / 6 - cap - (i == 2 ? 0 : 0.005))
                            .stroke([Color(nsColor: .systemGreen), Color(nsColor: .systemYellow), Color(nsColor: .systemRed)][i],
                                    style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    }
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: d * 0.32)
                        .offset(y: -d * 0.16)
                        .rotationEffect(.degrees(-90 + 180 * min(max(value, 0), 1)))
                        .animation(.smooth, value: value)
                    Circle().fill(.primary).frame(width: 9, height: 9)
                }
                .frame(width: d, height: d)
                .frame(width: d, height: d / 2 + 5, alignment: .top)
                Text(pct(value))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 84, height: 70)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Mirrored area chart: first series up, second series down (like Activity Monitor).
private struct MirrorChart: View {
    let up: [Double]
    let down: [Double]
    let upColor: Color
    let downColor: Color

    var body: some View {
        let maxUp = max(up.max() ?? 1, 1), maxDown = max(down.max() ?? 1, 1)
        Chart {
            ForEach(Array(up.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), yStart: .value("0", 0), yEnd: .value("v", v / maxUp), series: .value("s", "up"))
                    .foregroundStyle(upColor.gradient)
            }
            ForEach(Array(down.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), yStart: .value("0", 0), yEnd: .value("v", -v / maxDown), series: .value("s", "down"))
                    .foregroundStyle(downColor.gradient)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: -1...1)
        .frame(height: 70)
    }
}

private struct ProcessList: View {
    struct Item: Identifiable { let id: String; let name: String; let pid: Int32?; let a: String; let b: String? }
    let items: [Item]
    var empty = t("Raccolta in corso…", "Collecting…")
    var body: some View {
        VStack(spacing: 5) {
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(items) { item in
                HStack(spacing: 6) {
                    if let icon = Self.icon(for: item) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "gearshape").frame(width: 16, height: 16).foregroundStyle(.secondary)
                    }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(item.a).monospacedDigit().foregroundStyle(.secondary)
                    if let b = item.b { Text(b).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing) }
                }
                .font(.callout)
            }
        }
    }

    private static func icon(for item: Item) -> NSImage? {
        if let pid = item.pid { return NSRunningApplication(processIdentifier: pid)?.icon }
        return NSWorkspace.shared.runningApplications.first {
            $0.executableURL?.lastPathComponent == item.name || $0.localizedName == item.name
        }?.icon
    }
}

@MainActor private func topCPU(_ model: MenuStatsModel, _ n: Int = 6) -> [ProcessList.Item] {
    model.processes.sorted { $0.cpu > $1.cpu }.prefix(n).map {
        .init(id: "\($0.pid)", name: $0.name, pid: $0.pid, a: ($0.cpu / 100).formatted(.percent.precision(.fractionLength(1)).locale(UIText.locale)), b: nil)
    }
}

// MARK: - CPU

private struct CPUPanel: View {
    let model: MenuStatsModel
    var body: some View {
        let c = model.cpu
        let ncpu = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Ring(value: c.total, text: pct(c.total), caption: t("Utilizzo", "Usage"), color: loadColor(c.total))
                let load = c.loadAverage.first ?? 0
                Ring(value: load / ncpu, text: load.formatted(.number.precision(.fractionLength(2))),
                     caption: t("Carico 1 min", "Load 1 min"), color: loadColor(load / ncpu))
                if let gpu = model.stats?.gpuUsage {
                    Ring(value: gpu, text: pct(gpu), caption: "GPU", color: loadColor(gpu))
                }
            }
            Card(title: t("Cronologia d'uso", "Usage history")) {
                let sys = t("Sistema", "System"), user = t("Utente", "User")
                Chart {
                    ForEach(Array(model.cpuSystemHistory.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("t", i), y: .value("v", v), stacking: .standard)
                            .foregroundStyle(by: .value("s", sys))
                    }
                    ForEach(Array(model.cpuUserHistory.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("t", i), y: .value("v", v), stacking: .standard)
                            .foregroundStyle(by: .value("s", user))
                    }
                }
                .chartForegroundStyleScale([sys: Color(nsColor: .systemRed).gradient, user: Color(nsColor: .systemBlue).gradient])
                .chartLegend(.hidden)
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1)
                .frame(height: 60)
            }
            if !c.cores.isEmpty {
                Card(title: t("Nuclei", "Cores")) {
                    if c.efficiencyCount > 0 {
                        CoreBars(label: "E", values: c.efficiencyCores, color: Color(nsColor: .systemTeal))
                        CoreBars(label: "P", values: c.performanceCores, color: Color(nsColor: .systemBlue))
                    } else {
                        CoreBars(label: "", values: c.cores[...], color: Color(nsColor: .systemBlue))
                    }
                }
            }
            Card(title: t("Dettagli", "Details")) {
                Row(label: t("Sistema", "System"), value: pct(c.system), dot: Color(nsColor: .systemRed))
                Row(label: t("Utente", "User"), value: pct(c.user), dot: Color(nsColor: .systemBlue))
                Row(label: t("Inattiva", "Idle"), value: pct(c.idle), dot: Color.secondary.opacity(0.4))
                if let e = c.efficiency { Row(label: t("Nuclei di efficienza", "Efficiency cores"), value: pct(e)) }
                if let p = c.performance { Row(label: t("Nuclei di prestazioni", "Performance cores"), value: pct(p)) }
                Row(label: t("Tempo di attività", "Uptime"), value: Self.uptime(ProcessInfo.processInfo.systemUptime))
                Divider()
                HStack {
                    ForEach(Array(zip(["1 min", "5 min", "15 min"], c.loadAverage)), id: \.0) { label, v in
                        VStack(spacing: 2) {
                            Text(v.formatted(.number.precision(.fractionLength(2))))
                                .font(.callout.weight(.semibold)).monospacedDigit()
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(t("Carico medio", "Load average")).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            Card(title: t("Processi più attivi", "Top processes")) {
                ProcessList(items: topCPU(model))
            }
        }
    }

    static func uptime(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s > 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? "—"
    }
}

/// One vertical bar per core, the cluster's mean on the right.
private struct CoreBars: View {
    let label: String
    let values: ArraySlice<Double>
    let color: Color
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            if !label.isEmpty {
                Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 2.5).fill(color.gradient)
                            .frame(height: max(3, 26 * min(max(v, 0), 1)))
                    }
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.smooth, value: Array(values))
            Text(pct(values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Network

private struct NetworkPanel: View {
    let model: MenuStatsModel
    var body: some View {
        let n = model.network
        VStack(spacing: 10) {
            HStack {
                big(rate(model.networkSpeed?.bytesInPerSecond ?? 0), t("Scarica", "Download"), Color(nsColor: .systemBlue))
                big(rate(model.networkSpeed?.bytesOutPerSecond ?? 0), t("Caricamento", "Upload"), Color(nsColor: .systemRed))
            }
            Card(title: t("Cronologia d'uso", "Usage history")) {
                MirrorChart(up: model.netUpHistory, down: model.netDownHistory,
                            upColor: Color(nsColor: .systemRed), downColor: Color(nsColor: .systemBlue))
            }
            Card(title: t("Connettività", "Connectivity")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 4), spacing: 2), count: 30), spacing: 2) {
                    ForEach(Array((Array(repeating: true, count: max(0, 60 - model.connectivity.count)) + model.connectivity).enumerated()), id: \.offset) { i, ok in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < 60 - model.connectivity.count ? Color.secondary.opacity(0.2)
                                  : ok ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                Row(label: t("Connessione internet", "Internet"), value: "").overlay(alignment: .trailing) { StatusPill(ok: n.online) }
                Row(label: t("Latenza", "Latency"), value: n.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
                Row(label: "Jitter", value: n.jitterMs.map { $0.formatted(.number.precision(.fractionLength(1)).locale(UIText.locale)) + " ms" } ?? "—")
            }
            Card(title: t("Interfaccia", "Interface")) {
                Row(label: t("Interfaccia", "Interface"), value: "\(n.interfaceKind) (\(n.interfaceName))")
                Row(label: t("IP locale", "Local IP"), value: n.localIP)
                Row(label: t("Scaricati dall'avvio", "Downloaded since boot"), value: bytes(n.totalIn), dot: Color(nsColor: .systemBlue))
                Row(label: t("Caricati dall'avvio", "Uploaded since boot"), value: bytes(n.totalOut), dot: Color(nsColor: .systemRed))
            }
            Card(title: t("Processi", "Processes")) {
                ProcessList(items: model.processNetwork.prefix(6).map {
                    .init(id: $0.name, name: $0.name, pid: nil, a: rate($0.down), b: rate($0.up))
                })
            }
        }
    }

    private func big(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text(label).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Disk

private struct DiskPanel: View {
    let model: MenuStatsModel
    var body: some View {
        VStack(spacing: 10) {
            if let s = model.stats {
                Card(title: "Macintosh HD") {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Row(label: t("Scrittura", "Write"), value: rate(model.diskIO.writePerSecond), dot: Color(nsColor: .systemRed))
                            Row(label: t("Lettura", "Read"), value: rate(model.diskIO.readPerSecond), dot: Color(nsColor: .systemBlue))
                        }
                    }
                    MirrorChart(up: model.diskWriteHistory, down: model.diskReadHistory,
                                upColor: Color(nsColor: .systemRed), downColor: Color(nsColor: .systemBlue))
                    let used = s.diskTotal > s.diskFree ? Double(s.diskTotal - s.diskFree) / Double(max(s.diskTotal, 1)) : 0
                    ProgressView(value: used).tint(used > 0.9 ? Color(nsColor: .systemRed) : .accentColor)
                    HStack {
                        Text(t("Libero \(diskBytes(s.diskFree)) su \(diskBytes(s.diskTotal))", "\(diskBytes(s.diskFree)) free of \(diskBytes(s.diskTotal))"))
                        Spacer()
                        Text("\(Int(((1 - used) * 100).rounded()))%")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(title: t("Processi", "Processes")) {
                ProcessList(items: model.processes.sorted { $0.diskRead + $0.diskWrite > $1.diskRead + $1.diskWrite }
                    .prefix(6).filter { $0.diskRead + $0.diskWrite > 0 }.map {
                        .init(id: "\($0.pid)", name: $0.name, pid: $0.pid, a: rate($0.diskRead), b: rate($0.diskWrite))
                    }, empty: model.processes.isEmpty ? t("Raccolta in corso…", "Collecting…") : t("Nessuna attività", "No activity"))
            }
        }
    }
}

// MARK: - GPU

private struct GPUPanel: View {
    let model: MenuStatsModel
    var body: some View {
        let g = model.gpu
        let device = g.device ?? model.stats?.gpuUsage ?? 0
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Ring(value: device, text: pct(device), caption: t("Utilizzo", "Usage"), color: loadColor(device))
                if let r = g.renderer { Ring(value: r, text: pct(r), caption: "Renderer", color: loadColor(r)) }
                if let tl = g.tiler { Ring(value: tl, text: pct(tl), caption: "Tiler", color: loadColor(tl)) }
            }
            Card(title: t("Cronologia d'uso", "Usage history")) {
                Chart(Array(model.gpuHistory.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(Color(nsColor: .systemPurple).gradient)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1)
                .frame(height: 60)
            }
            Card(title: t("Dettagli", "Details")) {
                if let name = g.name { Row(label: t("Modello", "Model"), value: name) }
                if let c = g.cores { Row(label: t("Core GPU", "GPU cores"), value: "\(c)") }
                if let m = g.memoryInUse { Row(label: t("Memoria in uso", "Memory in use"), value: bytes(m)) }
                if let a = g.memoryAllocated { Row(label: t("Memoria allocata", "Memory allocated"), value: bytes(a)) }
                if let r = g.renderer { Row(label: "Renderer", value: pct(r)) }
                if let tl = g.tiler { Row(label: "Tiler", value: pct(tl)) }
            }
            Card(title: t("Processi", "Processes")) {
                ProcessList(items: g.processes.map {
                    .init(id: "\($0.pid)", name: $0.name, pid: $0.pid,
                          a: $0.share.formatted(.percent.precision(.fractionLength(1)).locale(UIText.locale)), b: nil)
                }, empty: t("Nessuna attività", "No activity"))
            }
        }
    }
}

// MARK: - Memory

private struct MemoryPanel: View {
    let model: MenuStatsModel
    var body: some View {
        let m = model.memory
        let segments: [(String, UInt64, Color)] = [
            (t("Applicazioni", "Apps"), m.app, Color(nsColor: .systemBlue)),
            ("Wired", m.wired, Color(nsColor: .systemOrange)),
            (t("Compressa", "Compressed"), m.compressed, Color(nsColor: .systemPink)),
            (t("Libera", "Free"), m.total > m.used ? m.total - m.used : 0, Color.secondary.opacity(0.3)),
        ]
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                PressureGauge(value: m.pressurePercent / 100,
                              caption: m.pressureLevel >= 4 ? t("Pressione critica", "Critical pressure")
                                : m.pressureLevel >= 2 ? t("Pressione alta", "High pressure") : t("Pressione normale", "Normal pressure"))
                Ring(value: m.usedFraction, text: pct(m.usedFraction), caption: t("Utilizzo", "Usage"), color: loadColor(m.usedFraction))
            }
            Card(title: t("Cronologia d'uso", "Usage history")) {
                Chart(Array(model.memoryHistory.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(Color(nsColor: .systemBlue).gradient)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1)
                .frame(height: 60)
            }
            Card(title: t("Dettagli", "Details")) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments.indices, id: \.self) { i in
                            let share = m.total > 0 ? CGFloat(segments[i].1) / CGFloat(m.total) : 0
                            Rectangle().fill(segments[i].2)
                                .frame(width: max(0, (geo.size.width - 6) * share))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 12)
                .animation(.smooth, value: m.used)
                Row(label: t("Usata", "Used"), value: "\(bytes(m.used)) / \(bytes(m.total))")
                ForEach(segments.indices, id: \.self) { i in
                    Row(label: segments[i].0, value: bytes(segments[i].1), dot: segments[i].2)
                }
                Row(label: "Swap", value: bytes(m.swapUsed))
                Row(label: t("Pressione memoria", "Memory pressure"), value: "\(Int(m.pressurePercent))%")
            }
            Card(title: t("Processi", "Processes")) {
                ProcessList(items: model.processes.sorted { $0.memory > $1.memory }.prefix(6).map {
                    .init(id: "\($0.pid)", name: $0.name, pid: $0.pid, a: bytes($0.memory), b: nil)
                })
            }
        }
    }
}

// MARK: - Battery

private func batteryColor(_ level: Double) -> Color {
    level < 0.4 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)
}

/// Large battery glyph filled to the charge level, bolt while charging.
private struct BatteryGlyph: View {
    let level: Double
    let charging: Bool
    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 2)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(batteryColor(level).gradient)
                        .frame(width: max(4, (geo.size.width) * min(max(level, 0), 1)))
                }
                .padding(4)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 72, height: 34)
            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 12)
        }
        .animation(.smooth, value: level)
    }
}

private struct BatteryPanel: View {
    let model: MenuStatsModel
    var body: some View {
        let b = model.battery
        let state: (String, Color) = b.isCharging ? (t("In carica", "Charging"), Color(nsColor: .systemGreen))
            : b.onAC ? (b.isCharged ? t("Carica completa", "Charged") : t("Alimentatore", "Power adapter"), Color(nsColor: .systemBlue))
            : (t("A batteria", "On battery"), Color(nsColor: .systemOrange))
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                BatteryGlyph(level: b.level, charging: b.isCharging)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pct(b.level))
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(state.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(state.1, in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            Card(title: t("Cronologia d'uso", "Usage history")) {
                let offset = 120 - model.batteryHistory.count
                Chart(Array(model.batteryHistory.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("t", i + offset), y: .value("v", v), width: .fixed(2))
                        .foregroundStyle(batteryColor(v).gradient)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1)
                .chartXScale(domain: 0...119)
                .frame(height: 50)
            }
            Card(title: t("Dettagli", "Details")) {
                Row(label: t("Sorgente", "Source"), value: b.onAC ? t("Alimentatore", "Power adapter") : t("Batteria", "Battery"))
                Row(label: b.isCharging ? t("Tempo alla carica", "Time to full") : t("Tempo di scarica", "Time to empty"),
                    value: b.minutesRemaining.map { duration(minutes: $0) }
                        ?? (b.onAC && !b.isCharging ? "—" : t("Calcolo…", "Calculating…")))
                if let maxCap = b.rawMaxCapacity, let design = b.designCapacity, design > 0 {
                    Row(label: t("Capacità massima", "Maximum capacity"), value: "\(maxCap) / \(design) mAh")
                    ProgressView(value: min(Double(maxCap) / Double(design), 1))
                        .tint(Double(maxCap) / Double(design) < 0.8 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                }
                if let h = b.health { Row(label: t("Salute", "Health"), value: pct(h)) }
                if let c = b.cycleCount { Row(label: t("Numero di cicli", "Cycle count"), value: "\(c)") }
                if let temp = b.temperature ?? model.stats?.batteryTemperature {
                    Row(label: t("Temperatura", "Temperature"), value: temp.formatted(.number.precision(.fractionLength(1))) + " °C")
                }
                if let w = b.watts {
                    Row(label: t("Potenza", "Power"), value: abs(w).formatted(.number.precision(.fractionLength(1))) + " W")
                }
                if let a = b.amperage { Row(label: t("Corrente", "Current"), value: "\(a) mA") }
                if let v = b.voltage {
                    Row(label: t("Tensione", "Voltage"), value: v.formatted(.number.precision(.fractionLength(2))) + " V")
                }
                if let w = b.adapterWatts { Row(label: t("Alimentatore", "Power adapter"), value: "\(w) W") }
            }
            Card(title: t("Consumo energetico (CPU)", "Energy use (CPU)")) {
                ProcessList(items: topCPU(model, 5))
            }
        }
    }
}
