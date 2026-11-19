import AppKit
import SwiftUI
import MacCleanerKit

struct UnusedAppsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @AppStorage("unusedApps.horizon") private var horizon: UnusedAppHorizon = .sixMonths
    /// Sort + filters, remembered between launches (biggest first by default).
    @AppStorage("unusedApps.listOptions") private var listOptions = AppListOptions(sort: .size)
    @State private var searchText = ""
    @State private var records: [UnusedAppRecord] = []
    @State private var facts: [String: AppListFacts] = [:]
    /// Idle apps for the period, after search/filters/sort. Recomputed when
    /// an input changes, never in `body`.
    @State private var visible: [UnusedAppRecord] = []
    @State private var idleCount = 0
    @State private var isLoading = true
    @State private var loadGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            AppsPageHeader(
                title: L10n.tr("未使用的应用", "Unused Apps", "Неиспользуемые приложения"),
                subtitle: L10n.tr(
                    "按上次打开时间列出应用，并按占用空间排序。一键转到卸载器。",
                    "Apps you have not opened recently, sorted by how much space they use. One click hands them to the Uninstaller.",
                    "Приложения, которые давно не открывали, отсортированные по занятому месту. Одним нажатием можно перейти к удалению."
                )
            ) {
                HStack(spacing: 8) {
                    // The label is a separate one-line Text: inside the
                    // segmented picker it got squeezed into "Perio-do".
                    Text(L10n.tr("时间", "Horizon", "Период"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Picker(L10n.tr("时间", "Horizon", "Период"), selection: $horizon) {
                        ForEach(UnusedAppHorizon.allCases) { h in
                            Text(h.label).tag(h)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(L10n.tr("刷新", "Refresh", "Обновить"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if isLoading {
                ScanProgressRing(
                    progress: 0,
                    phase: L10n.tr("正在查找未使用的应用…", "Looking for unused apps…", "Поиск неиспользуемых приложений…"),
                    detail: KMR.t("Leggo da Spotlight quando hai aperto ogni app l'ultima volta e quanto spazio occupa.",
                                  "Reading from Spotlight when you last opened each app and how much space it takes."),
                    theme: .applications,
                    indeterminate: true
                )
                .environment(\.currentModule, .unusedApps)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if UnusedApps.usageDataUnavailable(in: records) {
                ContentUnavailableView {
                    Label(L10n.tr("Spotlight 没有应用的使用记录", "Spotlight has no usage history for your apps", "В Spotlight нет истории использования приложений"),
                          systemImage: "magnifyingglass")
                } description: {
                    Text(L10n.tr(
                        "无法判断哪些应用未被使用。请检查 Spotlight 索引是否已开启。",
                        "Mac Mop can't tell which apps are unused. Check that Spotlight indexing is turned on.",
                        "Невозможно определить неиспользуемые приложения. Проверьте, что индексация Spotlight включена."
                    ))
                }
                .kmrGroupedBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            } else if idleCount == 0 {
                ContentUnavailableView {
                    Label(L10n.tr("没有符合条件的应用", "No unused apps in this window", "Нет неиспользуемых приложений за этот период"),
                          systemImage: "checkmark.circle")
                } description: {
                    Text(KMR.t("Hai aperto tutte le tue app nel periodo scelto.", "You have opened all your apps in the chosen period."))
                }
                .kmrGroupedBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    AppListControls(options: $listOptions, search: $searchText, showsIdleFilter: false, showsAppleFilter: false)
                    AppListFilterSummary(shown: visible.count, total: idleCount,
                                         hasFilters: listOptions.activeFilterCount > 0 || !searchText.isEmpty) {
                        listOptions = listOptions.clearingFilters
                        searchText = ""
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

                Group {
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(KMR.t("Nessuna app corrisponde", "No matching apps"), systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text(KMR.t("Cambia la ricerca o azzera i filtri.", "Change the search or clear the filters."))
                        } actions: {
                            Button(KMR.t("Azzera i filtri", "Clear filters")) {
                                listOptions = listOptions.clearingFilters
                                searchText = ""
                            }
                        }
                    } else {
                        List(visible) { app in row(app) }
                            .listStyle(.inset)
                    }
                }
                .kmrGroupedBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .animation(.smooth, value: isLoading)
        .task { await reload() }
        .onChange(of: horizon) { _, _ in refreshVisible() }
        .onChange(of: listOptions) { _, _ in refreshVisible() }
        .onChange(of: searchText) { _, _ in refreshVisible() }
        .respondsToModuleShortcuts(onScan: { Task { await reload() } }, canScan: !isLoading)
    }

    private func row(_ app: UnusedAppRecord) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.icon(forPath: app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if app.runsInBackground {
                        Text(L10n.tr("后台", "Background", "Фоновое"))
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                    if facts[app.path]?.isIntelOnly == true {
                        Image(systemName: "cpu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(KMR.t("Solo per Intel: gira con Rosetta", "Intel only: runs under Rosetta"))
                    }
                }
                Text(subtitle(for: app))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(FileSizeFormatter.format(app.totalBytes))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Button(L10n.tr("卸载…", "Uninstall…", "Удалить…")) {
                appState.openUninstaller(forAppPath: app.path)
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for app: UnusedAppRecord) -> String {
        let info = facts[app.path]
        var parts = [AppListFacts.lastOpenedText(app.lastUsed)]
        switch listOptions.sort {
        case .installed: parts.append(AppListFacts.installedText(info?.installed))
        case .developer: if let developer = info?.developer { parts.append(developer) }
        default: break
        }
        let supportLabel = L10n.tr("支持文件", "Support files", "Файлы поддержки")
        parts.append("\(supportLabel) \(FileSizeFormatter.format(app.supportBytes))")
        return parts.joined(separator: " · ")
    }

    private func refreshVisible() {
        let idle = UnusedApps.unused(from: records, horizon: horizon)
        idleCount = idle.count
        let byPath = Dictionary(idle.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let entries = idle.map { AppListEntry(record: $0, facts: facts[$0.path]) }
        visible = AppListQuery.apply(entries, search: searchText, options: listOptions).compactMap { byPath[$0.id] }
    }

    private func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.path(percentEncoded: false)
        })
        let listed = await Task.detached {
            await UnusedAppsClient().records(runningAppPaths: running)
        }.value
        // A newer refresh started while this one ran: drop the stale result.
        guard generation == loadGeneration else { return }
        records = listed
        refreshVisible()
        isLoading = false
        // Developer / source / install date for the widest period only.
        let candidates = UnusedApps.unused(from: listed, horizon: .threeMonths).map(\.path)
        let loaded = await AppListFactsStore.shared.facts(for: candidates)
        guard generation == loadGeneration else { return }
        facts.merge(loaded) { _, new in new }
        refreshVisible()
    }
}
