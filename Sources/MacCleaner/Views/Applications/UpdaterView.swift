import SwiftUI
import AppKit
import MacCleanerKit

struct UpdaterView: View {
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @State private var updates: [AppUpdateChecker.AppUpdate] = []
    @State private var isChecking = false
    @State private var hasChecked = false
    @State private var apps: [AppInfo] = []
    /// Update rows currently mid-action — drives the per-row spinner + disable.
    @State private var updatingIDs: Set<UUID> = []

    private let discovery = AppDiscovery()
    private let checker = AppUpdateChecker()

    var body: some View {
        VStack(spacing: 0) {
            AppsPageHeader(
                title: L10n.tr("应用更新", "Updater", "Обновления"),
                subtitle: L10n.tr("检查可用的应用更新", "Check for available app updates", "Проверка доступных обновлений приложений")
            ) {
                if !isChecking {
                    Button(hasChecked ? L10n.tr("重新检查", "Recheck", "Проверить снова") : L10n.tr("检查更新", "Check for Updates", "Проверить обновления")) {
                        checkUpdates()
                    }
                    .buttonStyle(SuperEllipseButtonStyle(
                        gradient: ModuleTheme.applications.buttonGradient,
                        size: CGSize(width: hasChecked ? 100 : 160, height: 34)
                    ))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if isChecking {
                Spacer()
                ScanProgressRing(progress: 0.5, phase: L10n.tr("正在检查更新...", "Checking for updates...", "Проверка обновлений..."), theme: .applications)
                Spacer()
            } else if hasChecked && updates.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.primary.opacity(0.8))
                    Text(L10n.tr("所有应用均为最新", "All apps are up to date", "Все приложения обновлены"))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if !updates.isEmpty {
                List {
                    ForEach(updates) { update in
                        HStack {
                            Image(nsImage: AppIconCache.icon(forPath: update.app.path.path(percentEncoded: false)))
                                .resizable()
                                .frame(width: 26, height: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(update.app.name)
                                    .font(.body.weight(.medium))
                                Text("\(update.currentVersion) → \(update.availableVersion ?? "?")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if updatingIDs.contains(update.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 60)
                            } else {
                                Button(L10n.tr("更新", "Update", "Обновить")) { startUpdate(update) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .kmrGroupedBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            } else {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("点击上方按钮检查更新", "Click above to check for updates", "Нажмите кнопку выше, чтобы проверить обновления"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func checkUpdates() {
        isChecking = true
        Task {
            apps = await discovery.discoverApps()
            updates = await checker.checkForUpdates(apps: apps)
            isChecking = false
            hasChecked = true
        }
    }

    /// Flip the row to a spinner + disable it the instant Update is tapped,
    /// fire the action, then hold the indicator briefly so the user clearly
    /// sees that the tap registered and something is happening.
    private func startUpdate(_ update: AppUpdateChecker.AppUpdate) {
        guard !updatingIDs.contains(update.id) else { return }
        updatingIDs.insert(update.id)
        Task {
            UpdaterActions.perform(update)
            try? await Task.sleep(for: .milliseconds(1200))
            updatingIDs.remove(update.id)
        }
    }
}
