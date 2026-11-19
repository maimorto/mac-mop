import SwiftUI
import AppKit
import MacCleanerKit

// "Installed packages": what .pkg installers put on this Mac (pkgutil
// receipts), what is still on disk, and a careful way to remove a package.
// Apple's receipts are never removable; shared system folders are never
// deleted, only the package's own files and its own empty folders.

struct InstalledPackage: Identifiable, Sendable {
    var id: String { receipt.packageID }
    let receipt: PackageReceipt
    /// Absolute paths from the receipt.
    let files: [String]
    let directories: [String]
    /// Files still on disk and their total size.
    let existingFiles: [String]
    let bytes: UInt64

    var appBundle: String? {
        directories.first { $0.hasSuffix(".app") && !$0.dropLast(4).contains(".app/") }
    }
    var isAppStore: Bool { files.contains { $0.contains(".app/Contents/_MASReceipt/") } }
}

@MainActor
@Observable
final class PackagesModel {
    var loading = false
    var loaded = false
    var progress: Double = 0
    var packages: [InstalledPackage] = []
    var busy: String?
    var lastBackup: URL?
    var errorMessage: String?

    /// Bumped by each load, so a load superseded by a newer one (the Apple
    /// toggle flipped twice) stops and never overwrites the newer list.
    private var generation = 0

    func load(includeApple: Bool) async {
        generation += 1
        let current = generation
        loading = true
        progress = 0
        let list = await Shell.run("/usr/sbin/pkgutil", ["--pkgs"])
        let ids = PackageReceipts.parseList(list.output, includeApple: includeApple)
        var result: [InstalledPackage] = []
        for (i, id) in ids.enumerated() {
            guard current == generation else { return }
            if let pkg = await Self.loadPackage(id) { result.append(pkg) }
            progress = Double(i + 1) / Double(max(ids.count, 1))
        }
        guard current == generation else { return }
        packages = result
        loading = false
        loaded = true
    }

    nonisolated static func loadPackage(_ id: String) async -> InstalledPackage? {
        async let info = Shell.run("/usr/sbin/pkgutil", ["--pkg-info", id])
        async let files = Shell.run("/usr/sbin/pkgutil", ["--only-files", "--files", id], timeout: 60)
        async let dirs = Shell.run("/usr/sbin/pkgutil", ["--only-dirs", "--files", id], timeout: 60)
        guard let receipt = await PackageReceipts.parseInfo(info.output) else { return nil }
        let filePaths = await PackageReceipts.parseFiles(files.output).map(receipt.absolutePath)
        let dirPaths = await PackageReceipts.parseFiles(dirs.output).map(receipt.absolutePath)
        return await Task.detached(priority: .userInitiated) {
            var existing: [String] = []
            var bytes: UInt64 = 0
            var st = stat()
            for path in filePaths where lstat(path, &st) == 0 {
                existing.append(path)
                bytes += UInt64(max(st.st_blocks, 0)) * 512
            }
            return InstalledPackage(receipt: receipt, files: filePaths, directories: dirPaths,
                                    existingFiles: existing, bytes: bytes)
        }.value
    }

    /// Removal plan, computed off the main thread: it unions every other
    /// receipt's paths (hundreds of thousands with Apple packages shown) and
    /// stats each file of the package.
    func plan(for pkg: InstalledPackage) async -> PackageReceipts.RemovalPlan? {
        let all = packages
        let home = MCConstants.home.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            var others = Set<String>()
            for p in all where p.id != pkg.id {
                others.formUnion(p.files)
                others.formUnion(p.directories)
            }
            return PackageReceipts.removalPlan(
                receipt: pkg.receipt, files: pkg.files, directories: pkg.directories,
                otherPackagesPaths: others, home: home,
                existing: { var st = stat(); return lstat($0, &st) == 0 })
        }.value
    }

    /// User files → Trash (Cleanup History); system files → admin prompt
    /// (backup folder or delete); then empty own folders and forget the receipt.
    func remove(_ pkg: InstalledPackage, deletePermanently: Bool, engine: CleaningEngine, includeApple: Bool) async {
        guard !pkg.receipt.isApple, let plan = await plan(for: pkg) else { return }
        busy = KMR.t("Rimozione del pacchetto…", "Removing the package…")
        defer { busy = nil }

        if !plan.userFiles.isEmpty {
            let items = plan.userFiles.map { path -> FileItem in
                let url = URL(filePath: path)
                var st = stat()
                let size = lstat(path, &st) == 0 ? UInt64(max(st.st_blocks, 0)) * 512 : 0
                return FileItem(url: url, name: url.lastPathComponent, size: size, allocatedSize: size, isDirectory: false)
            }
            _ = await CleanActions.executeUserClean(items: items, selectedItems: Set(items.map(\.url)), engine: engine)
        }

        var backup: URL?
        let action: PackageReceipts.SystemFileAction
        if deletePermanently || plan.systemFiles.isEmpty {
            action = .delete
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let stamp = formatter.string(from: Date())
            let folder = MCConstants.userAppSupport
                .appending(path: MCConstants.dataFolderName)
                .appending(path: "Package Backups")
                .appending(path: "\(pkg.id) \(stamp)")
            backup = folder
            action = .backup(folder: folder.path(percentEncoded: false))
        }
        let script = PackageReceipts.adminScript(packageID: pkg.id, systemFiles: plan.systemFiles,
                                                 directories: plan.directories, action: action, owner: NSUserName())
        if await Shell.runAsAdmin(script) {
            lastBackup = backup
            SoundFX.play(.cleanDone)
        } else {
            errorMessage = KMR.t("Il pacchetto non è stato rimosso: password annullata o errore. I file nella tua cartella Inizio sono nel Cestino e si possono ripristinare da Cronologia pulizia.",
                                 "The package was not removed: password cancelled or an error occurred. Files in your home folder are in the Trash and can be restored from Cleanup History.")
        }
        await load(includeApple: includeApple)
    }
}

struct PackagesView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PackagesModel()
    @State private var selectedID: String?
    @AppStorage("packagesShowApple") private var showApple = false
    @State private var packageQuery = ""
    @State private var pendingRemoval: InstalledPackage?
    /// Removal plan of the selected package, keyed by its id.
    @State private var plan: (id: String, value: PackageReceipts.RemovalPlan?)?

    var body: some View {
        ZStack {
            if model.loading && !model.loaded {
                ScanProgressRing(progress: model.progress, phase: KMR.t("Lettura dei pacchetti installati…", "Reading installed packages…"),
                                 indeterminate: false)
                    .environment(\.currentModule, .packages)
                    .transition(.immersive)
            } else if model.loaded {
                content.transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: model.loaded)
        .task {
            if !model.loaded { await model.load(includeApple: showApple) }
            // Debug hook for screenshots: KMR_SELECT_PACKAGE=<package id>.
            if let id = ProcessInfo.processInfo.environment["KMR_SELECT_PACKAGE"] { selectedID = id }
        }
        .onChange(of: showApple) { _, on in Task { await model.load(includeApple: on) } }
        .task(id: "\(selectedID ?? "")#\(model.packages.count)#\(model.loading)") {
            guard let pkg = selected, !model.loading else { plan = nil; return }
            if plan?.id != pkg.id { plan = nil }
            let value = await model.plan(for: pkg)
            if !Task.isCancelled { plan = (pkg.id, value) }
        }
        .respondsToModuleShortcuts(onScan: { Task { await model.load(includeApple: showApple) } }, canScan: !model.loading)
        .overlay(alignment: .bottom) {
            if let busy = model.busy {
                Label(busy, systemImage: "hourglass")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .alert(KMR.t("Pacchetti installati", "Installed packages"),
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(KMR.t("Rimuovere il pacchetto \(pendingRemoval?.id ?? "")?", "Remove package \(pendingRemoval?.id ?? "")?"),
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { pkg in
            Button(KMR.t("Rimuovi e conserva un backup", "Remove and keep a backup")) { start(pkg, delete: false) }
            if let plan = currentPlan(pkg), !plan.systemFiles.isEmpty {
                Button(KMR.t("Rimuovi ed elimina definitivamente", "Remove and delete permanently"), role: .destructive) { start(pkg, delete: true) }
            }
            Button(KMR.t("Annulla", "Cancel"), role: .cancel) {}
        } message: { pkg in
            Text(removalSummary(pkg))
        }
    }

    private func start(_ pkg: InstalledPackage, delete: Bool) {
        pendingRemoval = nil
        Task { await model.remove(pkg, deletePermanently: delete, engine: appState.cleaningEngine, includeApple: showApple) }
    }

    private func currentPlan(_ pkg: InstalledPackage) -> PackageReceipts.RemovalPlan? {
        plan?.id == pkg.id ? plan?.value : nil
    }

    private func removalSummary(_ pkg: InstalledPackage) -> String {
        guard let plan = currentPlan(pkg) else { return "" }
        var parts: [String] = []
        if !plan.userFiles.isEmpty {
            parts.append(KMR.t("File nella tua cartella Inizio, nel Cestino: \(plan.userFiles.count)",
                               "Files in your home folder, to the Trash: \(plan.userFiles.count)"))
        }
        if !plan.systemFiles.isEmpty {
            parts.append(KMR.t("File di sistema (serve la password): \(plan.systemFiles.count). Con il backup vengono spostati in Libreria › Application Support › \(MCConstants.dataFolderName) › Package Backups; altrimenti vengono eliminati senza Cestino.",
                               "System files (password needed): \(plan.systemFiles.count). With a backup they are moved to Library › Application Support › \(MCConstants.dataFolderName) › Package Backups; otherwise they are deleted without the Trash."))
        }
        parts.append(KMR.t("Le cartelle del pacchetto vengono tolte solo se vuote; le cartelle di sistema condivise non vengono mai toccate. Infine macOS dimentica la ricevuta del pacchetto.",
                           "The package's folders are removed only when empty; shared system folders are never touched. Finally macOS forgets the package receipt."))
        if !plan.sharedFiles.isEmpty {
            parts.append(KMR.t("Elementi lasciati perché usati da altri pacchetti: \(plan.sharedFiles.count)",
                               "Items left because other packages use them: \(plan.sharedFiles.count)"))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Layout

    private var selected: InstalledPackage? { model.packages.first { $0.id == selectedID } }

    private var content: some View {
        VStack(spacing: 0) {
            AppsPageHeader(
                title: KMR.t("Pacchetti installati", "Installed packages"),
                subtitle: KMR.t("Cosa hanno installato i file .pkg, cosa è ancora sul disco e come toglierlo con cura.",
                                "What .pkg installers put on this Mac, what is still on disk, and how to remove it carefully.")
            ) {
                HStack(spacing: 8) {
                    NativeSearchField(text: $packageQuery, prompt: KMR.t("Cerca pacchetti", "Search packages"))
                        .frame(width: 180)
                    Toggle(KMR.t("Mostra pacchetti Apple", "Show Apple packages"), isOn: $showApple)
                        .toggleStyle(.switch).controlSize(.small)
                    if model.loading { ProgressView().controlSize(.small) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if model.packages.isEmpty {
                ContentUnavailableView(KMR.t("Nessun pacchetto", "No packages"), systemImage: "shippingbox",
                                       description: Text(KMR.t("Nessun programma di installazione di terze parti ha lasciato ricevute su questo Mac.",
                                                               "No third-party installer left receipts on this Mac.")))
            } else {
                HSplitView {
                    // Minimums fit the smallest window (800 pt minus the sidebar).
                    packageList.frame(minWidth: 220, idealWidth: 300)
                    detail.frame(minWidth: 280, maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                .kmrGroupedBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var packageList: some View {
        let shown = model.packages.filter {
            SearchMatcher.tokens(packageQuery).isEmpty
                || SearchMatcher.matches(query: packageQuery, fields: [$0.id, $0.receipt.version])
        }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return List(selection: $selectedID) {
            if shown.isEmpty {
                Text(KMR.t("Nessun pacchetto per «\(packageQuery)»", "No packages match “\(packageQuery)”"))
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(PackageReceipts.groupedByVendor(shown.map(\.receipt)), id: \.vendor) { group in
                Section(group.vendor) {
                    ForEach(group.receipts) { receipt in
                        if let pkg = byID[receipt.packageID] {
                            row(pkg).tag(pkg.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func row(_ pkg: InstalledPackage) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: pkg.receipt.isApple ? "apple.logo" : "shippingbox.fill",
                     color: pkg.receipt.isApple ? KMR.gray : Color(nsColor: .systemBrown), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(pkg.id).lineLimit(1).truncationMode(.middle)
                Text([pkg.receipt.version.isEmpty || pkg.receipt.version == "0" ? nil : "v\(pkg.receipt.version)",
                      pkg.receipt.installDate?.formatted(date: .abbreviated, time: .omitted),
                      FileSizeFormatter.format(pkg.bytes)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            if pkg.receipt.isApple {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .help(KMR.t("Protetto: componente di Apple", "Protected: Apple component"))
            } else if pkg.existingFiles.isEmpty {
                Text(KMR.t("Solo ricevuta", "Receipt only")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var detail: some View {
        if let pkg = selected {
            packageDetail(pkg)
        } else {
            ContentUnavailableView(KMR.t("Seleziona un pacchetto", "Select a package"), systemImage: "shippingbox",
                                   description: Text(KMR.t("Vedrai cosa ha installato e cosa resta sul disco.",
                                                           "You will see what it installed and what is still on disk.")))
        }
    }

    private func packageDetail(_ pkg: InstalledPackage) -> some View {
        let plan = currentPlan(pkg)
        let home = MCConstants.home.path(percentEncoded: false)
        return Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: pkg.receipt.isApple ? "apple.logo" : "shippingbox.fill",
                             color: pkg.receipt.isApple ? KMR.gray : Color(nsColor: .systemBrown), size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pkg.id).font(.headline).textSelection(.enabled)
                        if pkg.receipt.isApple {
                            ProtectedBadge()
                        } else {
                            SafetyBadge(safety: .reviewFirst)
                        }
                    }
                }
                LabeledContent(KMR.t("Versione", "Version"), value: pkg.receipt.version.isEmpty ? "—" : pkg.receipt.version)
                LabeledContent(KMR.t("Installato il", "Installed on"),
                               value: pkg.receipt.installDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent(KMR.t("Posizione", "Location"), value: pkg.receipt.root)
                LabeledContent(KMR.t("File ancora presenti", "Files still present"),
                               value: "\(pkg.existingFiles.count) / \(pkg.files.count)")
                LabeledContent(KMR.t("Spazio occupato", "Space used"), value: FileSizeFormatter.format(pkg.bytes))
            } footer: {
                if pkg.receipt.isApple {
                    Text(KMR.t("Componente di macOS o di un'app Apple: non si può rimuovere da qui.",
                               "Part of macOS or an Apple app: it cannot be removed from here."))
                } else if pkg.isAppStore {
                    Text(KMR.t("App del Mac App Store: per toglierla usa il Disinstallatore, che rimuove anche i file residui.",
                               "Mac App Store app: use the Uninstaller to remove it, which also removes its leftover files."))
                } else {
                    Text(KMR.t("Una ricevuta è l'elenco dei file che un programma di installazione .pkg ha copiato. Rimuovere il pacchetto toglie quei file, non i tuoi documenti.",
                               "A receipt is the list of files a .pkg installer copied. Removing the package removes those files, not your documents."))
                }
            }

            if !pkg.receipt.isApple, plan == nil {
                Section(KMR.t("Rimozione", "Removal")) { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            }
            if !pkg.receipt.isApple, let plan {
                Section {
                    LabeledContent(KMR.t("Nella tua cartella Inizio (Cestino)", "In your home folder (Trash)"), value: "\(plan.userFiles.count)")
                    LabeledContent(KMR.t("Di sistema (serve la password)", "System (password needed)"), value: "\(plan.systemFiles.count)")
                    LabeledContent(KMR.t("Cartelle tolte se vuote", "Folders removed if empty"), value: "\(plan.directories.count)")
                    if !plan.protectedPaths.isEmpty || !plan.sharedFiles.isEmpty {
                        LabeledContent(KMR.t("Protetti o condivisi (lasciati)", "Protected or shared (left alone)"),
                                       value: "\(plan.protectedPaths.count + plan.sharedFiles.count)")
                    }
                    HStack {
                        if let app = pkg.appBundle, FileManager.default.fileExists(atPath: app) {
                            Button(KMR.t("Apri nel Disinstallatore", "Open in Uninstaller")) {
                                appState.openUninstaller(forAppPath: app)
                            }
                        }
                        Spacer()
                        Button(KMR.t("Rimuovi pacchetto…", "Remove package…")) { pendingRemoval = pkg }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(model.busy != nil || model.loading)
                    }
                    if let backup = model.lastBackup {
                        Button(KMR.t("Mostra l'ultimo backup nel Finder", "Show the last backup in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([backup])
                        }
                    }
                } header: {
                    Text(KMR.t("Rimozione", "Removal"))
                } footer: {
                    Text(KMR.t("Le cartelle condivise come /Applications, /Library e /usr/local non vengono mai eliminate: solo i file del pacchetto e le sue cartelle rimaste vuote.",
                               "Shared folders such as /Applications, /Library and /usr/local are never deleted: only the package's files and its own folders once empty."))
                }
            }

            Section(KMR.t("File ancora presenti", "Files still present")) {
                if pkg.existingFiles.isEmpty {
                    Label(KMR.t("Nessun file: resta solo la ricevuta.", "No files: only the receipt is left."),
                          systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(pkg.existingFiles.prefix(300), id: \.self) { path in
                    HStack {
                        Image(systemName: path.hasPrefix(home) ? "person.crop.circle" : "lock.shield")
                            .foregroundStyle(.secondary)
                            .help(path.hasPrefix(home)
                                  ? KMR.t("Nella tua cartella Inizio: va nel Cestino", "In your home folder: goes to the Trash")
                                  : KMR.t("File di sistema: serve la password", "System file: password needed"))
                        Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .contextMenu {
                        FileContextMenuItems(url: URL(filePath: path))
                    }
                }
                if pkg.existingFiles.count > 300 {
                    Text(KMR.t("Altri file: \(pkg.existingFiles.count - 300)", "More files: \(pkg.existingFiles.count - 300)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// "Protected": never offered for removal.
struct ProtectedBadge: View {
    var body: some View {
        Label(KMR.t("Protetto", "Protected"), systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.14), in: Capsule())
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}
