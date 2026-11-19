import Foundation

// "What grew since last time": a small JSON history of System Data category
// sizes and home-folder sizes (two levels deep), one entry per scan.

public struct SystemDataSnapshot: Codable, Equatable, Sendable {
    public var date: Date
    /// SystemDataCategoryID raw value → bytes.
    public var categories: [String: UInt64]
    /// Home-relative folder ("Library/Caches") → bytes. Empty until the home walk finishes.
    public var folders: [String: UInt64]

    public init(date: Date, categories: [String: UInt64], folders: [String: UInt64] = [:]) {
        self.date = date
        self.categories = categories
        self.folders = folders
    }
}

public struct SystemDataGrowth: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case category, folder }
    public let kind: Kind
    public let key: String
    public let before: UInt64
    public let after: UInt64
    public var id: String { kind.rawValue + ":" + key }
    public var delta: Int64 { Int64(clamping: after) - Int64(clamping: before) }
}

public enum SystemDataHistory {
    public static let maxSnapshots = 60
    /// Changes smaller than this are noise (caches breathe all the time).
    public static let minimumGrowth: UInt64 = 50 * 1024 * 1024

    /// The snapshot to compare against: the newest one at least `minAge` older
    /// than `now`, else the oldest one available, so two scans a minute apart
    /// still compare with something meaningful.
    public static func baseline(in history: [SystemDataSnapshot], now: Date, minAge: TimeInterval = 3600) -> SystemDataSnapshot? {
        let older = history.filter { $0.date < now }
        return older.filter { now.timeIntervalSince($0.date) >= minAge }.max { $0.date < $1.date }
            ?? older.min { $0.date < $1.date }
    }

    /// Largest positive changes, biggest first. Keys that are new count from
    /// zero only when the baseline already had data of that kind.
    public static func growth(from old: [String: UInt64], to new: [String: UInt64], kind: SystemDataGrowth.Kind,
                              limit: Int = 5, minimum: UInt64 = minimumGrowth) -> [SystemDataGrowth] {
        guard !old.isEmpty else { return [] }
        var out: [SystemDataGrowth] = []
        for (k, v) in new {
            let before = old[k] ?? 0
            if v > before, v - before >= minimum { out.append(SystemDataGrowth(kind: kind, key: k, before: before, after: v)) }
        }
        // Nested folders: "Library/Caches" growing also grows "Library". Keep the
        // child (more specific) and drop a parent whose growth it explains.
        if kind == .folder {
            out = out.filter { parent in
                !out.contains { child in
                    child.key.hasPrefix(parent.key + "/") && Double(child.delta) >= Double(parent.delta) * 0.8
                }
            }
        }
        return Array(out.sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.key < $1.key }.prefix(limit))
    }

    /// Appends (or, for the home walk that finishes later, merges into the
    /// snapshot of the same scan) and trims to `maxSnapshots`.
    public static func appending(_ snapshot: SystemDataSnapshot, to history: [SystemDataSnapshot]) -> [SystemDataSnapshot] {
        var h = history.filter { $0.date != snapshot.date }
        h.append(snapshot)
        h.sort { $0.date < $1.date }
        return Array(h.suffix(maxSnapshots))
    }

    // MARK: Storage

    public static var defaultURL: URL {
        MCConstants.userAppSupport.appending(path: "\(MCConstants.dataFolderName)/SystemData/history.json")
    }

    public static func load(from url: URL = defaultURL) -> [SystemDataSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([SystemDataSnapshot].self, from: data)) ?? []
    }

    public static func save(_ history: [SystemDataSnapshot], to url: URL = defaultURL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
