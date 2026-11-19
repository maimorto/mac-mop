import Foundation

/// Installer package receipts (`pkgutil`): parsing, grouping and a safe
/// removal plan. Pure logic only — the app target runs pkgutil and executes
/// the plan (user files to the Trash, system files behind an admin prompt).
public struct PackageReceipt: Hashable, Sendable, Identifiable {
    public var id: String { packageID }
    public let packageID: String
    public let version: String
    public let volume: String
    public let location: String
    public let installDate: Date?

    public init(packageID: String, version: String, volume: String, location: String, installDate: Date?) {
        self.packageID = packageID
        self.version = version
        self.volume = volume
        self.location = location
        self.installDate = installDate
    }

    /// Absolute folder the receipt's relative file paths are rooted at.
    public var root: String {
        var base = volume.isEmpty ? "/" : volume
        if !base.hasSuffix("/") { base += "/" }
        let loc = location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return loc.isEmpty ? base : base + loc + "/"
    }

    /// Absolute path of a receipt-relative path (`pkgutil --files` output).
    public func absolutePath(_ relative: String) -> String {
        let rel = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
        let joined = root + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return joined.count > 1 && joined.hasSuffix("/") ? String(joined.dropLast()) : joined
    }

    public var isApple: Bool { PackageReceipts.isAppleReceipt(packageID) }
    public var vendor: String { PackageReceipts.vendor(of: packageID) }
}

public enum PackageReceipts {
    /// Apple's own receipts (macOS components, Xcode, CLT, Safari, Pro Apps…)
    /// are never offered for removal.
    public static func isAppleReceipt(_ id: String) -> Bool {
        id.lowercased().hasPrefix("com.apple.")
    }

    /// Parse `pkgutil --pkg-info <id>` text output.
    public static func parseInfo(_ output: String) -> PackageReceipt? {
        var fields: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let id = fields["package-id"], !id.isEmpty else { return nil }
        let date = fields["install-time"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        return PackageReceipt(packageID: id, version: fields["version"] ?? "",
                              volume: fields["volume"] ?? "/", location: fields["location"] ?? "",
                              installDate: date)
    }

    /// Parse `pkgutil --pkgs` (one id per line).
    public static func parseList(_ output: String, includeApple: Bool) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && (includeApple || !isAppleReceipt($0)) }
    }

    /// Parse `pkgutil --files` / `--only-files` / `--only-dirs` (relative paths).
    public static func parseFiles(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    /// A readable vendor from a reverse-DNS id: "com.teamviewer.x" → "teamviewer",
    /// "net.whatsapp.WhatsApp" → "whatsapp", "TeamViewerUninstaller" → itself.
    public static func vendor(of id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        let tlds: Set<String> = ["com", "net", "org", "io", "de", "uk", "co", "me", "dev", "app", "us", "fr", "it", "jp", "ch", "nl", "eu"]
        guard parts.count >= 2, tlds.contains(parts[0].lowercased()) else { return parts.first ?? id }
        return parts[1]
    }

    // MARK: Protected paths

    /// Directories shared by the whole system: files inside may be removed,
    /// the directories themselves never.
    public static let protectedDirectories: Set<String> = [
        "/", "/Applications", "/Applications/Utilities", "/Library", "/System", "/Users", "/Users/Shared",
        "/usr", "/usr/local", "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/include",
        "/usr/local/share", "/usr/local/share/man", "/usr/local/etc", "/usr/local/libexec", "/usr/local/opt",
        "/bin", "/sbin", "/etc", "/var", "/tmp", "/opt", "/private", "/private/etc", "/private/var", "/private/tmp",
        "/etc/paths.d", "/private/etc/paths.d", "/etc/manpaths.d", "/private/etc/manpaths.d",
        "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Extensions",
        "/Library/Frameworks", "/Library/PrivilegedHelperTools", "/Library/Preferences", "/Library/Caches",
        "/Library/Logs", "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/HAL",
        "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3",
        "/Library/Internet Plug-Ins", "/Library/PreferencePanes", "/Library/QuickLook", "/Library/Spotlight",
        "/Library/Fonts", "/Library/Printers", "/Library/Security", "/Library/Security/SecurityAgentPlugins",
        "/Library/Filesystems", "/Library/Input Methods", "/Library/Services", "/Library/Screen Savers",
        "/Library/CoreMediaIO", "/Library/CoreMediaIO/Plug-Ins", "/Library/CoreMediaIO/Plug-Ins/DAL",
        "/Library/DriverExtensions", "/Library/SystemExtensions", "/Library/StartupItems", "/Library/Keychains",
        "/Library/Developer", "/Library/Documentation", "/Library/Receipts", "/Library/Scripts",
        "/Library/Managed Preferences", "/Library/Apple", "/Library/Updates", "/Library/WebServer",
    ]

    /// Paths a package removal must never touch at all (files or folders).
    public static func isForbidden(_ path: String) -> Bool {
        if path.contains("/../") || path.hasSuffix("/..") || path.contains("/./") { return true }
        let forbiddenRoots = ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/",
                              "/usr/share/", "/private/var/db/", "/var/db/", "/Library/Apple/", "/Library/Keychains/"]
        if forbiddenRoots.contains(where: { path.hasPrefix($0) }) { return true }
        return protectedDirectories.contains(path)
    }

    /// Whether a directory may be removed (only when empty) after its files go.
    public static func isProtectedDirectory(_ path: String, home: String) -> Bool {
        if protectedDirectories.contains(path) || isForbidden(path) { return true }
        let homeNoSlash = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == homeNoSlash { return true }
        // The user's own top-level folders and Library subfolders.
        if path.hasPrefix(homeNoSlash + "/") {
            let rel = path.dropFirst(homeNoSlash.count + 1).split(separator: "/")
            if rel.count <= 1 { return true }
            if rel.first == "Library" && rel.count <= 2 { return true }
        }
        return false
    }

    // MARK: Removal plan

    public struct RemovalPlan: Equatable, Sendable {
        /// Files inside the user's home: go through the Trash + Cleanup History.
        public var userFiles: [String]
        /// Files outside the home: need the administrator prompt.
        public var systemFiles: [String]
        /// Directories to `rmdir` afterwards (deepest first; rmdir refuses non-empty ones).
        public var directories: [String]
        /// Files skipped because another package also lists them.
        public var sharedFiles: [String]
        /// Protected/forbidden paths left alone.
        public var protectedPaths: [String]

        public var isEmpty: Bool { userFiles.isEmpty && systemFiles.isEmpty && directories.isEmpty }
    }

    /// Build the removal plan for `receipt` from its absolute file and
    /// directory lists. `existing` reports which paths are still on disk
    /// (lstat), `otherPackagesPaths` every path other receipts list.
    public static func removalPlan(
        receipt: PackageReceipt,
        files: [String],
        directories: [String],
        otherPackagesPaths: Set<String>,
        home: String,
        existing: (String) -> Bool
    ) -> RemovalPlan? {
        guard !receipt.isApple else { return nil }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        var plan = RemovalPlan(userFiles: [], systemFiles: [], directories: [], sharedFiles: [], protectedPaths: [])
        for path in files where existing(path) {
            if isForbidden(path) { plan.protectedPaths.append(path); continue }
            if otherPackagesPaths.contains(path) { plan.sharedFiles.append(path); continue }
            if path.hasPrefix(homePrefix) { plan.userFiles.append(path) } else { plan.systemFiles.append(path) }
        }
        for dir in directories where existing(dir) {
            if isProtectedDirectory(dir, home: home) { plan.protectedPaths.append(dir); continue }
            if otherPackagesPaths.contains(dir) { plan.sharedFiles.append(dir); continue }
            plan.directories.append(dir)
        }
        plan.directories.sort { a, b in
            let da = a.filter { $0 == "/" }.count, db = b.filter { $0 == "/" }.count
            return da != db ? da > db : a > b
        }
        return plan
    }

    // MARK: Admin script

    /// Single-quote a path for /bin/sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public enum SystemFileAction: Sendable {
        /// Move into a timestamped backup folder (restorable).
        case backup(folder: String)
        /// Delete permanently.
        case delete
    }

    /// The shell script run with administrator privileges: move or delete the
    /// system files, remove empty package folders, forget the receipt.
    /// `rmdir` (never `rm -r`) means a folder still holding anything stays.
    public static func adminScript(packageID: String, systemFiles: [String], directories: [String],
                                   action: SystemFileAction, owner: String? = nil) -> String {
        var lines: [String] = []
        switch action {
        case .backup(let folder):
            lines.append("/bin/mkdir -p \(shellQuote(folder))")
            for file in systemFiles {
                let dest = folder + file
                let parent = (dest as NSString).deletingLastPathComponent
                lines.append("/bin/mkdir -p \(shellQuote(parent)) && /bin/mv -f \(shellQuote(file)) \(shellQuote(dest))")
            }
            if let owner, !owner.isEmpty {
                lines.append("/usr/sbin/chown -R \(shellQuote(owner)) \(shellQuote(folder))")
            }
        case .delete:
            for file in systemFiles { lines.append("/bin/rm -f \(shellQuote(file))") }
        }
        for dir in directories { lines.append("/bin/rmdir \(shellQuote(dir)) 2>/dev/null") }
        lines.append("/usr/sbin/pkgutil --forget \(shellQuote(packageID))")
        // Each step is best effort except the last, whose status is the result.
        return lines.joined(separator: " ; ")
    }

    /// Group receipts by vendor, vendors sorted by name, receipts by id.
    public static func groupedByVendor(_ receipts: [PackageReceipt]) -> [(vendor: String, receipts: [PackageReceipt])] {
        Dictionary(grouping: receipts, by: { $0.vendor.lowercased() })
            .map { (vendor: $0.value.first?.vendor ?? $0.key,
                    receipts: $0.value.sorted { $0.packageID.localizedCaseInsensitiveCompare($1.packageID) == .orderedAscending }) }
            .sorted { $0.vendor.localizedCaseInsensitiveCompare($1.vendor) == .orderedAscending }
    }
}
