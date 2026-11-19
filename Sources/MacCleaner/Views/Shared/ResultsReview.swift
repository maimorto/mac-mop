import SwiftUI
import AppKit
import MacCleanerKit

// Plain-language review of scan results: one card per category that says what
// it is, whether it is safe, and which apps the files belong to. The raw file
// table stays available as "Detailed view" for experts.

// MARK: - Friendly names

/// Turns paths like ~/Library/Caches/com.google.Chrome into "Google Chrome"
/// and the path whose icon represents it. Results are cached; the Launch
/// Services lookups are cheap, and icons are drawn off-main by `FileIcon`.
@MainActor
enum FriendlyName {
    struct Info {
        let title: String
        /// File or app bundle whose Finder icon represents the item.
        let iconPath: String
        let owner: String?
    }

    private static var cache: [URL: Info] = [:]
    private static var appCache: [String: (name: String, path: String)?] = [:]

    static func info(for item: FileItem) -> Info {
        if let hit = cache[item.url] { return hit }
        let info = resolve(item)
        if cache.count > 20_000 { cache.removeAll() }
        cache[item.url] = info
        return info
    }

    private static func app(forBundleID id: String) -> (name: String, path: String)? {
        if let hit = appCache[id] { return hit }
        var result: (name: String, path: String)?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            result = (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url.path)
        }
        appCache[id] = result
        return result
    }

    private static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty } && !s.contains(" ")
            && ["com", "org", "net", "io", "app", "dev", "co", "us", "de", "it", "jp"].contains(parts[0].lowercased())
    }

    private static func resolve(_ item: FileItem) -> Info {
        // Walk up the path looking for a component that names an app.
        for component in item.url.pathComponents.reversed().prefix(6) {
            var id = component
            if id.hasSuffix(".savedState") { id = String(id.dropLast(".savedState".count)) }
            if id.hasSuffix(".plist") { id = String(id.dropLast(".plist".count)) }
            if looksLikeBundleID(id), let app = app(forBundleID: id) {
                let title = component == item.url.lastPathComponent ? app.name : "\(app.name) — \(item.name)"
                return Info(title: title, iconPath: app.path, owner: app.name)
            }
            if component.hasSuffix(".app") {
                let name = String(component.dropLast(4))
                return Info(title: item.name == component ? name : "\(name) — \(item.name)",
                            iconPath: appPath(in: item.url, component: component) ?? item.url.path,
                            owner: name)
            }
        }
        return Info(title: FileManager.default.displayName(atPath: item.url.path), iconPath: item.url.path, owner: nil)
    }

    private static func appPath(in url: URL, component: String) -> String? {
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: component) else { return nil }
        return NSString.path(withComponents: Array(comps[...idx]))
    }

    static func shortPath(_ url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Safety presentation

extension ScanCategory.CleanupSafety {
    var tint: Color {
        switch self {
        case .regenerates: KMR.green
        case .safeToRemove: Color(nsColor: .systemBlue)
        case .reviewFirst: KMR.orange
        }
    }

    var shortLabel: String {
        switch self {
        case .regenerates: KMR.t("Si ricrea da solo", "Rebuilds itself")
        case .safeToRemove: KMR.t("Sicuro", "Safe")
        case .reviewFirst: KMR.t("Controlla prima", "Review first")
        }
    }
}

struct SafetyBadge: View {
    let safety: ScanCategory.CleanupSafety

    var body: some View {
        Label(safety.shortLabel, systemImage: safety.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(safety.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(safety.tint.opacity(0.14), in: Capsule())
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

// MARK: - Review list

struct ResultsReview: View {
    let results: [ScanResult]
    @Binding var selectedItems: Set<URL>
    var permanent = false

    @State private var expanded: Set<ScanCategory> = []
    /// Items the user chose to always exclude during this review.
    @State private var excluded: Set<URL> = []
    @State private var exclusionNote: String?
    @State private var detailed = false
    /// Largest items per category, computed off the render path.
    @State private var topItems: [ScanCategory: [FileItem]] = [:]
    /// Selected count and bytes per category, computed off the main thread.
    @State private var stats: [ScanCategory: (count: Int, bytes: UInt64)] = [:]
    /// Debug aid (KMR_DRYRUN_PREVIEW=1, screenshots only): shows the dry-run
    /// sheet for these results. Its confirm button only dismisses.
    @State private var previewPlan: CleanSafety.Plan?
    @State private var showPreview = false
    /// Filter field: name or path, applied in place (both views).
    @State private var query = ""
    @State private var filtered: [ScanResult] = []
    /// The query `filtered` was computed for (nil: none yet).
    @State private var filteredQuery: String?

    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// What the cards and the table show: everything, or the filter matches
    /// (the previous matches stay up while the next filter runs).
    private var displayed: [ScanResult] { isFiltering && filteredQuery != nil ? filtered : results }

    private var selectionKey: String {
        "\(selectedItems.count)#\(query)#" + displayed.map { "\($0.category.rawValue):\($0.items.count)" }.joined(separator: ",")
    }

    /// Rows per expanded card. The grouped Form lays out every row it holds
    /// on each update (60 per card stalled System Junk for >1 s with all
    /// cards open); "All files" shows the rest in an AppKit table.
    nonisolated private static let previewLimit = 15

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: permanent ? "exclamationmark.triangle.fill" : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(permanent ? KMR.orange : KMR.green)
            Text(permanent
                 ? KMR.t("Questi elementi verranno eliminati definitivamente.", "These items will be deleted permanently.")
                 : KMR.t("Tutto ciò che pulisci va nel Cestino: puoi ripristinarlo da Cronologia pulizia.",
                         "Everything you clean goes to the Trash: you can restore it from Cleanup History."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            NativeSearchField(text: $query, prompt: KMR.t("Filtra per nome o percorso", "Filter by name or path"))
                .frame(minWidth: 120, idealWidth: 200, maxWidth: 220)
                .help(KMR.t("Mostra solo gli elementi che contengono queste parole (⌘F)", "Show only the items containing these words (⌘F)"))
            Picker("", selection: $detailed) {
                Text(KMR.t("Riepilogo", "Summary")).tag(false)
                Text(KMR.t("Tutti i file", "All files")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if detailed {
                banner
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            if let note = exclusionNote {
                Label(note, systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isFiltering && filteredQuery == query && filtered.isEmpty {
                VStack {
                    if !detailed { banner.padding(.horizontal, 24) }
                    ContentUnavailableView.search(text: query)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if detailed {
                FileListView(results: displayed, selectedItems: $selectedItems)
                    .id(isFiltering ? "filtered" : "all")
                    .transition(.opacity)
            } else {
                Form {
                    // The banner is the list's header so it lines up with the cards.
                    Section {} header: { banner.textCase(nil) }
                    ForEach(displayed, id: \.category) { result in
                        categorySection(result)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)   // cards sit on the page, no second box
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: detailed)
        // "All files" is a drill-down of the summary: Back / Esc return to it.
        .pageNavigation(id: "results.detailed", canGoBack: detailed, back: { detailed = false })
        .task(id: "\(query)#" + results.map { "\($0.category.rawValue):\($0.items.count)" }.joined()) {
            guard isFiltering else { filtered = []; filteredQuery = nil; return }
            try? await Task.sleep(for: .milliseconds(120))   // debounce typing
            guard !Task.isCancelled else { return }
            let input = results, q = query
            let out = await Task.detached(priority: .userInitiated) { input.filtered(matching: q) }.value
            guard !Task.isCancelled else { return }
            filtered = out
            filteredQuery = q
        }
        // Drawn inline rather than as a sheet so the window snapshot hook,
        // which captures only the main window, can see it.
        .overlay {
            if showPreview {
                DryRunSummarySheet(plan: previewPlan, onConfirm: { showPreview = false }, onCancel: { showPreview = false })
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(radius: 20)
            }
        }
        .task {
            // Debug aid for screenshots: KMR_REVIEW_FILTER=<text> fills the filter.
            if let f = ProcessInfo.processInfo.environment["KMR_REVIEW_FILTER"] { query = f }
            if ProcessInfo.processInfo.environment["KMR_REVIEW_DETAILED"] == "1" { detailed = true }
            guard ProcessInfo.processInfo.environment["KMR_DRYRUN_PREVIEW"] == "1", !permanent else { return }
            showPreview = true
            previewPlan = await CleanActions.plan(results: results, selectedItems: selectedItems)
        }
        .task(id: selectionKey) {
            let input = displayed
            let selection = selectedItems
            let computed = await Task.detached(priority: .userInitiated) {
                var out: [ScanCategory: (count: Int, bytes: UInt64)] = [:]
                for r in input {
                    var c = 0, b: UInt64 = 0
                    for item in r.items where selection.contains(item.url) { c += 1; b &+= item.size }
                    out[r.category] = (c, b)
                }
                return out
            }.value
            stats = computed
        }
        .task(id: "\(isFiltering ? filtered.count : -1)#" + displayed.map { "\($0.category.rawValue):\($0.items.count)" }.joined()) {
            let input = displayed
            let computed = await Task.detached(priority: .userInitiated) {
                var out: [ScanCategory: [FileItem]] = [:]
                for r in input {
                    out[r.category] = Array(r.items.sorted { $0.size > $1.size }.prefix(Self.previewLimit))
                }
                return out
            }.value
            topItems = computed
            // Perf repro (KMR_REVIEW_EXPAND=all): open every card.
            if ProcessInfo.processInfo.environment["KMR_REVIEW_EXPAND"] == "all" { expanded = Set(input.map(\.category)) }
        }
    }

    private func exclude(_ item: FileItem) {
        let path = item.url.path(percentEncoded: false)
        if FolderExclusionPreferences.add(path) {
            withAnimation(.smooth) {
                excluded.insert(item.url)
                selectedItems.remove(item.url)
                exclusionNote = KMR.t("\(item.name) non verrà più proposto. Puoi riattivarlo in Impostazioni › Cartelle escluse.",
                                      "\(item.name) won't be suggested again. You can re-enable it in Settings › Excluded folders.")
            }
        } else {
            exclusionNote = KMR.t("Questa posizione non può essere esclusa: solo cartelle nella tua cartella Inizio o in /Volumes.",
                                  "This location can't be excluded: only folders in your home folder or /Volumes.")
        }
    }

    // MARK: Category card

    private func selectionState(_ result: ScanResult) -> Bool? {
        guard let n = stats[result.category]?.count else {
            return result.autoSelect ? true : false
        }
        if n == 0 { return false }
        if n == result.items.count { return true }
        return nil
    }

    private func setAll(_ result: ScanResult, _ on: Bool) {
        let urls = result.items.map(\.url)
        withAnimation(.smooth(duration: 0.2)) {
            if on { selectedItems.formUnion(urls) } else { selectedItems.subtract(urls) }
        }
    }

    private func selectedSize(_ result: ScanResult) -> UInt64 {
        stats[result.category]?.bytes ?? 0
    }

    private func categorySection(_ result: ScanResult) -> some View {
        let category = result.category
        let safety = category.cleanupSafety
        let isOpen = expanded.contains(category) || isFiltering
        let state = selectionState(result)
        return Section {
            HStack(alignment: .top, spacing: 12) {
                TriStateCheckbox(state: state) { setAll(result, state != true) }
                    .padding(.top, 3)
                IconTile(symbol: category.systemImage, color: safety.tint, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(category.displayName).font(.headline)
                        SafetyBadge(safety: safety)
                    }
                    Text(category.safetyRationale)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(FileSizeFormatter.format(result.totalSize))
                        .font(.headline)
                        .monospacedDigit()
                    Text(KMR.t("\(result.items.count.formatted()) elementi", "\(result.items.count.formatted()) items"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    if isOpen { expanded.remove(category) } else { expanded.insert(category) }
                }
            } label: {
                HStack {
                    Text(isOpen ? KMR.t("Nascondi elementi", "Hide items")
                                : KMR.t("Mostra cosa contiene", "Show what's inside"))
                    Spacer()
                    if state == nil {
                        Text(KMR.t("\(FileSizeFormatter.format(selectedSize(result))) selezionati",
                                   "\(FileSizeFormatter.format(selectedSize(result))) selected"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            if isOpen {
                ForEach((topItems[category] ?? []).filter { !excluded.contains($0.url) }) { item in
                    ItemRow(item: item, isOn: selectedItems.contains(item.url), onExclude: { exclude(item) }) {
                        withAnimation(.smooth(duration: 0.15)) {
                            if selectedItems.contains(item.url) { selectedItems.remove(item.url) } else { selectedItems.insert(item.url) }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if result.items.count > Self.previewLimit {
                    Text(KMR.t("Mostrati i \(Self.previewLimit) più grandi su \(result.items.count.formatted()). Usa \"Tutti i file\" per vederli tutti.",
                               "Showing the \(Self.previewLimit) largest of \(result.items.count.formatted()). Use \"All files\" to see them all."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Rows

private struct ItemRow: View {
    let item: FileItem
    let isOn: Bool
    var onExclude: () -> Void = {}
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let info = FriendlyName.info(for: item)
        HStack(spacing: 10) {
            Toggle(info.title, isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            FileIcon(path: info.iconPath, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FriendlyName.shortPath(item.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if hovering {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(KMR.t("Mostra nel Finder", "Show in Finder"))
                .transition(.opacity)
            }
            Text(FileSizeFormatter.format(item.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(item.url.path)
        .contextMenu {
            FileContextMenuItems(url: item.url)
            Divider()
            Button(isOn ? KMR.t("Non pulire", "Don't Clean") : KMR.t("Seleziona per la pulizia", "Select for Cleanup"), action: toggle)
            Button(KMR.t("Escludi sempre questa posizione", "Always exclude this location"), action: onExclude)
        }
    }
}

/// Checkbox with a "mixed" state, drawn like the system checkbox.
struct TriStateCheckbox: View {
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(state == false ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(KMR.t("Seleziona tutto", "Select all"))
        .accessibilityValue(state == true ? "on" : state == nil ? "mixed" : "off")
    }
}
