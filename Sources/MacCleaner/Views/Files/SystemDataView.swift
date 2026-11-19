import SwiftUI
import AppKit
import MacCleanerKit

/// "System Data": what macOS's catch-all storage category really contains on
/// this Mac, measured item by item (each byte once), labelled Safe / Review /
/// Protected, with what grew since the last scan.
struct SystemDataView: View {
    @Environment(AppState.self) private var appState
    @State private var model = SystemDataModel.shared
    @State private var expanded: Set<SystemDataCategoryID> = []
    /// Category whose full item list is open in the sheet.
    @State private var allItemsOf: SystemDataCategoryID?
    @State private var confirmClean = false
    @State private var confirmSnapshots = false

    var body: some View {
        ZStack {
            if model.scanning {
                ScanProgressRing(progress: 0, phase: KMR.t("Misuro i dati di sistema…", "Measuring System Data…"),
                                 detail: KMR.t("Elementi esaminati: \(model.itemsVisited.formatted(.number.locale(UIText.locale)))",
                                               "Items examined: \(model.itemsVisited.formatted(.number.locale(UIText.locale)))"),
                                 indeterminate: true)
                    .environment(\.currentModule, .systemData)
                    .transition(.immersive)
            } else if !model.hasResults {
                intro.transition(.immersive)
            } else {
                results.transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: model.scanning)
        .overlay(alignment: .bottom) {
            if let busy = model.busy {
                Label(busy, systemImage: "hourglass")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.busy)
        .respondsToModuleShortcuts(onScan: { model.scan() }, onClean: { confirmClean = true },
                                   canScan: !model.scanning, canClean: model.hasResults && model.hasSelection)
        .task {
            if ProcessInfo.processInfo.environment["KMR_AUTOSCAN"] != nil, !model.hasResults { model.scan() }
        }
    }

    // MARK: Intro

    private var intro: some View {
        ContentUnavailableView {
            Label(KMR.t("Dati di sistema", "System Data"), systemImage: "internaldrive")
        } description: {
            VStack(spacing: 8) {
                Text(KMR.t("Scopri cosa c'è davvero in «Dati di sistema» di Impostazioni › Generali › Archiviazione: ogni voce misurata su questo Mac, spiegata e marcata come sicura, da controllare o protetta.",
                           "See what is really inside \"System Data\" in Settings › General › Storage: every item measured on this Mac, explained and marked as safe, to review or protected."))
                if let last = model.lastHistory {
                    Text(KMR.t("Ultima analisi: \(last.date.formatted(.relative(presentation: .named).locale(UIText.locale)))",
                               "Last scan: \(last.date.formatted(.relative(presentation: .named).locale(UIText.locale)))"))
                        .foregroundStyle(.tertiary)
                }
            }
        } actions: {
            Button(KMR.t("Analizza", "Scan")) { model.scan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    // MARK: Results

    private var results: some View {
        // Debug aid for snapshots: KMR_SYSTEMDATA_ONLY=safe|review|protected
        // shows just that group, with its largest category expanded.
        let only = ProcessInfo.processInfo.environment["KMR_SYSTEMDATA_ONLY"].flatMap(SystemDataSafety.init(rawValue:))
        return Form {
            if let only {
                group(only)
            } else {
                summarySection
                growthSection
                group(.safe)
                group(.review)
                group(.protected)
                accessSection
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { cleanBar }
        .sheet(isPresented: Binding(get: { allItemsOf != nil }, set: { if !$0 { allItemsOf = nil } })) {
            if let id = allItemsOf, let c = model.categories.first(where: { $0.id == id }) {
                SystemDataAllItemsSheet(category: c, model: model) { allItemsOf = nil }
            }
        }
        .task {
            if let only, let first = model.visible(only).first { expanded.insert(first.id) }
            // Perf repro (KMR_SYSTEMDATA_EXPAND=all): open every category and
            // the full list of the longest one, then toggle selections like a
            // user would.
            guard ProcessInfo.processInfo.environment["KMR_SYSTEMDATA_EXPAND"] == "all" else { return }
            let cats = (only.map { [$0] } ?? SystemDataSafety.allCases).flatMap { model.visible($0) }
            expanded = Set(cats.map(\.id))
            allItemsOf = cats.max { (model.listedItems[$0.id]?.count ?? 0) < (model.listedItems[$1.id]?.count ?? 0) }?.id
            let paths = cats.flatMap { model.removablePathList($0.id).prefix(5) }
            for path in paths.prefix(20) {
                try? await Task.sleep(for: .milliseconds(300))
                model.binding(path).wrappedValue.toggle()
            }
            try? await Task.sleep(for: .seconds(2))
            allItemsOf = nil   // an open sheet would block the stress harness from quitting
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FileSizeFormatter.format(model.totalMeasured))
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(KMR.t("misurati in Dati di sistema", "measured in System Data"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(KMR.t("Analizza di nuovo", "Scan again"), systemImage: "arrow.clockwise") { model.scan() }
                        .labelStyle(.iconOnly)
                        .help(KMR.t("Analizza di nuovo", "Scan again"))
                }
                SystemDataBar(segments: segments, total: model.totalMeasured)
                    .frame(height: 14)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(segments) { s in
                        HStack(spacing: 6) {
                            Circle().fill(s.color).frame(width: 8, height: 8)
                            Text(s.label).lineLimit(1)
                            Text(FileSizeFormatter.format(s.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(.vertical, 4)
            LabeledContent {
                Text(FileSizeFormatter.format(model.safelyReclaimable)).monospacedDigit().foregroundStyle(KMR.green).fontWeight(.semibold)
            } label: {
                Label { Text(KMR.t("Recuperabile in sicurezza", "Safely reclaimable")) } icon: { IconTile(symbol: "checkmark.shield.fill", color: KMR.green) }
            }
            LabeledContent {
                Text(FileSizeFormatter.format(model.total(.review))).monospacedDigit()
            } label: {
                Label { Text(KMR.t("Da controllare", "To review")) } icon: { IconTile(symbol: "exclamationmark.shield.fill", color: KMR.orange) }
            }
            LabeledContent {
                Text(FileSizeFormatter.format(model.total(.protected))).monospacedDigit()
            } label: {
                Label { Text(KMR.t("Protetto, gestito da macOS", "Protected, managed by macOS")) } icon: { IconTile(symbol: "lock.shield.fill", color: KMR.gray) }
            }
        } footer: {
            if let at = model.scannedAt {
                Text(KMR.t("Ogni byte è contato una volta: cartelle annidate e hard link non vengono sommati due volte. Analisi: \(at.formatted(date: .omitted, time: .shortened)).",
                           "Every byte is counted once: nested folders and hard links are not added twice. Scanned: \(at.formatted(date: .omitted, time: .shortened))."))
            }
        }
    }

    private var segments: [SystemDataBar.Segment] {
        let palette: [Color] = [.blue, .purple, .orange, .green, .teal, .pink, .yellow]
        let sorted = model.categories.filter(\.countsInTotal)
            .map { ($0.id, model.measurement($0.id)?.bytes ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        var out = sorted.prefix(palette.count).enumerated().map { i, e in
            SystemDataBar.Segment(id: e.0.rawValue, label: SystemDataCatalog.title(e.0), bytes: e.1, color: palette[i])
        }
        let rest = sorted.dropFirst(palette.count).reduce(UInt64(0)) { $0 &+ $1.1 }
        if rest > 0 { out.append(.init(id: "other", label: KMR.t("Altro", "Other"), bytes: rest, color: .gray)) }
        return out
    }

    // MARK: What grew

    @ViewBuilder
    private var growthSection: some View {
        let rows = model.categoryGrowth + model.folderGrowth
        if model.hasResults {
            Section {
                ForEach(model.categoryGrowth) { g in
                    growthRow(g, title: SystemDataCatalog.title(SystemDataCategoryID(rawValue: g.key) ?? .userCaches),
                              icon: SystemDataStyle.symbol(SystemDataCategoryID(rawValue: g.key) ?? .userCaches),
                              color: SystemDataStyle.color(SystemDataCategoryID(rawValue: g.key) ?? .userCaches))
                }
                ForEach(model.folderGrowth) { g in
                    growthRow(g, title: "~/" + g.key, icon: "folder.fill", color: Color(nsColor: .systemBlue))
                        .contextMenu {
                            Button(KMR.t("Mostra nel Finder", "Show in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSHomeDirectory() + "/" + g.key)])
                            }
                        }
                }
                if model.categoryBaselineDate == nil && model.folderBaselineDate == nil && !model.homeWalking {
                    Label(KMR.t("Prima analisi salvata: dalla prossima vedrai qui cosa è cresciuto.",
                                "First scan saved: from the next one you will see here what grew."), systemImage: "clock.badge.checkmark")
                        .foregroundStyle(.secondary)
                } else if model.homeWalking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(KMR.t("Misuro le cartelle della tua Inizio…", "Measuring the folders in your home…")).foregroundStyle(.secondary)
                    }
                } else if rows.isEmpty {
                    Label(KMR.t("Nessuna crescita rilevante", "No significant growth"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(KMR.t("Cosa è cresciuto dall'ultima volta", "What grew since last time"))
            } footer: {
                if let d = model.categoryBaselineDate ?? model.folderBaselineDate {
                    Text(KMR.t("Rispetto all'analisi del \(d.formatted(.dateTime.day().month().hour().minute().locale(UIText.locale))). Sono mostrate solo le crescite oltre 50 MB.",
                               "Compared with the scan of \(d.formatted(.dateTime.day().month().hour().minute().locale(UIText.locale))). Only growth above 50 MB is shown."))
                }
            }
        }
    }

    private func growthRow(_ g: SystemDataGrowth, title: String, icon: String, color: Color) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text("+" + FileSizeFormatter.format(UInt64(max(0, g.delta))))
                    .monospacedDigit().foregroundStyle(KMR.orange).fontWeight(.semibold)
                Text(KMR.t("ora \(FileSizeFormatter.format(g.after))", "now \(FileSizeFormatter.format(g.after))"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } label: {
            Label { Text(title).lineLimit(1).truncationMode(.middle) } icon: { IconTile(symbol: icon, color: color) }
        }
    }

    // MARK: Groups

    @ViewBuilder
    private func group(_ safety: SystemDataSafety) -> some View {
        let cats = model.visible(safety)
        if !cats.isEmpty {
            Section {
                ForEach(cats) { c in
                    categoryRow(c)
                    // Items are rows of the Form, not children of the
                    // DisclosureGroup: a disclosure's content is laid out as
                    // one stack, so hundreds of items made every checkbox
                    // click relayout all of them on the main thread.
                    if expanded.contains(c.id) { itemRows(c) }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: SystemDataStyle.safetySymbol(safety)).foregroundStyle(SystemDataStyle.safetyTint(safety))
                    Text(SystemDataStyle.safetyTitle(safety))
                }
            } footer: {
                Text(SystemDataStyle.safetyFooter(safety))
            }
        }
    }

    private func categoryRow(_ c: SystemDataCategory) -> some View {
        let m = model.measurement(c.id)
        let removable = model.removableCount(c.id)
        let picked = model.selectedPerCategory[c.id] ?? 0
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(c.id) },
            set: { if $0 { expanded.insert(c.id) } else { expanded.remove(c.id) } })) {
            categoryDetail(c)
        } label: {
            HStack(spacing: 10) {
                if c.action == .trash {
                    if removable == 0 {
                        Toggle("", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().disabled(true)
                            .help(KMR.t("Niente che Mac Mop possa spostare nel Cestino: file di sistema o in uso.",
                                        "Nothing Mac Mop can move to the Trash: system files or in use."))
                    } else {
                        // Two sources that differ when only some items are ticked,
                        // so the system checkbox shows its mixed state in O(1).
                        Toggle(sources: [Binding(get: { picked > 0 }, set: { model.setAll(c.id, $0) }),
                                         Binding(get: { picked >= removable }, set: { model.setAll(c.id, $0) })],
                               isOn: \.self) { EmptyView() }
                            .toggleStyle(.checkbox).labelsHidden()
                    }
                }
                IconTile(symbol: SystemDataStyle.symbol(c.id), color: SystemDataStyle.color(c.id), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SystemDataCatalog.title(c.id))
                    Text(SystemDataCatalog.explanation(c.id))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sizeText(c, m)).monospacedDigit().foregroundStyle(.secondary)
                    if m?.partial == true || !(m?.unreadableRoots.isEmpty ?? true) {
                        Text(KMR.t("in parte non leggibile", "partly unreadable")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func sizeText(_ c: SystemDataCategory, _ m: SystemDataMeasurement?) -> String {
        if c.id == .timeMachine {
            return KMR.t("Istantanee: \(model.snapshotNames.count)", "Snapshots: \(model.snapshotNames.count)")
        }
        let bytes = m?.bytes ?? 0
        if bytes == 0, !(m?.unreadableRoots.isEmpty ?? true) { return KMR.t("Non leggibile", "Not readable") }
        return FileSizeFormatter.format(bytes)
    }

    /// Items listed inline under an expanded category. The Form lays out
    /// every row it holds on each update, so longer lists open in a sheet
    /// whose List only builds the visible rows.
    private static func inlineLimit(_ c: SystemDataCategory) -> Int { c.granularity == .roots ? 12 : 8 }

    @ViewBuilder
    private func categoryDetail(_ c: SystemDataCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                SystemDataSafetyBadge(safety: c.safety)
                Text(SystemDataCatalog.guidance(c.id)).font(.callout).foregroundStyle(.secondary)
            }
            if c.id == .timeMachine {
                ForEach(model.snapshotNames.prefix(6), id: \.self) { s in
                    Text(s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: ""))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(KMR.t("APFS non indica quanto spazio occupa ogni istantanea: viene liberato man mano che i file cambiati vengono rilasciati.",
                           "APFS does not report how much space each snapshot holds: it is released as changed files are freed."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            actions(c)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func itemRows(_ c: SystemDataCategory) -> some View {
        if let m = model.measurement(c.id), c.id != .timeMachine, c.id != .purgeable {
            let listed = model.listedItems[c.id] ?? []
            let shown = listed.prefix(Self.inlineLimit(c))
            ForEach(shown) { item in
                SystemDataItemRow(item: item, trashable: c.action == .trash, backup: model.backupInfo[item.path],
                                  isOn: model.binding(item.path))
                    .padding(.leading, 20)
            }
            let rest = listed.dropFirst(shown.count)
            if !rest.isEmpty {
                let restBytes = rest.reduce(UInt64(0)) { $0 &+ $1.bytes }
                Button {
                    allItemsOf = c.id
                } label: {
                    Text(KMR.t("Mostra altri elementi: \(rest.count) · \(FileSizeFormatter.format(restBytes))",
                               "Show more items: \(rest.count) · \(FileSizeFormatter.format(restBytes))"))
                        .font(.callout)
                }
                .buttonStyle(.link)
                .padding(.leading, 20)
            }
            ForEach(m.unreadableRoots, id: \.self) { root in
                Label(KMR.t("Non leggibile: \(SystemDataStyle.tilde(root))", "Not readable: \(SystemDataStyle.tilde(root))"),
                      systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func actions(_ c: SystemDataCategory) -> some View {
        switch c.action {
        case .adminSnapshots:
            Button(KMR.t("Elimina istantanee locali…", "Delete local snapshots…"), role: .destructive) { confirmSnapshots = true }
                .confirmationDialog(KMR.t("Eliminare le istantanee locali?", "Delete local snapshots?"), isPresented: $confirmSnapshots) {
                    Button(KMR.t("Elimina", "Delete"), role: .destructive) { Task { await model.deleteSnapshots() } }
                } message: {
                    Text(KMR.t("Perderai i punti di ripristino delle ultime ore salvati su questo Mac. I backup sul disco di Time Machine non vengono toccati. Ti verrà chiesta la password.",
                               "You lose the recent restore points stored on this Mac. Backups on your Time Machine disk are not touched. You will be asked for your password."))
                }
        case .openTrash:
            Button(KMR.t("Apri Cestini", "Open Trash Bins")) { appState.selectedSidebarItem = .trashBins }
        case .reveal:
            HStack {
                if let first = model.measurement(c.id)?.items.first?.path ?? c.roots.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    Button(KMR.t("Mostra nel Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                    }
                }
                if c.id == .virtualMachines {
                    Button(KMR.t("Apri Spazio extra", "Open Extra space")) { appState.selectedSidebarItem = .storageExtras }
                }
            }
        case .info:
            if c.id == .appleIntelligence {
                Button(KMR.t("Apri Apple Intelligence e Siri", "Open Apple Intelligence & Siri")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
            }
        case .trash:
            if c.id == .aerials {
                Button(KMR.t("Apri Impostazioni Sfondo", "Open Wallpaper Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
            }
        }
    }

    // MARK: Access

    @ViewBuilder
    private var accessSection: some View {
        let roots = model.unreadableRoots
        if !roots.isEmpty || model.hasPartialResults {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(KMR.t("Alcune posizioni non sono leggibili", "Some locations are not readable"))
                        Text(KMR.t("Senza Accesso completo al disco le loro dimensioni mancano o sono parziali. Alcune cartelle (come l'indice di Spotlight) sono leggibili solo da macOS.",
                                   "Without Full Disk Access their sizes are missing or partial. Some folders (like the Spotlight index) can only be read by macOS."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { IconTile(symbol: "lock.fill", color: KMR.gray, size: 26) }
                Button(KMR.t("Apri Accesso completo al disco", "Open Full Disk Access")) {
                    PermissionManager.shared.openFullDiskAccessSettings()
                }
            }
        }
    }

    // MARK: Clean bar

    private var cleanBar: some View {
        let count = model.selectedCount
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary).lineLimit(2)
                        .transition(.opacity)
                } else {
                    Text(KMR.t("Selezionati: \(count) · \(FileSizeFormatter.format(model.selectedBytes))",
                               "Selected: \(count) · \(FileSizeFormatter.format(model.selectedBytes))"))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button(KMR.t("Pulisci", "Clean")) { confirmClean = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(count == 0 || model.busy != nil)
                    .confirmationDialog(KMR.t("Spostare nel Cestino gli elementi selezionati?", "Move the selected items to the Trash?"),
                                        isPresented: $confirmClean) {
                        Button(KMR.t("Sposta nel Cestino", "Move to Trash"), role: .destructive) {
                            Task { await model.clean(engine: appState.cleaningEngine) }
                        }
                    } message: {
                        Text(KMR.t("\(FileSizeFormatter.format(model.selectedBytes)) andranno nel Cestino. Puoi ripristinarli da Cronologia pulizie.",
                                   "\(FileSizeFormatter.format(model.selectedBytes)) will go to the Trash. You can restore them from Cleanup History."))
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
        .animation(.smooth, value: model.notice)
    }
}

// MARK: - Pieces

/// Every item of one category in a List, which builds only the visible
/// rows: thousands of items stay smooth to scroll and tick.
private struct SystemDataAllItemsSheet: View {
    let category: SystemDataCategory
    let model: SystemDataModel
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        let all = model.listedItems[category.id] ?? []
        let items = SearchMatcher.tokens(query).isEmpty ? all
            : all.filter { SearchMatcher.matches(query: query, fields: [$0.name, $0.path]) }
        let removable = model.removableCount(category.id)
        let picked = model.selectedPerCategory[category.id] ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: SystemDataStyle.symbol(category.id), color: SystemDataStyle.color(category.id), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SystemDataCatalog.title(category.id)).font(.headline)
                    Text(KMR.t("Elementi: \(items.count) · \(FileSizeFormatter.format(model.measurement(category.id)?.bytes ?? 0))",
                               "Items: \(items.count) · \(FileSizeFormatter.format(model.measurement(category.id)?.bytes ?? 0))"))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if category.action == .trash, removable > 0 {
                    Toggle(sources: [Binding(get: { picked > 0 }, set: { model.setAll(category.id, $0) }),
                                     Binding(get: { picked >= removable }, set: { model.setAll(category.id, $0) })],
                           isOn: \.self) { Text(KMR.t("Seleziona tutto", "Select all")) }
                        .toggleStyle(.checkbox)
                }
            }
            .padding(16)
            NativeSearchField(text: $query, prompt: KMR.t("Filtra per nome o percorso", "Filter by name or path"))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            if items.isEmpty, !all.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                List(items) { item in
                    SystemDataItemRow(item: item, trashable: category.action == .trash, backup: model.backupInfo[item.path],
                                      isOn: model.binding(item.path))
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text(KMR.t("Selezionati: \(model.selectedCount) · \(FileSizeFormatter.format(model.selectedBytes))",
                           "Selected: \(model.selectedCount) · \(FileSizeFormatter.format(model.selectedBytes))"))
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(KMR.t("Fine", "Done"), action: done)
                    .keyboardShortcut(.defaultAction)
                    .escapeKeyAction(done)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
    }
}

/// One item inside an expanded category. Its own view so a checkbox click
/// redraws only the rows, and its icon is drawn off the main thread.
private struct SystemDataItemRow: View {
    let item: SystemDataItem
    let trashable: Bool
    let backup: (name: String?, date: Date?)?
    let isOn: Binding<Bool>

    var body: some View {
        let info = FriendlyName.info(for: FileItem(url: URL(fileURLWithPath: item.path), name: item.name, size: item.bytes,
                                                   allocatedSize: item.bytes, isDirectory: item.isDirectory))
        let app = SystemDataStyle.app(forFolderNamed: item.name)
        HStack(spacing: 8) {
            if trashable {
                Toggle(item.name, isOn: isOn).toggleStyle(.checkbox).labelsHidden()
                    .disabled(!item.removable)
            }
            if backup != nil {
                Image(systemName: "iphone").frame(width: 18, height: 18).foregroundStyle(.secondary)
            } else {
                FileIcon(path: app?.path ?? info.iconPath, size: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(backup?.name ?? app?.name ?? (item.path.hasPrefix("/System/Library/AssetsV2/") ? SystemDataCatalog.assetDisplayName(item.name) : info.title)).lineLimit(1).truncationMode(.middle)
                Text(backup?.date.map { KMR.t("Ultimo backup: \($0.formatted(date: .abbreviated, time: .shortened))",
                                              "Last backup: \($0.formatted(date: .abbreviated, time: .shortened))") }
                     ?? (item.removable || !trashable ? SystemDataStyle.tilde(item.path)
                         : KMR.t("\(SystemDataStyle.tilde(item.path)) · non modificabile", "\(SystemDataStyle.tilde(item.path)) · not removable")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(FileSizeFormatter.format(item.bytes)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, trashable ? 0 : 4)
        .contextMenu {
            FileContextMenuItems(url: URL(fileURLWithPath: item.path))
        }
    }
}

/// Stacked storage bar, like the one in System Settings › Storage.
struct SystemDataBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: UInt64
        let color: Color
    }

    let segments: [Segment]
    let total: UInt64

    var body: some View {
        GeometryReader { geo in
            let t = max(Double(total), 1)
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    Rectangle()
                        .fill(s.color.gradient)
                        .frame(width: max(2, (geo.size.width - gaps) * Double(s.bytes) / t))
                        .help("\(s.label): \(FileSizeFormatter.format(s.bytes))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .accessibilityElement()
        .accessibilityLabel(segments.map { "\($0.label) \(FileSizeFormatter.format($0.bytes))" }.joined(separator: ", "))
    }
}

struct SystemDataSafetyBadge: View {
    let safety: SystemDataSafety

    var body: some View {
        Label(SystemDataStyle.safetyShort(safety), systemImage: SystemDataStyle.safetySymbol(safety))
            .font(.caption.weight(.semibold))
            .foregroundStyle(SystemDataStyle.safetyTint(safety))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SystemDataStyle.safetyTint(safety).opacity(0.14), in: Capsule())
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

enum SystemDataStyle {
    static func safetyTint(_ s: SystemDataSafety) -> Color {
        switch s {
        case .safe: KMR.green
        case .review: KMR.orange
        case .protected: KMR.gray
        }
    }

    static func safetySymbol(_ s: SystemDataSafety) -> String {
        switch s {
        case .safe: "checkmark.shield.fill"
        case .review: "exclamationmark.shield.fill"
        case .protected: "lock.shield.fill"
        }
    }

    static func safetyShort(_ s: SystemDataSafety) -> String {
        switch s {
        case .safe: KMR.t("Sicuro", "Safe")
        case .review: KMR.t("Controlla", "Review")
        case .protected: KMR.t("Protetto", "Protected")
        }
    }

    static func safetyTitle(_ s: SystemDataSafety) -> String {
        switch s {
        case .safe: KMR.t("Sicuro da pulire", "Safe to clean")
        case .review: KMR.t("Da controllare", "Review first")
        case .protected: KMR.t("Protetto", "Protected")
        }
    }

    static func safetyFooter(_ s: SystemDataSafety) -> String {
        switch s {
        case .safe: KMR.t("Si ricrea o si riscarica da solo. Gli elementi selezionati vanno nel Cestino e puoi annullare da Cronologia pulizie.",
                          "Rebuilds or downloads again by itself. Selected items go to the Trash and you can undo from Cleanup History.")
        case .review: KMR.t("Possono essere tuoi dati o cose che ti servono ancora: niente è preselezionato.",
                            "This may be your data or something you still need: nothing is preselected.")
        case .protected: KMR.t("Gestito da macOS: Mac Mop non lo tocca, ma ti spiega come ridurlo.",
                               "Managed by macOS: Mac Mop does not touch it, but explains how to reduce it.")
        }
    }

    static func symbol(_ id: SystemDataCategoryID) -> String {
        switch id {
        case .timeMachine: "clock.arrow.circlepath"
        case .purgeable: "icloud.fill"
        case .vmSwap: "memorychip.fill"
        case .appleIntelligence: NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil ? "apple.intelligence" : "sparkles"
        case .systemAssets: "square.and.arrow.down.fill"
        case .aerials: "photo.fill"
        case .userCaches: "archivebox.fill"
        case .systemCaches: "archivebox.fill"
        case .tempFiles: "hourglass"
        case .userLogs, .systemLogs: "doc.text.fill"
        case .unifiedLogs: "list.bullet.rectangle.fill"
        case .spotlight: "magnifyingglass"
        case .iosBackups: "iphone"
        case .xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport: "hammer.fill"
        case .simulatorCaches, .simulatorDevices: "ipad.and.iphone"
        case .installers: "arrow.down.app.fill"
        case .mailDownloads: "envelope.fill"
        case .messages: "message.fill"
        case .mediaAnalysis: "person.crop.rectangle.stack.fill"
        case .virtualMachines: "server.rack"
        case .devCaches: "terminal.fill"
        case .pnpmStore: "shippingbox.fill"
        case .appContainers: "square.stack.3d.up.fill"
        case .trash: "trash.fill"
        }
    }

    static func color(_ id: SystemDataCategoryID) -> Color {
        switch id {
        case .timeMachine: Color(nsColor: .systemGreen)
        case .purgeable: Color(nsColor: .systemCyan)
        case .vmSwap, .tempFiles, .unifiedLogs, .spotlight, .trash: Color(nsColor: .systemGray)
        case .appleIntelligence: Color(nsColor: .systemPurple)
        case .systemAssets, .appContainers: Color(nsColor: .systemIndigo)
        case .aerials: Color(nsColor: .systemTeal)
        case .userCaches, .systemCaches, .mailDownloads: Color(nsColor: .systemBlue)
        case .userLogs, .systemLogs, .pnpmStore: Color(nsColor: .systemOrange)
        case .iosBackups, .messages: Color(nsColor: .systemGreen)
        case .xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport, .simulatorCaches, .simulatorDevices: Color(nsColor: .systemBlue)
        case .installers: Color(nsColor: .systemPink)
        case .mediaAnalysis: Color(nsColor: .systemYellow)
        case .virtualMachines, .devCaches: Color(nsColor: .systemBrown)
        }
    }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    @MainActor private static var appCache: [String: (name: String, path: String)?] = [:]

    /// App behind a container or cache folder name: "com.google.Chrome",
    /// "6N38VWS5BX.ru.keepcoder.Telegram" (team prefix), "group.net.whatsapp.WhatsApp.shared".
    @MainActor
    static func app(forFolderNamed name: String) -> (name: String, path: String)? {
        if let hit = appCache[name] { return hit }
        var parts = name.split(separator: ".").map(String.init)
        if parts.first == "group" { parts.removeFirst() }
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) { parts.removeFirst() }
        var result: (name: String, path: String)?
        while parts.count >= 2, result == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) {
                result = (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url.path)
            }
            parts.removeLast()
        }
        appCache.updateValue(result, forKey: name)
        return result
    }
}
