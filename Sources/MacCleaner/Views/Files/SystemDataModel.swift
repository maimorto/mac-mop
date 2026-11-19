import SwiftUI
import AppKit
import MacCleanerKit

/// State of the System Data section. A single shared instance, so results
/// survive switching sections (the scan is not cheap).
@MainActor
@Observable
final class SystemDataModel {
    static let shared = SystemDataModel()

    private(set) var categories: [SystemDataCategory] = []
    private(set) var measurements: [SystemDataCategoryID: SystemDataMeasurement] = [:]
    private(set) var snapshotNames: [String] = []
    private(set) var backupInfo: [String: (name: String?, date: Date?)] = [:]
    private(set) var scanning = false
    private(set) var scannedAt: Date?
    private(set) var itemsVisited = 0
    private(set) var homeWalking = false
    private(set) var categoryGrowth: [SystemDataGrowth] = []
    private(set) var folderGrowth: [SystemDataGrowth] = []
    private(set) var categoryBaselineDate: Date?
    private(set) var folderBaselineDate: Date?
    private(set) var lastHistory: SystemDataSnapshot?
    /// Paths of the items ticked for cleaning. Changed only through
    /// `setSelected`/`setAll`/`replaceSelection`, which keep the summaries
    /// below current, so views never walk every item to draw a checkbox.
    private(set) var selection: Set<String> = []
    private(set) var selectedCount = 0
    private(set) var selectedBytes: UInt64 = 0
    private(set) var hasSelection = false
    /// Selected removable items per category (for the tri-state checkbox).
    private(set) var selectedPerCategory: [SystemDataCategoryID: Int] = [:]
    /// Items worth a row (more than zero bytes), largest first, per category.
    private(set) var listedItems: [SystemDataCategoryID: [SystemDataItem]] = [:]
    var busy: String?
    var notice: String?

    private var history: [SystemDataSnapshot] = []
    private var currentSnapshot: SystemDataSnapshot?
    /// Removable items by path, and removable paths per category.
    @ObservationIgnored private var removableByPath: [String: (item: SystemDataItem, category: SystemDataCategoryID)] = [:]
    @ObservationIgnored private var removablePaths: [SystemDataCategoryID: [String]] = [:]

    private init() {
        history = SystemDataHistory.load()
        lastHistory = history.last
    }

    var hasResults: Bool { scannedAt != nil }

    // MARK: Derived

    func measurement(_ id: SystemDataCategoryID) -> SystemDataMeasurement? { measurements[id] }

    /// Categories worth a row: present on this Mac with something to show.
    func visible(_ safety: SystemDataSafety) -> [SystemDataCategory] {
        categories.filter { c in
            guard c.safety == safety, let m = measurements[c.id] else { return false }
            if c.id == .timeMachine { return !snapshotNames.isEmpty }
            return m.present && (m.bytes > 0 || !m.unreadableRoots.isEmpty)
        }
        .sorted { (measurements[$0.id]?.bytes ?? 0) > (measurements[$1.id]?.bytes ?? 0) }
    }

    var totalMeasured: UInt64 {
        categories.filter(\.countsInTotal).reduce(0) { $0 &+ (measurements[$1.id]?.bytes ?? 0) }
    }

    func total(_ safety: SystemDataSafety) -> UInt64 {
        categories.filter { $0.safety == safety && $0.countsInTotal }.reduce(0) { $0 &+ (measurements[$1.id]?.bytes ?? 0) }
    }

    var safelyReclaimable: UInt64 {
        categories.filter(\.isSafelyCleanable).reduce(0) { $0 &+ (measurements[$1.id]?.removableBytes ?? 0) }
    }

    var selectedItems: [SystemDataItem] { selection.compactMap { removableByPath[$0]?.item } }

    var unreadableRoots: [String] { categories.flatMap { measurements[$0.id]?.unreadableRoots ?? [] } }
    var hasPartialResults: Bool { measurements.values.contains(where: \.partial) }

    // MARK: Scan

    func scan() {
        guard !scanning else { return }
        scanning = true
        itemsVisited = 0
        notice = nil
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let walker = SystemDataWalker()
        Task {
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.itemsVisited = walker.itemsVisited
                }
            }
            async let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
            let cats = await Task.detached { SystemDataCatalog.categories(.live()) }.value
            let result = await withCheckedContinuation { (c: CheckedContinuation<[SystemDataCategoryID: SystemDataMeasurement], Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: walker.measure(cats)) }
            }
            poll.cancel()
            var m = result
            let names = await snaps.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple") }
            m[.timeMachine]?.present = !names.isEmpty
            let purgeable = Self.purgeableBytes()
            m[.purgeable]?.bytes = purgeable
            m[.purgeable]?.present = purgeable > 0
            let backups = m[.iosBackups]?.items.map(\.path) ?? []
            backupInfo = await Task.detached { Self.readBackups(backups) }.value

            categories = cats
            setMeasurements(m)
            snapshotNames = names
            // Preselect only what is Safe and removable.
            replaceSelection(Set(cats.filter(\.isSafelyCleanable).flatMap { removablePaths[$0.id] ?? [] }))
            scannedAt = now
            itemsVisited = walker.itemsVisited
            withAnimation(.immersiveScreen) { scanning = false }
            SoundFX.play(.scanDone)
            recordCategories(now: now)
            await walkHome(now: now)
        }
    }

    private func recordCategories(now: Date) {
        var sizes: [String: UInt64] = [:]
        for c in categories where measurements[c.id]?.present == true && c.countsInTotal { sizes[c.id.rawValue] = measurements[c.id]?.bytes ?? 0 }
        let previous = history
        let base = SystemDataHistory.baseline(in: previous, now: now)
        categoryBaselineDate = base?.date
        categoryGrowth = base.map { SystemDataHistory.growth(from: $0.categories, to: sizes, kind: .category) } ?? []
        let snap = SystemDataSnapshot(date: now, categories: sizes)
        currentSnapshot = snap
        history = SystemDataHistory.appending(snap, to: history)
        lastHistory = snap
        let h = history
        Task.detached(priority: .utility) { SystemDataHistory.save(h) }
    }

    /// Home folder sizes, two levels deep, for "What grew". Runs after the
    /// results are on screen; it can take a minute on a big home folder.
    private func walkHome(now: Date) async {
        let folders: [String: UInt64]
        if let recent = history.last(where: { !$0.folders.isEmpty && $0.date != now }), now.timeIntervalSince(recent.date) < 15 * 60 {
            folders = recent.folders   // walked minutes ago: not worth another minute of disk activity
        } else {
            homeWalking = true
            let home = NSHomeDirectory()
            folders = await withCheckedContinuation { (c: CheckedContinuation<[String: UInt64], Never>) in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: SystemDataWalker().folderSizes(home: home)) }
            }
            homeWalking = false
        }
        guard var snap = currentSnapshot, snap.date == now else { return }
        let base = SystemDataHistory.baseline(in: history.filter { !$0.folders.isEmpty && $0.date != now }, now: now)
        folderBaselineDate = base?.date
        withAnimation(.smooth) {
            folderGrowth = base.map { SystemDataHistory.growth(from: $0.folders, to: folders, kind: .folder) } ?? []
        }
        snap.folders = folders
        currentSnapshot = snap
        history = SystemDataHistory.appending(snap, to: history)
        let h = history
        Task.detached(priority: .utility) { SystemDataHistory.save(h) }
    }

    nonisolated static func purgeableBytes() -> UInt64 {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        else { return 0 }
        let important = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
        let plain = UInt64(max(0, v.volumeAvailableCapacity ?? 0))
        return important > plain ? important - plain : 0
    }

    nonisolated static func readBackups(_ paths: [String]) -> [String: (name: String?, date: Date?)] {
        var out: [String: (name: String?, date: Date?)] = [:]
        for p in paths {
            guard let dict = NSDictionary(contentsOfFile: p + "/Info.plist") as? [String: Any] else { continue }
            let s = SystemDataCatalog.backupSummary(infoPlist: dict)
            out[p] = (s.name, s.date)
        }
        return out
    }

    // MARK: Selection

    func removableCount(_ id: SystemDataCategoryID) -> Int { removablePaths[id]?.count ?? 0 }

    func removablePathList(_ id: SystemDataCategoryID) -> [String] { removablePaths[id] ?? [] }

    func binding(_ path: String) -> Binding<Bool> {
        Binding(get: { self.selection.contains(path) }, set: { self.setSelected(path, $0) })
    }

    func setSelected(_ path: String, _ on: Bool) {
        guard let entry = removableByPath[path], on != selection.contains(path) else { return }
        if on { selection.insert(path) } else { selection.remove(path) }
        let sign: Int = on ? 1 : -1
        selectedCount += sign
        selectedBytes = on ? selectedBytes &+ entry.item.bytes : selectedBytes &- min(selectedBytes, entry.item.bytes)
        selectedPerCategory[entry.category, default: 0] += sign
        if hasSelection != (selectedCount > 0) { hasSelection = selectedCount > 0 }
    }

    /// Tick or untick every removable item of a category.
    func setAll(_ id: SystemDataCategoryID, _ on: Bool) {
        let paths = removablePaths[id] ?? []
        replaceSelection(on ? selection.union(paths) : selection.subtracting(paths))
    }

    private func replaceSelection(_ new: Set<String>) {
        var paths = Set<String>(), count = 0, bytes: UInt64 = 0
        var perCategory: [SystemDataCategoryID: Int] = [:]
        for path in new {
            guard let entry = removableByPath[path] else { continue }
            paths.insert(path)
            count += 1
            bytes &+= entry.item.bytes
            perCategory[entry.category, default: 0] += 1
        }
        selection = paths
        selectedCount = count
        selectedBytes = bytes
        selectedPerCategory = perCategory
        hasSelection = count > 0
    }

    private func setMeasurements(_ m: [SystemDataCategoryID: SystemDataMeasurement]) {
        measurements = m
        var byPath: [String: (item: SystemDataItem, category: SystemDataCategoryID)] = [:]
        var perCategory: [SystemDataCategoryID: [String]] = [:]
        var listed: [SystemDataCategoryID: [SystemDataItem]] = [:]
        for (id, measurement) in m {
            listed[id] = measurement.items.filter { $0.bytes > 0 }
            for item in measurement.items where item.removable {
                byPath[item.path] = (item, id)
                perCategory[id, default: []].append(item.path)
            }
        }
        removableByPath = byPath
        removablePaths = perCategory
        listedItems = listed
    }

    // MARK: Actions

    func clean(engine: CleaningEngine) async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        busy = KMR.t("Spostamento nel Cestino…", "Moving to the Trash…")
        let fileItems = items.map {
            FileItem(url: URL(fileURLWithPath: $0.path), name: $0.name, size: $0.bytes, allocatedSize: $0.bytes, isDirectory: $0.isDirectory)
        }
        let result = await CleanActions.executeUserClean(items: fileItems, selectedItems: Set(fileItems.map(\.url)), engine: engine)
        let removed = Set(result.removedURLs.map { $0.path(percentEncoded: false) }.map(SystemDataPlanner.normalize))
        withAnimation(.smooth) {
            var updated = measurements
            for (id, var m) in updated {
                let gone = m.items.filter { removed.contains($0.path) }
                guard !gone.isEmpty else { continue }
                m.items.removeAll { removed.contains($0.path) }
                m.bytes -= min(m.bytes, gone.reduce(0) { $0 &+ $1.bytes })
                updated[id] = m
            }
            setMeasurements(updated)
            replaceSelection(selection.subtracting(removed))
        }
        busy = nil
        if result.freedBytes > 0 || result.removedCount > 0 {
            notice = KMR.t("Spostati nel Cestino: \(FileSizeFormatter.format(result.freedBytes)). Puoi annullare da Cronologia pulizie.",
                           "Moved to the Trash: \(FileSizeFormatter.format(result.freedBytes)). You can undo from Cleanup History.")
        } else if !result.errors.isEmpty {
            notice = KMR.t("Alcuni elementi non sono stati spostati: sono in uso o protetti.",
                           "Some items were not moved: they are in use or protected.")
        }
    }

    func deleteSnapshots() async {
        busy = KMR.t("Eliminazione delle istantanee…", "Deleting snapshots…")
        let ok = await Shell.runAsAdmin("/usr/bin/tmutil deletelocalsnapshots /")
        busy = nil
        guard ok else { return }
        let r = await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        withAnimation(.smooth) {
            snapshotNames = r.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple") }
        }
        SoundFX.play(.cleanDone)
    }
}
