import SwiftUI
import MacCleanerKit

struct ModuleContainerView: View {
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    let title: String
    let subtitle: String
    let theme: ModuleTheme
    let emptyMessage: String
    let results: [ScanResult]
    @Binding var selectedItems: Set<URL>
    let isScanning: Bool
    let scanProgress: Double
    let scanPhase: String
    let scanComplete: Bool
    /// `nil` until clean has run. When set, the doneView renders one of
    /// three honest end-states (nothing selected / everything errored /
    /// happy path) instead of an ambiguous "0 bytes cleaned up".
    let completion: CleanSummary?
    /// Non-nil while a clean is in flight. The container renders a
    /// progress ring + cancel button instead of the results list during
    /// this window. nil means "no clean in flight" — either before any
    /// clean or after one finishes (then `completion` takes over).
    let cleaning: CleaningEngine.Progress?
    /// True when the scan came back empty because a target couldn't be read
    /// (Full Disk Access not granted) rather than because there was nothing
    /// to clean. Drives the "Grant Full Disk Access" empty-state instead of
    /// the misleading "nothing to clean up" one.
    let permissionDenied: Bool
    let onScan: () -> Void
    let onClean: () -> Void
    let onCancelClean: (() -> Void)?
    let onReset: () -> Void
    /// Done screen → the results that are left (cleaned items removed). When
    /// nil, Back/Esc on the done screen fall back to `onReset`.
    let onBackToResults: (() -> Void)?
    /// Stops an in-flight scan (Cancel on the scanning screen, Esc).
    let onCancelScan: (() -> Void)?
    /// Opens System Settings → Full Disk Access. Required when
    /// `permissionDenied` can be true; the empty-state button calls it.
    let onGrantAccess: (() -> Void)?
    /// When true, the Clean button ALWAYS shows an irreversible
    /// "Empty the Trash?" confirmation, regardless of selection size.
    /// Used only by the Trash Bins module, whose Clean permanently
    /// deletes (it empties ~/.Trash) rather than moving items to the Trash.
    let confirmEmptyTrash: Bool
    /// Optional replacement for the default flat `FileListView` in the results
    /// screen. When provided, the container keeps all of its chrome (selection
    /// header, Clean button + confirmations, cleaning/progress/done states) but
    /// renders this view for the item list instead. The Duplicates module uses
    /// it to show a grouped, keep-the-original layout while reusing everything
    /// else. The closure should read/write the same `selectedItems` binding.
    let resultsContent: (() -> AnyView)?
    /// Overrides the primary action button's label (default "Clean"). The
    /// Duplicates module sets "Consolidate" when in consolidate mode so the
    /// button reflects that it clones rather than deletes.
    let actionLabel: String?

    init(
        title: String,
        subtitle: String,
        theme: ModuleTheme,
        emptyMessage: String = L10n.tr("未找到项目", "No items found", "Ничего не найдено"),
        results: [ScanResult],
        selectedItems: Binding<Set<URL>>,
        isScanning: Bool,
        scanProgress: Double = 0.5,
        scanPhase: String = L10n.tr("正在扫描...", "Scanning...", "Сканирование..."),
        scanComplete: Bool = false,
        completion: CleanSummary? = nil,
        cleaning: CleaningEngine.Progress? = nil,
        permissionDenied: Bool = false,
        onScan: @escaping () -> Void,
        onClean: @escaping () -> Void,
        onCancelClean: (() -> Void)? = nil,
        onReset: @escaping () -> Void,
        onBackToResults: (() -> Void)? = nil,
        onCancelScan: (() -> Void)? = nil,
        onGrantAccess: (() -> Void)? = nil,
        confirmEmptyTrash: Bool = false,
        resultsContent: (() -> AnyView)? = nil,
        actionLabel: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.emptyMessage = emptyMessage
        self.results = results
        self._selectedItems = selectedItems
        self.isScanning = isScanning
        self.scanProgress = scanProgress
        self.scanPhase = scanPhase
        self.scanComplete = scanComplete
        self.completion = completion
        self.cleaning = cleaning
        self.permissionDenied = permissionDenied
        self.onScan = onScan
        self.onClean = onClean
        self.onCancelClean = onCancelClean
        self.onReset = onReset
        self.onBackToResults = onBackToResults
        self.onCancelScan = onCancelScan
        self.onGrantAccess = onGrantAccess
        self.confirmEmptyTrash = confirmEmptyTrash
        self.resultsContent = resultsContent
        self.actionLabel = actionLabel
    }

    @State private var showLargeSelectionConfirm = false
    @State private var showEmptyTrashConfirm = false
    @State private var showActivityLog = false
    /// "Prova senza pulire": shown before the first clean, or before every
    /// clean when Settings › dryRunFirstClean is on.
    @State private var showDryRun = false
    @State private var dryRunPlan: CleanSafety.Plan?
    /// Safety skips of the clean shown on the done screen.
    @State private var doneSkips: [CleanSafety.Skip] = []

    /// Deduped selected size (a file can appear in two categories), computed
    /// off the main thread whenever the selection or results change.
    @State private var totalSelected: UInt64 = 0

    private var selectionKey: String {
        "\(selectedItems.count)#" + results.map { "\($0.category.rawValue):\($0.items.count)" }.joined(separator: ",")
    }

    private var selectedCount: Int {
        selectedItems.count
    }

    private var formattedSelectedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSelected), countStyle: .file)
    }

    var body: some View {
        Group {
            if let completion {
                doneView(summary: completion)
                    .transition(.immersive)
            } else if let cleaning {
                cleaningView(progress: cleaning)
                    .transition(.immersive)
            } else if isScanning {
                scanningView
                    .transition(.immersive)
            } else if !results.isEmpty {
                resultsView
                    .transition(.immersive)
            } else if scanComplete {
                if permissionDenied {
                    permissionDeniedView
                        .transition(.immersive)
                } else {
                    emptyResultsView
                        .transition(.immersive)
                }
            } else {
                idleView
                    .transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: screenKey)
        .task(id: selectionKey) {
            let r = results, sel = selectedItems
            totalSelected = await Task.detached(priority: .userInitiated) { r.selectedSize(sel) }.value
        }
        .onChange(of: isScanning) { wasScanning, nowScanning in
            if nowScanning { SoundFX.play(.scanStart) }
            else if wasScanning { SoundFX.play(results.isEmpty ? .nothingFound : .scanDone) }
        }
        // Safer defaults for non-experts: categories that hold the user's own
        // data start unchecked; they can still be selected deliberately.
        .onChange(of: scanComplete) { _, done in
            guard done else { return }
            // Debug aid for screenshots: KMR_DRYRUN_PREVIEW=1 opens the
            // simulation sheet after the scan (it never cleans by itself).
            if ProcessInfo.processInfo.environment["KMR_DRYRUN_PREVIEW"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !results.isEmpty, !selectedItems.isEmpty, actionLabel == nil, !confirmEmptyTrash { startDryRun() }
                }
            }
            DispatchQueue.main.async {
                let review = results.filter {
                    $0.category.cleanupSafety == .reviewFirst && ![.malware, .trashBins].contains($0.category)
                }
                for r in review { selectedItems.subtract(r.items.map(\.url)) }
            }
        }
        .onChange(of: completion?.id, initial: true) { _, id in
            doneSkips = id == nil ? [] : CleanSafetyReport.shared.recentSkips
        }
        .sheet(isPresented: $showDryRun) {
            DryRunSummarySheet(plan: dryRunPlan,
                               onConfirm: { showDryRun = false; onClean() },
                               onCancel: { showDryRun = false })
        }
        // Back (toolbar, ⌘[, Esc, mouse) leaves the done screen for the
        // remaining results, and an empty/denied result for the start page.
        .pageNavigation(id: "container.done", canGoBack: completion != nil,
                        back: { (onBackToResults ?? onReset)() })
        .pageNavigation(id: "container.empty",
                        canGoBack: completion == nil && cleaning == nil && !isScanning && results.isEmpty && scanComplete,
                        back: onReset)
        .respondsToModuleShortcuts(
            onScan: onScan,
            onClean: requestClean,
            canScan: cleaning == nil && !isScanning && completion == nil,
            canClean: cleaning == nil && completion == nil && !results.isEmpty && selectedCount > 0
        )
    }

    /// Renders the error summary on the post-clean screen. Single error
    /// gets the full message; multi-error shows the top-3 groups
    /// ("X items: <message>") sorted by count, so the user immediately
    /// sees what kind of failure dominated rather than a flat count
    /// pointing them at Console.app.
    @ViewBuilder
    private func cleanErrorDetail(for summary: CleanSummary) -> some View {
        if summary.errorCount == 1, let msg = summary.firstErrorMessage {
            Text(msg)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .textSelection(.enabled)
        } else if !summary.topErrorGroups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary.topErrorGroups, id: \.message) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(group.count.formatted())×")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.6))
                            .frame(minWidth: 50, alignment: .trailing)
                        Text(group.message)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.8))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                if summary.errorCount > summary.topErrorGroups.reduce(0, { $0 + $1.count }) {
                    let shownTotal = summary.topErrorGroups.reduce(0) { $0 + $1.count }
                    Text(L10n.tr("…以及另外 \((summary.errorCount - shownTotal).formatted()) 项", "…and \((summary.errorCount - shownTotal).formatted()) more", "…и ещё \((summary.errorCount - shownTotal).formatted()) \(L10n.russianPlural(summary.errorCount - shownTotal, one: "ошибка", few: "ошибки", many: "ошибок"))"))
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.5))
                        .padding(.top, 2)
                }
                Text(L10n.tr("完整日志：~/Library/Logs/MacCleaner/operations.log", "Full log: ~/Library/Logs/MacCleaner/operations.log", "Полный журнал: ~/Library/Logs/MacCleaner/operations.log"))
                    .font(.system(size: 11, design: .monospacedUnlessRightToLeft))
                    .foregroundStyle(.primary.opacity(0.45))
                    .padding(.top, 4)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
        }
    }

    private func cleaningView(progress: CleaningEngine.Progress) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ScanProgressRing(
                progress: progress.fraction,
                phase: progress.totalItems > 0
                    ? L10n.tr("正在清理… \(Int((progress.fraction * 100).rounded()))%", "Cleaning… \(Int((progress.fraction * 100).rounded()))%", "Очистка… \(Int((progress.fraction * 100).rounded()))%")
                    : L10n.tr("正在开始清理...", "Starting cleanup...", "Подготовка к очистке..."),
                theme: theme
            )
            if progress.totalItems > 0 {
                Text(L10n.tr("已处理 \(progress.processedItems.formatted()) / \(progress.totalItems.formatted()) 项", "\(progress.processedItems.formatted()) of \(progress.totalItems.formatted()) items", "Всего \(progress.totalItems.formatted()) \(L10n.russianPlural(progress.totalItems, one: "объект", few: "объекта", many: "объектов")), обработано \(progress.processedItems.formatted())"))
                    .font(.system(size: 12, design: .monospacedUnlessRightToLeft))
                    .foregroundStyle(.primary.opacity(0.65))
            }
            if let onCancelClean {
                Button(L10n.tr("取消", "Cancel", "Отмена")) { onCancelClean() }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
            }
            Spacer()
        }
    }

    /// Identifies which screen is showing, so state changes animate.
    private var screenKey: Int {
        if completion != nil { return 6 }
        if cleaning != nil { return 5 }
        if isScanning { return 4 }
        if !results.isEmpty { return 3 }
        if scanComplete { return permissionDenied ? 2 : 1 }
        return 0
    }

    private var idleView: some View {
        // Pane header like System Settings: system icon, title, one line.
        SystemHero(title: title, subtitle: subtitle) {
            ScanButton(title: L10n.tr("扫描", "Scan", "Сканировать"), theme: theme, action: onScan)
        }
        .frame(maxWidth: 560)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 24) {
            Spacer()
            ScanProgressRing(progress: scanProgress, phase: scanPhase, theme: theme)
            if let onCancelScan {
                Button(L10n.tr("取消", "Cancel", "Отмена")) { onCancelScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .kmrCelebrate()
                .font(.largeTitle)
                .foregroundStyle(.primary.opacity(0.9))
            Text(emptyMessage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(L10n.tr("扫描完成——没有需要清理的内容", "Scan complete — nothing to clean up", "Сканирование завершено — очищать нечего"))
                .font(.body)
                .foregroundStyle(.primary.opacity(0.55))
            HStack(spacing: 10) {
                Button(L10n.tr("重新扫描", "Rescan", "Сканировать снова")) { onScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button(L10n.tr("完成", "Done", "Готово")) { onReset() }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
            }
            Spacer()
        }
    }

    /// Shown when the scan came back empty only because macOS blocked the
    /// read (Full Disk Access not granted). Without this the user saw
    /// "nothing to clean up" over a Trash that was actually full.
    private var permissionDeniedView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.primary.opacity(0.9))
            Text(L10n.tr("需要完全磁盘访问权限", "Full Disk Access needed", "Требуется полный доступ к диску"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(L10n.tr("macOS 正在阻止访问此位置。请为 \(MCConstants.appName) 授予完全磁盘访问权限，然后重新扫描。", "macOS is blocking access to this location. Grant \(MCConstants.appName) Full Disk Access, then scan again.", "macOS блокирует доступ к этому расположению. Предоставьте \(MCConstants.appName) полный доступ к диску и повторите сканирование."))
                .font(.body)
                .foregroundStyle(.primary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                if let onGrantAccess {
                    Button(L10n.tr("打开设置", "Open Settings", "Открыть настройки")) { onGrantAccess() }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .controlSize(.large)
                }
                Button(L10n.tr("重新扫描", "Rescan", "Сканировать снова")) { onScan() }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
                Button(L10n.tr("完成", "Done", "Готово")) { onReset() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Spacer()
        }
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            HStack {
                SizeDisplay(size: totalSelected, label: L10n.tr("已选择"))
                    .foregroundStyle(.primary)
                Spacer()
                Button(actionLabel ?? L10n.tr("清理", "Clean", "Очистить")) { requestClean() }
                    .buttonStyle(SuperEllipseButtonStyle(
                        gradient: theme.buttonGradient,
                        size: CGSize(width: 110, height: 40)
                    ))
                    // Prevent clicking Clean with nothing checked — the
                    // resulting "0 bytes cleaned up" screen used to be
                    // indistinguishable from a real cleanup failure.
                    .disabled(selectedCount == 0)
                    .opacity(selectedCount == 0 ? 0.5 : 1.0)
                    .help(selectedCount == 0
                          ? L10n.tr("请至少勾选一个要清理的项目", "Check at least one item to clean", "Выберите хотя бы один объект для очистки")
                          : confirmEmptyTrash
                            ? L10n.tr("从废纸篓中永久删除 \(selectedCount) 项", "Permanently delete \(selectedCount) item(s) from the Trash", "Навсегда удалить \(selectedCount) \(L10n.russianPlural(selectedCount, one: "объект", few: "объекта", many: "объектов")) из Корзины")
                            : L10n.tr("将 \(selectedCount) 项移到废纸篓", "Move \(selectedCount) item(s) to Trash", "Переместить \(selectedCount) \(L10n.russianPlural(selectedCount, one: "объект", few: "объекта", many: "объектов")) в Корзину"))
                    .alert(
                        L10n.tr("清理 \(selectedCount.formatted()) 项？", "Clean \(selectedCount.formatted()) items?", "Очистить \(selectedCount.formatted()) \(L10n.russianPlural(selectedCount, one: "объект", few: "объекта", many: "объектов"))?"),
                        isPresented: $showLargeSelectionConfirm
                    ) {
                        Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) { }
                        Button(L10n.tr("继续", "Continue", "Продолжить"), role: .destructive) { onClean() }
                    } message: {
                        Text(L10n.tr("约 \(formattedSelectedSize) 数据，可能需要几分钟。清理过程中可以取消。", "That's about \(formattedSelectedSize) of data and may take several minutes. You can cancel mid-cleanup.", "Объём данных — около \(formattedSelectedSize). Операция может занять несколько минут, но её можно отменить."))
                    }
                    // Trash Bins empties ~/.Trash permanently — there is no
                    // recovery, so this confirmation fires on every Empty
                    // regardless of how many items are selected.
                    .alert(
                        L10n.tr("清空废纸篓？", "Empty the Trash?", "Очистить Корзину?"),
                        isPresented: $showEmptyTrashConfirm
                    ) {
                        Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) { }
                        Button(L10n.tr("清空废纸篓", "Empty Trash", "Очистить Корзину"), role: .destructive) { onClean() }
                    } message: {
                        Text(L10n.tr("这会永久删除 \(selectedCount.formatted()) 项（\(formattedSelectedSize)），且无法撤销。", "Items to delete permanently: \(selectedCount.formatted()) (\(formattedSelectedSize)). This can't be undone.", "Безвозвратное удаление: \(selectedCount.formatted()) \(L10n.russianPlural(selectedCount, one: "объект", few: "объекта", many: "объектов")) (\(formattedSelectedSize)). Отменить это действие нельзя."))
                    }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Group {
                if let resultsContent {
                    resultsContent()
                } else {
                    ResultsReview(results: results, selectedItems: $selectedItems, permanent: confirmEmptyTrash)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    /// Clean button and ⌘⌫: the empty-Trash confirmation, the dry run, the
    /// large-selection confirmation, or straight to `onClean`.
    private func requestClean() {
        guard selectedCount > 0 else { return }
        if confirmEmptyTrash {
            // Trash Bins: permanent + irreversible — always confirm.
            showEmptyTrashConfirm = true
        } else if actionLabel == nil, CleanActions.needsDryRun {
            // The simulation also covers the large-selection confirmation.
            startDryRun()
        } else if selectedCount > MCConstants.cleanConfirmationThreshold {
            showLargeSelectionConfirm = true
        } else {
            onClean()
        }
    }

    /// Opens the simulation sheet; nothing is cleaned unless the user
    /// confirms in it.
    private func startDryRun() {
        dryRunPlan = nil
        showDryRun = true
        let r = results, sel = selectedItems
        Task { dryRunPlan = await CleanActions.plan(results: r, selectedItems: sel) }
    }

    /// Scrolls when taller than the window (support card on a small window)
    /// instead of overflowing the pane.
    private func doneView(summary: CleanSummary) -> some View {
        FitOrScroll { doneContent(summary: summary) }
    }

    private func doneContent(summary: CleanSummary) -> some View {
        VStack(spacing: 20) {
            Spacer()

            // Three honest end-states. Previously this view rendered
            // "0 bytes cleaned up" for all of: nothing-selected,
            // everything-errored, AND no-junk-found cases — making the
            // app look broken when it was working correctly.
            if summary.selectedCount == 0 {
                Image(systemName: "checklist.unchecked")
                    .font(.largeTitle)
                    .foregroundStyle(.primary.opacity(0.85))
                Text(L10n.tr("未选择任何项目", "Nothing was selected", "Ничего не выбрано"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr("请重新扫描，勾选要移除的项目，然后点击“清理”。", "Re-run the scan, check the items you want to remove, then click Clean.", "Повторите сканирование, отметьте объекты для удаления и нажмите «Очистить»."))
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else if summary.removedCount == 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange.opacity(0.85))
                Text(L10n.tr("\(summary.selectedCount) 项无法清理", "Items that couldn't be cleaned: \(summary.selectedCount)", "Не удалось очистить \(summary.selectedCount) \(L10n.russianPlural(summary.selectedCount, one: "объект", few: "объекта", many: "объектов"))"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                // Show the actual first error message instead of "Check
                // Console for details" — the user shouldn't need to open
                // Console.app to find out it was a limit / permission /
                // SafetyGuard issue. For multi-error cases, fall back to
                // the count summary.
                cleanErrorDetail(for: summary)
            } else {
                SuccessMark(size: 84)
                Text(FileSizeFormatter.format(summary.freedBytes))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(KMR.t("liberati", "freed"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if summary.removedCount < summary.selectedCount {
                    Text(L10n.tr("已移除 \(summary.removedCount) / \(summary.selectedCount) 项", "\(summary.removedCount) of \(summary.selectedCount) items removed", "Выбрано \(summary.selectedCount) \(L10n.russianPlural(summary.selectedCount, one: "объект", few: "объекта", many: "объектов")), удалено \(summary.removedCount)") +
                         (summary.errorCount > 0 ? L10n.tr(" — \(summary.errorCount) 个错误", " — errors: \(summary.errorCount)", " — \(summary.errorCount) \(L10n.russianPlural(summary.errorCount, one: "ошибка", few: "ошибки", many: "ошибок"))") : ""))
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.65))
                }
            }

            if summary.selectedCount > 0 {
                SafetySkipsSummary(skips: doneSkips)
            }

            HStack(spacing: 10) {
                if summary.errorCount > 0 {
                    Button {
                        showActivityLog = true
                    } label: {
                        Label(L10n.tr("查看日志", "View Log", "Открыть журнал"), systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
                    .help(L10n.tr("打开活动日志，查看每个错误并复制详情用于反馈问题", "Open the activity log to see every error and copy details for a bug report", "Открыть журнал операций, просмотреть каждую ошибку и скопировать сведения для отчёта"))
                }
                if let onBackToResults {
                    Button {
                        onBackToResults()
                    } label: {
                        Label(KMR.t("Torna ai risultati", "Back to Results"), systemImage: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(KMR.t("Rivedi gli elementi rimasti (Esc, ⌘[)", "Review the items that are left (Esc, ⌘[)"))
                }
                Button(L10n.tr("完成", "Done", "Готово")) { onReset() }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
            }
            DoneScreenFooter()
            Spacer()
        }
        .sheet(isPresented: $showActivityLog) { LogViewerView() }
    }
}
