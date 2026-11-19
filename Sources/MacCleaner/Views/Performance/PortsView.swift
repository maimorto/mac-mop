import SwiftUI
import AppKit
import MacCleanerKit

// Network ports: which of your apps are waiting for connections, whether
// other devices on the network can reach them, and a plain explanation of the
// common ones. Idea from MyMacCleaner (MIT); our own code, built on
// `lsof -F` (see ListeningPorts in MacCleanerKit).

@MainActor
@Observable
final class PortsModel {
    private(set) var listeners: [ListeningPorts.Listener] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?
    private(set) var icons: [Int32: NSImage] = [:]
    private(set) var appNames: [Int32: String] = [:]
    var killError: String?

    var exposedCount: Int { listeners.filter(\.isExposed).count }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let tcp = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcLuPnt"], timeout: 10)
        async let udp = Shell.run("/usr/sbin/lsof", ["-nP", "-iUDP", "-FpcLuPnt"], timeout: 10)
        let (t, u) = await (tcp, udp)
        let parsed = await Task.detached { ListeningPorts.parse(t.output) + ListeningPorts.parse(u.output) }.value
        let sorted = parsed.sorted {
            if $0.isExposed != $1.isExposed { return $0.isExposed }
            return ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid)
        }
        for pid in Set(sorted.map(\.pid)) where icons[pid] == nil {
            if let app = NSRunningApplication(processIdentifier: pid) {
                icons[pid] = app.icon
                appNames[pid] = app.localizedName
            } else {
                icons[pid] = NSWorkspace.shared.icon(for: .unixExecutable)
            }
        }
        listeners = sorted
        lastRefresh = Date()
    }

    func displayName(_ l: ListeningPorts.Listener) -> String {
        appNames[l.pid] ?? l.command
    }

    func canTerminate(_ l: ListeningPorts.Listener) -> Bool {
        l.pid > 1 && l.pid != getpid() && l.uid == getuid()
            && !ListeningPorts.isSystemProcess(command: l.command, uid: l.uid)
    }

    /// SIGTERM (the polite "please quit"), only for the user's own,
    /// non-system processes, after the user confirmed.
    func terminate(_ l: ListeningPorts.Listener) async {
        guard canTerminate(l) else { return }
        if kill(l.pid, SIGTERM) != 0 {
            killError = String(cString: strerror(errno))
        }
        try? await Task.sleep(for: .milliseconds(600))
        icons[l.pid] = nil
        await refresh()
    }
}

struct PortsView: View {
    @State private var model = PortsModel()
    @State private var pendingKill: ListeningPorts.Listener?
    /// Filter: app name, command, port number or address.
    @State private var query = ""

    private var shown: [ListeningPorts.Listener] {
        guard !SearchMatcher.tokens(query).isEmpty else { return model.listeners }
        return model.listeners.filter { l in
            SearchMatcher.matches(query: query, fields: [model.displayName(l), l.command, String(l.port), l.user ?? ""] + l.addresses)
        }
    }

    var body: some View {
        Form {
            summarySection
            if model.listeners.isEmpty, model.lastRefresh != nil {
                Section {
                    ContentUnavailableView(KMR.t("Nessuna porta in ascolto", "No listening ports"), systemImage: "network",
                                           description: Text(KMR.t("Nessuna delle tue app sta aspettando connessioni.",
                                                                   "None of your apps is waiting for connections.")))
                }
            }
            if !model.listeners.isEmpty, shown.isEmpty {
                Section { ContentUnavailableView.search(text: query) }
            }
            let exposed = shown.filter(\.isExposed)
            let local = shown.filter { !$0.isExposed }
            if !exposed.isEmpty {
                Section {
                    ForEach(exposed) { row($0) }
                } header: {
                    Text(KMR.t("Raggiungibili da altri dispositivi", "Reachable from other devices"))
                } footer: {
                    Text(KMR.t("Chiunque sia nella stessa rete Wi‑Fi può provare a collegarsi a queste porte. Va bene per AirPlay, Continuità e condivisioni che usi; chiudi ciò che non riconosci.",
                               "Anyone on the same Wi‑Fi network can try to connect to these ports. That's fine for AirPlay, Continuity and sharing you use; close what you don't recognise."))
                }
            }
            if !local.isEmpty {
                Section {
                    ForEach(local) { row($0) }
                } header: {
                    Text(KMR.t("Solo da questo Mac", "This Mac only"))
                } footer: {
                    Text(KMR.t("Ascoltano solo su localhost: nessun altro dispositivo può raggiungerle.",
                               "They listen on localhost only: no other device can reach them."))
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Auto refresh while the page is visible (the task ends on disappear).
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .respondsToModuleShortcuts(onScan: { Task { await model.refresh() } }, canScan: !model.isLoading)
        .confirmationDialog(killTitle, isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                            titleVisibility: .visible, presenting: pendingKill) { l in
            Button(KMR.t("Termina processo", "Terminate process"), role: .destructive) {
                pendingKill = nil
                Task { await model.terminate(l) }
            }
            Button(KMR.t("Annulla", "Cancel"), role: .cancel) { pendingKill = nil }
        } message: { l in
            Text(KMR.t("Chiede a \(model.displayName(l)) (PID \(l.pid)) di chiudersi. Il lavoro non salvato in quell'app potrebbe andare perso.",
                       "Asks \(model.displayName(l)) (PID \(l.pid)) to quit. Unsaved work in that app may be lost."))
        }
        .alert(KMR.t("Impossibile terminare il processo", "Couldn't terminate the process"),
               isPresented: Binding(get: { model.killError != nil }, set: { if !$0 { model.killError = nil } })) {
            Button("OK") { model.killError = nil }
        } message: { Text(model.killError ?? "") }
    }

    private var killTitle: String {
        let name = pendingKill.map { model.displayName($0) } ?? ""
        return KMR.t("Terminare «\(name)»?", "Terminate “\(name)”?")
    }

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                ModuleIcon(item: .ports, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KMR.t("Porte di rete", "Network ports")).font(.headline)
                    Text(KMR.t("Le app che aspettano connessioni, e se gli altri dispositivi della rete possono raggiungerle.",
                               "Apps waiting for connections, and whether other devices on the network can reach them."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isLoading { ProgressView().controlSize(.small) } else { Label(KMR.t("Aggiorna", "Refresh"), systemImage: "arrow.clockwise") }
                }
                .disabled(model.isLoading)
            }
            if model.lastRefresh != nil {
                LabeledContent(KMR.t("Cerca", "Search")) {
                    NativeSearchField(text: $query, prompt: KMR.t("App, porta o indirizzo", "App, port or address"))
                        .frame(maxWidth: 240)
                }
                LabeledContent(KMR.t("Porte in ascolto", "Listening ports"), value: "\(model.listeners.count)")
                LabeledContent(KMR.t("Esposte in rete", "Exposed to the network")) {
                    Text("\(model.exposedCount)")
                        .foregroundStyle(model.exposedCount > 0 ? .orange : .secondary)
                }
            }
        } footer: {
            Text(KMR.t("Si aggiorna da solo ogni 5 secondi. Mostra i processi del tuo utente: quelli di sistema avviati come amministratore richiedono la password e non sono elencati.",
                       "Refreshes by itself every 5 seconds. Shows your user's processes: system ones started as administrator need the password and aren't listed."))
        }
    }

    private func row(_ l: ListeningPorts.Listener) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: model.icons[l.pid] ?? NSWorkspace.shared.icon(for: .unixExecutable))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName(l)).fontWeight(.medium)
                    Text("\(l.proto.rawValue) \(l.port)")
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if l.isExposed {
                        Label(KMR.t("Esposto in rete", "Exposed to the network"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text(ListeningPorts.explanation(port: l.port, proto: l.proto, command: l.command)
                     ?? KMR.t("Porta senza un uso comune: è quella che l'app ha scelto. Se non riconosci l'app, chiudila.",
                              "No common meaning: it's the port the app picked. If you don't recognise the app, quit it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(KMR.t("PID \(l.pid) · \(l.user ?? "uid \(l.uid.map(String.init) ?? "?")") · \(addressText(l))",
                           "PID \(l.pid) · \(l.user ?? "uid \(l.uid.map(String.init) ?? "?")") · \(addressText(l))"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if model.canTerminate(l) {
                Button(KMR.t("Termina…", "Terminate…")) { pendingKill = l }
                    .help(KMR.t("Termina processo", "Terminate process"))
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help(KMR.t("Processo di macOS: non si termina da qui.", "A macOS process: not terminated from here."))
                    .accessibilityLabel(KMR.t("Processo di macOS: non si termina da qui.", "A macOS process: not terminated from here."))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(KMR.t("Copia porta", "Copy Port")) { FileActions.copyText(String(l.port)) }
            Button(KMR.t("Copia PID", "Copy PID")) { FileActions.copyText(String(l.pid)) }
            if let app = NSRunningApplication(processIdentifier: l.pid)?.bundleURL {
                Button(KMR.t("Mostra app nel Finder", "Show App in Finder")) { FileActions.reveal([app]) }
            }
            if model.canTerminate(l) {
                Divider()
                Button(KMR.t("Termina…", "Terminate…"), role: .destructive) { pendingKill = l }
            }
        }
    }

    private func addressText(_ l: ListeningPorts.Listener) -> String {
        l.addresses.map { $0 == "*" ? KMR.t("tutte le reti", "all networks") : $0 }.joined(separator: ", ")
    }
}
