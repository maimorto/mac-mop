import SwiftUI
import MacCleanerKit

/// Top-level destinations in the sidebar. Each groups related modules that
/// appear as tabs in the toolbar, the way Apple's own apps group views.
enum NavGroup: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, spaceLens, applications, protection, performance, files, settings

    var id: String { rawValue }

    var items: [SidebarItem] {
        switch self {
        case .overview: [.smartScan]
        case .cleanup: [.systemJunk, .mailAttachments, .trashBins, .projectJunk, .diskHogs, .cleanHistory]
        case .spaceLens: [.spaceLens, .systemData, .storageExtras]
        case .applications: [.uninstaller, .unusedApps, .extensions, .packages, .updater]
        case .protection: [.malwareRemoval, .securityCheck, .persistence, .privacy, .applePrivacy, .browserExtensions, .wifiNetworks, .appPermissions]
        case .performance: [.optimization, .maintenance, .ports]
        case .files: [.duplicates, .largeOldFiles, .shredder]
        case .settings: [.settings]
        }
    }

    static var sidebarGroups: [NavGroup] { allCases.filter { $0 != .settings } }

    var title: String {
        switch self {
        case .overview: KMR.t("Panoramica", "Overview")
        case .cleanup: KMR.t("Pulizia", "Cleanup")
        case .spaceLens: "Space Lens"
        case .applications: KMR.t("Applicazioni", "Applications")
        case .protection: KMR.t("Protezione", "Protection")
        case .performance: KMR.t("Prestazioni", "Performance")
        case .files: KMR.t("File", "Files")
        case .settings: KMR.t("Impostazioni", "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house.fill"
        case .cleanup: "sparkles"
        case .spaceLens: "chart.pie.fill"
        case .applications: "square.grid.2x2.fill"
        case .protection: "hand.raised.fill"
        case .performance: "gauge.with.needle.fill"
        case .files: "folder.fill"
        case .settings: "gearshape.fill"
        }
    }

    var tint: Color {
        let c: NSColor = switch self {
        case .overview: .systemBlue
        case .cleanup: .systemOrange
        case .spaceLens: .systemPurple
        case .applications: .systemIndigo
        case .protection: .systemGreen
        case .performance: .systemPink
        case .files: .systemTeal
        case .settings: .systemGray
        }
        return Color(nsColor: c)
    }
}

extension SidebarItem {
    var group: NavGroup {
        NavGroup.allCases.first { $0.items.contains(self) } ?? .overview
    }

    /// Short label used for the toolbar tab.
    var tabTitle: String {
        switch self {
        case .systemJunk: KMR.t("Sistema", "System")
        case .mailAttachments: "Mail"
        case .trashBins: KMR.t("Cestini", "Trash")
        case .projectJunk: KMR.t("Progetti", "Projects")
        case .diskHogs: KMR.t("Sviluppo", "Developer")
        case .cleanHistory: KMR.t("Cronologia", "History")
        case .uninstaller: KMR.t("Disinstalla", "Uninstall")
        case .unusedApps: KMR.t("Inutilizzate", "Unused")
        case .extensions: KMR.t("Estensioni", "Extensions")
        case .updater: KMR.t("Aggiornamenti", "Updates")
        case .malwareRemoval: "Malware"
        case .privacy: "Privacy"
        case .browserExtensions: KMR.t("Browser", "Browsers")
        case .wifiNetworks: "Wi‑Fi"
        case .appPermissions: KMR.t("Permessi", "Permissions")
        case .optimization: KMR.t("Ottimizzazione", "Optimization")
        case .maintenance: KMR.t("Manutenzione", "Maintenance")
        case .duplicates: KMR.t("Duplicati", "Duplicates")
        case .largeOldFiles: KMR.t("Grandi e vecchi", "Large & Old")
        case .shredder: KMR.t("Distruggi", "Shredder")
        case .storageExtras: KMR.t("Spazio extra", "Extra space")
        case .systemData: KMR.t("Dati di sistema", "System Data")
        case .spaceLens: KMR.t("Mappa", "Map")
        default: displayTitle
        }
    }
}

/// Tabs for the modules of the current group: a segmented control when it fits
/// at its natural width, otherwise a scrolling row of capsules. Labels are
/// never truncated.
struct ModuleTabs: View {
    let group: NavGroup
    @Binding var selection: SidebarItem?
    @Namespace private var pill
    private var activity = ScanActivity.shared

    init(group: NavGroup, selection: Binding<SidebarItem?>) {
        self.group = group
        self._selection = selection
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar.padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) { bar.padding(.horizontal, 16) }
        }
        .animation(.smooth(duration: 0.25), value: selection)
    }

    /// Segmented-style control (same metrics as the system one) that can also
    /// carry a per-tab scan status mark.
    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(group.items) { item in
                let on = selection == item
                Button { selection = item } label: {
                    HStack(spacing: 6) {
                        Text(item.tabTitle)
                            .lineLimit(1)
                            .fixedSize()
                        ScanStatusMark(state: activity.state(item), onAccent: on)
                    }
                    .font(.callout.weight(on ? .medium : .regular))
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.gradient)
                                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}
