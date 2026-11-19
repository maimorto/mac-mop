import SwiftUI
import AppKit
import MacCleanerKit

struct PrivacyView: View {
    @Environment(AppState.self) private var appState
    @State private var results: [ScanResult] = []
    @State private var selectedItems: Set<URL> = []
    @State private var isScanning = false
    @State private var scanProgress: Double = 0
    @State private var scanPhase = ""
    @State private var scanComplete = false
    @State private var completion: CleanSummary?
    @State private var cleaning: CleaningEngine.Progress?
    @State private var cleanTask: Task<Void, Never>?
    @State private var lastRemoved: Set<URL> = []
    @State private var timeFilter: PrivacyModule.TimeFilter = .allTime

    @Environment(\.moduleIsSelected) private var isSelected
    @State private var installed: [PrivacyBrowser] = []
    @State private var confirmClean = false

    var body: some View {
        ZStack {
            if let completion {
                doneScreen(completion).transition(.immersive)
            } else if let cleaning {
                VStack(spacing: 24) {
                    ScanProgressRing(progress: cleaning.totalItems > 0 ? Double(cleaning.processedItems) / Double(cleaning.totalItems) : 0,
                                     phase: KMR.t("Cancellazione delle tracce…", "Clearing traces…"))
                    Button(L10n.tr("取消", "Cancel", "Отмена")) { cleanTask?.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .transition(.immersive)
            } else if isScanning {
                ScanProgressRing(progress: scanProgress, phase: scanPhase).transition(.immersive)
            } else {
                dashboard.transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: screenKey)
        .pageNavigation(id: "privacy.done", canGoBack: completion != nil, back: backToResults)
        .onAppear {
            installed = PrivacyBrowser.allCases.filter(\.isInstalled)
            if let e = appState.scanResultsStore.entry(for: .privacy) {
                results = e.results
                selectedItems = e.selection
                scanComplete = e.scanComplete
            }
        }
        .onDisappear {
            appState.scanResultsStore.save(results: results, selection: selectedItems, scanComplete: scanComplete, for: .privacy)
        }
        .onChange(of: isScanning) { was, now in
            if was && !now { SoundFX.play(results.isEmpty ? .nothingFound : .scanDone) }
        }
    }

    private var screenKey: Int {
        completion != nil ? 3 : cleaning != nil ? 2 : isScanning ? 1 : 0
    }

    // MARK: Grouping

    private var allItems: [FileItem] { results.flatMap(\.items) }

    private func items(for browser: PrivacyBrowser?, kind: PrivacyDataKind) -> [FileItem] {
        allItems.filter { PrivacyBrowser(path: $0.url.path) == browser && PrivacyDataKind(path: $0.url.path) == kind }
    }

    private func size(_ items: [FileItem]) -> UInt64 { items.reduce(0) { $0 + $1.size } }

    private var selectedBytes: UInt64 {
        allItems.reduce(0) { $0 + (selectedItems.contains($1.url) ? $1.size : 0) }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(spacing: 6) {
                        ModuleIcon(item: .privacy, size: 64)
                        Text("Privacy").font(.title2.weight(.bold))
                        Text(KMR.t("Cancella la cronologia e le cache dei browser e le tracce dei documenti recenti. Password, cookie e dati delle estensioni non vengono mai toccati.",
                                   "Clear browser history and caches and recent-document traces. Passwords, cookies and extension data are never touched."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    Picker(KMR.t("Periodo", "Time range"), selection: $timeFilter) {
                        Text(KMR.t("Ultime 24 ore", "Last 24 hours")).tag(PrivacyModule.TimeFilter.today)
                        Text(KMR.t("Ultima settimana", "Last week")).tag(PrivacyModule.TimeFilter.lastWeek)
                        Text(KMR.t("Ultimo mese", "Last month")).tag(PrivacyModule.TimeFilter.lastMonth)
                        Text(KMR.t("Ultimo anno", "Last year")).tag(PrivacyModule.TimeFilter.lastYear)
                        Text(KMR.t("Da sempre", "All time")).tag(PrivacyModule.TimeFilter.allTime)
                    }
                }

                Section {
                    if installed.isEmpty {
                        Text(KMR.t("Nessun browser trovato", "No browsers found")).foregroundStyle(.secondary)
                    }
                    ForEach(installed) { browser in
                        browserBlock(browser)
                    }
                } header: {
                    Text("Browser")
                } footer: {
                    if !runningBrowsers.isEmpty {
                        Label(KMR.t("Chiudi \(runningBrowsers.map(\.name).joined(separator: ", ")) prima di pulire, altrimenti alcuni file restano in uso.",
                                    "Quit \(runningBrowsers.map(\.name).joined(separator: ", ")) before cleaning, otherwise some files stay in use."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(KMR.orange)
                            .font(.callout)
                    }
                }

                Section(KMR.t("Tracce di sistema", "System traces")) {
                    dataRow(browser: nil, kind: .recentItems)
                }
            }
            .formStyle(.grouped)

            actionBar
        }
    }

    private var runningBrowsers: [PrivacyBrowser] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return installed.filter { running.contains($0.bundleID) }
    }

    private func browserBlock(_ browser: PrivacyBrowser) -> some View {
        let kinds = browser.kinds
        let total = kinds.reduce(UInt64(0)) { $0 + size(items(for: browser, kind: $1)) }
        return Group {
            HStack(spacing: 10) {
                if let icon = browser.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                Text(browser.name).font(.headline)
                Spacer()
                if scanComplete {
                    Text(total > 0 ? FileSizeFormatter.format(total) : KMR.t("Pulito", "Clean"))
                        .foregroundStyle(total > 0 ? .primary : .secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            ForEach(kinds, id: \.self) { kind in
                dataRow(browser: browser, kind: kind)
                    .padding(.leading, 38)
            }
        }
    }

    private func dataRow(browser: PrivacyBrowser?, kind: PrivacyDataKind) -> some View {
        let list = items(for: browser, kind: kind)
        let urls = list.map(\.url)
        let on = !urls.isEmpty && urls.allSatisfy { selectedItems.contains($0) }
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { on },
                set: { v in withAnimation(.smooth(duration: 0.2)) {
                    if v { selectedItems.formUnion(urls) } else { selectedItems.subtract(urls) }
                } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(urls.isEmpty)
                .padding(.top, 2)
            Image(systemName: kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if scanComplete {
                Text(list.isEmpty ? "—" : FileSizeFormatter.format(size(list)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .opacity(scanComplete && list.isEmpty ? 0.55 : 1)
    }

    private var actionBar: some View {
        HStack {
            if scanComplete {
                VStack(alignment: .leading, spacing: 1) {
                    Text(FileSizeFormatter.format(selectedBytes))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(KMR.t("selezionati · vanno nel Cestino", "selected · moved to the Trash"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .animation(.smooth, value: selectedBytes)
            }
            Spacer()
            if scanComplete {
                Button(KMR.t("Scansiona di nuovo", "Scan again"), action: scan)
                    .controlSize(.large)
                Button(KMR.t("Pulisci", "Clean")) { confirmClean = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedItems.isEmpty)
                    .confirmationDialog(KMR.t("Cancellare le tracce selezionate?", "Clear the selected traces?"),
                                        isPresented: $confirmClean) {
                        Button(KMR.t("Pulisci", "Clean"), role: .destructive, action: clean)
                    } message: {
                        Text(KMR.t("\(FileSizeFormatter.format(selectedBytes)) finiranno nel Cestino. Puoi ripristinarli da Cronologia pulizia.",
                                   "\(FileSizeFormatter.format(selectedBytes)) will be moved to the Trash. You can restore them from Cleanup History."))
                    }
            } else {
                Button(KMR.t("Scansiona", "Scan"), action: scan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func doneScreen(_ summary: CleanSummary) -> some View {
        VStack(spacing: 14) {
            if summary.removedCount == 0 && summary.selectedCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(KMR.t("Nessuna traccia cancellata", "No traces were cleared")).font(.title2.weight(.bold))
            } else {
                SuccessMark(size: 84)
                Text(summary.wasCancelled ? KMR.t("Pulizia interrotta", "Cleanup stopped") : KMR.t("Tracce cancellate", "Traces cleared"))
                    .font(.title2.weight(.bold))
            }
            Text(KMR.t("\(FileSizeFormatter.format(summary.freedBytes)) spostati nel Cestino",
                       "\(FileSizeFormatter.format(summary.freedBytes)) moved to the Trash"))
                .foregroundStyle(.secondary)
            if let error = summary.firstErrorMessage {
                Text(summary.errorCount > 1 ? KMR.t("\(error) (errori: \(summary.errorCount))", "\(error) (errors: \(summary.errorCount))") : error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button {
                    backToResults()
                } label: {
                    Label(KMR.t("Torna ai risultati", "Back to Results"), systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(KMR.t("Rivedi gli elementi rimasti (Esc, ⌘[)", "Review the items that are left (Esc, ⌘[)"))
                Button(L10n.tr("完成", "Done", "Готово"), action: reset)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.top, 6)
            DoneScreenFooter()
        }
    }

    private func scan() {
        isScanning = true
        scanComplete = false
        scanProgress = 0
        results = []
        selectedItems = []
        Task {
            let scanStart = Date()

            scanPhase = L10n.tr("正在扫描 Safari 数据...", "Scanning Safari data...", "Сканирование данных Safari...")
            scanProgress = 0.15
            try? await Task.sleep(for: .milliseconds(400))

            scanPhase = L10n.tr("正在扫描 Chrome 数据...", "Scanning Chrome data...", "Сканирование данных Chrome...")
            scanProgress = 0.35

            let module = PrivacyModule(timeFilter: timeFilter)
            async let scanTask = module.scan()

            try? await Task.sleep(for: .milliseconds(400))
            scanPhase = L10n.tr("正在扫描 Firefox 数据...", "Scanning Firefox data...", "Сканирование данных Firefox...")
            scanProgress = 0.55

            try? await Task.sleep(for: .milliseconds(400))
            scanPhase = L10n.tr("正在检查系统痕迹...", "Checking system traces...", "Проверка системных следов...")
            scanProgress = 0.75

            results = await scanTask

            scanPhase = L10n.tr("正在分析结果...", "Analyzing results...", "Анализ результатов...")
            scanProgress = 0.9

            let elapsed = Date().timeIntervalSince(scanStart)
            if elapsed < 2.0 {
                try? await Task.sleep(for: .milliseconds(Int((2.0 - elapsed) * 1000)))
            }
            scanProgress = 1.0

            // Caches start selected; history and recent items are opt-in.
            selectedItems = Set(results.flatMap(\.items).filter { PrivacyDataKind(path: $0.url.path) == .cache }.map(\.url))
            isScanning = false
            scanComplete = true
        }
    }

    private func clean() {
        let preCleanSelectedCount = selectedItems.count
        cleaning = CleaningEngine.Progress(
            totalItems: preCleanSelectedCount,
            processedItems: 0, removedSoFar: 0, freedBytesSoFar: 0
        )
        cleanTask = Task {
            let result = await CleanActions.executeUserClean(
                results: results,
                selectedItems: selectedItems,
                engine: appState.cleaningEngine,
                onProgress: { progress in
                    Task { @MainActor in cleaning = progress }
                }
            )
            cleaning = nil
            lastRemoved = result.removedURLs
            completion = CleanSummary(
                selectedCount: preCleanSelectedCount,
                removedCount: result.removedCount,
                freedBytes: result.freedBytes,
                errorMessages: result.errors.map(\.error),
                wasCancelled: result.wasCancelled
            )
        }
    }

    private func backToResults() {
        let left = results.afterClean(removed: lastRemoved, selection: selectedItems)
        results = left.results
        selectedItems = left.selection
        lastRemoved = []
        completion = nil
    }

    private func reset() {
        results = []; selectedItems = []; completion = nil; cleaning = nil; cleanTask = nil; scanComplete = false
    }
}


// MARK: - Browser and data-type classification

enum PrivacyBrowser: String, CaseIterable, Identifiable {
    case safari, chrome, brave, edge, arc, firefox
    var id: String { rawValue }

    var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .firefox: "Firefox"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .arc: "company.thebrowser.Browser"
        case .firefox: "org.mozilla.firefox"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }
    var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    /// Data types this app supports in the scan.
    var kinds: [PrivacyDataKind] { self == .safari ? [.cache, .history] : [.cache] }

    init?(path: String) {
        if path.contains("/com.apple.Safari") || path.contains("/Library/Safari/") { self = .safari }
        else if path.contains("/Google/Chrome") { self = .chrome }
        else if path.contains("/BraveSoftware/") { self = .brave }
        else if path.contains("/Microsoft Edge") { self = .edge }
        else if path.contains("/Arc/") || path.hasSuffix("/Arc") { self = .arc }
        else if path.contains("/Firefox/") { self = .firefox }
        else { return nil }
    }
}

enum PrivacyDataKind: Hashable {
    case cache, history, recentItems

    init(path: String) {
        if path.contains("/Library/Safari/") { self = .history }
        else if path.contains("com.apple.sharedfilelist") || path.contains("RecentServers") { self = .recentItems }
        else { self = .cache }
    }

    var title: String {
        switch self {
        case .cache: KMR.t("Cache", "Cache")
        case .history: KMR.t("Cronologia di navigazione", "Browsing history")
        case .recentItems: KMR.t("Documenti e server recenti", "Recent documents and servers")
        }
    }

    var symbol: String {
        switch self {
        case .cache: "internaldrive"
        case .history: "clock"
        case .recentItems: "doc.text.magnifyingglass"
        }
    }

    var consequence: String {
        switch self {
        case .cache: KMR.t("Copie temporanee delle pagine. I siti si caricano un po' più lentamente la prima volta, poi tutto torna normale.",
                           "Temporary copies of pages. Sites load a little slower the first time, then everything is back to normal.")
        case .history: KMR.t("I siti visitati spariscono dalla cronologia e dai suggerimenti della barra degli indirizzi.",
                             "Visited sites disappear from history and from address-bar suggestions.")
        case .recentItems: KMR.t("Svuota gli elenchi Recenti del Finder e dei menu Apri recente.",
                                 "Empties the Recents lists in Finder and the Open Recent menus.")
        }
    }
}
