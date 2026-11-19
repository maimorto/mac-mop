import SwiftUI
import MacCleanerKit

@Observable
public final class AppState {
    var selectedSidebarItem: SidebarItem? = .smartScan {
        didSet {
            // Back/Forward history (see AppNavigation.swift). Moves made by
            // Back/Forward themselves are not recorded as new visits.
            guard !isTraversingHistory, let item = selectedSidebarItem, item != oldValue else { return }
            pageHistory.visit(item)
        }
    }
    /// Pages visited, for the toolbar's Back/Forward buttons and ⌘[ / ⌘].
    var pageHistory = NavigationHistory<SidebarItem>(current: .smartScan)
    @ObservationIgnored var isTraversingHistory = false
    /// Drill-downs the visible pages registered (done screen → results,
    /// folder → parent…). Back/Forward use these before the page history.
    var pageNavigation: [SidebarItem: [PageNavigationEntry]] = [:]
    /// Short confirmation shown at the bottom of the window (Undo, restore…).
    var toast: AppToast?
    /// Bumped by ⌘F when no page field takes focus: the sidebar search does.
    var sidebarSearchFocusRequest = 0
    /// Settings pane a search result asked to open.
    var requestedSettingsPane: SettingsPane?
    /// Last clean that went to the Trash, for Edit › Undo (⌘Z).
    var lastUndoableClean: CleanHistorySession?
    var scanCoordinator = ScanCoordinator()
    let cleaningEngine = CleaningEngine()
    let scanResultsStore = ScanResultsStore()

    /// Path of an app the Unused Apps module asked Uninstaller to open.
    var pendingUninstallerAppPath: String?

    /// Bumped by the global ⌘R command; selected module views observe and scan.
    private(set) var scanShortcutNonce: UInt64 = 0
    /// Bumped by the global ⌘K command; selected module views observe and clean.
    private(set) var cleanShortcutNonce: UInt64 = 0

    func requestScanShortcut() { scanShortcutNonce &+= 1 }
    func requestCleanShortcut() { cleanShortcutNonce &+= 1 }

    func openUninstaller(forAppPath path: String) {
        pendingUninstallerAppPath = path
        selectedSidebarItem = .uninstaller
    }

    init() {
        registerModules()
        // 30-day log retention. Runs once at app launch. Best-effort —
        // a failure here doesn't surface to the user; the unpruned log
        // is still queryable and we'll retry on the next launch.
        // Async so a slow filesystem doesn't delay window appearance.
        Task.detached(priority: .background) {
            CleanLogManager.pruneOldEntries()
        }
        // Discover installed languages off the main thread so Settings shows
        // the user's actual languages; refreshed on every launch so newly
        // added languages appear.
        Task.detached(priority: .background) {
            let found = LanguageScanner().discoverLproj(in: LanguageScanner.defaultRoots)
            await MainActor.run { LanguagePreferences.discoveredLproj = found }
        }
    }

    private func registerModules() {
        scanCoordinator.registerModules([
            SystemJunkModule(),
            MailAttachmentsModule(),
            TrashBinsModule(),
            // Smart Scan stays light: installed apps' executables are only
            // hashed from the Malware Removal screen.
            MalwareModule(hashesApplications: false),
            PrivacyModule(),
            OptimizationModule(),
            MaintenanceModule(),
            UninstallerModule(),
            UpdaterModule(),
            SpaceLensModule(),
            LargeOldFilesModule(),
            DuplicatesModule(),
            ShredderModule(),
        ])
    }

}
