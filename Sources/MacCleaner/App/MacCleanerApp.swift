import SwiftUI
import AppKit
import UserNotifications
import MacCleanerKit

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("showMenuBarWidget") private var showMenuBarWidget = true
    @AppStorage("menuBarFirstLaunchDone") private var menuBarFirstLaunchDone = false
    @AppStorage(AppLanguage.defaultsKey, store: SharedAppState.defaults) private var appLanguageRaw = AppLanguage.system.rawValue
    @State private var showOnboarding = false
    /// Launched from the disk image: show the first-run installer instead.
    @State private var showInstaller = InstallLocation.isRunningFromDiskImage

    init() {
        AppLanguage.registerDefault(.system)
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .fallback
    }

    var body: some Scene {
        // A single Window (not WindowGroup) so reopening the app, or following
        // a maccleaner:// deeplink from the menu bar while a window already
        // exists, reuses the one window instead of spawning a second. Combined
        // with LSMultipleInstancesProhibited in Info.plist (which keeps macOS
        // from launching a second process), the user never ends up with two
        // copies of the main window.
        Window(MCConstants.appName, id: "main") {
            if showInstaller {
                InstallerView { showInstaller = false }
                    .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))
                    .environment(\.layoutDirection, appLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
                    .id(appLanguage.rawValue)
            } else {
                ContentView()
                    .environment(appState)
                    .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))
                    .id(appLanguage.rawValue)
                    .frame(minWidth: 800, minHeight: 550)
                    .sheet(isPresented: $showOnboarding) {
                        OnboardingView(isPresented: $showOnboarding)
                            .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))
                            .environment(\.layoutDirection, appLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
                            .id(appLanguage.rawValue)
                    }
                    .onAppear {
                        if !hasCompletedOnboarding {
                            showOnboarding = true
                            hasCompletedOnboarding = true
                        }
                        syncMenuBarOnLaunch()
                        UninstallServiceProvider.shared.attach { appState.openUninstaller(forAppPath: $0) }
                    }
                    .onOpenURL { url in
                        // Expect exactly maccleaner://module/<slug> — one path
                        // segment (pathComponents is ["/", "<slug>"]). Reject
                        // malformed multi-segment URLs rather than guessing.
                        guard url.scheme == "maccleaner", url.host == "module",
                              url.pathComponents.count == 2,
                              let id = url.pathComponents.last,
                              let item = SidebarItem(deepLinkID: id) else { return }
                        appState.selectedSidebarItem = item
                    }
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 620)
        // Keep the standard "Settings…" menu item + Cmd-comma, but route
        // them to the in-app page (the separate Settings window is gone).
        .commands {
            CommandGroup(after: .appInfo) {
                if MCConstants.selfUpdatesEnabled, SelfUpdateController.shared.usesInAppUpdates {
                    Button(L10n.tr("检查更新…", "Check for Updates…", "Проверить обновления…")) {
                        SelfUpdateController.shared.checkForUpdates()
                    }
                    .disabled(!SelfUpdateController.shared.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("设置…", "Settings…", "Настройки…")) {
                    appState.selectedSidebarItem = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // File › New Scan ⌘R / Clean ⌘K, Edit › Find ⌘F, View › Back ⌘[ /
            // Forward ⌘] and ⌘1…⌘9, Help (App/AppNavigation.swift).
            AppNavigationCommands(appState: appState)
        }
    }

    /// First-launch default: ON (per product decision). On every launch
    /// we re-sync the SMAppService state with the preference so the
    /// truth of "is the helper actually running" matches the toggle —
    /// macOS occasionally drops registrations after updates, especially
    /// when the helper bundle path changes (which it doesn't here, but
    /// re-registering is cheap and idempotent).
    private func syncMenuBarOnLaunch() {
        if !menuBarFirstLaunchDone {
            menuBarFirstLaunchDone = true
            // showMenuBarWidget already defaults to true; setEnabled is
            // idempotent if already registered.
        }
        // Async: the SMAppService XPC round-trip must not block app launch.
        Task { await MenuBarLauncher.shared.setEnabled(showMenuBarWidget) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only a prepared installer needs update-specific Quit coordination;
        // ordinary Quit retains the application's existing behavior.
        return SelfUpdateController.shared.prepareForTermination(sender)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch completes so a click that launched the app is
        // still delivered to didReceive.
        // UNUserNotificationCenter throws outside an .app bundle (dev builds run from .build).
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceManager.applyStored()
        RealtimeProtection.shared.startIfEnabled()
        if MCConstants.selfUpdatesEnabled { SelfUpdateController.shared.start() }
        MenuBarLauncher.shared.startWatchingHelperTermination()
        // Finder › Services › "Uninstall with Mac Mop" (NSServices in Info.plist).
        NSApp.servicesProvider = UninstallServiceProvider.shared
        InstallerEject.handleLaunchArguments()   // just installed from the disk image: eject it
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// A click on a notification carrying a deep link (real-time protection
    /// alerts) opens that module.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = response.notification.request.content.userInfo[RealtimeProtection.urlUserInfoKey] as? String
        else { return }
        await MainActor.run { RealtimeProtection.open(deepLink: link) }
    }
}
