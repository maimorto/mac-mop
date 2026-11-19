import Foundation
import Darwin

// First-run installer: when Mac Mop is opened straight from its disk image
// (or from an App Translocation sandbox), offer to copy it into Applications,
// relaunch the installed copy and eject the image. Pure decisions live here
// so they can be tested; the window and animations are in the app target.

/// Where the running app bundle lives.
public enum InstallLocation: Equatable, Sendable {
    /// On a mounted disk image, `volume` is its root ("/Volumes/Mac Mop").
    case diskImage(volume: String)
    /// Gatekeeper's randomised read-only copy (App Translocation).
    case translocated
    /// Already in /Applications or ~/Applications (or a subfolder).
    case applications
    /// Anywhere else (build folder, Desktop, an external drive...).
    case other

    /// Root of the volume holding `path` ("/Volumes/<name>"), nil outside /Volumes.
    public static func volumeRoot(of path: String) -> String? {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// Classify a bundle path. A /Volumes path counts as a disk image only if
    /// the volume looks like an installer image (read-only, or carrying the
    /// Applications drop link), so running from an external drive does not
    /// trigger the installer.
    public static func classify(bundlePath: String, home: String,
                                volumeIsReadOnly: Bool, volumeHasApplicationsLink: Bool) -> InstallLocation {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        let userApps = (home as NSString).appendingPathComponent("Applications")
        if path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/") { return .applications }
        if let volume = volumeRoot(of: path), volumeIsReadOnly || volumeHasApplicationsLink {
            return .diskImage(volume: volume)
        }
        return .other
    }

    /// Whether to show the installer window instead of the main UI.
    public var offersInstaller: Bool {
        switch self {
        case .diskImage, .translocated: true
        case .applications, .other: false
        }
    }

    /// The running app, classified with live file-system facts.
    public static func current(bundlePath: String = Bundle.main.bundlePath) -> InstallLocation {
        let fm = FileManager.default
        var readOnly = false
        var hasLink = false
        if let volume = volumeRoot(of: bundlePath) {
            let url = URL(fileURLWithPath: volume)
            readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
            hasLink = (try? fm.destinationOfSymbolicLink(atPath: volume + "/Applications")) == "/Applications"
        }
        return classify(bundlePath: bundlePath, home: NSHomeDirectory(),
                        volumeIsReadOnly: readOnly, volumeHasApplicationsLink: hasLink)
    }

    /// True when launched from the disk image (or translocated), or when the
    /// debug override `KMR_FORCE_INSTALLER=1` is set.
    public static var isRunningFromDiskImage: Bool {
        if ProcessInfo.processInfo.environment["KMR_FORCE_INSTALLER"] == "1" { return true }
        return current().offersInstaller
    }
}

/// Everything the installer will do, decided before touching the disk.
public struct InstallPlan: Equatable, Sendable {
    public let source: URL
    public let destinationDirectory: URL
    /// Final location, e.g. /Applications/Mac Mop.app.
    public let destination: URL
    /// Hidden sibling the bundle is copied to first, then renamed into place.
    public let temporary: URL
    /// A previous copy at `destination`, moved to the Trash before the swap.
    public let existing: URL?
    /// True when /Applications was not writable and ~/Applications is used.
    public let usesUserApplications: Bool
    /// Disk image to eject once the installed copy is running.
    public let ejectVolume: String?
}

public enum InstallPlanner {
    /// Candidate folders in order: the override (tests / KMR_INSTALL_DEST),
    /// else /Applications then ~/Applications.
    public static func candidates(override: String?, home: String) -> [URL] {
        if let override, !override.isEmpty { return [URL(fileURLWithPath: override, isDirectory: true)] }
        return [URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Plan the install, or nil when no destination is writable or the source
    /// already is the destination.
    public static func plan(source: URL, override: String?, home: String, ejectVolume: String?,
                            isWritable: (URL) -> Bool, exists: (URL) -> Bool) -> InstallPlan? {
        let name = source.lastPathComponent
        guard name.hasSuffix(".app") else { return nil }
        let list = candidates(override: override, home: home)
        guard let dir = list.first(where: isWritable) else { return nil }
        let destination = dir.appendingPathComponent(name, isDirectory: true)
        let src = source.standardizedFileURL.path
        guard src != destination.standardizedFileURL.path, !src.hasPrefix(dir.standardizedFileURL.path + "/") else { return nil }
        let temporary = dir.appendingPathComponent(".\(name).installing", isDirectory: true)
        let userApps = override == nil && dir == list.last && list.count > 1
        return InstallPlan(source: source, destinationDirectory: dir, destination: destination, temporary: temporary,
                           existing: exists(destination) ? destination : nil,
                           usesUserApplications: userApps, ejectVolume: ejectVolume)
    }

    /// Live writability: an existing folder we can write to, or a missing
    /// folder whose parent we can write to (~/Applications gets created).
    public static func isWritableFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue && fm.isWritableFile(atPath: url.path)
        }
        return fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
}

/// Steps reported while installing (drive the progress animation).
public enum InstallStep: Int, Sendable, CaseIterable {
    case copying, replacing, finishing, done

    public var fraction: Double {
        switch self {
        case .copying: 0.15
        case .replacing: 0.7
        case .finishing: 0.88
        case .done: 1
        }
    }
}

/// Executes an `InstallPlan`. Copy to a hidden temporary name first (nothing
/// changes if that fails), move any previous version to the Trash, rename
/// the copy into place, then clear the download quarantine on our own copy.
public struct AppBundleInstaller: Sendable {
    public var trash: @Sendable (URL) throws -> Void

    public init(trash: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.trash = trash
    }

    @discardableResult
    public func install(_ plan: InstallPlan, progress: (InstallStep) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        progress(.copying)
        try fm.createDirectory(at: plan.destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: plan.temporary.path) { try fm.removeItem(at: plan.temporary) }  // our own leftover
        do {
            try fm.copyItem(at: plan.source, to: plan.temporary)
        } catch {
            try? fm.removeItem(at: plan.temporary)
            throw error
        }
        progress(.replacing)
        if fm.fileExists(atPath: plan.destination.path) {
            do { try trash(plan.destination) } catch {
                try? fm.removeItem(at: plan.temporary)
                throw error
            }
        }
        do {
            try fm.moveItem(at: plan.temporary, to: plan.destination)
        } catch {
            try? fm.removeItem(at: plan.temporary)
            throw error
        }
        progress(.finishing)
        Self.stripQuarantine(plan.destination)
        progress(.done)
        return plan.destination
    }

    /// Remove `com.apple.quarantine` from a bundle we just installed (the user
    /// already opened this copy of the app, so Gatekeeper has assessed it).
    public static func stripQuarantine(_ bundle: URL) {
        let name = "com.apple.quarantine"
        removexattr(bundle.path, name, XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let rel as String in walker {
            removexattr((bundle.path as NSString).appendingPathComponent(rel), name, XATTR_NOFOLLOW)
        }
    }
}

/// Launch arguments handed from the disk-image instance to the installed one.
public enum InstallerLaunchArgument {
    public static let ejectFlag = "--kmr-eject-volume"

    /// The volume to eject, only if it is a plain "/Volumes/<name>" root.
    public static func ejectVolume(in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: ejectFlag), i + 1 < arguments.count else { return nil }
        let value = arguments[i + 1]
        guard InstallLocation.volumeRoot(of: value) == value, !value.contains("/../"), !value.hasSuffix("/..") else { return nil }
        return value
    }

    /// `/bin/sh` arguments that wait for `pid` to exit, then open the installed
    /// copy as a new instance (Mac Mop prohibits two running instances), with
    /// the volume to eject. Values travel as positional parameters, never
    /// spliced into the script text.
    public static func relaunchCommand(pid: Int32, appPath: String, ejectVolume: String?) -> [String] {
        let script = """
        i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        if [ -n "$3" ]; then exec /usr/bin/open -n "$2" --args \(ejectFlag) "$3"; else exec /usr/bin/open -n "$2"; fi
        """
        return ["-c", script, "sh", String(pid), appPath, ejectVolume ?? ""]
    }
}
