import SwiftUI
import AppKit
import MacCleanerKit

// Apple privacy: Apple's own analytics, advertising and personalisation
// switches in one place. Each row reads the real current value; Mac Mop
// changes a value only when the user flips its toggle, and only for plain
// per-user preferences that System Settings itself writes. Everything else
// opens the exact System Settings pane. Keys and values from MacSpace (MIT),
// see ApplePrivacySettings and THIRD_PARTY_NOTICES.md.

@MainActor
@Observable
final class ApplePrivacyModel {
    struct Row: Identifiable {
        let setting: ApplePrivacySettings.Setting
        var state: ApplePrivacySettings.State
        var id: String { setting.id }
    }

    private(set) var rows: [Row] = []
    private(set) var intelligence: ApplePrivacySettings.IntelligenceState = .unknown
    private(set) var modelBytes: UInt64?
    private(set) var loaded = false
    var writeError: String?

    func load() async {
        let result = await Task.detached(priority: .userInitiated) { () -> ([Row], Int?, UInt64?) in
            let rows = ApplePrivacySettings.catalog().map { Row(setting: $0, state: Self.read($0)) }
            let eligibility = NSDictionary(contentsOfFile: ApplePrivacySettings.eligibilityPath) as? [String: Any]
            let answer = eligibility.flatMap { ApplePrivacySettings.siriModeAnswer(in: $0) }
            return (rows, answer, Self.folderSize(ApplePrivacySettings.generativeModelsPath))
        }.value
        rows = result.0
        modelBytes = result.2
        intelligence = ApplePrivacySettings.intelligenceState(siriModeAnswer: result.1, modelBytes: result.2)
        loaded = true
    }

    nonisolated static func read(_ setting: ApplePrivacySettings.Setting) -> ApplePrivacySettings.State {
        switch setting.storage {
        case .none:
            return .unknown
        case let .userDefaults(domain, key):
            let raw = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
            return ApplePrivacySettings.state(of: setting, raw: raw)
        case let .plistFile(path, key):
            // An unreadable file (no Full Disk Access) is "unknown", not "key missing".
            guard let plist = NSDictionary(contentsOfFile: path) else { return .unknown }
            return ApplePrivacySettings.state(of: setting, raw: plist[key])
        }
    }

    nonisolated static func folderSize(_ path: String) -> UInt64? {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return nil }
        var total: UInt64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += UInt64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Writes the per-user preference for a writable row, only in response
    /// to the user flipping its toggle, then reads it back.
    func set(_ row: Row, enabled: Bool) {
        guard row.setting.writable, case let .userDefaults(domain, key) = row.setting.storage,
              let value = ApplePrivacySettings.value(for: row.setting, enabled: enabled) else { return }
        let plistValue: CFPropertyList
        switch value {
        case .bool(let b): plistValue = b as CFBoolean
        case .int(let i): plistValue = i as CFNumber
        case .string(let s): plistValue = s as CFString
        }
        CFPreferencesSetAppValue(key as CFString, plistValue, domain as CFString)
        let ok = CFPreferencesAppSynchronize(domain as CFString)
        let state = Self.read(row.setting)
        if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].state = state }
        if !ok || state != (enabled ? .on : .off) {
            writeError = KMR.t("macOS non ha accettato la modifica. Cambiala in Impostazioni di Sistema.",
                               "macOS didn't accept the change. Change it in System Settings.")
        }
    }
}

struct ApplePrivacyView: View {
    @State private var model = ApplePrivacyModel()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ModuleIcon(item: .applePrivacy, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KMR.t("Privacy Apple", "Apple privacy")).font(.headline)
                        Text(KMR.t("Cosa condividi con Apple per analisi, pubblicità e suggerimenti. Mac Mop cambia qualcosa solo quando sposti un interruttore; il resto si apre in Impostazioni.",
                                   "What you share with Apple for analytics, ads and suggestions. Mac Mop changes something only when you flip a switch; the rest opens in Settings."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            intelligenceSection

            Section(KMR.t("Analisi, pubblicità e suggerimenti", "Analytics, ads and suggestions")) {
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(model.rows) { row in
                    settingRow(row)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: show what changed there.
            Task { await model.load() }
        }
        .respondsToModuleShortcuts(onScan: { Task { await model.load() } })
        .alert(KMR.t("Modifica non riuscita", "Change didn't stick"),
               isPresented: Binding(get: { model.writeError != nil }, set: { if !$0 { model.writeError = nil } })) {
            Button("OK") { model.writeError = nil }
        } message: { Text(model.writeError ?? "") }
    }

    // MARK: Rows

    @ViewBuilder
    private func settingRow(_ row: ApplePrivacyModel.Row) -> some View {
        let s = row.setting
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: s.symbol, color: color(for: row.state), size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title)
                Text(s.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let path = s.settingsPath {
                    Text(path).font(.caption).foregroundStyle(.tertiary)
                }
                if s.writable, s.needsRelaunch {
                    Text(KMR.t("Vale dalla prossima apertura delle app interessate.", "Applies the next time the affected apps open."))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if s.writable, row.state != .unknown {
                    Toggle("", isOn: Binding(get: { row.state == .on }, set: { model.set(row, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(s.title)
                } else {
                    stateBadge(row.state)
                }
                Button(s.settingsURL.hasPrefix("/") ? KMR.t("Apri Safari", "Open Safari") : KMR.t("Apri Impostazioni", "Open Settings")) {
                    open(s.settingsURL)
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(.vertical, 2)
    }

    private func stateBadge(_ state: ApplePrivacySettings.State) -> some View {
        Group {
            switch state {
            case .on: Text(KMR.t("Attivo", "On"))
            case .off: Text(KMR.t("Disattivato", "Off"))
            case .unknown: Text(KMR.t("Vedi in Impostazioni", "See in Settings"))
            }
        }
        .font(.callout)
        .foregroundStyle(state == .unknown ? .tertiary : .secondary)
    }

    /// Green when nothing is shared, orange when it is, grey when unknown.
    private func color(for state: ApplePrivacySettings.State) -> Color {
        switch state {
        case .on: .orange
        case .off: .green
        case .unknown: .gray
        }
    }

    private func open(_ target: String) {
        if target.hasPrefix("/") {
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
        } else if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Apple Intelligence

    private var intelligenceSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "sparkles", color: .purple, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Intelligence")
                    Text(intelligenceText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(intelligenceBadge).font(.callout).foregroundStyle(.secondary)
            }
            if let bytes = model.modelBytes {
                LabeledContent(KMR.t("Modelli sul disco", "Models on disk"), value: FileSizeFormatter.format(bytes))
            }
            LabeledContent {
                Button(KMR.t("Apri Impostazioni", "Open Settings")) { open(ApplePrivacySettings.siriPane) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(KMR.t("Come disattivarla e recuperare lo spazio", "How to turn it off and get the space back"))
                    Text(KMR.t("Impostazioni › Apple Intelligence e Siri › disattiva Apple Intelligence. macOS cancella da solo i modelli entro circa un giorno: non vanno rimossi a mano (sono in una cartella di sistema protetta).",
                               "Settings › Apple Intelligence & Siri › turn Apple Intelligence off. macOS deletes the models by itself within about a day: don't remove them by hand (they live in a protected system folder)."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Apple Intelligence")
        }
    }

    private var intelligenceBadge: String {
        switch model.intelligence {
        case .available: KMR.t("Disponibile", "Available")
        case .unavailable: KMR.t("Non disponibile", "Not available")
        case .unavailableModelsPresent: KMR.t("Non attiva, modelli ancora sul disco", "Not active, models still on disk")
        case .unknown: model.loaded ? KMR.t("Sconosciuto", "Unknown") : "…"
        }
    }

    private var intelligenceText: String {
        switch model.intelligence {
        case .available:
            KMR.t("È disponibile su questo Mac: i modelli linguistici restano sul disco anche se non la usi. Le richieste più complesse vanno ai server Private Cloud Compute di Apple.",
                  "It's available on this Mac: the language models stay on disk even if you don't use it. Harder requests go to Apple's Private Cloud Compute servers.")
        case .unavailable:
            KMR.t("Non è attiva su questo Mac (lingua, regione o modello non supportati) e non occupa spazio.",
                  "It isn't active on this Mac (unsupported language, region or model) and takes no space.")
        case .unavailableModelsPresent:
            KMR.t("Non è attiva, ma i modelli sono ancora sul disco. Di solito macOS li rimuove da solo; se restano per giorni, riavvia il Mac.",
                  "It isn't active, but the models are still on disk. macOS usually removes them by itself; if they stay for days, restart the Mac.")
        case .unknown:
            KMR.t("Per leggere lo stato serve l'accesso completo al disco.", "Reading its status needs Full Disk Access.")
        }
    }
}
