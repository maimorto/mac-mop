import Foundation

// Pure parsers for the launch-items inventory. Every function takes the text
// or data a command / file produced and returns plain values, so tests
// don't depend on the machine.

// MARK: - crontab

public struct CrontabEntry: Equatable, Sendable {
    public let schedule: String
    public let command: String
}

public enum CrontabParser {
    /// `crontab -l` / `/etc/crontab` lines. Skips comments, blank lines and
    /// `NAME=value` environment lines. `@reboot cmd` keeps `@reboot` as the
    /// schedule; classic lines use the first five fields (six with a user
    /// field in /etc/crontab when `systemWide`).
    public static func parse(_ text: String, systemWide: Bool = false) -> [CrontabEntry] {
        var entries: [CrontabEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).flatMap { $0.split(separator: "\t") }
            guard let first = fields.first else { continue }
            if first.contains("="), !first.hasPrefix("@"), !first.first!.isNumber, first != "*" { continue }
            let scheduleCount = first.hasPrefix("@") ? 1 : 5
            let skip = scheduleCount + (systemWide ? 1 : 0)
            guard fields.count > skip else { continue }
            entries.append(CrontabEntry(schedule: fields.prefix(scheduleCount).joined(separator: " "),
                                        command: fields.dropFirst(skip).joined(separator: " ")))
        }
        return entries
    }
}

// MARK: - launchctl

public enum LaunchctlParser {
    /// `launchctl print-disabled <domain>`: `"label" => disabled|enabled`
    /// (older systems print `true`/`false`). Returns label → isDisabled.
    public static func disabledOverrides(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// The `services = { … }` block of `launchctl print <domain>`:
    /// `  <pid|0|->  <status|->  <label>`. Returns label → running (pid > 0).
    public static func services(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var inServices = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "services = {" { inServices = true; continue }
            guard inServices else { continue }
            if line == "}" { break }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3 else { continue }
            let pid = Int(fields[0]) ?? 0
            result[String(fields[2])] = pid > 0
        }
        return result
    }
}

// MARK: - pluginkit

public struct PluginKitEntry: Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let path: String
    public let sdk: String?
    public let displayName: String?
    /// `+` elected (on), `-` ignored (off), nil when not printed.
    public let enabled: Bool?
}

public enum PersistencePluginKitParser {
    /// `pluginkit -mAvvv` output: a header line per plug-in
    /// (`[+|-|=|!]  com.x.y(1.0)`) followed by indented `Key = value` lines.
    public static func parse(_ text: String) -> [PluginKitEntry] {
        var entries: [PluginKitEntry] = []
        var current: (id: String, version: String, enabled: Bool?)?
        var fields: [String: String] = [:]
        func flush() {
            if let current, let path = fields["Path"] {
                entries.append(PluginKitEntry(identifier: current.id, version: current.version, path: path,
                                              sdk: fields["SDK"], displayName: fields["Display Name"], enabled: current.enabled))
            }
            current = nil
            fields = [:]
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let eq = trimmed.range(of: " = "), line.hasPrefix("\t") || line.hasPrefix("        ") {
                fields[String(trimmed[..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)] =
                    String(trimmed[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            var header = Substring(trimmed)
            var enabled: Bool?
            if let first = header.first, "+-=!".contains(first) {
                enabled = first == "+" ? true : first == "-" ? false : nil
                header = header.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            }
            guard header.hasSuffix(")"), let open = header.lastIndex(of: "("), !header.contains(" ") else { continue }
            flush()
            current = (String(header[..<open]), String(header[header.index(after: open)..<header.index(before: header.endIndex)]), enabled)
        }
        flush()
        return entries
    }

    /// Human name of a plug-in point.
    public static func kindLabel(sdk: String?) -> String {
        switch sdk ?? "" {
        case "com.apple.FinderSync": UIText.t("Integrazione con il Finder", "Finder integration")
        case "com.apple.share-services": UIText.t("Condivisione", "Sharing")
        case "com.apple.widgetkit-extension", "com.apple.widget-extension": UIText.t("Widget", "Widget")
        case "com.apple.quicklook.preview", "com.apple.quicklook.thumbnail": UIText.t("Anteprima Quick Look", "Quick Look preview")
        case "com.apple.Safari.web-extension", "com.apple.Safari.extension", "com.apple.Safari.content-blocker":
            UIText.t("Estensione di Safari", "Safari extension")
        case "com.apple.services": UIText.t("Azione (menu Servizi)", "Action (Services menu)")
        case "com.apple.spotlight.import": UIText.t("Importatore Spotlight", "Spotlight importer")
        case "com.apple.fileprovider-nonui": UIText.t("Provider di file (cloud)", "File provider (cloud)")
        case "com.apple.intents-service": UIText.t("Siri e Comandi rapidi", "Siri and Shortcuts")
        case "com.apple.photo-editing": UIText.t("Modifica foto", "Photo editing")
        case "com.apple.networkextension.packet-tunnel": UIText.t("VPN", "VPN")
        case "": UIText.t("Estensione", "Extension")
        default: UIText.t("Estensione", "Extension")
        }
    }

    /// Plug-ins inside Apple's sealed system volume are skipped: they can't
    /// be changed and there are hundreds of them.
    public static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}

// MARK: - systemextensionsctl

public struct SystemExtensionEntry: Equatable, Sendable {
    public let teamID: String
    public let bundleID: String
    public let version: String
    public let name: String
    public let enabled: Bool
    public let active: Bool
    public let state: String
    public let category: String
}

public enum SystemExtensionsParser {
    /// `systemextensionsctl list`. Category headers start with `---`, the
    /// column header with `enabled`; rows are tab-separated:
    /// `*\t*\tTEAMID\tbundle.id (1.0/1)\tName\t[activated enabled]`.
    public static func parse(_ text: String) -> [SystemExtensionEntry] {
        var entries: [SystemExtensionEntry] = []
        var category = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("---") {
                let parts = line.dropFirst(3).trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                category = parts.first.map { String($0).replacingOccurrences(of: "com.apple.system_extension.", with: "") } ?? ""
                continue
            }
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 6, !line.hasPrefix("enabled") else { continue }
            let idAndVersion = columns[3]
            let bundleID: String
            let version: String
            if let open = idAndVersion.firstIndex(of: "(") {
                bundleID = idAndVersion[..<open].trimmingCharacters(in: .whitespaces)
                version = idAndVersion[idAndVersion.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            } else {
                bundleID = idAndVersion.trimmingCharacters(in: .whitespaces)
                version = ""
            }
            guard !bundleID.isEmpty else { continue }
            entries.append(SystemExtensionEntry(
                teamID: columns[2].trimmingCharacters(in: .whitespaces),
                bundleID: bundleID, version: version,
                name: columns[4].trimmingCharacters(in: .whitespaces),
                enabled: columns[0].contains("*"), active: columns[1].contains("*"),
                state: columns[5].trimmingCharacters(in: CharacterSet(charactersIn: "[] ")),
                category: category))
        }
        return entries
    }
}

// MARK: - PAM

public enum PAMParser {
    /// Modules referenced by a /etc/pam.d file that macOS doesn't ship.
    /// `shipped` holds the file names in /usr/lib/pam (`pam_tid.so.2`); a
    /// bare `pam_tid.so` matches `pam_tid.so.2`. `include` lines and
    /// comments are ignored.
    public static func thirdPartyModules(_ text: String, shipped: Set<String>) -> [String] {
        var modules: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3, fields[1] != "include" else { continue }
            // The control field may be a bracketed list: [success=ok …].
            var index = 2
            if fields[1].hasPrefix("[") {
                while index < fields.count, !fields[index - 1].hasSuffix("]") { index += 1 }
            }
            guard index < fields.count else { continue }
            let module = fields[index]
            let name = (module as NSString).lastPathComponent
            let isShipped = !module.hasPrefix("/") || module.hasPrefix("/usr/lib/pam/")
                ? shipped.contains(name) || shipped.contains { $0.hasPrefix(name + ".") }
                : false
            if !isShipped { modules.append(module) }
        }
        return modules
    }
}

// MARK: - Launch plist environment

public enum LaunchPlistInspector {
    /// `DYLD_*` variables an item injects into what it starts:
    /// `EnvironmentVariables` in a launchd plist, `LSEnvironment` in an
    /// app's Info.plist.
    public static func injectedLibraries(_ plist: [String: Any]) -> [String] {
        var found: [String] = []
        for key in ["EnvironmentVariables", "LSEnvironment"] {
            guard let env = plist[key] as? [String: Any] else { continue }
            for (name, value) in env where name.hasPrefix("DYLD_") {
                found.append("\(name)=\(value)")
            }
        }
        return found.sorted()
    }

    /// Short facts about how launchd runs an item.
    public static func facts(_ plist: [String: Any]) -> [String] {
        var facts: [String] = []
        if plist["RunAtLoad"] as? Bool == true { facts.append(UIText.t("Parte all'accesso o all'avvio", "Starts at login or boot")) }
        if plist["KeepAlive"] as? Bool == true || plist["KeepAlive"] is [String: Any] {
            facts.append(UIText.t("Viene riavviato se si chiude", "Restarted if it quits"))
        }
        if let interval = plist["StartInterval"] as? Int {
            facts.append(UIText.t("Ripetuto ogni \(interval) secondi", "Repeats every \(interval) seconds"))
        }
        if plist["StartCalendarInterval"] != nil { facts.append(UIText.t("Parte a orari pianificati", "Starts on a schedule")) }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil {
            facts.append(UIText.t("Parte quando cambiano certi file", "Starts when certain files change"))
        }
        if plist["MachServices"] != nil { facts.append(UIText.t("Parte quando un'app lo chiama", "Starts when an app calls it")) }
        if plist["Disabled"] as? Bool == true { facts.append(UIText.t("Segnato come disattivato nel file", "Marked disabled in the file")) }
        return facts
    }
}

// MARK: - Shell startup files

public struct ShellStartupFlag: Equatable, Sendable {
    public let lineNumber: Int
    /// Truncated with secrets masked; safe to show.
    public let snippet: String
    public let findings: [ThreatFinding]
    /// Shell-specific concerns `ThreatCommandAnalyzer` has no rule for.
    public let notes: [String]
    public let severity: ThreatSeverity
}

public enum ShellStartupAudit {
    /// Lines of a shell startup file that do something dangerous. Uses
    /// `ThreatCommandAnalyzer` per line plus two shell-specific tricks:
    /// exporting `DYLD_INSERT_LIBRARIES` (high), and redefining `sudo`, a
    /// known way to capture the password (medium). Never returns raw text:
    /// snippets are truncated and masked.
    public static func flaggedLines(_ text: String) -> [ShellStartupFlag] {
        var flags: [ShellStartupFlag] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let findings = ThreatCommandAnalyzer.analyze(line)
            var notes: [String] = []
            var severity = findings.map(\.severity).max()
            let lower = line.lowercased()
            if lower.contains("dyld_insert_libraries") {
                notes.append(UIText.t("Fa caricare una libreria dentro ogni programma avviato dal Terminale (DYLD_INSERT_LIBRARIES).",
                                      "Loads a library into every program started from Terminal (DYLD_INSERT_LIBRARIES)."))
                severity = .high
            }
            if lower.hasPrefix("alias sudo=") || lower.hasPrefix("sudo()") || lower.hasPrefix("sudo ()") || lower.hasPrefix("function sudo") {
                notes.append(UIText.t("Ridefinisce il comando sudo: un trucco noto per catturare la password.",
                                      "Redefines the sudo command: a known trick to capture the password."))
                severity = max(severity ?? .medium, .medium)
            }
            guard let severity else { continue }
            flags.append(ShellStartupFlag(lineNumber: index + 1, snippet: ThreatCommandAnalyzer.snippet(line),
                                          findings: findings, notes: notes, severity: severity))
        }
        return flags
    }
}

// MARK: - Login hooks

public enum LoginHookParser {
    /// `LoginHook` / `LogoutHook` values from a com.apple.loginwindow plist.
    public static func hooks(_ plist: [String: Any]) -> [(kind: String, script: String)] {
        ["LoginHook", "LogoutHook"].compactMap { key in
            guard let value = plist[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (key, value)
        }
    }
}

// MARK: - Background Task Management database

/// One record of macOS's Login Items database (BackgroundItems-v*.btm).
public struct BTMRecord: Equatable, Sendable {
    public let identifier: String
    public let name: String?
    public let developerName: String?
    public let teamIdentifier: String?
    public let type: Int
    public let disposition: Int
    public let url: String?
    public let executablePath: String?
    public let bundleIdentifier: String?

    /// Bit 0 of `disposition`: the user left it on.
    public var isEnabled: Bool { disposition & 0x1 != 0 }

    public var isApp: Bool { type & 0x2 != 0 }
    public var isLoginItem: Bool { type & 0x4 != 0 }
    public var isAgent: Bool { type & 0x8 != 0 }
    public var isDaemon: Bool { type & 0x10 != 0 }
    /// Grouping record for a developer: not something that runs.
    public var isDeveloperGroup: Bool { type & 0x20 != 0 }
    public var isLegacy: Bool { type & 0x10000 != 0 }

    public var kindLabel: String {
        if isDaemon { return UIText.t("Servizio in background", "Background service") }
        if isAgent { return UIText.t("Agente in background", "Background agent") }
        if isLoginItem { return UIText.t("Aiutante di login", "Login helper") }
        if isApp { return UIText.t("App aperta al login", "App opened at login") }
        return UIText.t("Elemento in background", "Background item")
    }
}

public enum BTMArchive {
    /// Decodes an NSKeyedArchiver .btm file without knowing its private
    /// classes: walks `$objects`, follows UIDs, and returns every dictionary
    /// that looks like an item record (`type` + `disposition`). Developer
    /// grouping records are dropped.
    public static func records(from data: Data) -> [BTMRecord] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any],
              let top = root["$top"] as? [String: Any] else { return [] }
        var flattener = Flattener(objects: objects)
        var found: [BTMRecord] = []
        var seen = Set<String>()
        /// Embedded helpers store their URL relative to the app that
        /// contains them ("Contents/Library/LoginItems/…"): child identifier
        /// → container identifier, and identifier → absolute URL.
        var parentOf: [String: String] = [:]
        var absoluteURL: [String: String] = [:]
        func walk(_ value: Any, depth: Int) {
            guard depth < 64 else { return }
            if let dict = value as? [String: Any] {
                if let type = dict["type"] as? Int, let disposition = dict["disposition"] as? Int,
                   let identifier = dict["identifier"] as? String {
                    let record = BTMRecord(
                        identifier: identifier, name: dict["name"] as? String,
                        developerName: dict["developerName"] as? String,
                        teamIdentifier: dict["teamIdentifier"] as? String,
                        type: type, disposition: disposition,
                        url: (dict["url"] as? String).map(fileURLPath),
                        executablePath: dict["executablePath"] as? String,
                        bundleIdentifier: dict["bundleIdentifier"] as? String)
                    if let url = record.url, !isRelative(url) {
                        absoluteURL[identifier] = url
                        for case let child as String in dict["items"] as? [Any] ?? [] { parentOf[child] = identifier }
                    }
                    if let container = dict["container"] as? String { parentOf[identifier] = container }
                    if !record.isDeveloperGroup, seen.insert(identifier).inserted { found.append(record) }
                }
                for (_, child) in dict { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        for (_, value) in top { walk(flattener.resolve(value), depth: 0) }
        return found.map { record in
            guard let container = parentOf[record.identifier], let parent = absoluteURL[container] else { return record }
            func absolute(_ path: String?) -> String? {
                guard let path, isRelative(path) else { return path }
                let trimmed = path.drop(while: { $0 == "/" })
                return (parent.hasSuffix("/") ? parent : parent + "/") + trimmed
            }
            return BTMRecord(identifier: record.identifier, name: record.name, developerName: record.developerName,
                             teamIdentifier: record.teamIdentifier, type: record.type, disposition: record.disposition,
                             url: absolute(record.url), executablePath: absolute(record.executablePath),
                             bundleIdentifier: record.bundleIdentifier)
        }
    }

    /// Paths of helpers embedded in an app, stored relative to it.
    static func isRelative(_ path: String) -> Bool {
        !path.hasPrefix("/") || path.hasPrefix("/Contents/")
    }

    /// `file:///Library/LaunchAgents/x.plist` → `/Library/LaunchAgents/x.plist`.
    static func fileURLPath(_ string: String) -> String {
        guard string.hasPrefix("file://"), let url = URL(string: string) else { return string }
        return url.path(percentEncoded: false)
    }

    /// Integer value of a CFKeyedArchiverUID (no public API: read it from
    /// the description, `<CFKeyedArchiverUID …>{value = 42}`).
    static func uid(_ value: Any) -> Int? {
        let type = String(describing: Swift.type(of: value))
        guard type.contains("UID") || type.contains("__NSCFType") else { return nil }
        let text = String(describing: value)
        guard text.contains("CFKeyedArchiverUID"), let range = text.range(of: "value = ") else { return nil }
        return Int(text[range.upperBound...].prefix(while: \.isNumber))
    }

    struct Flattener {
        let objects: [Any]
        var cache: [Int: Any] = [:]
        var inProgress = Set<Int>()

        mutating func resolve(_ value: Any, depth: Int = 0) -> Any {
            guard depth < 64 else { return NSNull() }
            if let index = BTMArchive.uid(value) {
                guard index > 0, index < objects.count else { return NSNull() }
                if let cached = cache[index] { return cached }
                guard inProgress.insert(index).inserted else { return NSNull() }
                let result = resolve(objects[index], depth: depth + 1)
                inProgress.remove(index)
                cache[index] = result
                return result
            }
            if let string = value as? String { return string == "$null" ? NSNull() : string }
            if let array = value as? [Any] { return array.map { resolve($0, depth: depth + 1) } }
            guard let dict = value as? [String: Any] else { return value }
            if let keys = dict["NS.keys"] as? [Any], let values = dict["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (k, v) in zip(keys, values) {
                    if let key = resolve(k, depth: depth + 1) as? String { out[key] = resolve(v, depth: depth + 1) }
                }
                return out
            }
            if let values = dict["NS.objects"] as? [Any] { return values.map { resolve($0, depth: depth + 1) } }
            if let string = dict["NS.string"] { return resolve(string, depth: depth + 1) }
            if let relativeValue = dict["NS.relative"] {
                // NSURL: a relative string plus an optional base URL.
                let relative = resolve(relativeValue, depth: depth + 1) as? String ?? ""
                if let baseValue = dict["NS.base"], let base = resolve(baseValue, depth: depth + 1) as? String,
                   let baseURL = URL(string: base), let joined = URL(string: relative, relativeTo: baseURL) {
                    return joined.absoluteString
                }
                return relative
            }
            if let time = dict["NS.time"] as? Double { return Date(timeIntervalSinceReferenceDate: time) }
            if let bytes = dict["NS.uuidbytes"] as? Data, bytes.count == 16 {
                return NSUUID(uuidBytes: [UInt8](bytes)).uuidString
            }
            var out: [String: Any] = [:]
            for (key, child) in dict where key != "$class" {
                out[key] = resolve(child, depth: depth + 1)
            }
            return out
        }
    }
}

// MARK: - profiles

public enum ProfilesParser {
    /// `profiles list` output (run only after the user asked for the
    /// password): `_computerlevel[1] attribute: profileIdentifier: com.x.y`.
    /// Returns (scope, identifier) pairs; scope is `_computerlevel` or a
    /// user name.
    public static func profiles(_ text: String) -> [(scope: String, identifier: String)] {
        var result: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "attribute: profileIdentifier:") else { continue }
            let identifier = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let scope = line[..<range.lowerBound].split(separator: "[").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !identifier.isEmpty { result.append((scope, identifier)) }
        }
        return result
    }
}
