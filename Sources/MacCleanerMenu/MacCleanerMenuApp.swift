import SwiftUI
import AppKit
import MacCleanerKit

@main
struct MacCleanerMenuApp: App {
    init() {
        AppLanguage.registerDefault(.system)
        // Single-instance enforcement. macOS does NOT auto-deduplicate
        // LSUIElement apps by bundle id the way it does for regular apps,
        // and we have two launch paths (SMAppService + NSWorkspace). Keep
        // the oldest copy; never `exit(0)` from every sibling — that took
        // the extra down when both copies started at once.
        // Only enforce when we have a real bundle id (i.e. running from
        // the .app). Under `swift run` the bare executable has no bundle
        // id, and matching against other nil-bundle processes would make
        // the dev build exit immediately.
        if let myBundleID = Bundle.main.bundleIdentifier, ProcessInfo.processInfo.environment["KMR_MENU_SNAPSHOT"] == nil, ProcessInfo.processInfo.environment["KMR_MENU_SELFTEST"] == nil {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let running = NSWorkspace.shared.runningApplications
            let me = running.first { $0.processIdentifier == myPID }
            let siblings = running.compactMap { app -> MenuBarInstance? in
                guard app.bundleIdentifier == myBundleID,
                      app.processIdentifier != myPID else { return nil }
                return MenuBarInstance(pid: app.processIdentifier, launchDate: app.launchDate)
            }
            // Keep-one, never both-exit. The old any-sibling check killed
            // every copy when SMAppService and NSWorkspace raced
            //.
            if MenuBarInstancePolicy.shouldExitAsDuplicate(
                selfPID: myPID,
                selfLaunchDate: me?.launchDate,
                siblings: siblings
            ) {
                exit(0)
            }
        }
    }

    // The menu bar is driven from AppKit (StatusBarController, started by the
    // app delegate together with MenuStatsModel's continuous polling): one
    // NSStatusItem per module and a popup anchored under the clicked button,
    // like Stats. SwiftUI MenuBarExtra opened its window late and, on some
    // setups, away from the button. The App only needs a scene that opens no
    // window.
    @NSApplicationDelegateAdaptor(MenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
