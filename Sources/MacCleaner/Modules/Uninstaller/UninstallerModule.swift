import Foundation
import AppKit
import MacCleanerKit

public struct UninstallerModule: ScanModule {
    public let id = "uninstaller"
    public var name: String { L10n.tr("卸载器", "Uninstaller", "Удаление приложений") }
    public let category = ModuleCategory.applications

    public init() {}

    public func scan() async -> [ScanResult] {
        // The uninstaller doesn't produce traditional scan results.
        // It provides an app list with associated files.
        []
    }
}

// MARK: - App Discovery

public actor AppDiscovery {
    private let resourceKeys: [URLResourceKey] = [
        .fileSizeKey, .totalFileAllocatedSizeKey, .isApplicationKey,
        .contentModificationDateKey,
    ]

    public init() {}

    public func discoverApps() -> [AppInfo] {
        var apps: [AppInfo] = []
        var seen = Set<String>()

        let appDirs = [
            URL(filePath: "/Applications"),
            MCConstants.home.appending(path: "Applications"),
        ]

        for dir in appDirs {
            for appURL in Self.appBundles(in: dir) {
                let path = appURL.path(percentEncoded: false)
                guard seen.insert(path).inserted else { continue }
                if let info = appInfo(from: appURL) {
                    apps.append(info)
                }
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All `.app` bundles under `dir`, including those nested in subfolders
    /// (e.g. `/Applications/Adobe/Photoshop.app`, `/Applications/Utilities/`),
    /// which the old top-level-only scan missed.
    ///
    /// `.skipsPackageDescendants` stops the walk at each bundle so we never list
    /// helper apps buried inside another app (`…/Contents/Library/…/Helper.app`),
    /// and `maxDepth` bounds the recursion so a huge non-app folder can't stall
    /// discovery. Real installs nest an app one or two folders deep at most.
    static func appBundles(in dir: URL, maxDepth: Int = 4,
                           fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level >= maxDepth { enumerator.skipDescendants() }
            if url.pathExtension == "app" {
                found.append(url)
                enumerator.skipDescendants()   // never recurse into a bundle
            }
        }
        return found
    }

    /// Info for one bundle anywhere on disk (e.g. an app in Downloads picked
    /// from Finder's Services menu).
    public func appInfo(at url: URL) -> AppInfo? { appInfo(from: url) }

    private func appInfo(from url: URL) -> AppInfo? {
        let infoPlistURL = url.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        // The Finder name is always present and localized; bundle names can be empty.
        let finderName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespaces)
        let plistName = ((plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let name = !finderName.isEmpty ? finderName : (!plistName.isEmpty ? plistName : url.deletingPathExtension().lastPathComponent)
        let version = plist["CFBundleShortVersionString"] as? String

        let isApple = bundleID.hasPrefix("com.apple.")
        let size = directorySize(url)

        return AppInfo(
            bundleIdentifier: bundleID,
            name: name,
            path: url,
            version: version,
            size: size,
            lastOpened: lastOpenedDate(url),
            isAppleApp: isApple
        )
    }

    private func lastOpenedDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey])
        return values?.contentAccessDate
    }

    private func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .linkCountKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        var hardLinks = HardLinkTracker()
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .linkCountKey])
            guard hardLinks.shouldCount(fileURL, linkCount: values?.linkCount) else { continue }
            total += UInt64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// A leftover file plus why it was linked to the app.
public struct AssociatedFile: Identifiable, Hashable, Sendable {
    public let item: FileItem
    public let match: LeftoverMatch
    public var id: URL { item.url }
}

// MARK: - App Path Finder (system-side wrapper around MacCleanerKit.AppMatching)

public struct AppPathFinder: Sendable {
    public typealias MatchLevel = AppMatching.MatchLevel

    public let maxLevel: MatchLevel

    // Default stops at .versionStripped: the .companyName level matches the bare
    // vendor token and would flag sibling apps from the same vendor.
    public init(maxLevel: MatchLevel = .versionStripped) {
        self.maxLevel = maxLevel
    }

    /// The leftovers the Uninstaller would remove by default (confident
    /// matches only); used for size estimates such as Unused Apps.
    public func findAssociatedFiles(for app: AppInfo) -> [FileItem] {
        findLeftovers(for: app).filter(\.match.confidence.selectedByDefault).map(\.item)
    }

    /// Leftovers with the reason each one matched and a confidence, so the
    /// Uninstaller can explain itself and leave weak matches unchecked.
    public func findLeftovers(for app: AppInfo) -> [AssociatedFile] {
        let patterns = AppMatching.generatePatterns(for: app, maxLevel: maxLevel)
        let signing = AppTrustInspector.signingFacts(app.path, checkRevocation: false)
        let context = LeftoverContext(teamIdentifier: signing.teamID, appGroups: signing.appGroups)
        var found: [AssociatedFile] = []
        var seen = Set<URL>()
        let fm = FileManager.default

        func add(_ url: URL, _ match: LeftoverMatch) {
            guard seen.insert(url).inserted, let item = makeFileItem(from: url) else { return }
            found.append(AssociatedFile(item: item, match: match))
        }

        for subdir in AppMatching.librarySubdirectories {
            let dirURL = MCConstants.userLibrary.appending(path: subdir)
            guard let contents = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
            ) else { continue }

            for itemURL in contents {
                let name = itemURL.lastPathComponent
                let program = subdir == "LaunchAgents" ? Self.launchProgram(itemURL) : nil
                let nameMatches = AppMatching.filenameMatches(name, patterns: patterns)
                if nameMatches || program != nil || subdir == "Group Containers" {
                    let match = LeftoverExplainer.explain(fileName: name, librarySubdirectory: subdir, app: app,
                                                          context: context, launchProgram: program)
                    if let match {
                        add(itemURL, match)
                    } else if nameMatches {
                        add(itemURL, LeftoverMatch(reason: .versionStrippedName, confidence: .low))
                    }
                }
            }
        }

        // System launch agents/daemons (removal needs the engine's own checks).
        let systemDirs = [MCConstants.systemLaunchDaemons, MCConstants.systemLaunchAgents]
        for dirURL in systemDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)
            else { continue }
            for itemURL in contents where itemURL.pathExtension == "plist" {
                let name = itemURL.lastPathComponent
                let program = Self.launchProgram(itemURL)
                let nameMatches = AppMatching.filenameMatches(name, patterns: patterns)
                guard nameMatches || program != nil else { continue }
                let match = LeftoverExplainer.explain(fileName: name, librarySubdirectory: dirURL.lastPathComponent,
                                                      app: app, context: context, launchProgram: program)
                if let match { add(itemURL, match) }
                else if nameMatches { add(itemURL, LeftoverMatch(reason: .versionStrippedName, confidence: .low)) }
            }
        }

        return found.sorted {
            $0.match.confidence != $1.match.confidence ? $0.match.confidence > $1.match.confidence
                : $0.item.size > $1.item.size
        }
    }

    /// Program (or ProgramArguments[0]) of a launchd plist.
    static func launchProgram(_ url: URL) -> String? {
        guard url.pathExtension == "plist",
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        if let p = dict["Program"] as? String { return p }
        return (dict["ProgramArguments"] as? [String])?.first
    }

    private func makeFileItem(from url: URL) -> FileItem? {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey,
            .contentModificationDateKey, .nameKey,
        ])
        let isDir = values?.isDirectory ?? false
        var size = UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)

        if isDir {
            size = directorySize(url)
        }

        return FileItem(
            url: url,
            name: values?.name ?? url.lastPathComponent,
            size: size,
            allocatedSize: size,
            isDirectory: isDir,
            modificationDate: values?.contentModificationDate
        )
    }

    private func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .linkCountKey],
            options: []
        ) else { return 0 }
        var total: UInt64 = 0
        var hardLinks = HardLinkTracker()
        while let fileURL = enumerator.nextObject() as? URL {
            let v = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .linkCountKey])
            guard hardLinks.shouldCount(fileURL, linkCount: v?.linkCount) else { continue }
            total += UInt64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
