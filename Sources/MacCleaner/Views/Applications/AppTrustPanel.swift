import SwiftUI
import MacCleanerKit

/// Plain-language trust information for one app: who signed it, whether
/// Apple checked it, where it was downloaded from and what it can access.
/// Reusable anywhere an `AppInfo` is at hand; the work runs off the main
/// thread in `AppTrustInspector` and is cached.
struct AppTrustPanel: View {
    let app: AppInfo
    @State private var report: AppTrustReport?
    @State private var grants: [PrivacyPermission] = []

    var body: some View {
        Group {
            if let report {
                content(report)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(KMR.t("Verifica della firma…", "Checking the signature…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: app.path) {
            report = nil
            report = await AppTrustInspector.shared.report(for: app)
            grants = await TrustGrantCache.shared.permissions(bundleID: app.bundleIdentifier,
                                                              path: app.path.path(percentEncoded: false))
        }
    }

    private func verdictStyle(_ v: AppTrustVerdict) -> (String, Color) {
        switch v {
        case .trusted: ("checkmark.shield.fill", KMR.green)
        case .review: ("exclamationmark.shield.fill", KMR.orange)
        case .warning: ("xmark.shield.fill", KMR.red)
        }
    }

    private func yesNo(_ b: Bool) -> String { b ? KMR.t("Sì", "Yes") : KMR.t("No", "No") }

    @ViewBuilder
    private func content(_ r: AppTrustReport) -> some View {
        let (symbol, color) = verdictStyle(r.verdict)
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: symbol, color: color, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.verdict.title).font(.headline)
                        Text(r.verdictExplanation).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                LabeledContent(KMR.t("Firmata da", "Signed by")) {
                    Text(r.signer.title).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                .help(r.signer.explanation)
                LabeledContent(KMR.t("Notarizzata da Apple", "Notarized by Apple"), value: r.notarizationText)
                if case .developerID = r.signer {
                    LabeledContent(KMR.t("Certificato revocato", "Certificate revoked")) {
                        Text(yesNo(r.isRevoked)).foregroundStyle(r.isRevoked ? KMR.red : .secondary)
                    }
                }
                LabeledContent(KMR.t("Runtime protetto", "Hardened runtime"), value: yesNo(r.hardenedRuntime))
                LabeledContent(KMR.t("In sandbox", "Sandboxed"), value: yesNo(r.sandboxed))
            } header: {
                Text(KMR.t("Firma e controlli", "Signature and checks"))
            } footer: {
                Text(r.signer.explanation + " "
                     + KMR.t("Il runtime protetto e la sandbox limitano ciò che l'app può fare se viene compromessa.",
                             "Hardened runtime and the sandbox limit what the app can do if it is compromised."))
            }

            Section(KMR.t("Provenienza", "Origin")) {
                if let q = r.quarantine {
                    if let host = q.sourceHost {
                        LabeledContent(KMR.t("Scaricata da", "Downloaded from"), value: host)
                    }
                    if let agent = q.agent {
                        LabeledContent(KMR.t("Scaricata con", "Downloaded with"), value: agent)
                    }
                    if let date = q.date {
                        LabeledContent(KMR.t("Data del download", "Download date"),
                                       value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let first = q.whereFroms.first, q.sourceHost != nil {
                        Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                } else {
                    Label(KMR.t("Nessuna traccia di download: installata dall'App Store, da un pacchetto o copiata da un disco.",
                                "No download record: installed from the App Store, by a package or copied from a disk."),
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section(KMR.t("Informazioni", "Details")) {
                LabeledContent(KMR.t("Architettura", "Architecture"), value: r.architecture.title)
                LabeledContent(KMR.t("Ultima apertura", "Last opened"),
                               value: r.lastOpened?.formatted(date: .abbreviated, time: .omitted) ?? KMR.t("Sconosciuta", "Unknown"))
                LabeledContent(KMR.t("Dimensione", "Size"), value: FileSizeFormatter.format(r.size))
            }

            Section {
                if r.capabilities.isEmpty {
                    Label(KMR.t("Non chiede accesso a dati sensibili.", "It does not ask for sensitive data."),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(r.capabilities) { cap in
                    Label {
                        Text(cap.title)
                    } icon: {
                        IconTile(symbol: cap.symbol, color: cap.isSensitive ? KMR.orange : KMR.gray)
                    }
                }
            } header: {
                Text(KMR.t("Accessi che può chiedere", "Access it can ask for"))
            } footer: {
                Text(KMR.t("Dichiarati dall'app nei suoi permessi e nel suo Info.plist. macOS chiede comunque il tuo consenso prima di concederli.",
                           "Declared by the app in its entitlements and Info.plist. macOS still asks for your consent before granting them."))
            }

            if !grants.isEmpty {
                Section {
                    ForEach(grants) { p in
                        Label(Self.grantTitle(p), systemImage: "checkmark.seal.fill")
                    }
                } header: {
                    Text(KMR.t("Permessi già concessi", "Permissions already granted"))
                } footer: {
                    Text(KMR.t("Puoi revocarli in Impostazioni di Sistema › Privacy e sicurezza.",
                               "You can revoke them in System Settings › Privacy & Security."))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    static func grantTitle(_ p: PrivacyPermission) -> String {
        switch p {
        case .camera: KMR.t("Fotocamera", "Camera")
        case .microphone: KMR.t("Microfono", "Microphone")
        case .fullDiskAccess: KMR.t("Accesso completo al disco", "Full Disk Access")
        case .screenRecording: KMR.t("Registrazione schermo", "Screen recording")
        case .automation: KMR.t("Controllo di altre app", "Control other apps")
        }
    }
}

/// TCC grants read once per session (needs Full Disk Access; empty otherwise).
actor TrustGrantCache {
    static let shared = TrustGrantCache()
    private var grants: [AppPermissionGrant]?

    func permissions(bundleID: String, path: String) async -> [PrivacyPermission] {
        if grants == nil { grants = await AppPermissionsClient.live().load().grants }
        let mine = (grants ?? []).filter { $0.client == bundleID || $0.client == path || $0.client.hasPrefix(path + "/") }
        return PrivacyPermission.allCases.filter { p in mine.contains { $0.permission == p } }
    }
}
