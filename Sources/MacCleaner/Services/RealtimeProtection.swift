import Foundation
import AppKit
import UserNotifications
import MacCleanerKit

/// Owns the app's `RealTimeMalwareMonitor`: starts it at launch when the
/// "Protezione in tempo reale" setting is on, stops/starts it when the
/// setting changes, and turns alerts into user notifications that open the
/// Malware module when clicked.
@MainActor
final class RealtimeProtection {
    static let shared = RealtimeProtection()
    nonisolated static let enabledKey = "realtimeProtectionEnabled"
    nonisolated static let deepLink = "maccleaner://module/malware"
    nonisolated static let urlUserInfoKey = "url"

    let monitor = RealTimeMalwareMonitor()
    private init() {
        // Behaviour engine (persistence audit + dropped payloads). Appended,
        // so other analyzers (YARA) can register their own checks too.
        monitor.extraChecks.append { path in MalwareModule.realtimeBehaviourAlert(path: path) }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Called once at launch. Skipped in the snapshot debug mode.
    func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["KMR_SNAPSHOT"] == nil else { return }
        setEnabled(Self.isEnabled)
        // Weekly Balanced scan when the last one is older than 7 days.
        ScheduledMalwareScan.runIfDue()
        // The "Cosa ha fatto XProtect" report is loaded when the Malware page
        // opens: warming it 30 s after launch parsed a week of unified log on
        // every start (100% CPU for seconds) even when nobody looked at it.
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else { monitor.stop(); return }
        guard !monitor.running else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.start { alert in
            Task { @MainActor in RealtimeProtection.notify(alert) }
        }
    }

    private static func notify(_ alert: RealtimeMalwareAlert) {
        let content = UNMutableNotificationContent()
        content.title = KMR.t("Possibile minaccia rilevata", "Possible threat detected")
        content.subtitle = alert.name
        content.body = alert.reason + "\n" + (alert.path as NSString).abbreviatingWithTildeInPath
        content.sound = .default
        content.threadIdentifier = "malware"
        content.userInfo = [urlUserInfoKey: deepLink]
        let request = UNNotificationRequest(identifier: "malware-" + String(alert.dedupeKey.hashValue),
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Opens a notification's deep link in this very copy of the app (not
    /// whichever copy LaunchServices would pick for the URL scheme).
    static func open(deepLink string: String) {
        guard let url = URL(string: string), url.scheme == "maccleaner" else { return }
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
