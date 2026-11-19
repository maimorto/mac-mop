import SwiftUI
import MacCleanerKit

struct LargeOldFilesView: View {
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
    /// What the last clean removed, so "Back to Results" shows what is left.
    @State private var lastRemoved: Set<URL> = []

    var body: some View {
        ModuleContainerView(
            title: L10n.tr("大文件与旧文件", "Large & Old Files", "Большие и старые файлы"),
            subtitle: L10n.tr("查找大于 50 MB 且最近未访问的文件", "Find files larger than 50 MB that haven't been accessed recently", "Поиск файлов размером более 50 МБ, к которым давно не обращались"),
            theme: .files,
            emptyMessage: L10n.tr("未找到大文件或旧文件", "No large or old files found", "Большие или старые файлы не найдены"),
            results: results,
            selectedItems: $selectedItems,
            isScanning: isScanning,
            scanProgress: scanProgress,
            scanPhase: scanPhase,
            scanComplete: scanComplete,
            completion: completion,
            cleaning: cleaning,
            onScan: scan,
            onClean: clean,
            onCancelClean: { cleanTask?.cancel() },
            onReset: reset,
            onBackToResults: backToResults
        )
        .onAppear {
            if let e = appState.scanResultsStore.entry(for: .largeOldFiles) {
                results = e.results
                selectedItems = e.selection
                scanComplete = e.scanComplete
            }
        }
        // Debug aid for screenshots (never touches the disk): KMR_DEMO=done
        // shows a finished clean of two fake items; KMR_DEMO_BACK=1 then
        // presses the window's Back button.
        .task {
            let env = ProcessInfo.processInfo.environment
            guard env["KMR_DEMO"] == "done" else { return }
            let fake = (1...5).map { i in
                FileItem(url: URL(fileURLWithPath: "/private/tmp/kmr-demo/Video \(i).mov"), name: "Video \(i).mov",
                         size: UInt64(i) * 700_000_000, allocatedSize: UInt64(i) * 700_000_000, isDirectory: false)
            }
            results = [ScanResult(category: .largeFiles, items: fake)]
            selectedItems = Set(fake.prefix(3).map(\.url))
            scanComplete = true
            lastRemoved = Set(fake.prefix(2).map(\.url))
            completion = CleanSummary(selectedCount: 3, removedCount: 2, freedBytes: 2_100_000_000, errorMessages: [])
            if env["KMR_DEMO_BACK"] == "1" {
                try? await Task.sleep(for: .seconds(2))
                appState.goBack()
            } else if env["KMR_DEMO_BACK"] == "esc", let window = NSApp.keyWindow ?? NSApp.mainWindow {
                try? await Task.sleep(for: .seconds(2))
                window.makeFirstResponder(nil)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let esc = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(esc, atStart: false)
                    }
                }
            }
        }
        .onDisappear {
            appState.scanResultsStore.save(
                results: results,
                selection: selectedItems,
                scanComplete: scanComplete,
                for: .largeOldFiles
            )
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

            scanPhase = L10n.tr("正在扫描个人目录...", "Scanning home directory...", "Сканирование домашней папки...")
            scanProgress = 0.2
            try? await Task.sleep(for: .milliseconds(500))

            scanPhase = L10n.tr("正在检查文件大小...", "Checking file sizes...", "Проверка размеров файлов...")
            scanProgress = 0.45

            let module = LargeOldFilesModule()
            async let scanTask = module.scan()

            try? await Task.sleep(for: .milliseconds(400))
            scanPhase = L10n.tr("正在检查访问日期...", "Checking access dates...", "Проверка дат последнего доступа...")
            scanProgress = 0.7

            results = await scanTask

            scanPhase = L10n.tr("正在整理结果...", "Grouping results...", "Группировка результатов...")
            scanProgress = 0.9

            let elapsed = Date().timeIntervalSince(scanStart)
            if elapsed < 2.0 {
                try? await Task.sleep(for: .milliseconds(Int((2.0 - elapsed) * 1000)))
            }
            scanProgress = 1.0

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
                errorMessages: result.errors.map(\.error)
            )
        }
    }

    /// Done screen → the results that are left after the clean.
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
