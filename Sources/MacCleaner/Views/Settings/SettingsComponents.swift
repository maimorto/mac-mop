import SwiftUI
import AppKit

// MARK: - Panes

/// The panes of the Settings page, chosen with the tab bar at the top.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menuBar, alerts, cleanup, security, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: KMR.t("Generali", "General")
        case .menuBar: KMR.t("Barra dei menu", "Menu Bar")
        case .alerts: KMR.t("Avvisi", "Alerts")
        case .cleanup: KMR.t("Pulizia", "Cleanup")
        case .security: KMR.t("Sicurezza", "Security")
        case .about: KMR.t("Informazioni", "About")
        }
    }

    var subtitle: String {
        switch self {
        case .general: KMR.t("Avvio, aspetto, lingua e aggiornamenti.", "Startup, appearance, language and updates.")
        case .menuBar: KMR.t("Valori di sistema sempre visibili in alto.", "System stats always visible at the top.")
        case .alerts: KMR.t("Notifiche quando il Mac è sotto sforzo.", "Notifications when your Mac is under strain.")
        case .cleanup: KMR.t("Cosa pulire, quando, e cosa non toccare mai.", "What to clean, when, and what never to touch.")
        case .security: KMR.t("Firme usate per cercare malware.", "Signatures used to look for malware.")
        case .about: ""
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .alerts: "bell.badge.fill"
        case .cleanup: "sparkles"
        case .security: "checkmark.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    /// macOS icon of the matching System Settings pane (tile as fallback).
    var systemIcon: [SystemIconSource] {
        typealias S = SystemIconSource
        return switch self {
        case .general: [S.general, S.systemSettings]
        case .menuBar: [S.controlCenter]
        case .alerts: [S.notifications]
        case .cleanup: [S.trashFull]
        case .security: [S.securityShield, S.privacySecurity]
        case .about: [S.appIcon]
        }
    }

    var color: Color {
        let c: NSColor = switch self {
        case .general: .systemGray
        case .menuBar: .systemBlue
        case .alerts: .systemRed
        case .cleanup: .systemOrange
        case .security: .systemGreen
        case .about: .systemBlue
        }
        return Color(nsColor: c)
    }
}

// MARK: - Tab bar

/// Same look as `ModuleTabs`: a segmented-style bar with an accent pill that
/// slides to the selected pane. Scrolls horizontally when it doesn't fit.
struct SettingsTabBar: View {
    @Binding var selection: SettingsPane
    @Namespace private var pill

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar.padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) { bar.padding(.horizontal, 16) }
        }
        .animation(.smooth(duration: 0.25), value: selection)
    }

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                let on = selection == pane
                Button { selection = pane } label: {
                    Text(pane.title)
                        .lineLimit(1)
                        .fixedSize()
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

// MARK: - Rows

/// Pane header like System Settings: big tile, bold title, one short line.
struct SettingsHero: View {
    let pane: SettingsPane

    var body: some View {
        VStack(spacing: 8) {
            SystemIconView(sources: pane.systemIcon, symbol: pane.symbol, color: pane.color, size: 64)
                .padding(.bottom, 4)
            Text(pane.title)
                .font(.title2.weight(.bold))
            if !pane.subtitle.isEmpty {
                Text(pane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// Leading coloured tile + title + optional short caption, used as the
/// label of a Toggle / Picker / LabeledContent row.
struct SettingsRowLabel: View {
    let symbol: String
    let color: Color
    let title: String
    var caption: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            SystemIconView(sources: Self.systemIcon(for: symbol), symbol: symbol, color: color, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension SettingsRowLabel {
    /// Rows whose topic matches a System Settings pane show that pane's macOS
    /// icon; the others keep their coloured tile.
    static func systemIcon(for symbol: String) -> [SystemIconSource] {
        typealias S = SystemIconSource
        return switch symbol {
        case "power": [S.loginItems]
        case "speaker.wave.2.fill": [S.sound]
        case "circle.lefthalf.filled": [S.appearance]
        case "globe": [S.language]
        case "arrow.triangle.2.circlepath", "arrow.down.circle.fill": [S.softwareUpdate]
        case "menubar.rectangle": [S.controlCenter]
        case "clock.arrow.circlepath": [S.timeMachine]
        case "shield.checkered", "shield.lefthalf.filled": [S.securityShield]
        case "key.fill": [S.passwords, S.keychain]
        case "exclamationmark.bubble.fill": [S.feedback]
        case "bell.badge.fill": [S.notifications]
        default: []
        }
    }
}

/// Row that opens a web page, with a trailing arrow like System Settings.
struct SettingsLinkRow: View {
    let symbol: String
    let color: Color
    let title: String
    let url: URL

    var body: some View {
        SettingsActionRow(symbol: symbol, color: color, title: title, trailingSymbol: "arrow.up.forward") {
            NSWorkspace.shared.open(url)
        }
        .accessibilityAddTraits(.isLink)
        .help(url.absoluteString)
    }
}

/// Whole-row button with a tile, a title and a trailing glyph.
struct SettingsActionRow: View {
    let symbol: String
    let color: Color
    let title: String
    var trailingSymbol = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                SettingsRowLabel(symbol: symbol, color: color, title: title)
                Spacer()
                Image(systemName: trailingSymbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - License sheet

struct LicenseSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(KMR.t("Licenza open source", "Open Source License"))
                .font(.headline)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button(KMR.t("Fine", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .escapeKeyAction { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
    }

    /// Bundled LICENSE file, or a short fallback when it isn't packaged.
    static func loadText() -> String {
        var text = "BSD 3-Clause License"
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
           let license = try? String(contentsOf: url, encoding: .utf8) {
            text = license
        }
        // Third-party notices (MIT / BSD attributions) must ship with the app.
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let notices = try? String(contentsOf: url, encoding: .utf8) {
            text += "\n\n――――――――――――――――――――\n\n" + notices
        }
        return text
    }
}
