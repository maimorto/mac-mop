import SwiftUI
import AppKit
import MacCleanerKit

// "Launch items": every way software starts itself on this Mac, who signed
// it and whether it looks safe. Matches MacPersistenceChecker / KnockKnock /
// LaunchControl. Reads only unprivileged sources; anything that needs the
// administrator password sits behind a button that says so.

// MARK: - Model

@MainActor
@Observable
final class PersistenceModel {
    var inventory: PersistenceInventory?
    var scanning = false
    var phase = ""
    var snapshot: PersistenceSnapshot? = PersistenceSnapshot.load()
    var diff: PersistenceSnapshot.Diff?
    var busy: String?
    var message: String?
    /// `profiles list -all` output, after the user typed the password.
    var adminProfiles: [(scope: String, identifier: String)]?

    /// Everything Mac Mop turned off or moved to the Trash, kept on disk so it
    /// can be undone after a relaunch. `KMR_DISABLED_STORE` points it at a
    /// scratch file (screenshots, never the user's real record).
    let store = DisabledLaunchItemStore(
        fileURL: ProcessInfo.processInfo.environment["KMR_DISABLED_STORE"].map { URL(filePath: $0) } ?? DisabledLaunchItemStore.defaultURL)
    var disabledRecords: [DisabledLaunchItemRecord] = []
    /// Ids in the latest scan (rows check membership without a linear search).
    var scanIDs: Set<String> = []
    /// "Disabled · Undo" banner right after an action.
    var undoToast: UndoToast?

    struct UndoToast: Identifiable, Equatable {
        let id = UUID()
        let record: DisabledLaunchItemRecord
        let text: String
    }

    init() {
        disabledRecords = store.load()
        if ProcessInfo.processInfo.environment["KMR_UNDO_TOAST"] != nil, let first = disabledRecords.first {
            undoToast = UndoToast(record: first, text: first.method == .movedToTrash
                ? KMR.t("Spostato nel Cestino: \(first.item.name)", "Moved to Trash: \(first.item.name)")
                : KMR.t("Disattivato: \(first.item.name)", "Disabled: \(first.item.name)"))
        }
    }

    func record(for item: PersistenceItem) -> DisabledLaunchItemRecord? {
        disabledRecords.first { $0.id == item.id }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        phase = KMR.t("Ricerca degli elementi di avvio…", "Looking for launch items…")
        let collector = PersistenceCollector()
        var result = await Task.detached(priority: .userInitiated) {
            await collector.collect { text in Task { @MainActor [weak self] in self?.phase = text } }
        }.value
        phase = KMR.t("Lettura delle estensioni dei browser…", "Reading browser extensions…")
        let browsers = await BrowserExtensionsClient().list()
        result.items += browsers.records.map(Self.item(from:))
        // Mac Mop's own login items (a local build is only ad-hoc signed).
        for index in result.items.indices where result.items[index].label?.hasPrefix("com.maccleaner") == true {
            result.items[index].risk = .safe
            result.items[index].reasons = [KMR.t("È Mac Mop stesso.", "This is Mac Mop itself.")]
        }
        inventory = result
        scanIDs = Set(result.items.map(\.id))
        disabledRecords = store.reconcile(with: result.items)
        if diff != nil, let snapshot { diff = snapshot.compare(with: result.items) }
        scanning = false
        SoundFX.play(.scanDone)
    }

    static func item(from ext: BrowserExtensionRecord) -> PersistenceItem {
        var item = PersistenceItem(
            id: "\(PersistenceMechanism.browserExtensions.rawValue):\(ext.id)", mechanism: .browserExtensions,
            name: ext.name, path: ext.path, label: ext.identifier,
            signature: PersistenceSignature(kind: .notCode), addedDate: ext.updatedAt,
            facts: [[ext.browser.label, ext.profile].filter { !$0.isEmpty }.joined(separator: " · ")])
        if ext.isSuspicious {
            item.risk = .suspicious
            item.reasons = [KMR.t("Il nome corrisponde a una famiglia di adware conosciuta.", "The name matches a known adware family.")]
        } else {
            item.reasons = [KMR.t("Nessun segnale di adware. Controlla nella sezione Estensioni browser se la riconosci.",
                                  "No adware signs. Check in Browser Extensions whether you recognise it.")]
        }
        return item
    }

    // MARK: Snapshot

    func takeSnapshot() {
        guard let inventory else { return }
        let snap = PersistenceSnapshot(items: inventory.items)
        do {
            try snap.save()
            snapshot = snap
            diff = nil
            message = KMR.t("Istantanea salvata. Installa l'app che vuoi controllare, poi torna qui, analizza di nuovo e premi «Confronta».",
                            "Snapshot saved. Install the app you want to check, then come back, scan again and press “Compare”.")
        } catch {
            message = KMR.t("Non è stato possibile salvare l'istantanea: \(error.localizedDescription)",
                            "Could not save the snapshot: \(error.localizedDescription)")
        }
    }

    func compare() {
        guard let snapshot, let inventory else { return }
        withAnimation(.smooth) { diff = snapshot.compare(with: inventory.items) }
    }

    // MARK: Actions

    static func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    /// Launch agents (yours or for all users) run in your login session, so
    /// they can be stopped and disabled without a password. The plist stays
    /// where it is: launchd remembers the "disabled" override, and
    /// "Re-enable" undoes it exactly. Every change is recorded so the item
    /// stays findable (and undoable) even after a relaunch.
    func setEnabled(_ item: PersistenceItem, enabled: Bool) async {
        guard let label = item.label, let path = item.path, Self.isSafeLabel(label) else { return }
        let uid = getuid()
        busy = enabled ? KMR.t("Riattivazione…", "Re-enabling…") : KMR.t("Disattivazione…", "Disabling…")
        defer { busy = nil }
        let method: PersistenceDisableMethod
        switch item.mechanism {
        case .userLaunchAgents, .systemLaunchAgents:
            method = .launchctl
            if enabled {
                let r = await Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
                _ = await Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", path])
                if r.status != 0 { message = KMR.t("macOS non ha accettato la modifica.", "macOS did not accept the change."); return }
            } else {
                _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", path])
                let r = await Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])
                if r.status != 0 { message = KMR.t("macOS non ha accettato la modifica.", "macOS did not accept the change."); return }
            }
        case .launchDaemons:
            method = .launchctlAdmin
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let command = enabled
                ? "/bin/launchctl enable system/\(label); /bin/launchctl bootstrap system \(quoted)"
                : "/bin/launchctl bootout system/\(label); /bin/launchctl disable system/\(label)"
            if !(await Shell.runAsAdmin(command)) {
                message = KMR.t("Operazione annullata o non riuscita.", "Cancelled or failed.")
                return
            }
        default:
            return
        }
        if enabled {
            disabledRecords = store.forget(id: item.id)
            if undoToast?.record.id == item.id { undoToast = nil }
        } else {
            let record = DisabledLaunchItemRecord(item: item, method: method)
            disabledRecords = store.record(record)
            undoToast = UndoToast(record: record, text: KMR.t("Disattivato: \(item.name)", "Disabled: \(item.name)"))
        }
        markInPlace(item.id, enabled: enabled)
        await scan()
    }

    /// Shows the new state at once, before the rescan confirms it.
    private func markInPlace(_ id: String, enabled: Bool) {
        guard let index = inventory?.items.firstIndex(where: { $0.id == id }) else { return }
        inventory?.items[index].enabled = enabled
        if !enabled { inventory?.items[index].running = false }
    }

    /// Moves your own launch agent's plist to the Trash through the normal
    /// clean flow, so it shows up in Cleanup History and can be restored.
    func trash(_ item: PersistenceItem, engine: CleaningEngine) async {
        guard item.mechanism == .userLaunchAgents, let path = item.path else { return }
        busy = KMR.t("Spostamento nel Cestino…", "Moving to Trash…")
        defer { busy = nil }
        let url = URL(filePath: path)
        _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", path])
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let file = FileItem(url: url, name: url.lastPathComponent, size: size, allocatedSize: size, isDirectory: false)
        let result = await CleanActions.executeUserClean(items: [file], selectedItems: [url], engine: engine)
        if result.removedCount == 0 {
            message = KMR.t("Non è stato possibile spostarlo nel Cestino.", "Could not move it to the Trash.")
        } else {
            let trashPath = Self.historyItem(originalPath: path)?.trashPath
            let record = DisabledLaunchItemRecord(item: item, method: .movedToTrash, trashPath: trashPath)
            disabledRecords = store.record(record)
            undoToast = UndoToast(record: record, text: KMR.t("Spostato nel Cestino: \(item.name)", "Moved to Trash: \(item.name)"))
        }
        await scan()
    }

    /// Newest Cleanup History entry for a file Mac Mop trashed.
    nonisolated static func historyItem(originalPath: String) -> CleanHistoryItem? {
        for session in CleanHistoryRecorder.load() {
            if let item = session.items.first(where: { $0.originalPath == originalPath }) { return item }
        }
        return nil
    }

    /// Undo for any record: re-enable, or put the plist back from the Trash
    /// (through Cleanup History's validated restore) and load it again.
    func undo(_ record: DisabledLaunchItemRecord) async {
        if undoToast?.record.id == record.id { undoToast = nil }
        switch record.undoAction {
        case .reenable, .reenableWithPassword:
            await setEnabled(record.item, enabled: true)
        case .restoreFromTrash:
            await restoreFromTrash(record)
        case .readdLoginItem:
            await readdLoginItem(record)
        case .openLoginItemsSettings:
            Self.openLoginItems()
        case .none:
            break
        }
    }

    private func restoreFromTrash(_ record: DisabledLaunchItemRecord) async {
        guard let path = record.originalPath else { return }
        busy = KMR.t("Ripristino dal Cestino…", "Restoring from the Trash…")
        defer { busy = nil }
        let summary = await Task.detached(priority: .userInitiated) { () -> CleanHistoryRestoreSummary? in
            guard let item = Self.historyItem(originalPath: path) else { return nil }
            return CleanHistoryRecorder.restore(CleanHistorySession(id: UUID(), date: Date(), items: [item]))
        }.value
        guard let summary, summary.restored > 0 else {
            message = summary?.reappeared ?? 0 > 0
                ? KMR.t("Al suo posto c'è già un file con lo stesso nome: niente è stato sovrascritto.",
                        "A file with the same name is already there: nothing was overwritten.")
                : KMR.t("Non è stato trovato nel Cestino: forse il Cestino è stato svuotato. Puoi controllare in Cronologia pulizie.",
                        "It was not found in the Trash: the Trash may have been emptied. You can check in Cleanup History.")
            return
        }
        if record.item.mechanism == .userLaunchAgents || record.item.mechanism == .systemLaunchAgents {
            _ = await Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path])
        }
        disabledRecords = store.forget(id: record.id)
        await scan()
    }

    /// Puts an app back in "Open at Login" (System Events, like System
    /// Settings' "+" button).
    private func readdLoginItem(_ record: DisabledLaunchItemRecord) async {
        guard let app = record.item.program, FileManager.default.fileExists(atPath: app) else {
            message = KMR.t("L'app non è più installata.", "The app is no longer installed.")
            return
        }
        busy = KMR.t("Riattivazione…", "Re-enabling…")
        defer { busy = nil }
        let escaped = app.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to make new login item at end with properties {path:\"\(escaped)\", hidden:false}"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 60)
        guard r.status == 0 else {
            message = KMR.t("macOS non ha permesso di aggiungerla. Puoi farlo da Impostazioni › Generali › Elementi di login con il pulsante «+».",
                            "macOS did not allow adding it. You can do it in Settings › General › Login Items with the “+” button.")
            return
        }
        disabledRecords = store.forget(id: record.id)
        await scan()
    }

    /// Removes a record without touching the item (e.g. the app is gone).
    func forget(_ record: DisabledLaunchItemRecord) {
        withAnimation(.smooth) { disabledRecords = store.forget(id: record.id) }
        if undoToast?.record.id == record.id { undoToast = nil }
    }

    static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    func loadAdminProfiles() async {
        busy = KMR.t("Lettura dei profili…", "Reading profiles…")
        defer { busy = nil }
        let r = await Shell.run("/usr/bin/osascript",
                                ["-e", "do shell script \"/usr/bin/profiles list -all\" with administrator privileges"], timeout: 300)
        guard r.status == 0 else {
            message = KMR.t("Operazione annullata.", "Cancelled.")
            return
        }
        adminProfiles = ProfilesParser.profiles(r.output)
    }
}

// MARK: - View

struct PersistenceView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PersistenceModel()
    @AppStorage("persistence.nonAppleOnly") private var nonAppleOnly = true
    @State private var selected: PersistenceItem?
    /// Filter field: name, path, program, label or signer.
    @State private var query = ""

    var body: some View {
        ZStack {
            if model.scanning && model.inventory == nil {
                ScanProgressRing(progress: 0, phase: model.phase, indeterminate: true)
                    .environment(\.currentModule, .persistence)
                    .transition(.immersive)
            } else if let inventory = model.inventory {
                results(inventory).transition(.immersive)
            } else {
                ContentUnavailableView {
                    Label(KMR.t("Avvio automatico", "Launch items"), systemImage: "bolt.badge.clock")
                } description: {
                    Text(KMR.t("Elenca tutto ciò che si avvia da solo sul Mac, in 26 punti diversi: agenti, servizi, elementi di login, estensioni, plug-in, operazioni pianificate, file del Terminale. Per ognuno vedi chi l'ha firmato e se è sicuro.",
                               "Lists everything that starts by itself on your Mac, in 26 different places: agents, services, login items, extensions, plug-ins, scheduled jobs, Terminal files. For each you see who signed it and whether it is safe."))
                } actions: {
                    Button(KMR.t("Analizza", "Scan")) { Task { await model.scan() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: model.scanning)
        .animation(.immersiveScreen, value: model.inventory == nil)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let toast = model.undoToast {
                    undoBanner(toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let busy = model.busy ?? (model.scanning && model.inventory != nil ? model.phase : nil) {
                    Label(busy, systemImage: "hourglass")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 16)
        }
        .animation(.smooth, value: model.busy)
        .animation(.smooth, value: model.undoToast)
        .task(id: model.undoToast?.id) {
            // The banner stays long enough to read and reach "Undo", then
            // goes; the item stays in "Disabled by Mac Mop" for good.
            guard let id = model.undoToast?.id, ProcessInfo.processInfo.environment["KMR_UNDO_TOAST"] == nil else { return }
            try? await Task.sleep(for: .seconds(10))
            if model.undoToast?.id == id { model.undoToast = nil }
        }
        .respondsToModuleShortcuts(onScan: { Task { await model.scan() } }, canScan: !model.scanning)
        .task {
            if ProcessInfo.processInfo.environment["KMR_AUTOSCAN"] != nil, model.inventory == nil { await model.scan() }
        }
        .sheet(item: $selected) { item in
            PersistenceDetail(item: item, model: model, engine: appState.cleaningEngine,
                              isPlaceholder: model.inventory != nil && !model.scanIDs.contains(item.id),
                              openCleanHistory: { selected = nil; appState.selectedSidebarItem = .cleanHistory },
                              openBrowserExtensions: { selected = nil; appState.selectedSidebarItem = .browserExtensions })
        }
        .alert(KMR.t("Avvio automatico", "Launch items"),
               isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private func visible(_ inventory: PersistenceInventory) -> [PersistenceItem] {
        let base = nonAppleOnly ? inventory.items.filter { !$0.isApple } : inventory.items
        guard !SearchMatcher.tokens(query).isEmpty else { return base }
        return base.filter { item in
            SearchMatcher.matches(query: query, fields: [item.name, item.path ?? "", item.program ?? "", item.label ?? "",
                                                         item.mechanism.title] + item.arguments)
        }
    }

    private func results(_ inventory: PersistenceInventory) -> some View {
        let items = visible(inventory)
        let scanIDs = model.scanIDs
        // Trashed / vanished items Mac Mop turned off stay listed in place.
        let placeholders = DisabledLaunchItems.placeholders(for: model.disabledRecords, inScan: scanIDs)
        let groups = Dictionary(grouping: items + placeholders, by: \.mechanism)
        let empty = PersistenceMechanism.allCases.filter { groups[$0] == nil }
        let offInSettings = DisabledLaunchItems.disabledInSettings(items)
            .filter { item in !model.disabledRecords.contains { $0.id == item.id } }
        return Form {
            summary(inventory, items: items)
            if !model.disabledRecords.isEmpty { disabledByMacMopSection(scanIDs: scanIDs) }
            if !offInSettings.isEmpty { disabledInSettingsSection(offInSettings) }
            if let diff = model.diff { diffSection(diff) }
            ForEach(PersistenceMechanism.allCases.filter { groups[$0] != nil }, id: \.self) { mechanism in
                mechanismSection(mechanism, items: groups[mechanism] ?? [], limit: inventory.limits[mechanism])
            }
            if !empty.isEmpty {
                Section {
                    ForEach(empty, id: \.self) { mechanism in
                        HStack(spacing: 10) {
                            IconTile(symbol: mechanism.symbol, color: Self.color(mechanism).opacity(0.55), size: 22)
                            Text(mechanism.title).foregroundStyle(.secondary)
                            Spacer()
                            if let limit = inventory.limits[mechanism] {
                                Image(systemName: "lock.fill").foregroundStyle(.tertiary).help(limit)
                            }
                            Text(KMR.t("Nessuno", "None")).foregroundStyle(.tertiary)
                        }
                        .help(mechanism.explanation)
                    }
                } header: {
                    Text(KMR.t("Controllati, niente da segnalare", "Checked, nothing found"))
                } footer: {
                    Text(KMR.t("I componenti di macOS nella cartella /System non sono elencati: si trovano su un volume sigillato che nessun programma può modificare.",
                               "macOS components in /System are not listed: they live on a sealed volume no program can modify."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                Button(KMR.t("Analizza di nuovo", "Scan again")) { Task { await model.scan() } }
                    .disabled(model.scanning)
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ inventory: PersistenceInventory, items: [PersistenceItem]) -> some View {
        let suspicious = items.filter { $0.risk == .suspicious }.count
        let review = items.filter { $0.risk == .review }.count
        return Section {
            HStack(spacing: 14) {
                IconTile(symbol: suspicious > 0 ? "exclamationmark.triangle.fill" : review > 0 ? "eye.fill" : "checkmark.shield.fill",
                         color: suspicious > 0 ? KMR.red : review > 0 ? KMR.orange : KMR.green, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suspicious > 0 ? KMR.t("Elementi sospetti: \(suspicious)", "Suspicious items: \(suspicious)")
                         : review > 0 ? KMR.t("Elementi da controllare: \(review)", "Items to review: \(review)")
                         : KMR.t("Niente di sospetto", "Nothing suspicious"))
                        .font(.headline)
                    Text(KMR.t("Elementi che si avviano da soli: \(items.count) · Analisi: \(inventory.date.formatted(date: .omitted, time: .shortened))",
                               "Items that start by themselves: \(items.count) · Scanned: \(inventory.date.formatted(date: .omitted, time: .shortened))"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            Toggle(KMR.t("Mostra solo elementi non Apple", "Show only non-Apple items"), isOn: $nonAppleOnly)
            LabeledContent(KMR.t("Cerca", "Search")) {
                NativeSearchField(text: $query, prompt: KMR.t("Nome, percorso o etichetta", "Name, path or label"))
                    .frame(maxWidth: 260)
            }
            LabeledContent {
                HStack {
                    if model.snapshot != nil {
                        Button(KMR.t("Confronta", "Compare")) { model.compare() }
                    }
                    Button(KMR.t("Scatta istantanea", "Take snapshot")) { model.takeSnapshot() }
                }
            } label: {
                Text(KMR.t("Prima e dopo un'installazione", "Before and after an install"))
                Text(model.snapshot.map { KMR.t("Istantanea del \($0.date.formatted(date: .abbreviated, time: .shortened))", "Snapshot from \($0.date.formatted(date: .abbreviated, time: .shortened))") }
                     ?? KMR.t("Scatta un'istantanea prima di installare un'app, poi confronta per vedere cosa ha aggiunto.",
                              "Take a snapshot before installing an app, then compare to see what it added."))
            }
        }
    }

    private func diffSection(_ diff: PersistenceSnapshot.Diff) -> some View {
        Section {
            if diff.isEmpty {
                Label(KMR.t("Nessun cambiamento dall'istantanea", "No changes since the snapshot"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(diff.added.map { ("diff-added:" + $0.id, $0) }, id: \.0) { _, item in
                row(item, badge: AnyView(Text(KMR.t("Aggiunto", "Added")).font(.caption.weight(.semibold)).foregroundStyle(KMR.green)))
            }
            ForEach(diff.removed.map { ("diff-removed:" + $0.id, $0) }, id: \.0) { _, item in
                row(item, badge: AnyView(Text(KMR.t("Rimosso", "Removed")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)))
                    .opacity(0.7)
            }
        } header: {
            Text(KMR.t("Cambiamenti dall'istantanea", "Changes since the snapshot"))
        } footer: {
            Text(KMR.t("Aggiunti: \(diff.added.count) · Rimossi: \(diff.removed.count)", "Added: \(diff.added.count) · Removed: \(diff.removed.count)"))
        }
    }

    private func mechanismSection(_ mechanism: PersistenceMechanism, items: [PersistenceItem], limit: String?) -> some View {
        Section {
            ForEach(items.prefix(200)) { item in row(item) }
            if mechanism == .browserExtensions {
                Button(KMR.t("Gestisci in Estensioni browser…", "Manage in Browser Extensions…")) {
                    appState.selectedSidebarItem = .browserExtensions
                }
            }
            if mechanism == .configurationProfiles {
                profilesRow
            }
        } header: {
            HStack {
                Text(mechanism.title)
                Spacer()
                Text("\(items.count)").monospacedDigit()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(mechanism.explanation)
                if let limit { Label(limit, systemImage: "lock.fill") }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var profilesRow: some View {
        if let profiles = model.adminProfiles {
            if profiles.isEmpty {
                Label(KMR.t("Nessun profilo installato", "No profiles installed"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(Array(profiles.enumerated()), id: \.offset) { _, profile in
                LabeledContent(profile.identifier, value: profile.scope == "_computerlevel" ? KMR.t("Tutto il Mac", "Whole Mac") : profile.scope)
            }
        } else {
            Button(KMR.t("Mostra tutti i profili (richiede la password)…", "Show all profiles (asks for password)…")) {
                Task { await model.loadAdminProfiles() }
            }
        }
    }

    private func row(_ item: PersistenceItem, badge: AnyView? = nil) -> some View {
        let record = model.record(for: item)
        let inScan = model.scanIDs.contains(item.id)
        let off = item.enabled == false || (record != nil && !inScan)
        return HStack(spacing: 10) {
            Button { selected = item } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: item.mechanism.symbol, color: Self.color(item.mechanism), size: 26)
                        .saturation(off ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .opacity(off ? 0.6 : 1)
                    Spacer(minLength: 8)
                    if let record, !inScan {
                        statusBadge(record.method == .movedToTrash ? KMR.t("Nel Cestino", "In the Trash")
                                    : record.method == .removedLoginItem ? KMR.t("Tolto dal login", "Removed from login")
                                    : KMR.t("Non più presente", "No longer there"))
                    } else if off {
                        statusBadge(KMR.t("Disattivato", "Disabled"))
                    }
                    if let badge { badge } else if inScan { PersistenceRiskBadge(risk: item.risk).opacity(off ? 0.6 : 1) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if off { undoButton(for: item, record: record, inScan: inScan) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contextMenu {
            if let path = item.path ?? item.program, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                FileContextMenuItems(url: URL(filePath: path))
            }
            if let record {
                Button(KMR.t("Togli dall'elenco dei disattivati", "Remove from the disabled list")) { model.forget(record) }
            }
        }
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.fill.tertiary, in: Capsule())
            .fixedSize()
    }

    /// One click back: "Re-enable", "Restore" from the Trash, or a link to
    /// System Settings when only Settings can switch it back on.
    @ViewBuilder
    private func undoButton(for item: PersistenceItem, record: DisabledLaunchItemRecord?, inScan: Bool) -> some View {
        let action = DisabledLaunchItems.undoAction(for: item, record: record)
        let state = record.map { r in
            DisabledLaunchItems.state(of: r, inScan: inScan ? [r.id] : [], fileExists: { FileManager.default.fileExists(atPath: $0) })
        }
        switch action {
        case _ where state == .gone:
            if let record {
                Button(KMR.t("Dimentica", "Forget")) { model.forget(record) }
                    .controlSize(.small)
                    .help(KMR.t("Non è più sul Mac (app disinstallata o Cestino svuotato): toglilo da questo elenco.",
                                "It is no longer on this Mac (app uninstalled or Trash emptied): remove it from this list."))
            }
        case .readdLoginItem:
            if let record {
                Button(KMR.t("Riattiva", "Re-enable")) { Task { await model.undo(record) } }
                    .controlSize(.small)
                    .disabled(model.busy != nil)
                    .help(KMR.t("La rimette tra le app che si aprono all'accesso.", "Puts it back among the apps that open at login."))
            }
        case .reenable, .reenableWithPassword:
            Button(action == .reenableWithPassword ? KMR.t("Riattiva…", "Re-enable…") : KMR.t("Riattiva", "Re-enable")) {
                Task {
                    if let record { await model.undo(record) } else { await model.setEnabled(item, enabled: true) }
                }
            }
            .controlSize(.small)
            .disabled(model.busy != nil)
            .help(action == .reenableWithPassword ? KMR.t("Richiede la password di amministratore.", "Asks for the administrator password.")
                                                   : KMR.t("Lo riavvia ora e ad ogni accesso.", "Starts it now and at every login."))
        case .restoreFromTrash:
            if let record {
                Button(KMR.t("Ripristina", "Restore")) { Task { await model.undo(record) } }
                    .controlSize(.small)
                    .disabled(model.busy != nil)
                    .help(KMR.t("Rimette il file dov'era e lo riattiva.", "Puts the file back where it was and starts it again."))
            }
        case .openLoginItemsSettings:
            Button(KMR.t("Riattiva in Impostazioni…", "Re-enable in Settings…")) { PersistenceModel.openLoginItems() }
                .controlSize(.small)
                .help(KMR.t("Si accende da Impostazioni di Sistema › Generali › Elementi di login: si apre la pagina giusta.",
                            "It is switched on in System Settings › General › Login Items: this opens the right page."))
        case .none:
            EmptyView()
        }
    }

    private func undoBanner(_ toast: PersistenceModel.UndoToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: toast.record.method == .movedToTrash ? "trash" : "pause.circle")
                .foregroundStyle(.secondary)
            Text(toast.text).lineLimit(1).truncationMode(.middle)
            Button(KMR.t("Annulla", "Undo")) { Task { await model.undo(toast.record) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.busy != nil)
            Button { model.undoToast = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(KMR.t("Chiudi", "Close"))
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 520)
    }

    // MARK: Disabled items

    private func disabledByMacMopSection(scanIDs: Set<String>) -> some View {
        Section {
            // Row ids are prefixed: the same items also appear in their
            // mechanism section, and duplicate ids inside one Form confuse
            // its row diffing (rows ended up drawn outside the card).
            ForEach(disabledRows(scanIDs: scanIDs), id: \.rowID) { entry in
                disabledRow(record: entry.record, item: entry.item, inScan: entry.inScan)
            }
        } header: {
            HStack {
                Text(KMR.t("Disattivati da Mac Mop", "Disabled by Mac Mop"))
                Spacer()
                Text("\(model.disabledRecords.count)").monospacedDigit()
            }
        } footer: {
            Text(KMR.t("Mac Mop tiene nota di tutto ciò che spegne o sposta nel Cestino, anche dopo un riavvio: da qui lo rimetti com'era con un clic.",
                       "Mac Mop keeps a note of everything it turns off or moves to the Trash, even after a restart: from here you put it back with one click."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct DisabledRowEntry {
        let record: DisabledLaunchItemRecord
        let item: PersistenceItem
        let inScan: Bool
        var rowID: String { "disabled-by-mac-mop:" + record.id }
    }

    private func disabledRows(scanIDs: Set<String>) -> [DisabledRowEntry] {
        let current = Dictionary((model.inventory?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return model.disabledRecords.map { record in
            DisabledRowEntry(record: record, item: current[record.id] ?? record.item, inScan: scanIDs.contains(record.id))
        }
    }

    private func disabledRow(record: DisabledLaunchItemRecord, item: PersistenceItem, inScan: Bool) -> some View {
        let state = DisabledLaunchItems.state(of: record, inScan: inScan ? [record.id] : [],
                                              fileExists: { FileManager.default.fileExists(atPath: $0) })
        let date = record.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UIText.locale))
        let how: String = switch (record.method, state) {
        case (_, .gone): KMR.t("Non più presente sul Mac", "No longer on this Mac")
        case (.movedToTrash, _): KMR.t("Spostato nel Cestino il \(date)", "Moved to the Trash on \(date)")
        case (.removedLoginItem, _): KMR.t("Tolto dagli elementi di login il \(date)", "Removed from Login Items on \(date)")
        default: KMR.t("Disattivato il \(date)", "Disabled on \(date)")
        }
        return HStack(spacing: 10) {
            Button { selected = item } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: item.mechanism.symbol, color: Self.color(item.mechanism), size: 26)
                        .saturation(0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text("\(how) · \(item.mechanism.title)").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(record.undoHint)
            undoButton(for: item, record: record, inScan: inScan)
        }
        .contextMenu {
            if let path = record.originalPath, FileManager.default.fileExists(atPath: path) {
                Button(KMR.t("Mostra nel Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
            }
            if let path = record.originalPath {
                Button(KMR.t("Copia la posizione originale", "Copy original location")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            Button(KMR.t("Togli dall'elenco", "Remove from the list")) { model.forget(record) }
        }
    }

    private func disabledInSettingsSection(_ items: [PersistenceItem]) -> some View {
        Section {
            ForEach(items.map { ("off-in-settings:" + $0.id, $0) }, id: \.0) { _, item in
                HStack(spacing: 10) {
                    Button { selected = item } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: item.mechanism.symbol, color: Self.color(item.mechanism), size: 26)
                                .saturation(0)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .opacity(0.6)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(KMR.t("Riattiva in Impostazioni…", "Re-enable in Settings…")) { PersistenceModel.openLoginItems() }
                        .controlSize(.small)
                }
            }
        } header: {
            HStack {
                Text(KMR.t("Spenti in Impostazioni › Elementi di login", "Turned off in Settings › Login Items"))
                Spacer()
                Text("\(items.count)").monospacedDigit()
            }
        } footer: {
            Text(KMR.t("Questi li hai spenti in Impostazioni di Sistema: macOS permette di riaccenderli solo da lì. Il pulsante apre la pagina giusta.",
                       "You turned these off in System Settings: macOS only lets you switch them back on there. The button opens the right page."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subtitle(_ item: PersistenceItem) -> String {
        var parts = [item.signature.shortLabel]
        if item.signature.kind == .notCode, let fact = item.facts.first { parts = [fact] }
        if let date = item.addedDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if item.running { parts.append(KMR.t("in esecuzione", "running")) }
        return parts.joined(separator: " · ")
    }

    static func color(_ mechanism: PersistenceMechanism) -> Color {
        switch mechanism {
        case .userLaunchAgents, .systemLaunchAgents: .orange
        case .launchDaemons, .privilegedHelpers: .red
        case .backgroundItems, .legacyLoginItems: .blue
        case .kernelExtensions, .systemExtensions: .purple
        case .configurationProfiles: .gray
        case .cron, .atJobs, .periodic: .teal
        case .emond, .startupItems, .rcScripts, .loginHooks: .brown
        case .authorizationPlugins, .directoryServicesPlugins, .pam, .sudoers: .indigo
        case .dyldInjection: .pink
        case .shellStartup: Color(nsColor: .darkGray)
        case .spotlightImporters, .quickLookPlugins, .appExtensions: .cyan
        case .browserExtensions: .green
        }
    }
}

// MARK: - Risk badge

struct PersistenceRiskBadge: View {
    let risk: PersistenceRisk

    var body: some View {
        let tint: Color = switch risk {
        case .safe: KMR.green
        case .review: KMR.orange
        case .suspicious: KMR.red
        }
        let symbol = switch risk {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .suspicious: "exclamationmark.triangle.fill"
        }
        Label(risk.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

// MARK: - Detail

private struct PersistenceDetail: View {
    let item: PersistenceItem
    let model: PersistenceModel
    let engine: CleaningEngine
    /// Not in the latest scan: a record of something Mac Mop trashed.
    var isPlaceholder = false
    var openCleanHistory: () -> Void = {}
    let openBrowserExtensions: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmTrash = false
    @State private var confirmAdmin = false

    private var canToggle: Bool {
        guard !isPlaceholder, item.disabledInSettings != true else { return false }
        guard item.label.map(PersistenceModel.isSafeLabel) == true, item.path != nil else { return false }
        return [.userLaunchAgents, .systemLaunchAgents, .launchDaemons].contains(item.mechanism)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: item.mechanism.symbol, color: PersistenceView.color(item.mechanism), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline).lineLimit(2)
                            Text(item.mechanism.title).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        PersistenceRiskBadge(risk: item.risk)
                    }
                }
                Section(KMR.t("Valutazione", "Assessment")) {
                    ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                    }
                }
                Section(KMR.t("Dettagli", "Details")) {
                    LabeledContent(KMR.t("Firmato da", "Signed by")) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.signature.shortLabel)
                            if let team = item.signature.teamID, item.signature.kind != .apple {
                                Text(team).font(.caption).foregroundStyle(.secondary).monospaced()
                            }
                        }
                    }
                    if item.signature.kind != .notCode {
                        Text(item.signature.explanation).font(.callout).foregroundStyle(.secondary)
                    }
                    if let notarized = item.signature.notarized {
                        LabeledContent(KMR.t("Autenticato da Apple (notarizzato)", "Notarized by Apple"),
                                       value: notarized ? KMR.t("Sì", "Yes") : KMR.t("No", "No"))
                    }
                    if let enabled = item.enabled {
                        LabeledContent(KMR.t("Stato", "Status"),
                                       value: enabled ? (item.running ? KMR.t("Attivo, in esecuzione", "On, running") : KMR.t("Attivo", "On"))
                                                      : KMR.t("Disattivato", "Disabled"))
                    }
                    if let date = item.addedDate {
                        LabeledContent(KMR.t("Aggiunto il", "Added on"), value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let label = item.label { pathRow(KMR.t("Identificativo", "Identifier"), label, reveal: false) }
                    if let path = item.path { pathRow(KMR.t("File", "File"), path, reveal: path.hasPrefix("/")) }
                    if let program = item.program, program != item.path { pathRow(KMR.t("Programma", "Program"), program, reveal: program.hasPrefix("/")) }
                    if item.arguments.count > 1 || (item.mechanism == .cron && !item.arguments.isEmpty) {
                        LabeledContent(KMR.t("Comando", "Command")) {
                            Text(ThreatCommandAnalyzer.snippet(item.arguments.joined(separator: " ")))
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                    ForEach(Array(item.facts.enumerated()), id: \.offset) { _, fact in
                        Label(fact, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                actions
                Section {
                    Text(item.mechanism.explanation).font(.callout).foregroundStyle(.secondary)
                } header: {
                    Text(KMR.t("Che cos'è", "What it is"))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(KMR.t("Fine", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .escapeKeyAction { dismiss() }
            }
            .padding(14)
        }
        // Fits the smallest main window (sheets taller than it hang off-screen).
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 520, maxHeight: 640)
    }

    private func pathRow(_ title: String, _ value: String, reveal: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle).multilineTextAlignment(.trailing)
                if reveal {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: value)]) } label: {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(KMR.t("Mostra nel Finder", "Show in Finder"))
                }
            }
        }
    }

    @ViewBuilder private var disabledRecordSection: some View {
        if let record = model.record(for: item) {
            Section {
                LabeledContent(KMR.t("Data", "Date"), value: record.date.formatted(date: .abbreviated, time: .shortened))
                if let path = record.originalPath {
                    LabeledContent(KMR.t("Posizione originale", "Original location")) {
                        Text(path).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle).multilineTextAlignment(.trailing)
                    }
                }
                if let trash = record.trashPath, record.method == .movedToTrash {
                    LabeledContent(KMR.t("Nel Cestino come", "In the Trash as"), value: (trash as NSString).lastPathComponent)
                }
                Text(record.undoHint).font(.callout).foregroundStyle(.secondary)
                HStack {
                    switch record.undoAction {
                    case .restoreFromTrash:
                        Button(KMR.t("Ripristina", "Restore")) { Task { await model.undo(record); dismiss() } }
                            .buttonStyle(.borderedProminent)
                        Button(KMR.t("Apri Cronologia pulizie", "Open Cleanup History")) { openCleanHistory() }
                    case .readdLoginItem:
                        Button(KMR.t("Riattiva", "Re-enable")) { Task { await model.undo(record); dismiss() } }
                            .buttonStyle(.borderedProminent)
                    case .reenable, .reenableWithPassword:
                        if !isPlaceholder {
                            Button(record.undoAction == .reenableWithPassword ? KMR.t("Riattiva (richiede la password)…", "Re-enable (asks for password)…")
                                                                             : KMR.t("Riattiva", "Re-enable")) {
                                Task { await model.undo(record); dismiss() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    default:
                        EmptyView()
                    }
                    Spacer()
                    Button(KMR.t("Togli dall'elenco", "Remove from the list")) { model.forget(record); dismiss() }
                }
            } header: {
                Text(record.method == .movedToTrash ? KMR.t("Spostato nel Cestino da Mac Mop", "Moved to the Trash by Mac Mop")
                                                    : KMR.t("Disattivato da Mac Mop", "Disabled by Mac Mop"))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        disabledRecordSection
        Section {
            if item.disabledInSettings == true || (item.enabled == false && item.mechanism == .backgroundItems) {
                Button(KMR.t("Riattiva in Impostazioni…", "Re-enable in Settings…")) { PersistenceModel.openLoginItems() }
            }
            if let path = item.path ?? item.program, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                Button(KMR.t("Mostra nel Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
            }
            if canToggle {
                let enabled = item.enabled ?? true
                if item.mechanism == .launchDaemons {
                    Button(enabled ? KMR.t("Disattiva (richiede la password)…", "Disable (asks for password)…")
                                   : KMR.t("Riattiva (richiede la password)…", "Re-enable (asks for password)…")) { confirmAdmin = true }
                        .confirmationDialog(enabled ? KMR.t("Disattivare questo servizio?", "Disable this service?") : KMR.t("Riattivare questo servizio?", "Re-enable this service?"),
                                            isPresented: $confirmAdmin) {
                            Button(enabled ? KMR.t("Disattiva", "Disable") : KMR.t("Riattiva", "Re-enable"), role: enabled ? .destructive : nil) {
                                Task { await model.setEnabled(item, enabled: !enabled); dismiss() }
                            }
                        } message: {
                            Text(KMR.t("macOS ti chiederà la password di amministratore. Il file resta dov'è: puoi riattivarlo quando vuoi da qui.",
                                       "macOS will ask for your administrator password. The file stays where it is: you can re-enable it from here at any time."))
                        }
                } else {
                    Button(enabled ? KMR.t("Disattiva", "Disable") : KMR.t("Riattiva", "Re-enable")) {
                        Task { await model.setEnabled(item, enabled: !enabled); dismiss() }
                    }
                }
            }
            if item.mechanism == .userLaunchAgents, item.path != nil, !isPlaceholder {
                Button(KMR.t("Sposta nel Cestino…", "Move to Trash…"), role: .destructive) { confirmTrash = true }
                    .confirmationDialog(KMR.t("Spostare questo agente nel Cestino?", "Move this agent to the Trash?"), isPresented: $confirmTrash) {
                        Button(KMR.t("Sposta nel Cestino", "Move to Trash"), role: .destructive) {
                            Task { await model.trash(item, engine: engine); dismiss() }
                        }
                    } message: {
                        Text(KMR.t("Viene fermato e il suo file va nel Cestino. Lo trovi in Cronologia pulizie e puoi ripristinarlo con un clic. L'app che l'ha installato potrebbe ricrearlo: in quel caso disinstalla l'app.",
                                   "It is stopped and its file goes to the Trash. You'll find it in Cleanup History and can restore it in one click. The app that installed it may recreate it: in that case uninstall the app."))
                    }
            }
            switch item.mechanism {
            case .backgroundItems, .legacyLoginItems:
                Button(KMR.t("Apri Elementi di login", "Open Login Items")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            case .systemExtensions:
                Button(KMR.t("Apri Elementi di login ed estensioni", "Open Login Items & Extensions")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            case .configurationProfiles:
                Button(KMR.t("Apri Gestione dispositivi", "Open Device Management")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension")!)
                }
            case .appExtensions:
                Button(KMR.t("Apri le estensioni in Impostazioni", "Open extensions in Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
                }
            case .browserExtensions:
                Button(KMR.t("Apri Estensioni browser", "Open Browser Extensions")) { openBrowserExtensions() }
            default:
                EmptyView()
            }
        } header: {
            Text(KMR.t("Azioni", "Actions"))
        } footer: {
            if canToggle {
                Text(KMR.t("«Disattiva» ferma l'elemento e chiede a macOS di non avviarlo più, senza cancellare niente: è il modo più sicuro e si annulla con «Riattiva». Gli elementi gestiti da Impostazioni › Elementi di login vanno spenti lì.",
                           "“Disable” stops the item and tells macOS not to start it again, without deleting anything: it's the safest way and “Re-enable” undoes it. Items managed in Settings › Login Items should be turned off there."))
            }
        }
    }
}
