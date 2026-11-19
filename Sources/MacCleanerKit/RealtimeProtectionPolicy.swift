import Foundation

/// One real-time protection finding. Lives in MacCleanerKit so analyzers in
/// the Kit (behavioural engine, YARA) can return it to the monitor directly.
public struct RealtimeMalwareAlert: Sendable, Hashable {
    public let path: String
    public let name: String
    public let reason: String
    public let timestamp: Date

    public init(path: String, name: String, reason: String, timestamp: Date = Date()) {
        self.path = path
        self.name = name
        self.reason = reason
        self.timestamp = timestamp
    }

    /// Identity used to never alert twice for the same thing in a session.
    public var dedupeKey: String { path + "\u{0}" + reason }
}

/// Remembers which path + reason pairs were already alerted this session.
public struct RealtimeAlertDeduper: Sendable {
    private var seen: Set<String> = []

    public init() {}

    /// True the first time an alert is seen; false for every repeat.
    public mutating func shouldAlert(_ alert: RealtimeMalwareAlert) -> Bool {
        seen.insert(alert.dedupeKey).inserted
    }
}

/// Which file-system events the real-time monitor looks at, and what it
/// inspects for each. Pure: roots are injected, nothing touches the disk.
public struct RealtimeWatchPolicy: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// LaunchAgents / LaunchDaemons: direct `.plist` children only.
        case launchItems
        /// Direct children only (Application Support).
        case shallow
        /// Up to two levels deep (Downloads, /Users/Shared, temp folders).
        case dropZone
    }

    public struct Root: Sendable, Equatable {
        public let path: String
        public let kind: Kind
        public init(path: String, kind: Kind) {
            self.path = RealtimeWatchPolicy.resolvedTmp(path)
            self.kind = kind
        }
    }

    public let roots: [Root]

    public init(roots: [Root]) {
        // Longest first so a nested root (e.g. TMPDIR under /private/var)
        // wins over a broader one.
        self.roots = roots.sorted { $0.path.count > $1.path.count }
    }

    /// Default roots for the current user. `tmpDir` is the user's TMPDIR.
    public static func standard(home: String = NSHomeDirectory(),
                                tmpDir: String = NSTemporaryDirectory()) -> RealtimeWatchPolicy {
        var roots: [Root] = [
            Root(path: home + "/Library/LaunchAgents", kind: .launchItems),
            Root(path: "/Library/LaunchAgents", kind: .launchItems),
            Root(path: "/Library/LaunchDaemons", kind: .launchItems),
            Root(path: home + "/Downloads", kind: .dropZone),
            Root(path: "/Users/Shared", kind: .dropZone),
            Root(path: home + "/Library/Application Support", kind: .shallow),
            Root(path: "/private/tmp", kind: .dropZone),
        ]
        if !tmpDir.isEmpty { roots.append(Root(path: resolvedTmp(tmpDir), kind: .dropZone)) }
        return RealtimeWatchPolicy(roots: roots)
    }

    /// FSEvents reports real paths, so /var/folders/... arrives as
    /// /private/var/folders/...; normalise roots and events the same way
    /// (`standardizingPath` alone strips /private, hence the re-add).
    static func resolvedTmp(_ path: String) -> String {
        let p = (path as NSString).standardizingPath
        if p.hasPrefix("/var/") || p == "/var" { return "/private" + p }
        if p.hasPrefix("/tmp/") || p == "/tmp" { return "/private" + p }
        return p
    }

    /// Transient names written while a download or editor save is in progress.
    static let transientSuffixes = [".download", ".crdownload", ".part", ".partial", ".tmp", ".swp", "~"]

    /// The path the monitor should inspect for an event at `path`, or nil to
    /// ignore it. Events inside a bundle collapse to the bundle itself
    /// (`~/Downloads/Foo.app/Contents/MacOS/Foo` -> `~/Downloads/Foo.app`), so
    /// one copy produces one inspection.
    public func inspectionTarget(for rawPath: String) -> String? {
        let path = Self.resolvedTmp(rawPath)
        guard let root = roots.first(where: { path.hasPrefix($0.path + "/") }) else { return nil }
        let relative = path.dropFirst(root.path.count + 1)
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = components.first else { return nil }

        // Collapse into the first bundle-like component.
        let bundleExtensions: Set<String> = ["app", "pkg", "mpkg", "bundle", "plugin", "kext", "appex", "framework"]
        var kept: [String] = []
        for component in components {
            kept.append(component)
            let ext = (component as NSString).pathExtension.lowercased()
            if bundleExtensions.contains(ext) { break }
        }
        let name = kept.last ?? first
        let lower = name.lowercased()
        if lower == ".ds_store" || lower.hasPrefix("._") { return nil }
        if Self.transientSuffixes.contains(where: { lower.hasSuffix($0) }) { return nil }
        // An in-progress Safari download is a folder "x.download/..." too.
        if kept.dropLast().contains(where: { $0.lowercased().hasSuffix(".download") }) { return nil }

        switch root.kind {
        case .launchItems:
            guard kept.count == 1, lower.hasSuffix(".plist") else { return nil }
        case .shallow:
            guard kept.count == 1 else { return nil }
        case .dropZone:
            guard kept.count <= 2 else { return nil }
        }
        return root.path + "/" + kept.joined(separator: "/")
    }

    /// True when `path` (already a target) is a launch item plist.
    public func isLaunchItem(_ path: String) -> Bool {
        roots.first(where: { path.hasPrefix($0.path + "/") })?.kind == .launchItems
    }

    /// Distinct inspection targets for a batch of event paths, in first-seen
    /// order, with Mac Mop's own files dropped.
    public func coalescedTargets(_ rawPaths: [String], isSelf: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in rawPaths {
            guard let target = inspectionTarget(for: raw), !isSelf(target),
                  seen.insert(target).inserted else { continue }
            out.append(target)
        }
        return out
    }
}
