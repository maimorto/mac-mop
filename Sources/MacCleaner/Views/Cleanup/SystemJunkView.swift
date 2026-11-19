import SwiftUI
import MacCleanerKit

struct SystemJunkView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.moduleIsSelected) private var moduleIsSelected
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @State private var viewModel = SystemJunkViewModel()
    @State private var showLargeSelectionConfirm = false
    @State private var showDryRun = false
    @State private var dryRunPlan: CleanSafety.Plan?
    @State private var showActivityLog = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isScanComplete && !viewModel.permissionDeniedPaths.isEmpty {
                permissionWarning
            }
            Group {
                switch viewModel.state {
                case .idle:
                    idleView
                case .scanning(let progress):
                    scanningView(progress: progress)
                case .results:
                    resultsView
                case .empty:
                    emptyView
                case .cleaning(let progress):
                    cleaningView(progress: progress)
                case .done(let summary):
                    doneView(summary: summary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let e = appState.scanResultsStore.entry(for: .systemJunk) {
                viewModel.restore(results: e.results, selection: e.selection, scanComplete: e.scanComplete, permissionDeniedPaths: e.permissionDeniedPaths)
            }
        }
        .onDisappear {
            appState.scanResultsStore.save(
                results: viewModel.results,
                selection: viewModel.selectedItems,
                scanComplete: viewModel.isScanComplete,
                for: .systemJunk,
                permissionDeniedPaths: viewModel.permissionDeniedPaths
            )
        }
        .pageNavigation(id: "systemjunk.done", canGoBack: viewModel.isDone, back: { viewModel.backToResults() })
        .pageNavigation(id: "systemjunk.empty", canGoBack: { if case .empty = viewModel.state { return true }; return false }(),
                        back: { viewModel.reset() })
        .respondsToModuleShortcuts(
            onScan: { viewModel.startScan() },
            onClean: { requestCleanup() },
            canScan: {
                switch viewModel.state {
                case .idle, .empty, .done, .results: true
                case .scanning, .cleaning: false
                }
            }(),
            canClean: {
                if case .results = viewModel.state { return viewModel.selectedCount > 0 }
                return false
            }()
        )
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.tr("扫描未完成：部分文件夹无法读取", "Scan incomplete: some folders could not be read", "Сканирование неполное: некоторые папки недоступны"), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(L10n.tr("受保护的文件夹（包括剪贴板归档）需要完全磁盘访问权限。请为此 Mac Mop 副本授权，重新启动应用并再次扫描。", "Protected folders, including clipboard archives, require Full Disk Access. Grant it to this copy of Mac Mop, restart the app, and scan again.", "Для защищённых папок, включая архивы буфера обмена, нужен полный доступ к диску. Предоставьте его этой копии Mac Mop, перезапустите приложение и повторите сканирование."))
                .font(.caption)
            Text(viewModel.permissionDeniedPaths.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .help(viewModel.permissionDeniedPaths.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
            Button(L10n.tr("打开完全磁盘访问设置", "Open Full Disk Access Settings", "Открыть настройки доступа к диску")) {
                PermissionManager.shared.openFullDiskAccessSettings()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.15))
    }

    private var idleView: some View {
        VStack(spacing: 22) {
            Spacer()

            ModuleHero(theme: .cleanup, size: 120)

            VStack(spacing: 10) {
                    Text(L10n.tr("系统垃圾", "System Junk", "Системный мусор"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                    Text(L10n.tr("查找并移除系统缓存、日志、\n语言文件和其他垃圾", "Find and remove system caches, logs,\nlanguage files, and other junk", "Поиск и удаление системных кэшей, журналов,\nфайлов локализации и другого мусора"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScanButton(
                title: L10n.tr("扫描", "Scan", "Сканировать"),
                subtitle: L10n.tr("系统垃圾", "System Junk", "Системный мусор"),
                theme: .cleanup
            ) {
                viewModel.startScan()
            }

            Spacer()
        }
    }

    private func scanningView(progress: Double) -> some View {
        VStack(spacing: 0) {
            Spacer()

            ScanProgressRing(
                progress: progress,
                phase: viewModel.scanPhase,
                detail: L10n.tr("发现 \(viewModel.filesFound) 个文件", "\(viewModel.filesFound) files found", "\(viewModel.filesFound) \(L10n.russianPlural(viewModel.filesFound, one: "файл найден", few: "файла найдено", many: "файлов найдено"))"),
                theme: .cleanup
            )

            Spacer()
        }
    }

    private var resultsView: some View {
        VStack(spacing: 16) {
            SizeDisplay(size: viewModel.totalSelectedSize,
                        label: L10n.tr("已选择待清理", "selected to clean", "выбрано для очистки"))
                .foregroundStyle(.primary)
                .padding(.top, 16)

            ResultsReview(results: viewModel.results, selectedItems: $viewModel.selectedItems)
            .padding(.horizontal, 20)

            CleanupActionBar(
                selectedCount: viewModel.selectedCount,
                totalCount: viewModel.totalFileCount,
                selectedSize: viewModel.totalSelectedSize,
                gradient: ModuleTheme.cleanup.buttonGradient,
                action: { requestCleanup() }
            )
            .sheet(isPresented: $showDryRun) {
                DryRunSummarySheet(plan: dryRunPlan,
                                   onConfirm: { showDryRun = false; viewModel.startCleaning(engine: appState.cleaningEngine) },
                                   onCancel: { showDryRun = false })
            }
            .alert(
                CleanupStrings.confirmationTitle(count: viewModel.selectedCount),
                isPresented: $showLargeSelectionConfirm
            ) {
                Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) { }
                Button(L10n.tr("继续", "Continue", "Продолжить"), role: .destructive) {
                    viewModel.startCleaning(engine: appState.cleaningEngine)
                }
            } message: {
                if showLargeSelectionConfirm {
                    Text(cleanupConfirmationMessage(for: CleanupSelectionPolicy.selectedCategories(
                        in: viewModel.results, selection: viewModel.selectedItems)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func requestCleanup() {
        if CleanActions.needsDryRun {
            // Simulation first (covers the large-selection confirmation too).
            dryRunPlan = nil
            showDryRun = true
            let r = viewModel.results, sel = viewModel.selectedItems
            Task { dryRunPlan = await CleanActions.plan(results: r, selectedItems: sel) }
            return
        }
        if viewModel.selectedCount > MCConstants.cleanConfirmationThreshold
            || CleanupSelectionPolicy.requiresReview(in: viewModel.results, selection: viewModel.selectedItems) {
            showLargeSelectionConfirm = true
        } else {
            viewModel.startCleaning(engine: appState.cleaningEngine)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.primary.opacity(0.9))
            Text(L10n.tr("未发现垃圾", "No junk found", "Мусор не найден"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(L10n.tr("你的 Mac 很干净！", "Your Mac is clean!", "Ваш Mac чист!"))
                .font(.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(L10n.tr("重新扫描", "Rescan", "Сканировать снова")) { viewModel.startScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button(L10n.tr("完成", "Done", "Готово")) { viewModel.reset() }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
            }
            Spacer()
        }
    }

    private func cleaningView(progress: CleaningEngine.Progress?) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Determinate progress when the engine has emitted at least one
            // snapshot; indeterminate spinner before the first chunk lands.
            ScanProgressRing(
                progress: progress?.fraction ?? 0.0,
                phase: cleaningPhaseText(progress),
                theme: .cleanup
            )

            if let progress {
                Text(L10n.tr("已处理 \(progress.processedItems.formatted()) / \(progress.totalItems.formatted()) 项", "\(progress.processedItems.formatted()) of \(progress.totalItems.formatted()) items", "Обработано \(progress.processedItems.formatted()) из \(progress.totalItems.formatted()) \(L10n.russianPlural(progress.totalItems, one: "объекта", few: "объектов", many: "объектов"))"))
                    .font(.system(size: 12, design: .monospacedUnlessRightToLeft))
                    .foregroundStyle(.secondary)
            }

            // Cancel button — engine honors Task.isCancelled at chunk
            // boundaries, so a cancel halts the operation and produces a
            // partial CleanResult (which the .done state shows honestly).
            Button(L10n.tr("取消", "Cancel", "Отмена")) { viewModel.cancelCleaning() }
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.large)
            Text(L10n.tr("取消后会先完成当前一组。", "Cancelling finishes the current group first.", "При отмене текущая группа сначала завершится."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    /// See ModuleContainerView.cleanErrorDetail for the design rationale —
    /// this is the same UI, lifted here because SystemJunkView has its
    /// own state machine and doesn't route through ModuleContainerView.
    @ViewBuilder
    private func cleanErrorDetail(for summary: CleanSummary) -> some View {
        if summary.errorCount == 1, let msg = summary.firstErrorMessage {
            Text(msg)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .textSelection(.enabled)
        } else if !summary.topErrorGroups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary.topErrorGroups, id: \.message) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(group.count.formatted())×")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 50, alignment: .trailing)
                        Text(group.message)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.8))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                let shownTotal = summary.topErrorGroups.reduce(0) { $0 + $1.count }
                if summary.errorCount > shownTotal {
                    Text(L10n.tr("…以及另外 \((summary.errorCount - shownTotal).formatted()) 项", "…and \((summary.errorCount - shownTotal).formatted()) more", "…и ещё \((summary.errorCount - shownTotal).formatted()) \(L10n.russianPlural(summary.errorCount - shownTotal, one: "ошибка", few: "ошибки", many: "ошибок"))"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Text(L10n.tr("完整日志：~/Library/Logs/MacCleaner/operations.log", "Full log: ~/Library/Logs/MacCleaner/operations.log", "Полный журнал: ~/Library/Logs/MacCleaner/operations.log"))
                    .font(.system(size: 11, design: .monospacedUnlessRightToLeft))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    private func cleaningPhaseText(_ progress: CleaningEngine.Progress?) -> String {
        guard let progress, progress.totalItems > 0 else {
            return L10n.tr("正在开始清理...", "Starting cleanup...", "Подготовка к очистке...")
        }
        let pct = Int((progress.fraction * 100).rounded())
        return L10n.tr("正在清理… \(pct)%", "Cleaning… \(pct)%", "Очистка… \(pct)%")
    }

    /// Scrolls when taller than the window (support card on a small window)
    /// instead of overflowing the pane.
    private func doneView(summary: CleanSummary) -> some View {
        FitOrScroll { doneContent(summary: summary) }
    }

    private func doneContent(summary: CleanSummary) -> some View {
        VStack(spacing: 20) {
            Spacer()

            // Three distinguishable end-states. The user-reported confusion
            // (the Reddit "0 bytes cleaned up" screenshot) was the second
            // case: scan surfaced items but they were all in autoSelect=false
            // categories (most commonly Universal Binaries) so nothing was
            // checked when Clean was clicked. Saying "0 bytes" looked broken;
            // saying "Nothing was selected" tells the user what to do next.
            if summary.wasCancelled {
                Image(systemName: "pause.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(L10n.tr("清理已停止", "Cleanup stopped", "Очистка остановлена"))
                    .font(.title3.weight(.semibold))
                SizeDisplay(size: summary.freedBytes, label: L10n.tr("已处理", "processed", "обработано"))
                cleanErrorDetail(for: summary)
                SafetySkipsSummary(skips: CleanSafetyReport.shared.recentSkips)
            } else if summary.selectedCount == 0 {
                Image(systemName: "checklist.unchecked")
                    .font(.largeTitle)
                    .foregroundStyle(.primary.opacity(0.85))
                Text(L10n.tr("未选择任何项目", "Nothing was selected", "Ничего не выбрано"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr("请重新扫描，勾选要移除的项目，然后点击“清理”。", "Re-run the scan, check the items you want to remove, then click Clean.", "Запустите сканирование снова, отметьте объекты для удаления и нажмите «Очистить»."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else if summary.removedCount == 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange.opacity(0.85))
                Text(L10n.tr("\(summary.selectedCount) 项无法清理", "Items that couldn't be cleaned: \(summary.selectedCount)", "Не удалось очистить \(summary.selectedCount) \(L10n.russianPlural(summary.selectedCount, one: "объект", few: "объекта", many: "объектов"))"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                cleanErrorDetail(for: summary)
                SafetySkipsSummary(skips: CleanSafetyReport.shared.recentSkips)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.primary)
                SizeDisplay(size: summary.freedBytes, label: L10n.tr("已清理", "cleaned up", "освобождено"))
                    .foregroundStyle(.primary)
                if summary.removedCount < summary.selectedCount {
                    // Partial success — tell them what got skipped.
                    Text(L10n.tr("已移除 \(summary.removedCount) / \(summary.selectedCount) 项", "\(summary.removedCount) of \(summary.selectedCount) items removed", "Удалено \(summary.removedCount) из \(summary.selectedCount) \(L10n.russianPlural(summary.selectedCount, one: "объекта", few: "объектов", many: "объектов"))") +
                         (summary.errorCount > 0 ? L10n.tr(" — \(summary.errorCount) 个错误", " — errors: \(summary.errorCount)", " — \(summary.errorCount) \(L10n.russianPlural(summary.errorCount, one: "ошибка", few: "ошибки", many: "ошибок"))") : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr(
                        "选中的文件夹与其内容计为一项。已经消失的文件会被跳过。",
                        "Selected folders count as one item together with their contents. Files already gone are skipped.",
                        "Выбранная папка учитывается как один объект вместе с содержимым. Уже исчезнувшие файлы пропускаются."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                cleanErrorDetail(for: summary)
                SafetySkipsSummary(skips: CleanSafetyReport.shared.recentSkips)
            }

            HStack(spacing: 10) {
                if summary.errorCount > 0 {
                    Button {
                        showActivityLog = true
                    } label: {
                        Label(L10n.tr("查看日志", "View Log", "Журнал"), systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.large)
                    .help(L10n.tr("打开活动日志，查看每个错误并复制详情用于反馈问题", "Open the activity log to see every error and copy details for a bug report", "Откройте журнал действий, чтобы просмотреть каждую ошибку и скопировать сведения для отчёта о проблеме"))
                }
                Button {
                    viewModel.backToResults()
                } label: {
                    Label(KMR.t("Torna ai risultati", "Back to Results"), systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(KMR.t("Rivedi gli elementi rimasti (Esc, ⌘[)", "Review the items that are left (Esc, ⌘[)"))
                Button(L10n.tr("完成", "Done", "Готово")) { viewModel.reset() }
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
