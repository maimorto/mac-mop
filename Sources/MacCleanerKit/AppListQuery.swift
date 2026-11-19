import Foundation

// Sorting and filtering for the Uninstaller and Unused Apps lists. Pure and
// fast: every entry carries precomputed sort/search keys, so re-sorting a few
// hundred apps when a menu changes costs microseconds and never runs in `body`.

/// Where an installed app comes from, as far as its signature tells.
public enum AppSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, appStore, developerID, unsigned, unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .apple: UIText.t("Apple", "Apple")
        case .appStore: UIText.t("App Store", "App Store")
        case .developerID: UIText.t("Developer ID", "Developer ID")
        case .unsigned: UIText.t("Non firmate", "Unsigned")
        case .unknown: UIText.t("Sconosciuta", "Unknown")
        }
    }

    /// Maps a signer (from a signature read without full validation) plus the
    /// presence of a Mac App Store receipt. Ad-hoc and broken signatures count
    /// as "unsigned": nobody identifiable vouches for them.
    public static func from(signer: AppSigner?, hasAppStoreReceipt: Bool, bundleIdentifier: String) -> AppSource {
        if hasAppStoreReceipt { return .appStore }
        switch signer {
        case .apple?: return bundleIdentifier.hasPrefix("com.apple.") ? .apple : .developerID
        case .appStore?: return .appStore
        case .developerID?: return .developerID
        case .adHoc?, .unsigned?, .invalid?: return .unsigned
        case nil: return .unknown
        }
    }
}

/// Best-effort developer name for apps without a Developer ID certificate
/// name (Mac App Store apps): taken from the Info.plist copyright line.
public enum AppDeveloperName {
    public static func fromCopyright(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Only the first sentence/line: "© 2024 Foo Inc. All rights reserved."
        if let line = text.split(whereSeparator: \.isNewline).first { text = String(line) }
        for marker in ["All rights reserved", "All Rights Reserved", "ALL RIGHTS RESERVED", "Tous droits réservés", "Alle Rechte vorbehalten"] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        for token in ["Copyright", "copyright", "COPYRIGHT", "©", "(c)", "(C)", "℗"] {
            text = text.replacingOccurrences(of: token, with: " ")
        }
        // Drop years and year ranges ("2010-2024", "2019 –").
        let words = text.split(separator: " ").filter { word in
            let core = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.-–—"))
            if core.isEmpty { return false }
            return !core.allSatisfy { $0.isNumber || "-–—".contains($0) }
        }
        var name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—"))
        if name.lowercased().hasPrefix("by ") { name = String(name.dropFirst(3)) }
        guard name.count >= 2, name.count <= 60 else { return nil }
        return name
    }
}

/// One row of an app list with everything sorting/filtering needs.
public struct AppListEntry: Hashable, Sendable, Identifiable {
    /// The bundle path: stable across rescans (AppInfo ids are not).
    public let id: String
    public let name: String
    public let bundleIdentifier: String
    public let developer: String?
    public let bytes: UInt64
    public let lastUsed: Date?
    public let installed: Date?
    public let source: AppSource
    public let isIntelOnly: Bool
    public let isApple: Bool

    let sortName: String
    let sortDeveloper: String?
    let searchKey: String

    public init(id: String, name: String, bundleIdentifier: String, developer: String? = nil, bytes: UInt64,
                lastUsed: Date? = nil, installed: Date? = nil, source: AppSource = .unknown,
                isIntelOnly: Bool = false, isApple: Bool = false) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.developer = developer
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.installed = installed
        self.source = source
        self.isIntelOnly = isIntelOnly
        self.isApple = isApple
        sortName = AppListQuery.fold(name)
        sortDeveloper = developer.map(AppListQuery.fold)
        searchKey = AppListQuery.fold([name, developer ?? "", bundleIdentifier].joined(separator: "\n"))
    }
}

public enum AppSortKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case name, size, lastUsed, installed, developer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: UIText.t("Nome", "Name")
        case .size: UIText.t("Dimensione", "Size")
        case .lastUsed: UIText.t("Ultimo utilizzo", "Last opened")
        case .installed: UIText.t("Data di installazione", "Date installed")
        case .developer: UIText.t("Sviluppatore", "Developer")
        }
    }

    public var symbol: String {
        switch self {
        case .name: "textformat"
        case .size: "internaldrive"
        case .lastUsed: "clock"
        case .installed: "calendar"
        case .developer: "person"
        }
    }

    /// The direction people expect when they pick this key: A→Z, biggest
    /// first, least recently used first, newest install first.
    public var defaultAscending: Bool {
        switch self {
        case .name, .developer, .lastUsed: true
        case .size, .installed: false
        }
    }

    /// Plain words for the two directions, instead of "ascending/descending".
    public func orderLabel(ascending: Bool) -> String {
        switch (self, ascending) {
        case (.name, true), (.developer, true): UIText.t("Dalla A alla Z", "A to Z")
        case (.name, false), (.developer, false): UIText.t("Dalla Z alla A", "Z to A")
        case (.size, false): UIText.t("Prima le più grandi", "Largest first")
        case (.size, true): UIText.t("Prima le più piccole", "Smallest first")
        case (.lastUsed, true): UIText.t("Prima quelle non usate da più tempo", "Least recently opened first")
        case (.lastUsed, false): UIText.t("Prima quelle usate di recente", "Most recently opened first")
        case (.installed, false): UIText.t("Prima le più recenti", "Newest first")
        case (.installed, true): UIText.t("Prima le più vecchie", "Oldest first")
        }
    }
}

public enum AppSizeFilter: String, CaseIterable, Codable, Sendable, Identifiable {
    case any, over100MB, over1GB

    public var id: String { rawValue }

    public var minimumBytes: UInt64 {
        switch self {
        case .any: 0
        case .over100MB: 100_000_000
        case .over1GB: 1_000_000_000
        }
    }

    public var label: String {
        switch self {
        case .any: UIText.t("Qualsiasi dimensione", "Any size")
        case .over100MB: UIText.t("Più di 100 MB", "Over 100 MB")
        case .over1GB: UIText.t("Più di 1 GB", "Over 1 GB")
        }
    }
}

/// "Not opened for at least…" filter.
public enum AppIdleFilter: String, CaseIterable, Codable, Sendable, Identifiable {
    case any, threeMonths, sixMonths, twelveMonths

    public var id: String { rawValue }

    public var months: Int? {
        switch self {
        case .any: nil
        case .threeMonths: 3
        case .sixMonths: 6
        case .twelveMonths: 12
        }
    }

    public var label: String {
        switch self {
        case .any: UIText.t("Usate di recente o no", "Any time")
        case .threeMonths: UIText.t("Non aperte da 3 mesi", "Not opened for 3 months")
        case .sixMonths: UIText.t("Non aperte da 6 mesi", "Not opened for 6 months")
        case .twelveMonths: UIText.t("Non aperte da 12 mesi", "Not opened for 12 months")
        }
    }
}

/// The source filters offered in the menu (a subset of `AppSource`).
public enum AppSourceFilter: String, CaseIterable, Codable, Sendable, Identifiable {
    case appStore, developerID, unsigned

    public var id: String { rawValue }
    public var source: AppSource {
        switch self {
        case .appStore: .appStore
        case .developerID: .developerID
        case .unsigned: .unsigned
        }
    }
    public var label: String {
        switch self {
        case .appStore: UIText.t("Mac App Store", "Mac App Store")
        case .developerID: UIText.t("Developer ID (da Internet)", "Developer ID (from the web)")
        case .unsigned: UIText.t("Non firmate o firmate in locale", "Unsigned or self-signed")
        }
    }
}

/// Sort + filters, remembered in @AppStorage as one JSON string.
public struct AppListOptions: Equatable, Sendable {
    public var sort: AppSortKey
    public var ascending: Bool
    public var hideApple: Bool
    public var size: AppSizeFilter
    /// Empty = every source.
    public var sources: Set<AppSourceFilter>
    public var intelOnly: Bool
    public var idle: AppIdleFilter

    public init(sort: AppSortKey = .name, ascending: Bool? = nil, hideApple: Bool = false, size: AppSizeFilter = .any,
                sources: Set<AppSourceFilter> = [], intelOnly: Bool = false, idle: AppIdleFilter = .any) {
        self.sort = sort
        self.ascending = ascending ?? sort.defaultAscending
        self.hideApple = hideApple
        self.size = size
        self.sources = sources
        self.intelOnly = intelOnly
        self.idle = idle
    }

    /// Number of filters that hide something (sort doesn't count).
    public var activeFilterCount: Int {
        (hideApple ? 1 : 0) + (size != .any ? 1 : 0) + (sources.isEmpty ? 0 : 1) + (intelOnly ? 1 : 0) + (idle != .any ? 1 : 0)
    }

    /// Same sort, no filters.
    public var clearingFilters: AppListOptions {
        AppListOptions(sort: sort, ascending: ascending)
    }

    /// Picks a new key with its natural direction (re-picking keeps it).
    public mutating func setSort(_ key: AppSortKey) {
        guard key != sort else { return }
        sort = key
        ascending = key.defaultAscending
    }
}

extension AppListOptions: RawRepresentable {
    private struct Payload: Codable {
        var sort: AppSortKey?
        var ascending: Bool?
        var hideApple: Bool?
        var size: AppSizeFilter?
        var sources: [AppSourceFilter]?
        var intelOnly: Bool?
        var idle: AppIdleFilter?
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        self.init(sort: p.sort ?? .name, ascending: p.ascending, hideApple: p.hideApple ?? false, size: p.size ?? .any,
                  sources: Set(p.sources ?? []), intelOnly: p.intelOnly ?? false, idle: p.idle ?? .any)
    }

    public var rawValue: String {
        let p = Payload(sort: sort, ascending: ascending, hideApple: hideApple, size: size,
                        sources: sources.sorted { $0.rawValue < $1.rawValue }, intelOnly: intelOnly, idle: idle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

public enum AppListQuery {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Entries that pass the search and filters, in the requested order.
    /// Search matches every word against name, developer and bundle id.
    /// Entries missing the sort value (no date, no developer) always go last.
    public static func apply(
        _ entries: [AppListEntry],
        search: String = "",
        options: AppListOptions,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AppListEntry] {
        let words = fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
        let minBytes = options.size.minimumBytes
        let sources = Set(options.sources.map(\.source))
        let idleCutoff = options.idle.months.flatMap { calendar.date(byAdding: .month, value: -$0, to: now) }

        let kept = entries.filter { entry in
            if options.hideApple && entry.isApple { return false }
            if entry.bytes < minBytes { return false }
            if !sources.isEmpty && !sources.contains(entry.source) { return false }
            if options.intelOnly && !entry.isIntelOnly { return false }
            if let idleCutoff {
                // No date: macOS can't prove it is idle, so it doesn't qualify.
                guard let last = entry.lastUsed, last <= idleCutoff else { return false }
            }
            return words.allSatisfy { entry.searchKey.contains($0) }
        }
        return kept.sorted { ordered($0, $1, by: options.sort, ascending: options.ascending) }
    }

    static func ordered(_ a: AppListEntry, _ b: AppListEntry, by key: AppSortKey, ascending: Bool) -> Bool {
        func nameOrder(_ x: AppListEntry, _ y: AppListEntry) -> Bool {
            let r = x.sortName.compare(y.sortName, options: .numeric)
            if r != .orderedSame { return r == .orderedAscending }
            return x.id < y.id
        }
        func byName() -> Bool { nameOrder(a, b) }
        func optional<T: Comparable>(_ x: T?, _ y: T?) -> Bool? {
            switch (x, y) {
            case let (x?, y?): x == y ? nil : (ascending ? x < y : x > y)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): nil
            }
        }
        switch key {
        case .name:
            return ascending ? nameOrder(a, b) : nameOrder(b, a)
        case .size:
            if a.bytes != b.bytes { return ascending ? a.bytes < b.bytes : a.bytes > b.bytes }
            return byName()
        case .lastUsed:
            return optional(a.lastUsed, b.lastUsed) ?? byName()
        case .installed:
            return optional(a.installed, b.installed) ?? byName()
        case .developer:
            if let d = optional(a.sortDeveloper, b.sortDeveloper) { return d }
            return byName()
        }
    }
}
