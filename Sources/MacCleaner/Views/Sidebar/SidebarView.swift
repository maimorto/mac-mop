import SwiftUI
import MacCleanerKit

public enum SidebarItem: String, CaseIterable, Identifiable {
    // Main
    case smartScan = "智能扫描"

    // Cleanup
    case systemJunk = "系统垃圾"
    case mailAttachments = "邮件附件"
    case trashBins = "废纸篓"

    // Protection
    case malwareRemoval = "恶意软件清理"
    case privacy = "隐私清理"
    case wifiNetworks = "已保存的 Wi-Fi"
    case appPermissions = "权限总览"

    // Performance
    case optimization = "优化"
    case maintenance = "维护"

    // Applications
    case uninstaller = "卸载器"
    case unusedApps = "未使用的应用"
    case extensions = "扩展"
    case updater = "应用更新"

    // Files
    case spaceLens = "空间透视"
    case largeOldFiles = "大文件与旧文件"
    case duplicates = "重复文件"
    case shredder = "文件粉碎"
    case storageExtras = "额外空间"
    case browserExtensions = "浏览器扩展"
    case ports = "网络端口"
    case packages = "安装包"
    case applePrivacy = "Apple 隐私"
    case securityCheck = "安全检查"
    case persistence = "启动项检查"
    case systemData = "系统数据"

    // Cleanup, declared last so the ⌘1…⌘9 shortcuts above keep their digits
    case diskHogs = "开发者磁盘占用"
    // Listed under Cleanup (see `section`); declared last so it doesn't
    // shift the Cmd+1...9 shortcuts of the items above.
    case projectJunk = "项目垃圾"
    // Cleanup (declared last so the ⌘1-⌘9 shortcuts, which follow
    // declaration order, keep pointing at the same modules)
    case cleanHistory = "清理历史"

    // Footer (pinned below the list, not rendered in any section)
    case settings = "设置"

    public var id: String { rawValue }
    public var title: String { L10n.tr(rawValue) }

    /// Stable slug used in `maccleaner://module/<id>` deep links.
    public var deepLinkID: String {
        switch self {
        case .smartScan: "smart-scan"
        case .systemJunk: "system-junk"
        case .mailAttachments: "mail-attachments"
        case .trashBins: "trash-bins"
        case .malwareRemoval: "malware"
        case .privacy: "privacy"
        case .wifiNetworks: "wifi-networks"
        case .appPermissions: "app-permissions"
        case .optimization: "optimization"
        case .maintenance: "maintenance"
        case .uninstaller: "uninstaller"
        case .extensions: "extensions"
        case .updater: "updater"
        case .spaceLens: "space-lens"
        case .largeOldFiles: "large-old-files"
        case .duplicates: "duplicates"
        case .shredder: "shredder"
        case .storageExtras: "storage-extras"
        case .browserExtensions: "browser-extensions"
        case .diskHogs: "disk-hogs"
        case .projectJunk: "project-junk"
        case .cleanHistory: "clean-history"
        case .unusedApps: "unused-apps"
        case .systemData: "system-data"
        case .persistence: "persistence"
        case .securityCheck: "security-check"
        case .applePrivacy: "apple-privacy"
        case .packages: "packages"
        case .ports: "ports"
        case .settings: "settings"
        }
    }

    public init?(deepLinkID: String) {
        guard let match = Self.allCases.first(where: { $0.deepLinkID == deepLinkID }) else { return nil }
        self = match
    }

    public var icon: String {
        switch self {
        case .smartScan: "house"
        case .systemJunk: "trash.circle"
        case .mailAttachments: "paperclip.circle"
        case .trashBins: "trash"
        case .malwareRemoval: "shield.lefthalf.filled"
        case .privacy: "hand.raised.fill"
        case .wifiNetworks: "wifi"
        case .appPermissions: "lock.shield"
        case .optimization: "gauge.with.dots.needle.67percent"
        case .maintenance: "wrench.and.screwdriver"
        case .uninstaller: "xmark.app"
        case .extensions: "puzzlepiece.extension"
        case .updater: "arrow.triangle.2.circlepath"
        case .spaceLens: "chart.pie"
        case .largeOldFiles: "doc.richtext"
        case .duplicates: "plus.square.on.square"
        case .shredder: "scissors"
        case .storageExtras: "externaldrive.badge.plus"
        case .browserExtensions: "puzzlepiece"
        case .diskHogs: "externaldrive.badge.xmark"
        case .projectJunk: "shippingbox"
        case .cleanHistory: "arrow.uturn.backward.circle"
        case .unusedApps: "app.badge.checkmark"
        case .systemData: "internaldrive"
        case .persistence: "bolt.badge.clock"
        case .securityCheck: "checkmark.shield"
        case .applePrivacy: "eye.slash"
        case .packages: "shippingbox"
        case .ports: "network"
        case .settings: "gearshape"
        }
    }

    public var theme: ModuleTheme {
        switch self {
        case .smartScan: .smartScan
        case .systemJunk, .mailAttachments, .trashBins, .projectJunk, .diskHogs, .cleanHistory: .cleanup
        case .malwareRemoval, .privacy, .browserExtensions, .wifiNetworks, .appPermissions,
             .persistence, .securityCheck, .applePrivacy: .protection
        case .optimization, .maintenance, .ports: .performance
        case .uninstaller, .unusedApps, .extensions, .updater, .packages: .applications
        case .spaceLens, .largeOldFiles, .duplicates, .shredder, .storageExtras, .systemData: .files
        case .settings: .settings
        }
    }

    public var section: SidebarSection {
        switch self {
        case .smartScan: .main
        case .systemJunk, .mailAttachments, .trashBins, .projectJunk, .diskHogs, .cleanHistory: .cleanup
        case .malwareRemoval, .privacy, .browserExtensions, .wifiNetworks, .appPermissions,
             .persistence, .securityCheck, .applePrivacy: .protection
        case .optimization, .maintenance, .ports: .performance
        case .uninstaller, .unusedApps, .extensions, .updater, .packages: .applications
        case .spaceLens, .largeOldFiles, .duplicates, .shredder, .storageExtras, .systemData: .files
        case .settings: .main
        }
    }

    /// Modules jumpable via ⌘1…⌘9 (Settings excluded). Order matches
    /// `CaseIterable` / sidebar listing.
    public static var keyboardShortcutItems: [SidebarItem] {
        Array(allCases.filter { $0 != .settings }.prefix(9))
    }

    /// 1-based digit → sidebar item for ⌘1…⌘9. Returns nil out of range.
    public static func item(forShortcutDigit digit: Int) -> SidebarItem? {
        let items = keyboardShortcutItems
        guard digit >= 1, digit <= items.count else { return nil }
        return items[digit - 1]
    }
}

public enum SidebarSection: String, CaseIterable, Identifiable {
    case main = ""
    case cleanup = "清理"
    case protection = "防护"
    case performance = "性能"
    case applications = "应用"
    case files = "文件"

    public var id: String { rawValue }
    public var title: String { L10n.tr(rawValue) }

    public var items: [SidebarItem] {
        // .settings is pinned to the footer; it never renders inside a section.
        SidebarItem.allCases.filter { $0.section == self && $0 != .settings }
    }
}

public struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: SidebarItem?
    @State private var query = ""
    /// Highlighted search result (opens on click / arrow keys).
    @State private var searchSelection: String?
    @State private var searchFocused = false
    /// Last module shown in each group, so returning to a group restores it.
    @State private var lastItem: [NavGroup: SidebarItem] = [:]

    public init(selection: Binding<SidebarItem?>) {
        self._selection = selection
    }

    private var groupSelection: Binding<NavGroup?> {
        Binding(
            get: { selection?.group },
            set: { group in
                guard let group else { return }
                selection = lastItem[group] ?? group.items.first
            }
        )
    }

    /// Modules and settings matching the query (titles, tabs, keywords in
    /// several languages), best match first.
    private var matches: [SidebarSearchHit] { SidebarSearch.hits(for: query) }

    private func open(_ hit: SidebarSearchHit) {
        switch hit.target {
        case .module(let item): selection = item
        case .settings(let pane): appState.openSettings(pane)
        }
    }

    public var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                List(selection: groupSelection) {
                    ForEach(NavGroup.sidebarGroups) { group in
                        HStack {
                            Label {
                                Text(group.title)
                            } icon: {
                                // The macOS icons, like System Settings' sidebar.
                                GroupIcon(group: group, size: 20)
                            }
                            Spacer(minLength: 4)
                            ScanStatusMark(state: ScanActivity.shared.state(group))
                        }
                        .tag(group)
                    }
                }
            } else {
                let hits = matches
                List(selection: $searchSelection) {
                    if hits.isEmpty {
                        Text(KMR.t("Nessun risultato per «\(query)»", "No results for “\(query)”"))
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(hits) { hit in
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(hit.title).lineLimit(2)
                                if !hit.subtitle.isEmpty {
                                    Text(hit.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            switch hit.target {
                            case .module(let item): ModuleIcon(item: item, size: 20)
                            case .settings: GroupIcon(group: .settings, size: 20)
                            }
                        }
                        .tag(hit.id)
                    }
                }
                .onChange(of: searchSelection) { _, id in
                    if let id, let hit = hits.first(where: { $0.id == id }) { open(hit) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: Text(KMR.t("Cerca", "Search")))
        // Return in the field opens the best match, like System Settings.
        .onSubmit(of: .search) {
            if let first = matches.first { searchSelection = first.id; open(first) }
        }
        .onChange(of: query) { _, _ in searchSelection = nil }
        // Debug aid for screenshots: KMR_SEARCH=<text> pre-fills the field.
        .task { if let q = ProcessInfo.processInfo.environment["KMR_SEARCH"] { query = q } }
        .modifier(SidebarSearchFocus(focused: $searchFocused))
        .onChange(of: appState.sidebarSearchFocusRequest) { _, _ in searchFocused = true }
        // The footer is a safe-area inset (not a sibling in a VStack) so the
        // list stays the sidebar's scroll view and gets the system scroll-edge
        // effect under the window controls.
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsFooter }
        .onChange(of: selection, initial: true) { _, item in
            if let item { lastItem[item.group] = item }
        }
        .frame(
            minWidth: [.de, .it].contains(AppLanguage.current.resolved) ? 220 : 190,
            idealWidth: 230
        )
    }

    private var settingsFooter: some View {
        Button {
            selection = .settings
        } label: {
            Label {
                Text(L10n.tr("设置", "Settings", "Настройки"))
            } icon: {
                GroupIcon(group: .settings, size: 20)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selection == .settings ? Color.primary.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityLabel(L10n.tr("设置", "Settings", "Настройки"))
    }
}

/// ⌘F → the sidebar search field (macOS 15+ API; older systems fall back to
/// AppKit focusing in `AppState.focusSearch`).
private struct SidebarSearchFocus: ViewModifier {
    @Binding var focused: Bool
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($isFocused)
                .onChange(of: focused) { _, on in
                    if on { isFocused = true; focused = false }
                }
        } else {
            content
        }
    }
}
