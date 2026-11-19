import SwiftUI
import AppKit
import MacCleanerKit

// Space Lens: a fast, zoomable treemap of a folder or the whole disk.
//
// Navigation works like Finder: `path` is the chain root → current folder,
// `back`/`forward` are history stacks of whole paths. The selection is always
// a direct child of the current folder (i.e. a tile you can see); it is cleared
// on every folder change, rescan and trash, and every action re-validates its
// target before touching the disk.

// MARK: - Model

@MainActor
@Observable
final class SpaceLensModel {
    enum Target: Hashable {
        case home, disk, folder(URL)

        var url: URL {
            switch self {
            case .home: FileManager.default.homeDirectoryForCurrentUser
            case .disk: URL(fileURLWithPath: "/System/Volumes/Data")
            case .folder(let u): u
            }
        }

        var title: String {
            switch self {
            case .home: KMR.t("Cartella Inizio", "Home folder")
            case .disk: "Macintosh HD"
            case .folder(let u): FileManager.default.displayName(atPath: u.path)
            }
        }
    }

    /// Everything the inspector shows, computed once per selection/folder
    /// change (kind and the safety check touch the file system).
    struct Inspected {
        let node: DiskNode
        /// True when `node` is the selection (the target of actions), false
        /// when the inspector is just describing the current folder.
        let isSelection: Bool
        let displayPath: String
        let kind: String
        let size: UInt64
        /// Why the item can't be moved to the Trash; nil when it can.
        let protection: String?
    }

    var target: Target = .home
    private(set) var root: DiskNode?
    /// Target that produced `root` (differs from `target` while a new scan runs).
    private(set) var rootTarget: Target?
    /// root … current folder. Never empty while `root` is set.
    private(set) var path: [DiskNode] = []
    private(set) var back: [[DiskNode]] = []
    private(set) var forward: [[DiskNode]] = []
    /// Always a direct, visible child of `current` (or nil).
    private(set) var selection: DiskNode?
    private(set) var inspected: Inspected?
    /// Item waiting for the user's confirmation in the Trash dialog.
    private(set) var pendingTrash: DiskNode?
    private(set) var isTrashing = false
    var trashError: String?

    var isScanning = false
    var scannedItems = 0
    var scannedBytes: UInt64 = 0
    var started = Date()
    var lastScan: Date?
    var zoomToken = 0
    /// Size measured by the previous scan of each target, for an honest progress estimate.
    var knownSize: [String: UInt64] = [:]

    /// Partial tree drawn while a scan runs: the root plus one node per
    /// top-level folder, resized from the scanner's live totals every 0.5 s.
    private(set) var liveRoot: DiskNode?
    /// Bumped on every live update (DiskNode itself is not observable).
    private(set) var liveRevision = 0
    private var liveNodes: [String: DiskNode] = [:]
    private var pollTicks = 0

    private var scanner: FastDiskScanner?
    private var poll: Timer?

    var current: DiskNode? { path.last }
    var canGoBack: Bool { !isScanning && !back.isEmpty }
    var canGoForward: Bool { !isScanning && !forward.isEmpty }
    var canGoUp: Bool { !isScanning && path.count > 1 }

    var estimatedTotal: UInt64? {
        if let known = knownSize[target.url.path] { return known }
        guard target == .disk else { return nil }
        let values = try? target.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let free = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return total > free ? total - free : 0
    }

    // MARK: Scan

    func scan(_ target: Target? = nil) {
        if let target { self.target = target }
        scanner?.cancel()
        let scanner = FastDiskScanner()
        self.scanner = scanner
        isScanning = true
        // Nothing may stay armed against the tree that is about to be replaced.
        pendingTrash = nil
        selection = nil
        refreshInspected()
        scannedItems = 0
        scannedBytes = 0
        started = Date()
        liveRoot = nil
        liveNodes = [:]
        pollTicks = 0
        let url = self.target.url
        let scannedTarget = self.target
        poll?.invalidate()
        // UI updates are throttled to 4 per second, read from the scanner.
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.scanner else { return }
                let p = s.progress
                self.scannedItems = p.items
                self.scannedBytes = p.bytes
                self.pollTicks += 1
                if self.pollTicks % 2 == 0 { self.updateLiveMap(from: s, url: url) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let node = scanner.scan(root: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scanner === scanner else { return }
                    self.finishScan(node, target: scannedTarget)
                }
            }
        }
    }

    /// Copies the scanner's per-folder totals into `liveRoot`. Node identity
    /// is kept per folder name so tiles glide to their new size instead of
    /// being rebuilt.
    private func updateLiveMap(from scanner: FastDiskScanner, url: URL) {
        let snapshot = scanner.liveSnapshot()
        guard !snapshot.tiles.isEmpty else { return }
        let root = liveRoot ?? DiskNode(name: target.title, isDirectory: true, size: 0, rootPath: url.path)
        var total = snapshot.loose
        var children: [DiskNode] = []
        for tile in snapshot.tiles {
            total &+= tile.bytes
            // Same rule as the finished tree: folders under 1 MB fold into "Other files".
            guard tile.bytes >= 1_048_576 else { continue }
            let node = liveNodes[tile.name] ?? {
                let n = DiskNode(name: tile.name, isDirectory: true, size: 0)
                n.parent = root
                liveNodes[tile.name] = n
                return n
            }()
            node.setLiveSize(tile.bytes)
            children.append(node)
        }
        children.sort { $0.size > $1.size }
        root.children = children
        root.setLiveSize(total)
        liveRoot = root
        liveRevision += 1
    }

    private func finishScan(_ node: DiskNode, target: Target) {
        poll?.invalidate()
        liveRoot = nil
        liveNodes = [:]
        // A rescan of the same place keeps you in the same folder (matched by
        // name in the new tree); history refers to the old tree, so it goes.
        let names = root?.path == node.path ? path.dropFirst().map(\.name) : []
        var newPath = [node]
        for name in names {
            guard let next = newPath.last?.children.first(where: { $0.isDirectory && $0.name == name }) else { break }
            newPath.append(next)
        }
        root = node
        rootTarget = target
        path = newPath
        back = []
        forward = []
        selection = nil
        pendingTrash = nil
        knownSize[node.path] = node.size
        isScanning = false
        lastScan = Date()
        zoomToken += 1
        refreshInspected()
        SoundFX.play(.scanDone)
    }

    func cancel() {
        scanner?.cancel()
        scanner = nil
        poll?.invalidate()
        isScanning = false
        liveRoot = nil
        liveNodes = [:]
        // The previous tree (if any) is still on screen: keep the title honest.
        if let rootTarget { target = rootTarget }
        refreshInspected()
    }

    // MARK: Navigation

    /// Double-click / "Open": folders are entered, anything else is selected.
    func open(_ node: DiskNode) {
        guard !isScanning, isVisibleChild(node) else { return }
        if node.isDirectory, node.size > 0 {
            navigate(to: path + [node])
        } else {
            select(node)
        }
    }

    func goBack() {
        guard canGoBack, let previous = back.popLast() else { return }
        forward.append(path)
        setPath(previous)
    }

    func goForward() {
        guard canGoForward, let next = forward.popLast() else { return }
        back.append(path)
        setPath(next)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: Array(path.dropLast()))
    }

    /// Breadcrumb click: jump to an ancestor of (or to) the current folder.
    func jump(to node: DiskNode) {
        guard !isScanning, let i = path.firstIndex(where: { $0 === node }) else { return }
        navigate(to: Array(path.prefix(i + 1)))
    }

    /// Esc: first clears the selection, then goes up a level.
    @discardableResult
    func escape() -> Bool {
        if selection != nil { select(nil); return true }
        if canGoUp { goUp(); return true }
        return false
    }

    /// Shows `node` in the treemap and selects it. Accepts a child of the
    /// current folder, or a child of the selected folder (entered first).
    func reveal(_ node: DiskNode) {
        guard !isScanning else { return }
        if isVisibleChild(node) { select(node); return }
        guard let parent = node.parent, isVisibleChild(parent),
              parent.children.contains(where: { $0 === node }) else { return }
        navigate(to: path + [parent])
        select(node)
    }

    private func navigate(to newPath: [DiskNode]) {
        guard !newPath.isEmpty, !Self.same(newPath, path) else { return }
        back.append(path)
        forward.removeAll()
        setPath(newPath)
    }

    private func setPath(_ newPath: [DiskNode]) {
        withAnimation(.smooth(duration: 0.38)) {
            path = newPath
            selection = nil
            pendingTrash = nil
            zoomToken += 1
        }
        refreshInspected()
    }

    // MARK: Selection

    func select(_ node: DiskNode?) {
        guard let node else {
            if selection != nil { selection = nil; refreshInspected() }
            return
        }
        guard !isScanning, isVisibleChild(node), selection !== node else { return }
        selection = node
        refreshInspected()
    }

    /// True when `node` is a tile of the current folder (identity-checked, so a
    /// node removed from the tree or from another scan never qualifies).
    func isVisibleChild(_ node: DiskNode) -> Bool {
        guard let current, node.parent === current else { return false }
        return current.children.contains { $0 === node }
    }

    private func refreshInspected() {
        guard !isScanning, let node = selection ?? current else { inspected = nil; return }
        let kind = (try? node.url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription
            ?? (node.isDirectory ? KMR.t("Cartella", "Folder") : KMR.t("File", "File"))
        inspected = Inspected(node: node,
                              isSelection: selection != nil,
                              displayPath: Self.canonicalPath(node.path),
                              kind: kind,
                              size: node.size,
                              protection: selection.flatMap { protectionReason(for: $0) })
    }

    // MARK: Safety

    /// `/System/Volumes/Data/Users/x` → `/Users/x`: the path Finder shows, and
    /// the one the safety rules understand (otherwise every disk-scan item
    /// would look like it lives under SIP-protected /System).
    static func canonicalPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }

    /// Why `node` must not be moved to the Trash, or nil if it may.
    func protectionReason(for node: DiskNode) -> String? {
        if isScanning { return KMR.t("Analisi in corso.", "A scan is running.") }
        if node === root || path.contains(where: { $0 === node }) {
            return KMR.t("È la cartella che stai esplorando (o una che la contiene).",
                         "It's the folder you are browsing (or one containing it).")
        }
        guard isVisibleChild(node) else {
            return KMR.t("L'elemento non è più in questa cartella.", "The item is no longer in this folder.")
        }
        let p = Self.canonicalPath(node.path)
        let home = Self.canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
        let systemReason = KMR.t("Cartella di sistema protetta.", "Protected system folder.")
        if p.split(separator: "/").count <= 1 || p == home || home.hasPrefix(p + "/") { return systemReason }
        let critical = ["Library", "Library/Keychains", "Library/Mobile Documents", "Library/Application Support",
                        "Library/Containers", "Library/Group Containers", "Library/Preferences", ".Trash"]
            .map { home + "/" + $0 }
        if critical.contains(p) || p.hasPrefix(home + "/Library/Keychains/") { return systemReason }
        do {
            try SafetyGuard().validatePath(URL(fileURLWithPath: p))
        } catch SafetyGuard.SafetyError.userExcluded {
            return KMR.t("È in una cartella che hai escluso nelle impostazioni.", "It's inside a folder you excluded in Settings.")
        } catch SafetyGuard.SafetyError.symlinkTarget {
            return KMR.t("Il percorso passa da un collegamento che porta altrove.", "The path goes through a link pointing elsewhere.")
        } catch {
            return systemReason
        }
        return nil
    }

    // MARK: Trash

    /// Arms the confirmation dialog. The item becomes the selection so the
    /// inspector shows exactly what the dialog is about.
    func requestTrash(_ node: DiskNode) {
        guard !isTrashing, protectionReason(for: node) == nil else { return }
        select(node)
        guard selection === node else { return }
        pendingTrash = node
    }

    func dismissTrash() { pendingTrash = nil }

    /// Tiles moved to the Trash from here, so an Undo (⌘Z) or a Cleanup
    /// History restore puts them back on the map without a rescan.
    @ObservationIgnored private var recentlyTrashed: [(node: DiskNode, parent: DiskNode)] = []

    func reinsertRestoredItems() {
        var restoredAny = false
        recentlyTrashed.removeAll { entry in
            guard FileManager.default.fileExists(atPath: entry.node.path) else { return false }
            entry.parent.reinsert(entry.node)
            restoredAny = true
            return true
        }
        if restoredAny { withAnimation(.smooth) { treeDidChange() } }
    }

    func confirmTrash() {
        guard let node = pendingTrash else { return }
        pendingTrash = nil
        // Re-validate at the last moment: folder, scan or tree may have changed.
        guard !isTrashing, selection === node, protectionReason(for: node) == nil else { return }
        isTrashing = true
        refreshInspected()
        let originalURL = node.url
        let bytes = node.size
        NSWorkspace.shared.recycle([originalURL]) { [weak self] newURLs, error in
            let message = error?.localizedDescription
            // Cleanup History + Edit › Undo (⌘Z), like every other clean.
            if message == nil, let trashURL = newURLs[originalURL] {
                CleanHistoryRecorder.record(trashedItems: [
                    CleaningEngine.TrashedItem(originalURL: originalURL, trashURL: trashURL, bytes: bytes)])
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTrashing = false
                    if let message {
                        self.trashError = message
                        self.refreshInspected()
                        return
                    }
                    withAnimation(.smooth) {
                        // Sizes are subtracted all the way up to the root.
                        if let parent = node.parent { self.recentlyTrashed.append((node, parent)) }
                        node.parent?.remove(node)
                        self.treeDidChange()
                    }
                    SoundFX.play(.cleanDone)
                }
            }
        }
    }

    /// After a removal: stay in the same folder if it still exists (else the
    /// nearest surviving ancestor), drop history entries that point into the
    /// removed subtree, and drop a selection that is no longer visible.
    private func treeDidChange() {
        guard let root else { return }
        path = validPrefix(path, root: root)
        if path.isEmpty { path = [root] }
        back = prune(back, root: root)
        forward = prune(forward, root: root)
        if let s = selection, !isVisibleChild(s) { selection = nil }
        if let t = pendingTrash, !isVisibleChild(t) { pendingTrash = nil }
        if let rootTarget { knownSize[rootTarget.url.path] = root.size }
        zoomToken += 1
        refreshInspected()
    }

    private func validPrefix(_ p: [DiskNode], root: DiskNode) -> [DiskNode] {
        guard let first = p.first, first === root else { return [] }
        var out = [first]
        for node in p.dropFirst() {
            guard let parent = out.last, node.parent === parent,
                  parent.children.contains(where: { $0 === node }) else { break }
            out.append(node)
        }
        return out
    }

    private func prune(_ stack: [[DiskNode]], root: DiskNode) -> [[DiskNode]] {
        var out: [[DiskNode]] = []
        for entry in stack {
            let p = validPrefix(entry, root: root)
            if !p.isEmpty, !Self.same(p, out.last ?? []) { out.append(p) }
        }
        return out
    }

    private static func same(_ a: [DiskNode], _ b: [DiskNode]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    }
}

// MARK: - View

struct SpaceLensView: View {
    @State private var model = SpaceLensModel()
    @State private var dropTargeted = false
    @Environment(\.moduleIsSelected) private var moduleIsSelected
    @FocusState private var lensFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            ZStack {
                if model.isScanning {
                    scanning.transition(.immersive)
                } else if let current = model.current {
                    HStack(spacing: 0) {
                        TreemapView(node: current, selected: model.selection,
                                    zoomToken: model.zoomToken,
                                    onOpen: { lensFocused = true; model.open($0) },
                                    onSelect: { lensFocused = true; model.select($0) },
                                    onTrash: { model.requestTrash($0) },
                                    canTrash: { model.protectionReason(for: $0) == nil })
                            .padding(14)
                            .contentShape(Rectangle())
                            .onTapGesture { lensFocused = true; model.select(nil) }
                        Divider().opacity(0.5)
                        Group {
                            if let info = model.inspected { inspector(info) } else { Color.clear }
                        }
                        .frame(width: 270)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($lensFocused)
                    .onKeyPress(.escape) { model.escape() ? .handled : .ignored }
                    .onKeyPress(.space) {
                        guard let node = model.selection else { return .ignored }
                        QuickLook.show(node.url)
                        return .handled
                    }
                    .transition(.immersive)
                } else {
                    intro.transition(.immersive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.immersiveScreen, value: model.isScanning)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            model.scan(.folder(url))
            return true
        } isTargeted: { dropTargeted = $0 }
        .confirmationDialog(trashTitle,
                            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.dismissTrash() } }),
                            titleVisibility: .visible,
                            presenting: model.pendingTrash) { _ in
            Button(KMR.t("Sposta nel Cestino", "Move to Trash"), role: .destructive) { model.confirmTrash() }
            Button(KMR.t("Annulla", "Cancel"), role: .cancel) { model.dismissTrash() }
        } message: { node in
            Text(KMR.t("\(node.isDirectory ? "Cartella" : "File") di \(FileSizeFormatter.format(node.size))\n\(SpaceLensModel.canonicalPath(node.path))\n\nPotrai ripristinarlo dal Cestino.",
                       "\(node.isDirectory ? KMR.t("Cartella", "Folder") : KMR.t("File", "File")) of \(FileSizeFormatter.format(node.size))\n\(SpaceLensModel.canonicalPath(node.path))\n\nYou can put it back from the Trash."))
        }
        .alert(KMR.t("Impossibile spostare nel Cestino", "Couldn't move to the Trash"),
               isPresented: Binding(get: { model.trashError != nil }, set: { if !$0 { model.trashError = nil } })) {
            Button("OK") { model.trashError = nil }
        } message: {
            Text(model.trashError ?? "")
        }
        .respondsToModuleShortcuts(onScan: { model.scan() }, canScan: !model.isScanning)
        .onReceive(NotificationCenter.default.publisher(for: CleanHistoryRecorder.didRestoreNotification)) { _ in
            model.reinsertRestoredItems()
        }
        .selectedFilesForMenu(model.selection.map { [$0.url] } ?? [], isVisible: moduleIsSelected)
        .task(id: model.root?.id) { if model.root != nil { lensFocused = true } }
        // The window's Back/Forward buttons, ⌘[ / ⌘] and the mouse/swipe
        // gestures walk the folder history first (AppNavigation.swift). Esc
        // keeps its own meaning here (deselect, then up a level).
        .pageNavigation(id: "spacelens.folders", canGoBack: model.canGoBack, handlesEscape: false,
                        back: { model.goBack() },
                        canGoForward: model.canGoForward, forward: { model.goForward() })
        .task {
            // Debug aid: KMR_SPACELENS=<folder> starts an analysis on open.
            if let path = ProcessInfo.processInfo.environment["KMR_SPACELENS"], model.root == nil {
                model.scan(.folder(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            }
        }
    }

    private var trashTitle: String {
        let name = model.pendingTrash?.name ?? ""
        return KMR.t("Spostare «\(name)» nel Cestino?", "Move “\(name)” to the Trash?")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.goUp() } label: { Label(KMR.t("Su di un livello", "Enclosing folder"), systemImage: "chevron.up") }
                .labelStyle(.iconOnly)
                .disabled(!model.canGoUp || !moduleIsSelected)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help(KMR.t("Su di un livello (⌘↑)", "Enclosing folder (⌘↑)"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.path.enumerated()), id: \.element.id) { i, node in
                        if i > 0 {
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        let isCurrent = i == model.path.count - 1
                        Button { model.jump(to: node) } label: {
                            Label {
                                Text(i == 0 ? (model.rootTarget?.title ?? node.name) : node.name)
                                    .lineLimit(1)
                                    .fontWeight(isCurrent ? .semibold : .regular)
                            } icon: {
                                FileIcon(path: node.path, size: 16)
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .disabled(model.isScanning)
                        .help(SpaceLensModel.canonicalPath(node.path))
                    }
                }
                .controlSize(.regular)
            }
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(KMR.t("Cartella Inizio", "Home folder")) { model.scan(.home) }
                Button("Macintosh HD") { model.scan(.disk) }
                Divider()
                Button(KMR.t("Scegli cartella…", "Choose folder…")) { chooseFolder() }
            } label: {
                Label(model.target.title, systemImage: "internaldrive")
            }
            .fixedSize()

            if model.isScanning {
                Button(KMR.t("Interrompi", "Stop")) { model.cancel() }
            } else {
                Button(model.root == nil ? KMR.t("Analizza", "Analyze") : KMR.t("Rianalizza", "Rescan")) { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = KMR.t("Analizza", "Analyze")
        if panel.runModal() == .OK, let url = panel.url { model.scan(.folder(url)) }
    }

    // MARK: States

    private var intro: some View {
        ContentUnavailableView {
            Label("Space Lens", systemImage: "square.grid.3x3.topleft.filled")
        } description: {
            Text(KMR.t("Guarda cosa occupa spazio, entra nelle cartelle con un doppio clic e sposta nel Cestino ciò che non ti serve. Puoi anche trascinare qui una cartella.",
                       "See what takes up space, open folders with a double-click and move what you don't need to the Trash. You can also drop a folder here."))
        } actions: {
            Button(KMR.t("Analizza la cartella Inizio", "Analyze Home folder")) { model.scan(.home) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button(KMR.t("Analizza tutto il disco", "Analyze the whole disk")) { model.scan(.disk) }
                .controlSize(.large)
        }
    }

    /// Live map once the first folders have numbers; the ring until then.
    @ViewBuilder
    private var scanning: some View {
        if let live = model.liveRoot {
            liveScanning(live)
        } else {
            scanningRing
        }
    }

    private var scanProgress: Double? {
        model.estimatedTotal.map { min(Double(model.scannedBytes) / Double(max($0, 1)), 0.99) }
    }

    private func liveScanning(_ live: DiskNode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KMR.t("Analisi di \(model.target.title)…", "Analyzing \(model.target.title)…"))
                        .font(.headline)
                    TimelineView(.periodic(from: model.started, by: 1)) { context in
                        Text(KMR.t("\(model.scannedItems.formatted()) elementi · \(FileSizeFormatter.format(model.scannedBytes)) · \(ScanProgressRing.elapsed(context.date.timeIntervalSince(model.started)))",
                                   "\(model.scannedItems.formatted()) items · \(FileSizeFormatter.format(model.scannedBytes)) · \(ScanProgressRing.elapsed(context.date.timeIntervalSince(model.started)))"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if let p = scanProgress {
                    ProgressView(value: p)
                        .frame(width: 160)
                    Text("\(Int((p * 100).rounded(.down)))%")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            TreemapView(node: live, selected: nil, zoomToken: 0, revision: model.liveRevision,
                        onOpen: { _ in }, onSelect: { _ in }, onTrash: { _ in }, canTrash: { _ in false })
                .padding(14)
                .allowsHitTesting(false)
                .help(KMR.t("La mappa si riempie mentre l'analisi procede. Al termine potrai entrare nelle cartelle e spostare elementi nel Cestino.",
                            "The map fills in as the scan runs. When it finishes you can open folders and move items to the Trash."))
        }
        .onAppear { ScanActivity.shared.begin(.spaceLens) }
        .onDisappear { ScanActivity.shared.end(.spaceLens) }
    }

    private var scanningRing: some View {
        let progress = scanProgress
        return ScanProgressRing(
            progress: progress ?? 0,
            phase: KMR.t("Analisi di \(model.target.title)…", "Analyzing \(model.target.title)…"),
            detail: KMR.t("\(model.scannedItems.formatted()) elementi · \(FileSizeFormatter.format(model.scannedBytes))",
                          "\(model.scannedItems.formatted()) items · \(FileSizeFormatter.format(model.scannedBytes))"),
            indeterminate: progress == nil)
            .environment(\.currentModule, .spaceLens)
    }

    // MARK: Inspector

    private func inspector(_ info: SpaceLensModel.Inspected) -> some View {
        let node = info.node
        let parentSize = node.parent?.size ?? info.size
        let share = parentSize > 0 ? min(1, Double(info.size) / Double(parentSize)) : 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(info.isSelection ? KMR.t("Elemento selezionato", "Selected item") : KMR.t("Cartella corrente", "Current folder"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    FileIcon(path: node.path, size: 64)
                    Text(node.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(FileSizeFormatter.format(info.size))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let parent = node.parent {
                        ProgressView(value: share)
                        Text(KMR.t("\(Int((share * 100).rounded()))% di \(parent.name)",
                                   "\(Int((share * 100).rounded()))% of \(parent.name)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.smooth(duration: 0.2), value: node.id)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text(KMR.t("Tipo", "Kind")).foregroundStyle(.secondary)
                        Text(info.kind)
                    }
                    if node.isDirectory {
                        GridRow {
                            Text(KMR.t("Contiene", "Contains")).foregroundStyle(.secondary)
                            Text(KMR.t("\(node.fileCount.formatted()) file", "\(node.fileCount.formatted()) files"))
                        }
                    }
                    GridRow {
                        Text(KMR.t("Percorso", "Path")).foregroundStyle(.secondary)
                        Text(info.displayPath)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .help(info.displayPath)
                    }
                }
                .font(.caption)

                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    } label: { Label("Finder", systemImage: "folder") }
                    if info.isSelection, node.isDirectory, node.size > 0 {
                        Button { model.open(node) } label: { Label(KMR.t("Apri", "Open"), systemImage: "arrow.down.right.circle") }
                            .keyboardShortcut(.downArrow, modifiers: .command)
                            .disabled(!moduleIsSelected)
                            .help(KMR.t("Entra nella cartella (⌘↓)", "Open the folder (⌘↓)"))
                    } else {
                        Button {
                            QuickLook.show(node.url)
                        } label: { Label(KMR.t("Anteprima", "Preview"), systemImage: "eye") }
                        .disabled(node.isDirectory)
                        .help(KMR.t("Anteprima (Spazio)", "Quick Look (Space)"))
                    }
                }
                .frame(maxWidth: .infinity)

                if info.isSelection {
                    VStack(spacing: 6) {
                        Button(role: .destructive) { model.requestTrash(node) } label: {
                            Label(KMR.t("Sposta nel Cestino…", "Move to Trash…"), systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(info.protection != nil || model.isScanning || model.isTrashing)
                        if let reason = info.protection {
                            Label(reason, systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.isTrashing {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Text(KMR.t("Seleziona un riquadro per vederne i dettagli o spostarlo nel Cestino. Doppio clic su una cartella per entrarci, Esc per tornare su.",
                               "Select a tile to see its details or move it to the Trash. Double-click a folder to open it, Esc to go back up."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }

                if node.isDirectory, !node.children.isEmpty {
                    Divider()
                    Text(KMR.t("Elementi più grandi", "Largest items")).font(.subheadline.weight(.semibold))
                    ForEach(Array(node.children.prefix(10).enumerated()), id: \.element.id) { index, child in
                        Button { model.reveal(child) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    FileIcon(path: child.path, size: 16)
                                    Text(child.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(FileSizeFormatter.format(child.size))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                GeometryReader { g in
                                    Capsule().fill(TreemapView.color(for: child, index: index).gradient)
                                        .frame(width: max(3, g.size.width * Double(child.size) / Double(max(node.size, 1))))
                                }
                                .frame(height: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .contextMenu {
                            FileContextMenuItems(url: child.url)
                            Divider()
                            Button(KMR.t("Sposta nel Cestino…", "Move to Trash…"), role: .destructive) { model.requestTrash(child) }
                                .disabled(model.protectionReason(for: child) != nil)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Treemap

struct TreemapView: View {
    let node: DiskNode
    let selected: DiskNode?
    let zoomToken: Int
    /// Changes when the node's sizes changed in place (live map during a scan).
    var revision: Int = 0
    let onOpen: (DiskNode) -> Void
    let onSelect: (DiskNode) -> Void
    let onTrash: (DiskNode) -> Void
    let canTrash: (DiskNode) -> Bool

    @State private var hovered: DiskNode?
    @State private var cache = LayoutCache()

    struct Tile: Identifiable {
        let id: ObjectIdentifier
        let node: DiskNode?
        let label: String
        let size: UInt64
        let rect: CGRect
        let index: Int
    }

    /// Layout memo: hover/selection changes re-run `body` but not the layout.
    final class LayoutCache {
        struct Key: Equatable {
            let node: ObjectIdentifier
            let size: UInt64
            let count: Int
            let token: Int
            let revision: Int
            let bounds: CGSize
        }
        var key: Key?
        var tiles: [Tile] = []
    }

    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemGreen, .systemPink,
                                             .systemTeal, .systemIndigo, .systemYellow, .systemRed, .systemBrown]

    static func color(for node: DiskNode?, index: Int) -> Color {
        guard let node else { return Color(nsColor: .systemGray) }
        if !node.isDirectory { return Color(nsColor: .systemGray).opacity(0.85) }
        return Color(nsColor: palette[index % palette.count])
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = cachedLayout(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    tileView(tile)
                        .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            .id(zoomToken)
            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                    removal: .opacity))
            .animation(revision == 0 ? nil : .smooth(duration: 0.45), value: revision)
        }
        .onChange(of: zoomToken) { hovered = nil }
    }

    private func cachedLayout(in size: CGSize) -> [Tile] {
        let key = LayoutCache.Key(node: node.id, size: node.size, count: node.children.count, token: zoomToken, revision: revision, bounds: size)
        if cache.key != key {
            cache.tiles = layout(in: CGRect(origin: .zero, size: size))
            cache.key = key
        }
        return cache.tiles
    }

    private func tileView(_ tile: Tile) -> some View {
        let base = Self.color(for: tile.node, index: tile.index)
        let isHover = tile.node != nil && hovered === tile.node
        let isSelected = tile.node != nil && selected === tile.node
        let big = tile.rect.width > 72 && tile.rect.height > 40
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(base.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(isHover ? 0.28 : 0.16), .clear], startPoint: .top, endPoint: .center))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.95 : 0), lineWidth: 2.5)
            }
            .overlay(alignment: .topLeading) {
                if big {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: tile.node?.isDirectory == true ? "folder.fill" : tile.node == nil ? "square.grid.3x3.fill" : "doc.fill")
                                .font(.caption)
                            Text(tile.label).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        Text(FileSizeFormatter.format(tile.size))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(8)
                }
            }
            .scaleEffect(isHover ? 1.012 : 1)
            .brightness(isHover ? 0.05 : 0)
            .animation(.smooth(duration: 0.15), value: isHover)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { inside in
                if inside { hovered = tile.node } else if hovered === tile.node { hovered = nil }
            }
            // Single click selects immediately; the second click of a
            // double-click opens (folders) — no single-click delay.
            .onTapGesture { if let n = tile.node { onSelect(n) } }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let n = tile.node { onOpen(n) } })
            .help("\(tile.label) — \(FileSizeFormatter.format(tile.size))")
            .contextMenu {
                if let n = tile.node {
                    if n.isDirectory, n.size > 0 {
                        Button(KMR.t("Apri", "Open")) { onOpen(n) }
                    }
                    Button(KMR.t("Mostra nel Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
                    if !n.isDirectory { Button(KMR.t("Anteprima", "Preview")) { QuickLook.show(n.url) } }
                    Button(KMR.t("Copia percorso", "Copy Path")) { FileActions.copyPaths([n.url]) }
                    Divider()
                    Button(KMR.t("Sposta nel Cestino…", "Move to Trash…"), role: .destructive) { onTrash(n) }
                        .disabled(!canTrash(n))
                }
            }
    }

    // MARK: Squarified layout

    private func layout(in rect: CGRect) -> [Tile] {
        var items: [(DiskNode?, String, UInt64, Int)] = node.children.prefix(160).enumerated().map { ($0.element, $0.element.name, $0.element.size, $0.offset) }
        let shown = items.reduce(UInt64(0)) { $0 + $1.2 }
        let rest = node.size > shown ? node.size - shown : 0
        if rest > node.size / 200 {
            items.append((nil, KMR.t("Altri file", "Other files"), rest, items.count))
        }
        items = items.filter { $0.2 > 0 }
        let total = Double(items.reduce(UInt64(0)) { $0 + $1.2 })
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        let areas = items.map { Double($0.2) * scale }
        var tiles: [Tile] = []
        var free = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(free.width, free.height))
            var row: [Int] = [i]
            var rowSum = areas[i]
            func worst(_ sum: Double, _ idx: [Int]) -> Double {
                let mx = idx.map { areas[$0] }.max() ?? 0, mn = idx.map { areas[$0] }.min() ?? 1
                return max(side * side * mx / (sum * sum), (sum * sum) / (side * side * max(mn, 0.0001)))
            }
            var j = i + 1
            while j < areas.count {
                let next = row + [j]
                if worst(rowSum + areas[j], next) <= worst(rowSum, row) {
                    row = next; rowSum += areas[j]; j += 1
                } else { break }
            }
            let thickness = rowSum / side
            var offset = 0.0
            for k in row {
                let length = areas[k] / thickness
                let r: CGRect = free.width >= free.height
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                let it = items[k]
                tiles.append(Tile(id: it.0.map { ObjectIdentifier($0) } ?? ObjectIdentifier(DiskNode.self),
                                  node: it.0, label: it.1, size: it.2, rect: r, index: it.3))
                offset += length
            }
            if free.width >= free.height {
                free = CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
            } else {
                free = CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
            }
            i = j
        }
        return tiles
    }
}

// MARK: - Quick Look

@MainActor
enum QuickLook {
    /// The system Quick Look panel, in-process (Space or Esc closes it).
    @MainActor static func show(_ url: URL) {
        QuickLookPanelController.shared.show([url])
    }
}
