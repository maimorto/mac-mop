import SwiftUI
import AppKit
import MacCleanerKit

struct UninstallerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @Environment(\.moduleIsSelected) private var moduleIsSelected
    @State private var apps: [AppInfo] = []
    /// Selected apps: one shows its details, several show a combined review.
    /// ⌘-click / ⇧-click in the list, or the checkboxes in selection mode.
    @State private var selection: Set<AppInfo.ID> = []
    @State private var leftovers: [AppInfo.ID: [AssociatedFile]] = [:]
    @State private var loadingFiles: Set<AppInfo.ID> = []
    @State private var selectedFiles: Set<URL> = []
    @State private var isLoading = true
    @State private var isUninstalling = false
    @State private var isResetting = false
    @State private var appsPendingUninstall: [AppInfo] = []
    @State private var appPendingReset: AppInfo?
    @State private var uninstallError: String?
    @State private var resetError: String?
    @State private var searchText = ""
    /// Sort + filters, remembered between launches.
    @AppStorage("uninstaller.listOptions") private var listOptions = AppListOptions()
    /// Developer, source, dates… per bundle path, read in the background.
    @State private var facts: [String: AppListFacts] = [:]
    /// `apps` after search/filters/sort; recomputed only when an input changes.
    @State private var visibleApps: [AppInfo] = []
    @State private var selectionMode = false
    @State private var detailTab: DetailTab = .files
    @State private var isExporting = false

    enum DetailTab: Hashable { case files, trust }

    private let discovery = AppDiscovery()
    private let pathFinder = AppPathFinder()
    private let safetyGuard = SafetyGuard()

    private var selectedApps: [AppInfo] { apps.filter { selection.contains($0.id) } }
    private var selectedApp: AppInfo? { selectedApps.count == 1 ? selectedApps.first : nil }

    private func files(for app: AppInfo) -> [FileItem] { (leftovers[app.id] ?? []).map(\.item) }

    /// HSplitView wraps NSSplitView, which ignores SwiftUI's right-to-left
    /// layout: in Farsi it squeezed the details pane into a thin column. A
    /// plain HStack mirrors correctly, so right-to-left languages use that.
    @ViewBuilder
    private var splitPanes: some View {
        if layoutDirection == .rightToLeft {
            HStack(spacing: 0) {
                appList
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity)
            }
        } else {
            HSplitView {
                appList
                    .frame(minWidth: 240)
                detailPane
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let app = selectedApp {
            appDetailView(app)
                .frame(minWidth: 280)
        } else if selectedApps.count > 1 {
            multiDetailView(selectedApps)
                .frame(minWidth: 280)
        } else {
            VStack {
                Spacer()
                Text(L10n.tr("选择一个应用以查看相关文件", "Select an app to see its files", "Выберите приложение, чтобы увидеть связанные с ним файлы"))
                    .foregroundStyle(.tertiary)
                    .font(.body)
                Text(KMR.t("Tieni premuto ⌘ per selezionarne più di una.", "Hold ⌘ to select more than one."))
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppsPageHeader(
                title: L10n.tr("卸载器", "Uninstaller", "Удаление приложений"),
                subtitle: L10n.tr("彻底移除应用及其残留文件", "Completely remove apps and their leftover files", "Полностью удаляйте приложения и оставшиеся после них файлы")
            ) {
                Button {
                    isExporting = true
                    Task {
                        await AppListExporter.export(apps: apps)
                        isExporting = false
                    }
                } label: {
                    Label(KMR.t("Esporta elenco app…", "Export app list…"), systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .disabled(apps.isEmpty || isExporting)
                .help(KMR.t("Salva un elenco delle app installate (e un Brewfile se usi Homebrew) per reinstallarle su un altro Mac.",
                            "Save a list of installed apps (and a Brewfile if you use Homebrew) to reinstall them on another Mac."))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if isLoading {
                ScanProgressRing(progress: 0,
                                 phase: L10n.tr("正在发现已安装应用...", "Discovering installed apps...", "Поиск установленных приложений..."),
                                 theme: .applications, indeterminate: true)
                    .environment(\.currentModule, .uninstaller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    AppListControls(options: $listOptions, search: $searchText) {
                        Toggle(isOn: $selectionMode.animation(.smooth)) {
                            Label(KMR.t("Selezione multipla", "Select several"), systemImage: "checklist")
                        }
                        .toggleStyle(.button)
                        .help(KMR.t("Mostra le caselle per disinstallare più app insieme.",
                                    "Show checkboxes to uninstall several apps at once."))
                    }
                    AppListFilterSummary(shown: visibleApps.count, total: apps.count,
                                         hasFilters: listOptions.activeFilterCount > 0 || !searchText.isEmpty) {
                        listOptions = listOptions.clearingFilters
                        searchText = ""
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

                splitPanes
                .kmrGroupedBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .task { await loadApps() }
        .onChange(of: listOptions) { _, _ in refreshVisible() }
        .onChange(of: searchText) { _, _ in refreshVisible() }
        .onChange(of: appState.pendingUninstallerAppPath) { _, path in
            guard let path else { return }
            selectPendingApp(path: path)
        }
        .selectedFilesForMenu(selectedApps.map(\.path), isVisible: moduleIsSelected)
        .onChange(of: selection) { _, ids in
            for app in apps where ids.contains(app.id) && leftovers[app.id] == nil && !loadingFiles.contains(app.id) {
                loadAssociatedFiles(for: app)
            }
        }
        // Attached to the top-level body (not the conditionally-rendered
        // detail pane) so the confirmation can't be torn down mid-present
        // when the selection changes. `appsPendingUninstall` is the anchor.
        .alert(uninstallAlertTitle,
               isPresented: Binding(get: { !appsPendingUninstall.isEmpty },
                                    set: { if !$0 { appsPendingUninstall = [] } })) {
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) { appsPendingUninstall = [] }
            Button(L10n.tr("移到废纸篓", "Move to Trash", "Переместить в Корзину"), role: .destructive) {
                let targets = appsPendingUninstall; appsPendingUninstall = []; uninstall(targets)
            }
        } message: {
            if appsPendingUninstall.count == 1, let app = appsPendingUninstall.first {
                Text(L10n.tr("\(app.name) 及其关联文件将被移到废纸篓。如有需要，你可以从废纸篓恢复。", "\(app.name) and its associated files will be moved to the Trash. You can restore them from the Trash if needed.", "Приложение \(app.name) и связанные с ним файлы будут перемещены в Корзину. При необходимости их можно восстановить."))
            } else {
                let names = appsPendingUninstall.map(\.name).joined(separator: ", ")
                Text(KMR.t("\(names) e i file residui selezionati (\(FileSizeFormatter.format(combinedBytes(appsPendingUninstall)))) andranno nel Cestino. Puoi ripristinarli da Cronologia pulizia.",
                           "\(names) and the selected leftover files (\(FileSizeFormatter.format(combinedBytes(appsPendingUninstall)))) will go to the Trash. You can restore them from Cleanup History."))
            }
        }
        .alert(L10n.tr("卸载", "Uninstall"),
               isPresented: Binding(get: { uninstallError != nil },
                                    set: { if !$0 { uninstallError = nil } })) {
            Button(L10n.tr("好", "OK"), role: .cancel) { uninstallError = nil }
        } message: {
            Text(uninstallError ?? "")
        }
        .alert(
            L10n.tr(
                "将 \(appPendingReset?.name ?? "此应用") 恢复为默认设置？",
                "Reset \(appPendingReset?.name ?? "this app") to defaults?",
                "Сбросить \(appPendingReset?.name ?? "это приложение") к настройкам по умолчанию?"
            ),
            isPresented: Binding(get: { appPendingReset != nil },
                                 set: { if !$0 { appPendingReset = nil } }),
            presenting: appPendingReset
        ) { app in
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) { appPendingReset = nil }
            Button(L10n.tr("恢复默认", "Reset to Defaults", "Сбросить настройки"), role: .destructive) {
                let target = app; appPendingReset = nil; resetToDefaults(target)
            }
        } message: { app in
            let plan = AppReset.plan(app: app, associatedFiles: files(for: app), selectedFiles: selectedFiles)
            let count = plan?.items.count ?? 0
            let bytes = plan?.items.reduce(0 as UInt64) { $0 + $1.size } ?? 0
            Text(L10n.tr(
                "将把 \(app.name) 的缓存、偏好设置和保存的状态（\(count) 项，\(FileSizeFormatter.format(bytes))）移到废纸篓。应用本身会保留。若应用正在运行，请先退出，否则它可能会重新写入这些文件。",
                "Caches, preferences, and saved state for \(app.name) (\(count) items, \(FileSizeFormatter.format(bytes))) will be moved to the Trash. The app stays installed. Quit the app first if it is running, or it may rewrite these files.",
                "Кэш, настройки и сохранённое состояние \(app.name) (\(count) \(L10n.russianPlural(count, one: "объект", few: "объекта", many: "объектов")), \(FileSizeFormatter.format(bytes))) будут перемещены в Корзину. Само приложение останется. Если оно запущено, сначала закройте его — иначе файлы могут быть записаны заново."
            ))
        }
        .alert(L10n.tr("恢复默认", "Reset to Defaults", "Сброс настроек"),
               isPresented: Binding(get: { resetError != nil },
                                    set: { if !$0 { resetError = nil } })) {
            Button(L10n.tr("好", "OK"), role: .cancel) { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
    }

    private var uninstallAlertTitle: String {
        if appsPendingUninstall.count == 1, let app = appsPendingUninstall.first {
            return L10n.tr("将 \(app.name) 移到废纸篓？", "Move \(app.name) to the Trash?", "Переместить \(app.name) в Корзину?")
        }
        return KMR.t("Disinstallare le app selezionate? App: \(appsPendingUninstall.count)",
                     "Uninstall the selected apps? Apps: \(appsPendingUninstall.count)")
    }

    private func combinedBytes(_ targets: [AppInfo]) -> UInt64 {
        targets.reduce(0 as UInt64) { total, app in
            total + app.size + (leftovers[app.id] ?? []).filter { selectedFiles.contains($0.item.url) }
                .reduce(0 as UInt64) { $0 + $1.item.size }
        }
    }

    /// Runs the (cheap, precomputed-key) query when apps, facts, search or
    /// options change: never from `body`.
    private func refreshVisible() {
        let byPath = Dictionary(apps.map { ($0.path.path(percentEncoded: false), $0) }, uniquingKeysWith: { a, _ in a })
        let entries = apps.map { AppListEntry(app: $0, facts: facts[$0.path.path(percentEncoded: false)]) }
        visibleApps = AppListQuery.apply(entries, search: searchText, options: listOptions).compactMap { byPath[$0.id] }
    }

    private func loadFacts() async {
        let paths = apps.map { $0.path.path(percentEncoded: false) }
        let loaded = await AppListFactsStore.shared.facts(for: paths)
        facts.merge(loaded) { _, new in new }
        refreshVisible()
    }

    /// Size plus the value the list is sorted by (last opened by default).
    private func caption(for app: AppInfo) -> String {
        let info = facts[app.path.path(percentEncoded: false)]
        let detail: String
        switch listOptions.sort {
        case .installed: detail = AppListFacts.installedText(info?.installed)
        case .developer: detail = info?.developer ?? info?.source.label ?? AppListFacts.lastOpenedText(info?.lastUsed)
        default: detail = info == nil ? "" : AppListFacts.lastOpenedText(info?.lastUsed)
        }
        return detail.isEmpty ? app.formattedSize : "\(app.formattedSize) · \(detail)"
    }

    private func isIdle(_ app: AppInfo) -> Bool {
        guard let last = facts[app.path.path(percentEncoded: false)]?.lastUsed else { return false }
        return last < Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? last
    }

    private func isSelectedBinding(_ app: AppInfo) -> Binding<Bool> {
        Binding(get: { selection.contains(app.id) },
                set: { on in if on { selection.insert(app.id) } else { selection.remove(app.id) } })
    }

    /// Native selection: the whole row is the hit target and the system draws
    /// the highlight, exactly like Finder / Music sidebars. ⌘-click and
    /// ⇧-click extend it.
    private var appList: some View {
        VStack(spacing: 0) {
            if selectionMode {
                HStack {
                    Button(KMR.t("Seleziona tutte", "Select all")) {
                        selection = Set(visibleApps.filter { !safetyGuard.isProtectedApp($0.bundleIdentifier) }.map(\.id))
                    }
                    Button(KMR.t("Nessuna", "None")) { selection = [] }
                    Spacer()
                    Text(KMR.t("Selezionate: \(selection.count)", "Selected: \(selection.count)"))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            List(visibleApps, selection: $selection) { app in
                HStack(spacing: 10) {
                    if selectionMode {
                        Toggle(app.name, isOn: isSelectedBinding(app))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(safetyGuard.isProtectedApp(app.bundleIdentifier))
                    }
                    Image(nsImage: AppIconCache.icon(forPath: app.path.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Text(caption(for: app))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)

                    if facts[app.path.path(percentEncoded: false)]?.isIntelOnly == true {
                        Image(systemName: "cpu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(KMR.t("Solo per Intel: gira con Rosetta", "Intel only: runs under Rosetta"))
                            .accessibilityLabel(KMR.t("Solo Intel", "Intel only"))
                    }
                    if isIdle(app) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(KMR.t("Non la apri da più di 6 mesi", "Not opened in over 6 months"))
                            .accessibilityLabel(KMR.t("Inutilizzata", "Unused"))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(KMR.t("Apri", "Open")) { NSWorkspace.shared.open(app.path) }
                    FileContextMenuItems(url: app.path)
                }
                .tag(app.id)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Single app

    private func appDetailView(_ app: AppInfo) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: AppIconCache.icon(forPath: app.path.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let version = app.version {
                        Text("v\(version)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)

                if isUninstalling || isResetting {
                    // In-progress feedback: the button is gone (can't be
                    // re-tapped) and a spinner shows the work is happening.
                    ProgressView()
                        .controlSize(.small)
                    Text(isResetting
                         ? L10n.tr("正在恢复默认…", "Resetting…", "Сброс…")
                         : L10n.tr("正在卸载…", "Uninstalling…", "Удаление…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if safetyGuard.isProtectedApp(app.bundleIdentifier) {
                            Label(KMR.t("Protetta", "Protected"), systemImage: "lock.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .help(L10n.tr("受保护的系统应用——无法移除", "Protected system app — can't be removed", "Защищённое системное приложение — удалить нельзя"))
                        } else {
                            Button(L10n.tr("卸载", "Uninstall", "Удалить")) { appsPendingUninstall = [app] }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                        }

                        Button(L10n.tr("恢复默认", "Reset to Defaults", "Сбросить настройки")) {
                            appPendingReset = app
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(AppReset.plan(app: app, associatedFiles: files(for: app), selectedFiles: selectedFiles) == nil)
                        .help(L10n.tr(
                            "清除缓存、偏好设置和保存的状态，保留应用本身。",
                            "Clears caches, preferences, and saved state. The app stays installed.",
                            "Очищает кэш, настройки и сохранённое состояние. Само приложение остаётся."
                        ))
                    }
                    .fixedSize()
                }
            }
            .padding([.horizontal, .top])

            Picker("", selection: $detailTab) {
                Text(KMR.t("File residui", "Leftover files")).tag(DetailTab.files)
                Text(KMR.t("Affidabilità", "Trust")).tag(DetailTab.trust)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch detailTab {
            case .files: leftoversSection(app)
            case .trust: AppTrustPanel(app: app)
            }
        }
    }

    @ViewBuilder
    private func leftoversSection(_ app: AppInfo) -> some View {
        let found = leftovers[app.id] ?? []
        if loadingFiles.contains(app.id) || leftovers[app.id] == nil {
            Spacer()
            ProgressView(L10n.tr("正在查找关联文件...", "Finding associated files...", "Поиск связанных файлов..."))
                .tint(.secondary)
                .font(.callout)
            Spacer()
        } else if !found.isEmpty {
            let totalSize = found.reduce(0 as UInt64) { $0 + $1.item.size }
            Text(L10n.tr("\(found.count) 个关联文件（\(FileSizeFormatter.format(totalSize))）", "\(found.count) associated files (\(FileSizeFormatter.format(totalSize)))", "\(found.count) \(L10n.russianPlural(found.count, one: "связанный файл", few: "связанных файла", many: "связанных файлов")) (\(FileSizeFormatter.format(totalSize)))"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            List(found) { file in leftoverRow(file) }
                .listStyle(.inset)

            if found.contains(where: { !$0.match.confidence.selectedByDefault }) {
                lowConfidenceNote.padding(.horizontal).padding(.bottom, 10)
            }
        } else {
            Spacer()
            Text(L10n.tr("未找到关联文件", "No associated files found", "Связанные файлы не найдены"))
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
    }

    private var lowConfidenceNote: some View {
        Label(KMR.t("I file con corrispondenza incerta non sono selezionati: includili solo se sei sicuro che appartengano a questa app.",
                    "Files with an uncertain match are not selected: include them only if you are sure they belong to this app."),
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leftoverRow(_ file: AssociatedFile) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(
                get: { selectedFiles.contains(file.item.url) },
                set: { on in
                    if on { selectedFiles.insert(file.item.url) }
                    else { selectedFiles.remove(file.item.url) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: file.item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(file.item.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ConfidencePill(confidence: file.match.confidence)
                    Text(file.match.reason.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
            Text(file.item.formattedSize)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .help(file.match.reason.explanation)
        .contextMenu {
            FileContextMenuItems(url: file.item.url)
        }
    }

    // MARK: - Several apps

    private func multiDetailView(_ targets: [AppInfo]) -> some View {
        let removable = targets.filter { !safetyGuard.isProtectedApp($0.bundleIdentifier) }
        let protected = targets.count - removable.count
        let loading = targets.contains { leftovers[$0.id] == nil }
        return VStack(spacing: 10) {
            HStack(alignment: .center) {
                IconTile(symbol: "square.stack.3d.up.fill", color: KMR.red, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KMR.t("App selezionate: \(targets.count)", "Selected apps: \(targets.count)"))
                        .font(.title3.weight(.semibold))
                    Text(KMR.t("Totale da spostare nel Cestino: \(FileSizeFormatter.format(combinedBytes(removable)))",
                               "Total to move to the Trash: \(FileSizeFormatter.format(combinedBytes(removable)))"))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if isUninstalling {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("正在卸载…", "Uninstalling…", "Удаление…")).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(KMR.t("Disinstalla tutte", "Uninstall all")) { appsPendingUninstall = removable }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                        .disabled(removable.isEmpty || loading)
                }
            }
            .padding([.horizontal, .top])

            if protected > 0 {
                Label(KMR.t("App di sistema protette escluse: \(protected)", "Protected system apps left out: \(protected)"),
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            List {
                ForEach(removable) { app in
                    Section {
                        if let found = leftovers[app.id] {
                            if found.isEmpty {
                                Text(L10n.tr("未找到关联文件", "No associated files found", "Связанные файлы не найдены"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(found) { file in leftoverRow(file) }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(nsImage: AppIconCache.icon(forPath: app.path.path(percentEncoded: false)))
                                .resizable().frame(width: 20, height: 20)
                            Text(app.name).font(.headline)
                            Spacer()
                            Text(app.formattedSize).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)

            if targets.contains(where: { (leftovers[$0.id] ?? []).contains { !$0.match.confidence.selectedByDefault } }) {
                lowConfidenceNote.padding(.horizontal).padding(.bottom, 10)
            }
        }
    }

    // MARK: - Actions

    private func resetToDefaults(_ app: AppInfo) {
        guard !isResetting, !isUninstalling else { return }
        guard let plan = AppReset.plan(
            app: app,
            associatedFiles: files(for: app),
            selectedFiles: selectedFiles
        ) else { return }

        isResetting = true
        Task {
            let result = await CleanActions.executeUserClean(
                items: plan.items,
                selectedItems: plan.selection,
                engine: appState.cleaningEngine
            )
            if !result.errors.isEmpty {
                resetError = L10n.tr(
                    "恢复 \(app.name) 的默认设置时部分项目失败（\(result.errors.count) 个）。请确认应用已退出后重试。",
                    "Some items couldn't be reset for \(app.name) (\(result.errors.count)). Quit the app if it is running and try again.",
                    "Не удалось сбросить часть данных \(app.name) (\(result.errors.count)). Закройте приложение, если оно запущено, и повторите попытку."
                )
            }
            loadAssociatedFiles(for: app)
            isResetting = false
        }
    }

    private func loadApps() async {
        apps = await discovery.discoverApps()
        // Fresh AppInfo values carry new ids: drop per-app state keyed by the old ones.
        leftovers = [:]
        selectedFiles = []
        selection = []
        refreshVisible()
        isLoading = false
        Task { await loadFacts() }
        if let path = appState.pendingUninstallerAppPath {
            selectPendingApp(path: path)
        } else if let names = ProcessInfo.processInfo.environment["KMR_SELECT_APPS"] {
            // Debug hook for screenshots: KMR_SELECT_APPS="Firefox,Discord".
            let wanted = Set(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            selection = Set(apps.filter { wanted.contains($0.name.lowercased()) }.map(\.id))
            if ProcessInfo.processInfo.environment["KMR_UNINSTALL_TAB"] == "trust" { detailTab = .trust }
        }
    }

    private func selectPendingApp(path: String) {
        // Consume the request either way, so a stale path (app removed since
        // Unused Apps listed it) can't select something on a later visit.
        appState.pendingUninstallerAppPath = nil
        let wanted = URL(filePath: path).standardizedFileURL.path
        if let match = apps.first(where: { $0.path.standardizedFileURL.path == wanted }) {
            // Make sure the row is visible: drop search/filters hiding it.
            if !visibleApps.contains(where: { $0.id == match.id }) {
                searchText = ""
                listOptions = listOptions.clearingFilters
                refreshVisible()
            }
            selection = [match.id]
            return
        }
        // An app outside /Applications (dropped, or picked from Finder's
        // Services menu): add it to the list so it can be uninstalled.
        guard wanted.hasSuffix(".app"), FileManager.default.fileExists(atPath: wanted) else { return }
        Task {
            guard let info = await discovery.appInfo(at: URL(filePath: wanted)) else { return }
            apps.append(info)
            searchText = ""
            listOptions = listOptions.clearingFilters
            refreshVisible()
            selection = [info.id]
            await loadFacts()
        }
    }

    private func loadAssociatedFiles(for app: AppInfo) {
        loadingFiles.insert(app.id)
        let finder = pathFinder
        Task {
            let found = await Task.detached(priority: .userInitiated) { finder.findLeftovers(for: app) }.value
            if let old = leftovers[app.id] { selectedFiles.subtract(old.map(\.item.url)) }
            leftovers[app.id] = found
            selectedFiles.formUnion(found.filter(\.match.confidence.selectedByDefault).map(\.item.url))
            loadingFiles.remove(app.id)
        }
    }

    private func uninstall(_ targets: [AppInfo]) {
        guard !isUninstalling, !targets.isEmpty else { return }   // ignore double-taps

        // Build one validated plan for all apps. Refuses protected system apps
        // (bundle-id check that SafetyGuard.validatePath can't do) and routes
        // each bundle through the same validated, logged, trash-first engine as
        // its leftovers, so the whole batch lands in Cleanup History.
        var items: [FileItem] = []
        var selected: Set<URL> = []
        var refused: [String] = []
        for app in targets {
            guard let plan = AppUninstaller.plan(
                app: app,
                associatedFiles: files(for: app),
                selectedFiles: selectedFiles,
                safetyGuard: safetyGuard
            ) else { refused.append(app.name); continue }
            items += plan.items
            selected.formUnion(plan.selection)
        }
        guard !items.isEmpty else {
            if let name = refused.first {
                uninstallError = L10n.tr(
                    "\(name) 是受保护的系统应用，无法移除。",
                    "\(name) is a protected system app and can't be removed.")
            }
            return
        }

        isUninstalling = true
        Task {
            let result = await CleanActions.executeUserClean(
                items: items,
                selectedItems: selected,
                engine: appState.cleaningEngine
            )
            // Surface failures instead of silently swallowing them: if the
            // bundle or a leftover couldn't be removed, tell the user.
            if !result.errors.isEmpty {
                if targets.count == 1, let app = targets.first {
                    uninstallError = L10n.tr(
                        "移除 \(app.name) 时部分项目失败（\(result.errors.count) 个）。请查看该应用是否仍在，如仍在可重试。",
                        "Some items couldn't be removed while uninstalling \(app.name) (\(result.errors.count)). Check whether the app is still there and try again.")
                } else {
                    uninstallError = KMR.t(
                        "Alcuni elementi non sono stati rimossi (\(result.errors.count)). Controlla se le app sono ancora presenti e riprova.",
                        "Some items couldn't be removed (\(result.errors.count)). Check whether the apps are still there and try again.")
                }
            }
            await loadApps()
            isUninstalling = false
        }
    }
}

/// "Certain / Likely / Uncertain" tag next to each leftover's reason.
struct ConfidencePill: View {
    let confidence: MatchConfidence

    private var tint: Color {
        switch confidence {
        case .high: KMR.green
        case .medium: .blue
        case .low: KMR.orange
        }
    }

    var body: some View {
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}
