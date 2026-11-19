import Darwin
import Foundation

/// Last-moment checks before an item goes to the Trash, and the dry-run
/// ("Prova senza pulire") summary built from the same checks.
///
/// A scan can be minutes old when the user clicks Clean: a cache file may
/// have been rewritten by its app, a folder replaced, an app launched. Every
/// item is compared with what the scan saw and skipped when it changed, so a
/// clean only ever moves what the user reviewed.
public enum CleanSafety {
    public enum SkipReason: String, Sendable, Hashable, CaseIterable, Comparable {
        /// No longer on disk (nothing to do: not an error).
        case missing
        /// Replaced or modified since the scan.
        case changed
        /// An app bundle that is running right now.
        case inUse
        /// Wallets, browser profiles, keychains, password managers, notes.
        case protectedData
        /// System, excluded or otherwise unsafe path (SafetyGuard).
        case protectedPath

        public static func < (a: SkipReason, b: SkipReason) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }

        public var explanation: String {
            switch self {
            case .missing: UIText.t("Non c'è più (forse l'ha già rimosso l'app).", "No longer there (the app may have removed it).")
            case .changed: UIText.t("È cambiato dopo l'analisi: rianalizza per rivederlo.", "Changed after the scan: scan again to review it.")
            case .inUse: UIText.t("L'app è aperta: chiudila e riprova.", "The app is open: quit it and try again.")
            case .protectedData: UIText.t("Dati protetti (portafogli, browser, password, note): Mac Mop non li sposta mai.",
                                          "Protected data (wallets, browsers, passwords, notes): Mac Mop never moves it.")
            case .protectedPath: UIText.t("Percorso di sistema o escluso nelle impostazioni.", "System path, or excluded in Settings.")
            }
        }

        /// "Skipped because changed: {n}" style label for the done screen.
        public func countLabel(_ n: Int) -> String {
            switch self {
            case .missing: UIText.t("Elementi già spariti: \(n)", "Items already gone: \(n)")
            case .changed: UIText.t("Elementi saltati perché cambiati: \(n)", "Items skipped because they changed: \(n)")
            case .inUse: UIText.t("Elementi saltati perché in uso: \(n)", "Items skipped because in use: \(n)")
            case .protectedData: UIText.t("Elementi protetti non toccati: \(n)", "Protected items left alone: \(n)")
            case .protectedPath: UIText.t("Elementi di sistema non toccati: \(n)", "System items left alone: \(n)")
            }
        }
    }

    public struct Skip: Sendable, Hashable {
        public let path: String
        public let reason: SkipReason
        public init(path: String, reason: SkipReason) {
            self.path = path
            self.reason = reason
        }
    }

    /// What the scan recorded about an item.
    public struct Fingerprint: Sendable, Equatable {
        public let isDirectory: Bool
        public let inode: UInt64
        public let device: Int32
        public let size: UInt64
        public let allocatedSize: UInt64
        public let modificationDate: Date?

        public init(isDirectory: Bool, inode: UInt64 = 0, device: Int32 = 0, size: UInt64 = 0,
                    allocatedSize: UInt64 = 0, modificationDate: Date? = nil) {
            self.isDirectory = isDirectory
            self.inode = inode
            self.device = device
            self.size = size
            self.allocatedSize = allocatedSize
            self.modificationDate = modificationDate
        }

        public init(_ item: FileItem) {
            self.init(isDirectory: item.isDirectory || item.isPackage, inode: item.inode, device: item.deviceID,
                      size: item.size, allocatedSize: item.allocatedSize, modificationDate: item.modificationDate)
        }
    }

    /// What is on disk now (`lstat`, never following a final symlink).
    public struct DiskState: Sendable, Equatable {
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let inode: UInt64
        public let device: Int32
        public let size: UInt64
        public let allocatedSize: UInt64
        public let modificationDate: Date

        public init(isDirectory: Bool, isSymlink: Bool = false, inode: UInt64, device: Int32, size: UInt64,
                    allocatedSize: UInt64, modificationDate: Date) {
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
            self.inode = inode
            self.device = device
            self.size = size
            self.allocatedSize = allocatedSize
            self.modificationDate = modificationDate
        }

        public static func read(_ path: String) -> DiskState? {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let type = st.st_mode & S_IFMT
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                             + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
            return DiskState(isDirectory: type == S_IFDIR, isSymlink: type == S_IFLNK,
                             inode: UInt64(st.st_ino), device: st.st_dev,
                             size: UInt64(max(0, st.st_size)), allocatedSize: UInt64(max(0, st.st_blocks)) * 512,
                             modificationDate: mtime)
        }
    }

    /// Compares the scan's view of an item with the disk.
    ///
    /// - Folders and packages: only identity (inode/device, when the scan
    ///   recorded it) and type. Their modification date moves every time an
    ///   app adds a cache file, and their size is a scan-time total.
    /// - Files: identity, then modification date (1 s tolerance, the
    ///   resolution some file systems keep), then size, which may be logical
    ///   or allocated depending on the scanner.
    public static func compare(scanned: Fingerprint, now: DiskState?) -> SkipReason? {
        guard let now else { return .missing }
        if scanned.inode != 0, now.inode != scanned.inode { return .changed }
        if scanned.device != 0, now.device != scanned.device { return .changed }
        if scanned.isDirectory != now.isDirectory, !now.isSymlink { return .changed }
        if scanned.isDirectory { return nil }
        if let date = scanned.modificationDate, abs(now.modificationDate.timeIntervalSince(date)) > 1 { return .changed }
        if scanned.size > 0 {
            let known: Set<UInt64> = [scanned.size, scanned.allocatedSize]
            if !known.contains(now.size), !known.contains(now.allocatedSize) { return .changed }
        }
        return nil
    }

    /// True when `path` is a running app's bundle or inside one.
    public static func isInUse(path: String, runningBundlePaths: Set<String>) -> Bool {
        guard !runningBundlePaths.isEmpty else { return false }
        let p = normalized(path)
        return runningBundlePaths.contains { bundle in
            let b = normalized(bundle)
            return p == b || p.hasPrefix(b + "/")
        }
    }

    /// Browser and system-privacy cleanups exist to remove browser data, so
    /// the protected-data rule (which covers whole browser profiles) does not
    /// apply to them; every other cleanup leaves protected data alone.
    public static func enforcesProtectedUserData(for category: ScanCategory) -> Bool {
        switch category {
        case .browserPrivacy, .systemPrivacy: false
        default: true
        }
    }

    /// Per item: cache cleanups may also empty a browser's own cache
    /// folder (`…/Containers/com.apple.Safari/Data/Library/Caches/…`),
    /// which is regenerable by definition, even though the browser's
    /// profile around it is protected.
    public static func enforcesProtectedUserData(for category: ScanCategory, path: String) -> Bool {
        guard enforcesProtectedUserData(for: category) else { return false }
        guard category == .userCaches || category == .systemCaches else { return true }
        let parts = path.split(separator: "/").map { $0.lowercased() }
        return !parts.contains { $0 == "caches" || $0 == "cache" }
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath.lowercased()
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Dry run

    /// What a clean would do, without touching anything.
    public struct Plan: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case trash, thinInPlace, deletePermanently }

        public struct Line: Sendable, Equatable, Identifiable {
            public let category: ScanCategory
            public let action: Action
            public var count: Int
            public var bytes: UInt64
            public var id: String { category.rawValue }
        }

        public var lines: [Line]
        public var skips: [Skip]

        public var totalCount: Int { lines.reduce(0) { $0 + $1.count } }
        public var totalBytes: UInt64 { lines.reduce(0) { $0 + $1.bytes } }
        public var skipCounts: [(reason: SkipReason, count: Int)] { CleanSafety.counts(skips) }

        public init(lines: [Line] = [], skips: [Skip] = []) {
            self.lines = lines
            self.skips = skips
        }
    }

    public static func action(for category: ScanCategory) -> Plan.Action {
        switch category {
        case .universalBinaries: .thinInPlace
        case .trashBins: .deletePermanently
        default: .trash
        }
    }

    /// Builds a plan from already-checked entries: `skip == nil` means the
    /// item would be cleaned. Lines are sorted by size, largest first.
    public static func plan(_ entries: [(category: ScanCategory, bytes: UInt64, path: String, skip: SkipReason?)]) -> Plan {
        var lines: [ScanCategory: Plan.Line] = [:]
        var order: [ScanCategory] = []
        var skips: [Skip] = []
        for e in entries {
            if let reason = e.skip {
                skips.append(Skip(path: e.path, reason: reason))
                continue
            }
            if lines[e.category] == nil {
                order.append(e.category)
                lines[e.category] = Plan.Line(category: e.category, action: action(for: e.category), count: 0, bytes: 0)
            }
            lines[e.category]!.count += 1
            lines[e.category]!.bytes += e.bytes
        }
        let sorted = order.compactMap { lines[$0] }.sorted { $0.bytes > $1.bytes }
        return Plan(lines: sorted, skips: skips)
    }

    /// Per-reason counts, in `SkipReason` order, zero counts dropped.
    public static func counts(_ skips: [Skip]) -> [(reason: SkipReason, count: Int)] {
        var c: [SkipReason: Int] = [:]
        for s in skips { c[s.reason, default: 0] += 1 }
        return SkipReason.allCases.compactMap { r in c[r].map { (r, $0) } }
    }

    /// Whether the dry-run sheet must be shown before a clean.
    public static func needsDryRun(hasCleanedBefore: Bool, alwaysDryRun: Bool) -> Bool {
        alwaysDryRun || !hasCleanedBefore
    }

    /// UserDefaults keys. `dryRunFirstClean` is the Settings toggle
    /// ("show the simulation before every clean").
    public static let dryRunDefaultsKey = "dryRunFirstClean"
    public static let hasCleanedDefaultsKey = "hasCompletedFirstClean"
}
