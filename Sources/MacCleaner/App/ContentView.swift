import SwiftUI
import MacCleanerKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    /// Module views the user has visited at least once. Once a view is here it
    /// stays in the hierarchy (hidden via opacity, NOT destroyed) when the user
    /// switches tabs — so in-flight scans keep running and large result lists
    /// don't re-render on every switch (fixes the switch-back lag and the
    /// mid-scan "cancel"). Views are created lazily on first visit so we don't
    /// front-load every module's `.task` (app discovery, login items, …) at
    /// launch.
    @State private var visited: Set<SidebarItem> = []
    @State private var demoScan = false
    @State private var demoResults: [ScanResult] = []
    @State private var demoSelection: Set<URL> = []
    @State private var updateCoordinator = UpdateCoordinator()
    @State private var selfUpdater = SelfUpdateController.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Right-to-left applies inside the sidebar and the module panes, not to
    /// the NavigationSplitView itself: its AppKit split view always lays out
    /// left to right, and a mirrored SwiftUI frame on top of it pushed the
    /// sidebar out of the window once the window was resized.
    private var contentDirection: LayoutDirection {
        AppLanguage.current.isRightToLeft ? .rightToLeft : .leftToRight
    }

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            SidebarView(selection: $state.selectedSidebarItem)
                // The sidebar is the app's primary navigation and is always
                // shown, so the toolbar's collapse-sidebar button is just
                // dead weight. Remove it.
                .toolbar(removing: .sidebarToggle)
                .environment(\.layoutDirection, contentDirection)
        } detail: {
            ZStack {
                if let item = appState.selectedSidebarItem {
                    GradientBackgroundView(theme: item.theme)
                        .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    if let item = appState.selectedSidebarItem, item.group.items.count > 1 {
                        ModuleTabs(group: item.group, selection: $state.selectedSidebarItem)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
                    ZStack {
                // Keep every visited module view alive across tab switches:
                        // show the selected one, hide (don't tear down) the rest.
                        ForEach(SidebarItem.allCases, id: \.self) { item in
                            // Render if currently selected (so the first frame is never
                            // blank) or previously visited (kept alive in the background).
                            if visited.contains(item) || item == appState.selectedSidebarItem {
                                let isSelected = item == appState.selectedSidebarItem
                                // Hidden modules stay alive (state, running scans) but get a
                                // zero-size frame, so layout passes skip their content.
                                moduleView(for: item)
                                    .frame(maxWidth: isSelected ? .infinity : 0, maxHeight: isSelected ? .infinity : 0)
                                    .clipped()
                                    .opacity(isSelected ? 1 : 0)
                                    .allowsHitTesting(isSelected)
                                    .accessibilityHidden(!isSelected)
                                    .environment(\.moduleIsSelected, isSelected)
                                    .environment(\.currentModule, item)
                            }
                        }
                    }
                }

                if !demoResults.isEmpty {
                    GradientBackgroundView(theme: .cleanup).ignoresSafeArea()
                    ResultsReview(results: demoResults, selectedItems: $demoSelection)
                        .padding(.top, 8)
                }
                if demoScan, let item = appState.selectedSidebarItem {
                    GradientBackgroundView(theme: item.theme).ignoresSafeArea()
                    ScanProgressRing(progress: 0.42, phase: KMR.t("Analisi in corso…", "Scanning…"), detail: "~/Library/Caches")
                        .environment(\.currentModule, item)
                }

                if appState.selectedSidebarItem == nil {
                    Text(L10n.tr("请从侧边栏选择一个模块", "Select a module from the sidebar", "Выберите модуль на боковой панели"))
                        .foregroundStyle(.secondary)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            // Keep the toolbar the same height on every page (some modules add
            // toolbar buttons, some do not), so the title and the window
            // controls never jump when switching modules.
            .environment(\.layoutDirection, contentDirection)
        }
        // Drop an app anywhere in the window to uninstall it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            appState.openUninstaller(forAppPath: app.path(percentEncoded: false))
            return true
        }
        .disabled(selfUpdater.isPreparingInstallation)
        .overlay {
            if selfUpdater.isPreparingInstallation {
                SelfUpdatePreparationOverlay(
                    canCancel: selfUpdater.canCancelPreparation,
                    onCancel: { selfUpdater.cancelPreparation() })
                .environment(\.layoutDirection, contentDirection)
            }
        }
        .background(TitleBarConfigurator())
        // Empty: the system-drawn title pins to the leading edge and on
        // macOS 26 ignores titleVisibility re-asserts while SwiftUI owns a
        // non-empty title. The visible (centered) title is drawn by the
        // detail-pane overlay; the real NSWindow.title is set by
        // TitleBarConfigurator so Mission Control/VoiceOver keep the name.
        .navigationTitle(appState.selectedSidebarItem?.group.title ?? MCConstants.appName)
        .toolbar {
            // Same items on every page, so the toolbar never changes height.
            ToolbarItem(placement: .primaryAction) { CleanupPermissionsButton() }
        }
        // Back/Forward, Esc, mouse/swipe navigation, Undo toast (AppNavigation.swift).
        .appNavigationSupport()
        // Mark the current selection visited (runs initially too) so its view
        // is created on first visit and then retained.
        .onChange(of: appState.selectedSidebarItem, initial: true) { _, newValue in
            if let newValue { visited.insert(newValue) }
        }
        // Automatic update check: ~3s after launch (never blocks startup) and
        // again whenever the app becomes active. UpdateCoordinator throttles to
        // once per day and one popup per session.
        .task {
            try? await Task.sleep(for: .seconds(3))
            if MCConstants.selfUpdatesEnabled, !selfUpdater.usesInAppUpdates { await updateCoordinator.runCheckIfDue() }
        }
        .task { AutoCleaner.runIfDue(engine: appState.cleaningEngine) }
        .task {
            if let path = ProcessInfo.processInfo.environment["KMR_STRESS"] {
                try? await Task.sleep(for: .seconds(2))
                await StressHarness.run(appState: appState, reportPath: path)
            }
        }
        // Debug aid: KMR_SNAPSHOT=/path/out.png [KMR_MODULE=<deep-link-id>]
        // renders this window to a PNG (no screen-recording permission needed).
        .task {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["KMR_SNAPSHOT"] else { return }
            if let id = env["KMR_MODULE"], let item = SidebarItem(deepLinkID: id) { appState.selectedSidebarItem = item }
            if env["KMR_DEMO"] == "scan" { demoScan = true }
            if env["KMR_DEMO"] == "results" {
                func items(_ dir: String, _ filter: (URL) -> Bool = { _ in true }) -> [FileItem] {
                    let base = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                    let urls = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                    return urls.filter(filter).prefix(25).map { u in
                        let size = UInt64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + UInt64(abs(u.path.hashValue % 900_000_000))
                        return FileItem(url: u, name: u.lastPathComponent, size: size, allocatedSize: size, isDirectory: true)
                    }
                }
                demoResults = [
                    ScanResult(category: .userCaches, items: items("~/Library/Caches")),
                    ScanResult(category: .userLogs, items: items("~/Library/Logs")),
                    ScanResult(category: .unusedDiskImages, items: items("~/Downloads")),
                ].filter { !$0.items.isEmpty }
                demoSelection = Set(demoResults.filter { $0.category != .unusedDiskImages }.flatMap(\.items).map(\.url))
            }
            if env["KMR_RUNSCAN"] != nil {   // debug: start the visible module's scan like ⌘R
                try? await Task.sleep(for: .seconds(1.5))
                appState.requestScanShortcut()
            }
            try? await Task.sleep(for: .seconds(Double(env["KMR_DELAY"] ?? "") ?? 4))
            guard let window = NSApp.windows.filter({ $0.isVisible && $0.frame.width > 500 }).max(by: { $0.frame.width < $1.frame.width }) else { return }
            // Window-server capture of our own window (includes Liquid Glass,
            // which the view hierarchy alone cannot render). Looked up
            // dynamically because the symbol is hidden from Swift.
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
               let image = unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                AutoCleaner.runIfDue(engine: appState.cleaningEngine)
                Task { if MCConstants.selfUpdatesEnabled, !selfUpdater.usesInAppUpdates { await updateCoordinator.runCheckIfDue() } }
            }
        }
        .alert(
            L10n.tr("发现新版本", "Update available", "Доступно обновление"),
            isPresented: Binding(
                get: { updateCoordinator.pendingUpdate != nil },
                set: { if !$0 { updateCoordinator.dismiss() } }
            ),
            presenting: updateCoordinator.pendingUpdate
        ) { pending in
            switch pending.action {
            case .brewCommand:
                Button(L10n.tr("复制升级命令", "Copy Upgrade Command", "Скопировать команду обновления")) {
                    updateCoordinator.performPrimaryAction()
                }
            case .openRelease:
                Button(L10n.tr("下载", "Download", "Загрузить")) {
                    updateCoordinator.performPrimaryAction()
                }
            }
            Button(L10n.tr("跳过此版本", "Skip This Version", "Пропустить эту версию")) {
                updateCoordinator.skip(pending.version)
            }
            Button(L10n.tr("稍后", "Later", "Позже"), role: .cancel) {
                updateCoordinator.dismiss()
            }
        } message: { pending in
            switch pending.action {
            case .brewCommand(let cmd):
                Text(L10n.tr(
                    "Mac Mop \(pending.version) 已发布。使用 Homebrew 升级：\n\(cmd)",
                    "Mac Mop \(pending.version) is available. Upgrade with Homebrew:\n\(cmd)",
                    "Доступна версия Mac Mop \(pending.version). Обновите через Homebrew:\n\(cmd)"))
            case .openRelease:
                Text(L10n.tr(
                    "Mac Mop \(pending.version) 已发布。",
                    "Mac Mop \(pending.version) is available.",
                    "Доступна версия Mac Mop \(pending.version)."))
            }
        }
    }

    /// Hides the system-drawn window title once the view lands in a window.
    /// The title string itself stays set (Mission Control, App Exposé, and
    /// VoiceOver still read it); only the toolbar's leading-edge rendering
    /// is suppressed, replaced by the centered principal toolbar item above.
    private struct TitleBarConfigurator: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { ConfiguringView() }

        // Re-assert on every SwiftUI update. SwiftUI's navigationTitle is
        // empty (it kept drawing a leading-edge title on macOS 26), so the
        // real window title lives here: Mission Control, App Exposé, the
        // Window menu, and VoiceOver read NSWindow.title; titleVisibility
        // keeps it out of the toolbar where the overlay draws instead.
        static func apply(to window: NSWindow?) {
            guard let window else { return }
            window.titleVisibility = .visible
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async { [weak nsView] in
                Self.apply(to: nsView?.window)
            }
        }

        private final class ConfiguringView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                DispatchQueue.main.async { [weak self] in
                    TitleBarConfigurator.apply(to: self?.window)
                }
            }
        }
    }

    @ViewBuilder
    private func moduleView(for item: SidebarItem) -> some View {
        switch item {
        case .smartScan:
            SmartScanView()
        case .systemJunk:
            SystemJunkView()
        case .mailAttachments:
            MailAttachmentsView()
        case .trashBins:
            TrashBinsView()
        case .diskHogs:
            DiskHogsView()
        case .projectJunk:
            ProjectJunkView()
        case .cleanHistory:
            CleanHistoryView()
        case .malwareRemoval:
            MalwareView()
        case .privacy:
            PrivacyView()
        case .browserExtensions:
            BrowserExtensionsView()
        case .wifiNetworks:
            WiFiNetworksView()
        case .appPermissions:
            AppPermissionsView()
        case .optimization:
            OptimizationView()
        case .maintenance:
            MaintenanceView()
        case .uninstaller:
            UninstallerView()
        case .unusedApps:
            UnusedAppsView()
        case .extensions:
            ExtensionsView()
        case .updater:
            UpdaterView()
        case .spaceLens:
            SpaceLensView()
        case .largeOldFiles:
            LargeOldFilesView()
        case .duplicates:
            DuplicatesView()
        case .storageExtras:
            StorageExtrasView()
        case .ports:
            PortsView()
        case .packages:
            PackagesView()
        case .applePrivacy:
            ApplePrivacyView()
        case .securityCheck:
            SecurityCheckView()
        case .persistence:
            PersistenceView()
        case .systemData:
            SystemDataView()
        case .shredder:
            ShredderView()
        case .settings:
            SettingsPageView()
        }
    }
}
