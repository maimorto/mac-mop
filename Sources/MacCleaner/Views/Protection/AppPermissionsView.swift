import AppKit
import SwiftUI
import MacCleanerKit

struct AppPermissionsView: View {
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @State private var snapshot = AppPermissionsSnapshot(grants: [], listing: .loaded)
    @State private var isLoading = true
    private let client = AppPermissionsClient.live()

    private var apps: [AppPermissionApp] {
        AppPermissionOverview.apps(from: snapshot.grants)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("权限总览", "Permissions", "Обзор разрешений"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr(
                        "按应用查看持有哪些隐私权限。这是只读列表——按钮会打开系统设置。本应用无法关闭权限。",
                        "See which privacy grants each app holds. This list is read-only — buttons open System Settings. Mac Mop cannot turn a permission off.",
                        "Смотрите, какие разрешения есть у каждого приложения. Список только для чтения — кнопки открывают Системные настройки. Это приложение не может выключить разрешение."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label(L10n.tr("刷新", "Refresh", "Обновить"), systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help(L10n.tr("重新读取权限列表", "Reload the permission list", "Заново прочитать список разрешений"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                            .controlSize(.large)
                            .tint(.primary)
                        Text(L10n.tr("正在读取权限…", "Reading permissions…", "Чтение разрешений…"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    list
                }
            }
            .kmrGroupedBox()
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task { await reload() }
        .respondsToModuleShortcuts(onScan: { Task { await reload() } }, canScan: !isLoading)
    }

    private var list: some View {
        List {
            if snapshot.listing != .loaded {
                listingBanner
            }

            if snapshot.listing == .loaded {
                if apps.isEmpty {
                    Text(L10n.tr(
                        "未列出任何应用。",
                        "No apps listed.",
                        "Приложения не показаны."
                    ))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(apps) { app in
                        appSection(app)
                    }
                }
            }

            settingsJumpSection
        }
        .listStyle(.inset)
    }

    private func appSection(_ app: AppPermissionApp) -> some View {
        Section {
            ForEach(app.grants) { grant in
                grantRow(grant)
            }
        } header: {
            HStack(spacing: 8) {
                Image(nsImage: icon(for: app))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(displayName(for: app))
                    .font(.body.weight(.semibold))
                Spacer()
                if isUninstalled(app) {
                    Text(KMR.t("App non più installata", "App no longer installed"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KMR.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(KMR.orange.opacity(0.14), in: Capsule())
                }
                Text(grantCountLabel(app.grants.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func grantRow(_ grant: AppPermissionGrant) -> some View {
        HStack(spacing: 10) {
            Image(systemName: permissionIcon(grant.permission))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(permissionTitle(grant.permission))
                        .font(.body.weight(.medium))
                    if grant.isLimited {
                        Text(L10n.tr("受限", "Limited", "Ограничено"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let target = grant.indirectObjectIdentifier, !target.isEmpty {
                    Text(L10n.tr("控制 \(target)", "Controls \(target)", "Управляет \(target)"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(L10n.tr("在系统设置中打开", "Open in System Settings", "Открыть в Системных настройках")) {
                client.openSettings(for: grant.permission)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var settingsJumpSection: some View {
        Section {
            ForEach(PrivacyPermission.allCases) { permission in
                Button {
                    client.openSettings(for: permission)
                } label: {
                    HStack {
                        Label(permissionTitle(permission), systemImage: permissionIcon(permission))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(L10n.tr("在系统设置中打开", "Open in System Settings", "Открыть в Системных настройках"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(L10n.tr("在系统设置中打开类别", "Open a category in System Settings", "Открыть категорию в Системных настройках"))
                .font(.body.weight(.semibold))
        } footer: {
            Text(L10n.tr(
                "更改权限只能在系统设置中完成。",
                "Changing a grant can only be done in System Settings.",
                "Изменить разрешение можно только в Системных настройках."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var listingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                snapshot.listing == .needsFullDiskAccess
                    ? L10n.tr("需要完全磁盘访问权限才能列出应用", "Full Disk Access needed to list apps", "Чтобы показать приложения, нужен полный доступ к диску")
                    : L10n.tr("无法读取权限数据库", "Couldn't read the permission database", "Не удалось прочитать базу разрешений")
            )
            .font(.body.weight(.semibold))
            Text(
                snapshot.listing == .needsFullDiskAccess
                    ? L10n.tr(
                        "macOS 正在阻止按应用汇总。请为 \(MCConstants.appName) 授予完全磁盘访问权限，然后刷新。下方按钮仍会打开系统设置。",
                        "macOS is blocking the by-app overview. Grant \(MCConstants.appName) Full Disk Access, then refresh. The buttons below still open System Settings.",
                        "macOS блокирует сводку по приложениям. Предоставьте \(MCConstants.appName) полный доступ к диску и обновите. Кнопки ниже по-прежнему открывают Системные настройки."
                    )
                    : L10n.tr(
                        "无法列出哪些应用持有哪些权限。仍可通过下方按钮打开系统设置。",
                        "This app can't list which apps hold which grants. You can still open System Settings with the buttons below.",
                        "Не получается показать, какие приложения какими разрешениями владеют. По-прежнему можно открыть Системные настройки кнопками ниже."
                    )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if snapshot.listing == .needsFullDiskAccess {
                Button(L10n.tr("在系统设置中打开", "Open in System Settings", "Открыть в Системных настройках")) {
                    client.openFullDiskAccessSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private func reload() async {
        isLoading = true
        snapshot = await client.load()
        isLoading = false
    }

    private func grantCountLabel(_ count: Int) -> String {
        L10n.tr(
            "\(count) 项权限",
            KMR.t(count == 1 ? "1 permesso" : "\(count) permessi", count == 1 ? "1 permission" : "\(count) permissions"),
            "\(count) \(L10n.russianPlural(count, one: "разрешение", few: "разрешения", many: "разрешений"))"
        )
    }

    private func permissionTitle(_ permission: PrivacyPermission) -> String {
        switch permission {
        case .camera: L10n.tr("相机", "Camera", "Камера")
        case .microphone: L10n.tr("麦克风", "Microphone", "Микрофон")
        case .fullDiskAccess: L10n.tr("完全磁盘访问权限", "Full Disk Access", "Полный доступ к диску")
        case .screenRecording: L10n.tr("屏幕录制", "Screen Recording", "Запись экрана")
        case .automation: L10n.tr("自动化", "Automation", "Автоматизация")
        }
    }

    private func permissionIcon(_ permission: PrivacyPermission) -> String {
        switch permission {
        case .camera: "web.camera"
        case .microphone: "mic"
        case .fullDiskAccess: "externaldrive"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .automation: "gearshape.2"
        }
    }

    private func displayName(for app: AppPermissionApp) -> String {
        if app.clientIsPath {
            return URL(filePath: app.client).deletingPathExtension().lastPathComponent
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.client) {
            return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        }
        // Not installed any more: "com.runningwithcrayons.Alfred" → "Alfred".
        let last = app.client.split(separator: ".").last.map(String.init) ?? app.client
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private func isUninstalled(_ app: AppPermissionApp) -> Bool {
        !app.clientIsPath && NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.client) == nil
    }

    private func icon(for app: AppPermissionApp) -> NSImage {
        if app.clientIsPath {
            return AppIconCache.icon(forPath: app.client)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.client) {
            return AppIconCache.icon(forPath: url.path(percentEncoded: false))
        }
        return NSWorkspace.shared.icon(forFileType: "app")
    }
}
