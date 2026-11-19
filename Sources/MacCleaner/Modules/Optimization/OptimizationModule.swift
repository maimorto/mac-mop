import Foundation
import AppKit
import MacCleanerKit

public struct OptimizationModule: ScanModule {
    public let id = "optimization"
    public var name: String { L10n.tr("优化", "Optimization", "Оптимизация") }
    public let category = ModuleCategory.performance

    public init() {}

    public func scan() async -> [ScanResult] {
        []
    }
}

// MARK: - Unified Auto-Start Model

public struct AutoStartItem: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let bundleIdentifier: String?
    public let programPath: String?
    public let configFilePath: String?
    public let sourceType: SourceType
    public let isSystem: Bool
    public var isEnabled: Bool

    public enum SourceType: String, Sendable, CaseIterable {
        case loginItem
        case launchAgent
        case launchDaemon

        public var localizedName: String {
            switch self {
            case .loginItem:    return L10n.tr("登录项", "Login Item", "Объект входа")
            case .launchAgent:  return L10n.tr("启动代理", "Launch Agent", "Агент запуска")
            case .launchDaemon: return L10n.tr("启动守护进程", "Launch Daemon", "Демон запуска")
            }
        }
    }

    public var hasConfigFile: Bool {
        guard let p = configFilePath else { return false }
        return !p.isEmpty
    }

}

// MARK: - Unified Auto-Start Manager

public final class AutoStartManager: @unchecked Sendable {
    public init() {}

    // MARK: Public API

    public func getLoginItems() -> [AutoStartItem] {
        loadLoginItemsViaSystemEvents()
    }

    public func getLaunchAgents() -> [AutoStartItem] {
        var agents: [AutoStartItem] = []
        agents.append(contentsOf: scanPlistDir(MCConstants.userLaunchAgents, type: .launchAgent, isSystem: false))
        agents.append(contentsOf: scanPlistDir(MCConstants.systemLaunchAgents, type: .launchAgent, isSystem: true))
        return agents
    }

    public func getLaunchDaemons() -> [AutoStartItem] {
        scanPlistDir(MCConstants.systemLaunchDaemons, type: .launchDaemon, isSystem: true)
    }

    // MARK: Toggle

    public enum ToggleError: Error {
        case systemItemReadOnly
        case unreadablePlist
        case sfltoolFailed(String)
    }

    public func toggleItem(_ item: AutoStartItem, enabled: Bool) throws {
        switch item.sourceType {
        case .loginItem:
            guard let bid = item.bundleIdentifier else { return }
            try toggleLoginItem(bundleId: bid, enabled: enabled)
        case .launchAgent, .launchDaemon:
            try togglePlistItem(item, enabled: enabled)
        }
    }

    // MARK: Open in Finder

    public func openConfigInFinder(_ item: AutoStartItem) {
        guard let path = item.configFilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Login Items Acquisition

    /// Read login items from System Settings → General → Login Items & Extensions
    /// via System Events (AppleScript). This is the only reliable API on macOS 15+
    /// — sfltool dumpbtm only returns system-level items (UID -2), and the old
    /// backgrounditems.btm plist path no longer exists.
    private func loadLoginItemsViaSystemEvents() -> [AutoStartItem] {
        let script = """
        tell application "System Events"
            set loginItemsList to {}
            repeat with loginItem in every login item
                set end of loginItemsList to {name:name of loginItem, path:path of loginItem, hidden:hidden of loginItem}
            end repeat
            return loginItemsList
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return []
        }
        // System Events can sit on an Automation prompt or hang: give up after
        // a minute instead of blocking the caller forever.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        // Read before waiting: a full pipe would otherwise block osascript.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return [] }
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parseOsascriptLoginItems(output)
    }

    /// Maps the System Events records (see `LoginItemsOutput`) to rows.
    private func parseOsascriptLoginItems(_ output: String) -> [AutoStartItem] {
        var items: [AutoStartItem] = []
        for record in LoginItemsOutput.parse(output) {
            let bundleId = record.name
            let path = record.path

            let displayName: String
            let resolvedPath: String?
            if let p = path, FileManager.default.fileExists(atPath: p) {
                var raw = FileManager.default.displayName(atPath: p)
                if raw.hasSuffix(".app") {
                    raw = String(raw.dropLast(4))
                }
                displayName = raw
                resolvedPath = p
            } else {
                displayName = bundleId
                resolvedPath = resolveAppPath(bundleId: bundleId, path: path)
            }

            items.append(AutoStartItem(
                name: displayName,
                bundleIdentifier: bundleId,
                programPath: resolvedPath,
                configFilePath: path,
                sourceType: .loginItem,
                isSystem: false,
                isEnabled: true
            ))
        }
        return items
    }

    // MARK: - Launch Agents / Daemons Acquisition

    private func scanPlistDir(_ dir: URL, type: AutoStartItem.SourceType, isSystem: Bool) -> [AutoStartItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var items: [AutoStartItem] = []
        for url in contents where url.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }

            let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
            let program: String?
            if let prog = plist["Program"] as? String {
                program = prog
            } else if let args = plist["ProgramArguments"] as? [String] {
                program = args.first
            } else {
                program = nil
            }
            let disabled = plist["Disabled"] as? Bool ?? false

            // Resolve a human-readable name
            let name: String
            if let progPath = program, let displayName = resolveAppNameFromPath(progPath) {
                name = displayName
            } else {
                name = label
            }

            items.append(AutoStartItem(
                name: name,
                bundleIdentifier: label,
                programPath: program,
                configFilePath: url.path,
                sourceType: type,
                isSystem: isSystem,
                isEnabled: !disabled
            ))
        }
        return items
    }

    // MARK: - Helpers

    private func resolveAppNameFromPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return FileManager.default.displayName(atPath: expanded)
    }

    private func resolveAppPath(bundleId: String, path: String?) -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.path
        }
        if let p = path {
            let expanded = (p as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    // MARK: - Toggle Implementations

    private func toggleLoginItem(bundleId: String, enabled: Bool) throws {
        // Use AppleScript via System Events to add/remove the login item.
        // This matches what System Settings → General → Login Items does.
        let script: String
        if enabled {
            // When enabling, we need the app path. Look it up from bundle ID.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                throw ToggleError.sfltoolFailed("Cannot find app for bundle ID: \(bundleId)")
            }
            // Escape backslash and double-quote so a path like /Apps/foo".app
            // cannot break out of the AppleScript string literal.
            let escapedPath = url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "System Events"
                make new login item at end with properties {path:"\(escapedPath)", hidden:false}
            end tell
            """
        } else {
            let escapedId = bundleId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "System Events"
                delete login item "\(escapedId)"
            end tell
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw ToggleError.sfltoolFailed(output)
        }
    }

    private func togglePlistItem(_ item: AutoStartItem, enabled: Bool) throws {
        guard !item.isSystem else { throw ToggleError.systemItemReadOnly }
        guard let configPath = item.configFilePath else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToggleError.unreadablePlist
        }
        plist["Disabled"] = !enabled
        let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try newData.write(to: URL(fileURLWithPath: configPath))
    }
}

// MARK: - Backward-compatible Wrappers

public final class LaunchAgentsManager: @unchecked Sendable {
    public struct LaunchAgent: Identifiable, Sendable {
        public let id: UUID = UUID()
        public let label: String
        public let path: URL
        public let program: String?
        public let isSystem: Bool
        public var isEnabled: Bool

        public var asAutoStartItem: AutoStartItem {
            AutoStartItem(
                name: label,
                bundleIdentifier: label,
                programPath: program,
                configFilePath: path.path,
                sourceType: .launchAgent,
                isSystem: isSystem,
                isEnabled: isEnabled
            )
        }
    }

    private let inner = AutoStartManager()
    public init() {}

    public func getLaunchAgents() -> [LaunchAgent] {
        inner.getLaunchAgents().map { item in
            LaunchAgent(
                label: item.name,
                path: URL(fileURLWithPath: item.configFilePath ?? ""),
                program: item.programPath,
                isSystem: item.isSystem,
                isEnabled: item.isEnabled
            )
        }
    }

    public enum ToggleError: Error { case systemAgentReadOnly, unreadablePlist }

    public func toggleAgent(_ agent: LaunchAgent, enabled: Bool) throws {
        do {
            try inner.toggleItem(agent.asAutoStartItem, enabled: enabled)
        } catch AutoStartManager.ToggleError.systemItemReadOnly {
            throw ToggleError.systemAgentReadOnly
        } catch AutoStartManager.ToggleError.unreadablePlist {
            throw ToggleError.unreadablePlist
        } catch {
            throw ToggleError.unreadablePlist
        }
    }
}

// MARK: - Process Monitor

public final class ProcessMonitor: @unchecked Sendable {
    public init() {}

    public func forceQuit(pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.forceTerminate()
        }
    }
}
