import Foundation

// What Apple's XProtect did recently, read from the unified log without root.
//
// Idea from Howard Oakley's Skint / XProCheck (closed source, ideas only):
// XProtect works silently, so show the user its scans, updates and any
// detections in plain words. Everything here is a pure parser over
// `log show --style ndjson` output; the app runs the command detached.
//
// What a non-admin process can read on macOS 26/27 (checked on 27.2):
// - XProtect's background scan runner: "Starting / Finished system scan".
// - Remediator reports (subsystem com.apple.XProtectFramework.PluginAPI):
//   the payload is `<private>` without a logging profile, so they are counted,
//   and parsed only when readable.
// - `osascript` loading XPScripts.yr: each AppleScript run is checked.
// - Updates come from /Library/Receipts/InstallHistory.plist (world-readable,
//   complete history), not the log: matching softwareupdated messages in the
//   log made the query four times slower.
// - Detections Gatekeeper (syspolicyd) or a remediator log in clear text.
// Messages are never stored beyond the parsed counters and family names.

public struct XProtectActivitySummary: Sendable, Equatable {
    public struct Detection: Sendable, Equatable, Hashable {
        public let date: Date?
        /// Rule, signature or remediator label as logged ("MACOS.SOMA.JAPEENA").
        public let label: String
        /// The item was removed / remediated, not only detected.
        public let remediated: Bool
        public let process: String

        public init(date: Date?, label: String, remediated: Bool, process: String) {
            self.date = date
            self.label = label
            self.remediated = remediated
            self.process = process
        }

        /// Common family name when known.
        public var family: String { MalwareFamilies.displayName(for: label) }
    }

    public struct Update: Sendable, Equatable, Hashable {
        public let date: Date?
        /// "XProtectPayloads" (remediators) or "XProtectPlistConfigData" (rules).
        public let component: String
        public let version: String

        public init(date: Date?, component: String, version: String) {
            self.date = date
            self.component = component
            self.version = version
        }
    }

    /// Oldest and newest event seen: the log keeps only some days.
    public var firstEvent: Date?
    public var lastEvent: Date?
    public var systemScans = 0
    public var lastSystemScan: Date?
    public var remediatorReports = 0
    public var scriptChecks = 0
    public var lastScriptCheck: Date?
    public var detections: [Detection] = []
    public var updates: [Update] = []

    public init() {}

    public var lastUpdate: Update? { updates.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } }
    public var isEmpty: Bool { firstEvent == nil }
}

public enum XProtectActivity {
    /// Bounded predicate: only the processes and subsystems that matter, so
    /// 30 days of log take seconds, not minutes.
    public static let predicate = [
        #"subsystem BEGINSWITH "com.apple.XProtectFramework""#,
        #"(process == "osascript" AND subsystem == "com.apple.xprotect")"#,
        #"(subsystem == "com.apple.xprotect" AND process == "syspolicyd" AND eventMessage CONTAINS[c] "malware")"#,
        #"(process BEGINSWITH "XProtectRemediator" AND subsystem != "com.apple.launchservices" AND subsystem != "com.apple.xpc")"#,
    ].joined(separator: " OR ")

    /// Arguments for `/usr/bin/log`.
    public static func logArguments(days: Int) -> [String] {
        ["show", "--last", "\(max(1, days))d", "--info", "--style", "ndjson", "--predicate", predicate]
    }

    /// Parses `log show --style ndjson` output.
    public static func parse(ndjson data: Data) -> XProtectActivitySummary {
        var summary = XProtectActivitySummary()
        var seenDetections = Set<String>()
        data.withUnsafeBytes { raw in
            var start = 0
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0...bytes.count {
                guard i == bytes.count || bytes[i] == 0x0A else { continue }
                defer { start = i + 1 }
                guard i > start, bytes[start] == UInt8(ascii: "{") else { continue }
                let line = Data(bytes[start..<i])
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                apply(object, to: &summary, seenDetections: &seenDetections)
            }
        }
        summary.detections.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return summary
    }

    static func apply(_ e: [String: Any], to s: inout XProtectActivitySummary, seenDetections: inout Set<String>) {
        let message = e["eventMessage"] as? String ?? ""
        let process = ((e["processImagePath"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
        let subsystem = e["subsystem"] as? String ?? ""
        let category = e["category"] as? String ?? ""
        let date = (e["timestamp"] as? String).flatMap(parseDate)
        guard !message.isEmpty || subsystem.hasPrefix("com.apple.XProtect") else { return }
        if let date {
            if s.firstEvent == nil || date < s.firstEvent! { s.firstEvent = date }
            if s.lastEvent == nil || date > s.lastEvent! { s.lastEvent = date }
        }
        let lower = message.lowercased()

        if subsystem == "com.apple.XProtectFramework", category == "Runner" {
            if lower.hasPrefix("finished system scan") {
                s.systemScans += 1
                if let date, s.lastSystemScan.map({ date > $0 }) ?? true { s.lastSystemScan = date }
            }
            return
        }
        if subsystem == "com.apple.XProtectFramework.PluginAPI" {
            s.remediatorReports += 1
            if let detection = pluginDetection(message, date: date, process: process),
               seenDetections.insert(detection.label + "|\(detection.date?.timeIntervalSince1970 ?? 0)").inserted {
                s.detections.append(detection)
            }
            return
        }
        if process == "osascript" {
            if lower.contains("xprotect rules") || lower.contains("xpscripts") {
                s.scriptChecks += 1
                if let date, s.lastScriptCheck.map({ date > $0 }) ?? true { s.lastScriptCheck = date }
            }
            return
        }
        // syspolicyd / remediators / XProtect itself, in clear text.
        if let detection = clearTextDetection(message, date: date, process: process),
           seenDetections.insert(detection.label + "|\(detection.date?.timeIntervalSince1970 ?? 0)").inserted {
            s.detections.append(detection)
        }
    }

    /// A remediator report, when its payload is readable JSON that says
    /// something was found. Private (redacted) payloads give nil.
    static func pluginDetection(_ message: String, date: Date?, process: String) -> XProtectActivitySummary.Detection? {
        guard message != "<private>", let start = message.firstIndex(of: "{"),
              let data = String(message[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return clearTextDetection(message, date: date, process: process)
        }
        var labels: [String] = []
        var remediated = false
        var found = false
        func walk(_ value: Any, key: String) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict { walk(v, key: k.lowercased()) }
            } else if let array = value as? [Any] {
                for v in array { walk(v, key: key) }
            } else if let text = value as? String {
                let t = text.lowercased()
                if key.contains("remediat") && (t.contains("success") || t == "true") { remediated = true; found = true }
                if (key.contains("detect") || key.contains("status")) && (t.contains("detected") || t.contains("found")) { found = true }
                if key == "plugin" || key == "pluginname" || key.contains("signature") || key.contains("family")
                    || key.contains("rule") { labels.append(text) }
            } else if let flag = value as? Bool, flag {
                if key.contains("remediat") { remediated = true; found = true }
                if key.contains("detect") || key.contains("infected") { found = true }
            }
        }
        walk(json, key: "")
        guard found else { return nil }
        let label = labels.first { MalwareFamilies.lookup($0) != nil } ?? labels.first ?? process
        return .init(date: date, label: label, remediated: remediated, process: process)
    }

    /// Plain log lines from syspolicyd, a remediator or XProtect that name
    /// a detection ("… malware detected: MACOS.ADLOAD.X", "… remediated …").
    static func clearTextDetection(_ message: String, date: Date?, process: String) -> XProtectActivitySummary.Detection? {
        let lower = message.lowercased()
        let mentionsDetection = lower.contains("malware") || lower.contains("detected") || lower.contains("remediat")
        // Status chatter that is not a detection.
        let benign = ["no malware", "not malware", "0 malware", "no threats", "scan started", "scanning",
                      "succeeded!", "rules location"]
        guard mentionsDetection, !benign.contains(where: { lower.contains($0) }) else { return nil }
        let remediated = lower.contains("remediated") || lower.contains("removed") || lower.contains("quarantined")
        let label = familyLabel(in: message)
            ?? (process.hasPrefix("XProtectRemediator") ? process : nil)
        guard let label else {
            return lower.contains("malware") && (lower.contains("detected") || lower.contains("found"))
                ? .init(date: date, label: process, remediated: remediated, process: process) : nil
        }
        return .init(date: date, label: label, remediated: remediated, process: process)
    }

    nonisolated(unsafe) static let labelRegex = try! NSRegularExpression(
        pattern: #"(XProtect_[A-Za-z0-9_]+|MACOS[._][A-Za-z0-9_.]+|OSX\.[A-Za-z0-9_.]+)"#)

    static func familyLabel(in message: String) -> String? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = labelRegex.firstMatch(in: message, range: range),
              let r = Range(match.range, in: message) else { return nil }
        var label = String(message[r])
        while label.hasSuffix(".") { label.removeLast() }
        return label
    }

    /// `2026-11-18 16:52:15.365256+0100`
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        if let d = formatter.date(from: text) { return d }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter.date(from: text)
    }

    // MARK: Updates

    /// XProtect components in /Library/Receipts/InstallHistory.plist.
    static let updateComponents: Set<String> = ["XProtectPlistConfigData", "XProtectPayloads", "XProtectCloudKitUpdate"]

    /// XProtect installs recorded in InstallHistory.plist, newest first.
    public static func updates(installHistory data: Data) -> [XProtectActivitySummary.Update] {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        return list.compactMap { entry -> XProtectActivitySummary.Update? in
            guard let name = entry["displayName"] as? String, updateComponents.contains(name),
                  let version = entry["displayVersion"] as? String else { return nil }
            let date = entry["date"] as? Date
            guard seen.insert(name + version).inserted else { return nil }
            return XProtectActivitySummary.Update(date: date, component: name, version: version)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: Versions

    public struct VersionInfo: Sendable, Equatable {
        /// XProtect rules / signatures version (`xprotect version`).
        public var version: String?
        public var installed: Date?
    }

    /// Parses `Version: 5372 Installed: 2026-11-11 07:58:51 +0000`.
    public static func parseVersion(_ output: String) -> VersionInfo {
        var info = VersionInfo()
        if let r = output.range(of: #"Version:\s*(\d+)"#, options: .regularExpression) {
            info.version = output[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let r = output.range(of: #"Installed:\s*.+"#, options: .regularExpression) {
            let text = output[r].dropFirst("Installed:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            info.installed = formatter.date(from: text)
        }
        return info
    }

    /// Parses `xprotect status --json`: background scans on / off.
    public static func parseBackgroundScans(_ output: String) -> Bool? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["xprotect_background_scans"] as? Bool
    }
}
