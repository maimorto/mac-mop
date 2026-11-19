import SwiftUI
import AppKit
import MacCleanerKit

// "Extra space": space hogs that are not junk files but are easy to forget —
// leftover installers, local Time Machine snapshots, Docker data — plus the
// purgeable space macOS can free on its own.

// MARK: - Shell helper

enum Shell {
    struct Result { let status: Int32; let output: String }

    /// Runs a command off the main thread with a timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: Result(status: -1, output: "")); return }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Runs a shell command with the administrator password prompt.
    static func runAsAdmin(_ command: String) async -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let r = await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 300)
        return r.status == 0
    }
}

// MARK: - Model

struct InstallerFile: Identifiable, Hashable {
    let url: URL
    let size: UInt64
    let date: Date?
    let installedApp: String?
    var id: URL { url }
}

@MainActor
@Observable
final class StorageExtrasModel {
    var scanning = false
    var scanned = false
    var installers: [InstallerFile] = []
    var selectedInstallers: Set<URL> = []
    var snapshots: [String] = []
    var dockerPath: String?
    var dockerRunning = false
    var dockerRows: [(type: String, size: String, reclaimable: String)] = []
    var purgeable: UInt64 = 0
    var busy: String?

    nonisolated static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    func scan() async {
        scanning = true
        async let inst = Self.findInstallers()
        async let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        let docker = Self.findDocker()
        dockerPath = docker
        if let docker {
            let r = await Shell.run(docker, ["system", "df", "--format", "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}"], timeout: 10)
            dockerRunning = r.status == 0
            dockerRows = r.output.split(separator: "\n").compactMap {
                let f = $0.split(separator: "\t").map(String.init)
                return f.count == 3 ? (f[0], f[1], f[2]) : nil
            }
        }
        installers = await inst
        selectedInstallers = Set(installers.filter { $0.installedApp != nil }.map(\.url))
        snapshots = await snaps.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple") }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            let important = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
            let plain = UInt64(max(0, v.volumeAvailableCapacity ?? 0))
            purgeable = important > plain ? important - plain : 0
        }
        scanning = false
        scanned = true
        SoundFX.play(.scanDone)
    }

    nonisolated static func findDocker() -> String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "\(home)/.local/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func findInstallers() async -> [InstallerFile] {
        await Task.detached(priority: .userInitiated) { scanInstallers() }.value
    }

    nonisolated static func scanInstallers() -> [InstallerFile] {
        let home = NSHomeDirectory()
        let roots: [(String, Int)] = [
            ("\(home)/Downloads", 4), ("\(home)/Desktop", 3), ("\(home)/Documents", 2),
            ("\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", 3),
            ("\(home)/Library/Caches/Homebrew/downloads", 1),
        ]
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        let appNames = apps.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        var found: [InstallerFile] = []
        var seen = Set<String>()
        for (root, depth) in roots {
            let base = URL(fileURLWithPath: root)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = e.nextObject() as? URL {
                if e.level > depth { e.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                guard installerExtensions.contains(ext), seen.insert(url.path).inserted else { continue }
                let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey])
                let size = UInt64(v?.totalFileAllocatedSize ?? 0)
                guard size > 0 else { continue }
                found.append(InstallerFile(url: url, size: size, date: v?.contentModificationDate,
                                           installedApp: matchApp(url.deletingPathExtension().lastPathComponent, appNames)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// "Obsidian-1.12.4" → "Obsidian" if Obsidian.app is installed.
    nonisolated static func matchApp(_ file: String, _ apps: [String]) -> String? {
        let key = file.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return apps.first { app in
            let a = app.lowercased()
            let first = a.split(separator: " ").first.map(String.init) ?? a
            return first.count >= 4 && (key.hasPrefix(a) || key.hasPrefix(first))
        }
    }

    func trashInstallers() {
        let urls = Array(selectedInstallers)
        NSWorkspace.shared.recycle(urls) { [weak self] done, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let removed = Set(done.keys)
                    withAnimation(.smooth) {
                        self.installers.removeAll { removed.contains($0.url) }
                        self.selectedInstallers.subtract(removed)
                    }
                    SoundFX.play(.cleanDone)
                }
            }
        }
    }

    func deleteSnapshots() async {
        busy = KMR.t("Eliminazione delle istantanee…", "Deleting snapshots…")
        if await Shell.runAsAdmin("/usr/bin/tmutil deletelocalsnapshots /") {
            withAnimation(.smooth) { snapshots = [] }
            SoundFX.play(.cleanDone)
        }
        busy = nil
    }

    func pruneDocker() async {
        guard let dockerPath else { return }
        busy = KMR.t("Pulizia di Docker…", "Cleaning Docker…")
        let r = await Shell.run(dockerPath, ["system", "prune", "-a", "-f"], timeout: 600)
        busy = nil
        if r.status == 0 {
            SoundFX.play(.cleanDone)
            await scan()
        }
    }
}

// MARK: - View

struct StorageExtrasView: View {
    @State private var model = StorageExtrasModel()
    @State private var confirmInstallers = false
    @State private var confirmSnapshots = false
    @State private var confirmDocker = false

    var body: some View {
        ZStack {
            if model.scanning {
                ScanProgressRing(progress: 0, phase: KMR.t("Ricerca di spazio nascosto…", "Looking for hidden space…"), indeterminate: true)
                    .environment(\.currentModule, .storageExtras)
                    .transition(.immersive)
            } else if !model.scanned {
                ContentUnavailableView {
                    Label(KMR.t("Spazio extra", "Extra space"), systemImage: "externaldrive.badge.plus")
                } description: {
                    Text(KMR.t("Trova lo spazio che le altre pulizie non vedono: installer dimenticati, istantanee locali di Time Machine e dati di Docker.",
                               "Find space other cleanups miss: forgotten installers, local Time Machine snapshots and Docker data."))
                } actions: {
                    Button(KMR.t("Cerca", "Search")) { Task { await model.scan() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .transition(.immersive)
            } else {
                results.transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: model.scanning)
        .animation(.immersiveScreen, value: model.scanned)
        .overlay(alignment: .bottom) {
            if let busy = model.busy {
                Label(busy, systemImage: "hourglass")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.busy)
        .task {
            if ProcessInfo.processInfo.environment["KMR_AUTOSCAN"] != nil, !model.scanned { await model.scan() }
        }
    }

    static func dockerLabel(_ t: String) -> String {
        switch t {
        case "Images": KMR.t("Immagini", "Images")
        case "Containers": KMR.t("Container", "Containers")
        case "Local Volumes": KMR.t("Volumi (non toccati)", "Volumes (not touched)")
        case "Build Cache": KMR.t("Cache di build", "Build cache")
        default: t
        }
    }

    private var results: some View {
        Form {
            installersSection
            snapshotsSection
            dockerSection
            Section {
                LabeledContent(KMR.t("Spazio che macOS può liberare da solo", "Space macOS can free by itself"),
                               value: FileSizeFormatter.format(model.purgeable))
            } footer: {
                Text(KMR.t("Cache e copie di file in iCloud che macOS elimina automaticamente quando serve spazio. Non va pulito a mano.",
                           "Caches and iCloud file copies macOS removes automatically when it needs space. No need to clean it by hand."))
            }
            Section {
                Button(KMR.t("Cerca di nuovo", "Search again")) { Task { await model.scan() } }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Installers

    private var installersSection: some View {
        let selectedBytes = model.installers.filter { model.selectedInstallers.contains($0.url) }.reduce(UInt64(0)) { $0 + $1.size }
        return Section {
            if model.installers.isEmpty {
                Label(KMR.t("Nessun installer trovato", "No installers found"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.installers.prefix(80)) { file in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { model.selectedInstallers.contains(file.url) },
                        set: { on in if on { model.selectedInstallers.insert(file.url) } else { model.selectedInstallers.remove(file.url) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if let app = file.installedApp {
                                Text(KMR.t("\(app) già installata", "\(app) installed"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(KMR.green)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(KMR.green.opacity(0.14), in: Capsule())
                            }
                        }
                        Text([FriendlyName.shortPath(file.url), file.date?.formatted(date: .abbreviated, time: .omitted)]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(FileSizeFormatter.format(file.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                .contextMenu {
                    FileContextMenuItems(url: file.url)
                }
            }
            if !model.installers.isEmpty {
                HStack {
                    Text(KMR.t("\(FileSizeFormatter.format(selectedBytes)) selezionati", "\(FileSizeFormatter.format(selectedBytes)) selected"))
                        .foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button(KMR.t("Sposta nel Cestino", "Move to Trash")) { confirmInstallers = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedInstallers.isEmpty)
                        .confirmationDialog(KMR.t("Spostare gli installer nel Cestino?", "Move the installers to the Trash?"),
                                            isPresented: $confirmInstallers) {
                            Button(KMR.t("Sposta nel Cestino", "Move to Trash"), role: .destructive) { model.trashInstallers() }
                        } message: {
                            Text(KMR.t("Le app già installate continuano a funzionare. Potrai ripristinare i file dal Cestino.",
                                       "Installed apps keep working. You can restore the files from the Trash."))
                        }
                }
            }
        } header: {
            Text(KMR.t("Installer dimenticati", "Forgotten installers"))
        } footer: {
            Text(KMR.t("File .dmg, .pkg, .iso e .xip in Download, Scrivania, Documenti, allegati di Mail e cache di Homebrew. Servono solo per installare: l'app resta. Sono preselezionati solo quelli di app già installate.",
                       ".dmg, .pkg, .iso and .xip files in Downloads, Desktop, Documents, Mail attachments and the Homebrew cache. They are only needed to install: the app stays. Only those of installed apps are preselected."))
        }
    }

    // MARK: Snapshots

    private var snapshotsSection: some View {
        Section {
            if model.snapshots.isEmpty {
                Label(KMR.t("Nessuna istantanea locale", "No local snapshots"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(KMR.t("Istantanee sul disco", "Snapshots on disk"), value: "\(model.snapshots.count)")
                ForEach(model.snapshots.prefix(6), id: \.self) { s in
                    Text(s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: ""))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button(KMR.t("Elimina istantanee locali…", "Delete local snapshots…"), role: .destructive) { confirmSnapshots = true }
                    .confirmationDialog(KMR.t("Eliminare le istantanee locali?", "Delete local snapshots?"), isPresented: $confirmSnapshots) {
                        Button(KMR.t("Elimina", "Delete"), role: .destructive) { Task { await model.deleteSnapshots() } }
                    } message: {
                        Text(KMR.t("Perderai i punti di ripristino delle ultime ore salvati su questo Mac. I backup sul disco di Time Machine non vengono toccati. Ti verrà chiesta la password.",
                                   "You lose the recent restore points stored on this Mac. Backups on your Time Machine disk are not touched. You will be asked for your password."))
                    }
            }
        } header: {
            Text(KMR.t("Istantanee locali di Time Machine", "Local Time Machine snapshots"))
        } footer: {
            Text(KMR.t("macOS le elimina da solo quando serve spazio. Cancellarle ora libera spazio subito.",
                       "macOS removes them by itself when space is needed. Deleting them now frees space immediately."))
        }
    }

    // MARK: Docker

    private var dockerSection: some View {
        Section {
            if model.dockerPath == nil {
                Label(KMR.t("Docker non è installato", "Docker is not installed"), systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
            } else if !model.dockerRunning {
                Label(KMR.t("Docker non è in esecuzione. Avvia Docker Desktop o Colima e cerca di nuovo.",
                            "Docker is not running. Start Docker Desktop or Colima and search again."),
                      systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.dockerRows, id: \.type) { row in
                    LabeledContent(StorageExtrasView.dockerLabel(row.type)) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.size).monospacedDigit()
                            Text(KMR.t("recuperabili \(row.reclaimable)", "reclaimable \(row.reclaimable)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(KMR.t("Pulisci immagini e cache inutilizzate…", "Clean unused images and cache…")) { confirmDocker = true }
                    .confirmationDialog(KMR.t("Pulire Docker?", "Clean Docker?"), isPresented: $confirmDocker) {
                        Button(KMR.t("Pulisci", "Clean"), role: .destructive) { Task { await model.pruneDocker() } }
                    } message: {
                        Text(KMR.t("Rimuove container fermi, immagini non usate da nessun container e cache di build. I volumi, dove vivono i database, non vengono toccati. Le immagini si riscaricano quando servono.",
                                   "Removes stopped containers, images no container uses and build cache. Volumes, where databases live, are not touched. Images are downloaded again when needed."))
                    }
            }
        } header: {
            Text("Docker")
        } footer: {
            if model.dockerPath != nil {
                Text(KMR.t("Con Colima lo spazio liberato dentro la macchina virtuale potrebbe tornare al Mac solo dopo aver eseguito `colima ssh -- sudo fstrim -av`.",
                           "With Colima, space freed inside the virtual machine may only return to your Mac after running `colima ssh -- sudo fstrim -av`."))
            }
        }
    }
}
