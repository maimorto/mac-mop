import Foundation
import AppKit
import UserNotifications
import MacCleanerKit

/// Scheduled cleanup limited to caches that rebuild themselves. Runs when the
/// app launches or becomes active and the interval has passed. Skips files
/// touched in the last three days and anything belonging to a running app.
/// Everything goes to the Trash and into Cleanup History.
@MainActor
enum AutoCleaner {
    static let intervalKey = "autoCleanIntervalDays"   // 0 = off
    static let lastRunKey = "autoCleanLastRun"
    static let lastBytesKey = "autoCleanLastBytes"
    private static var running = false

    static var intervalDays: Int { UserDefaults.standard.integer(forKey: intervalKey) }

    static var lastRun: Date? { UserDefaults.standard.object(forKey: lastRunKey) as? Date }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func runIfDue(engine: CleaningEngine) {
        let days = intervalDays
        guard days > 0, !running else { return }
        if let last = lastRun, Date().timeIntervalSince(last) < Double(days) * 86_400 { return }
        running = true
        Task {
            let freed = await run(engine: engine)
            UserDefaults.standard.set(Date(), forKey: lastRunKey)
            UserDefaults.standard.set(Double(freed), forKey: lastBytesKey)
            running = false
            if freed > 0 { notify(freed) }
        }
    }

    private static func run(engine: CleaningEngine) async -> UInt64 {
        let module = SystemJunkModule()
        let scan = await module.scanReportingPermissions(categories: [UserCacheCategory(), PackageManagerCachesCategory()])
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        var selected = Set<URL>()
        for result in scan.results {
            for item in result.items {
                let path = item.url.path
                if running.contains(where: { path.contains($0) }) { continue }
                if let m = item.modificationDate, m > cutoff { continue }
                selected.insert(item.url)
            }
        }
        guard !selected.isEmpty else { return 0 }
        let result = await CleanActions.executeUserClean(results: scan.results, selectedItems: selected, engine: engine)
        return result.freedBytes
    }

    private static func notify(_ bytes: UInt64) {
        let content = UNMutableNotificationContent()
        content.title = KMR.t("Pulizia automatica completata", "Automatic cleanup done")
        content.body = KMR.t("\(FileSizeFormatter.format(bytes)) di cache spostati nel Cestino.",
                             "\(FileSizeFormatter.format(bytes)) of caches moved to the Trash.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autoclean", content: content, trigger: nil))
    }
}
