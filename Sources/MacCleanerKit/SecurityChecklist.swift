import Foundation

// "Security check": the Mac's protections, each with its current state, why
// it matters and exactly how to fix it. Ideas from Pareto Security (GPL:
// ideas only, no code or text) and Mergen (MIT); everything here is our own,
// written from Apple's documentation and the tools' public output.
//
// Pure: `SecurityChecklist.evaluate` turns raw command output and plist
// contents (gathered by `SecurityChecklistProbe`) into results, so tests
// need no Mac state.

public enum SecurityCheckKind: String, CaseIterable, Codable, Sendable {
    case fileVault
    case firewall
    case firewallStealth
    case gatekeeper
    case sip
    case automaticUpdates
    case securityResponses
    case xprotect
    case appUpdates
    case screenLock
    case autoLogin
    case guestAccount
    case remoteLogin
    case screenSharing
    case remoteManagement
    case fileSharing
    case airDrop
    case bluetoothSharing
    case findMy
    case passwordHints
    case timeMachine
    case safariSafeFiles
    case firewallBlockAll
    case lockdownMode

    public var title: String {
        switch self {
        case .fileVault: "FileVault"
        case .firewall: "Firewall"
        case .firewallStealth: UIText.t("Modalità invisibile del firewall", "Firewall stealth mode")
        case .gatekeeper: "Gatekeeper"
        case .sip: UIText.t("Protezione dell'integrità di sistema", "System Integrity Protection")
        case .automaticUpdates: UIText.t("Aggiornamenti automatici di macOS", "Automatic macOS updates")
        case .securityResponses: UIText.t("Risposte di sicurezza e file di sistema", "Security responses and system files")
        case .xprotect: UIText.t("Definizioni antimalware (XProtect)", "Malware definitions (XProtect)")
        case .appUpdates: UIText.t("Aggiornamenti automatici delle app", "Automatic app updates")
        case .screenLock: UIText.t("Password dopo lo stop o il salvaschermo", "Password after sleep or screen saver")
        case .autoLogin: UIText.t("Login automatico", "Automatic login")
        case .guestAccount: UIText.t("Account ospite", "Guest account")
        case .remoteLogin: UIText.t("Login remoto (SSH)", "Remote Login (SSH)")
        case .screenSharing: UIText.t("Condivisione schermo", "Screen Sharing")
        case .remoteManagement: UIText.t("Gestione remota", "Remote Management")
        case .fileSharing: UIText.t("Condivisione file", "File Sharing")
        case .airDrop: "AirDrop"
        case .bluetoothSharing: UIText.t("Condivisione Bluetooth", "Bluetooth Sharing")
        case .findMy: UIText.t("Dov'è il mio Mac", "Find My Mac")
        case .passwordHints: UIText.t("Suggerimenti password", "Password hints")
        case .timeMachine: UIText.t("Backup Time Machine", "Time Machine backup")
        case .safariSafeFiles: UIText.t("Safari apre i file «sicuri»", "Safari opens “safe” files")
        case .firewallBlockAll: UIText.t("Blocca tutte le connessioni in entrata", "Block all incoming connections")
        case .lockdownMode: UIText.t("Modalità di isolamento", "Lockdown Mode")
        }
    }

    public var symbol: String {
        switch self {
        case .fileVault: "lock.doc.fill"
        case .firewall, .firewallBlockAll: "flame.fill"
        case .firewallStealth: "eye.slash.fill"
        case .gatekeeper: "checkmark.seal.fill"
        case .sip: "lock.shield.fill"
        case .automaticUpdates: "arrow.triangle.2.circlepath"
        case .securityResponses: "bolt.shield.fill"
        case .xprotect: "shield.lefthalf.filled"
        case .appUpdates: "app.badge.fill"
        case .screenLock: "lock.display"
        case .autoLogin: "person.badge.key.fill"
        case .guestAccount: "person.fill.questionmark"
        case .remoteLogin: "terminal.fill"
        case .screenSharing: "rectangle.on.rectangle"
        case .remoteManagement: "desktopcomputer.and.arrow.down"
        case .fileSharing: "folder.fill.badge.person.crop"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .bluetoothSharing: "wave.3.right"
        case .findMy: "location.fill"
        case .passwordHints: "questionmark.key.filled"
        case .timeMachine: "clock.arrow.circlepath"
        case .safariSafeFiles: "safari.fill"
        case .lockdownMode: "hand.raised.fill"
        }
    }

    /// Score weight: 3 essential, 2 important, 1 nice to have, 0 information.
    public var weight: Int {
        switch self {
        case .fileVault, .firewall, .gatekeeper, .sip, .automaticUpdates, .securityResponses, .xprotect, .screenLock, .autoLogin: 3
        case .remoteLogin, .screenSharing, .remoteManagement, .fileSharing, .guestAccount, .findMy, .timeMachine, .airDrop: 2
        case .firewallStealth, .appUpdates, .passwordHints, .bluetoothSharing, .safariSafeFiles: 1
        case .firewallBlockAll, .lockdownMode: 0
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case protection, updates, access, sharing, recovery, information

        public var title: String {
            switch self {
            case .protection: UIText.t("Protezioni di base", "Core protections")
            case .updates: UIText.t("Aggiornamenti", "Updates")
            case .access: UIText.t("Accesso al Mac", "Access to the Mac")
            case .sharing: UIText.t("Condivisione e accesso remoto", "Sharing and remote access")
            case .recovery: UIText.t("Furto e recupero", "Theft and recovery")
            case .information: UIText.t("Per informazione", "For information")
            }
        }
    }

    public var group: Group {
        switch self {
        case .fileVault, .firewall, .firewallStealth, .gatekeeper, .sip, .safariSafeFiles: .protection
        case .automaticUpdates, .securityResponses, .xprotect, .appUpdates: .updates
        case .screenLock, .autoLogin, .guestAccount, .passwordHints: .access
        case .remoteLogin, .screenSharing, .remoteManagement, .fileSharing, .airDrop, .bluetoothSharing: .sharing
        case .findMy, .timeMachine: .recovery
        case .firewallBlockAll, .lockdownMode: .information
        }
    }
}

public enum SecurityCheckState: String, Codable, Sendable, Comparable {
    case fail, warning, unknown, info, pass

    private var order: Int {
        switch self {
        case .fail: 0
        case .warning: 1
        case .unknown: 2
        case .info: 3
        case .pass: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }

    public var label: String {
        switch self {
        case .pass: UIText.t("A posto", "OK")
        case .warning: UIText.t("Da migliorare", "Could be better")
        case .fail: UIText.t("Da sistemare", "Needs fixing")
        case .info: UIText.t("Informazione", "Information")
        case .unknown: UIText.t("Sconosciuto", "Unknown")
        }
    }
}

public struct SecurityCheckResult: Identifiable, Sendable, Equatable {
    public var id: SecurityCheckKind { kind }
    public let kind: SecurityCheckKind
    public let state: SecurityCheckState
    /// Current state in words ("On", "Off", "Asks after 5 minutes"…).
    public let status: String
    /// Extra context (e.g. why it couldn't be read).
    public let note: String?

    public init(kind: SecurityCheckKind, state: SecurityCheckState, status: String, note: String? = nil) {
        self.kind = kind
        self.state = state
        self.status = status
        self.note = note
    }

    public var needsAttention: Bool { state == .fail || state == .warning }
}

/// Why a check matters and how to fix it.
public struct SecurityCheckGuide: Sendable {
    public let why: String
    public let steps: [String]
    /// `x-apple.systempreferences:` URL of the right Settings pane.
    public let paneURL: String?
    /// A command to paste into Terminal (shown, never run silently).
    public let command: String?
    /// A command the app may run itself after an explicit administrator
    /// password prompt ("Fix (asks for password)").
    public let adminFix: String?
}

/// Raw inputs, gathered without administrator rights.
public struct SecurityProbe: Sendable {
    public var fdesetup: String?
    public var firewallGlobal: String?
    public var firewallStealth: String?
    public var firewallBlockAll: String?
    public var spctl: String?
    public var csrutil: String?
    public var softwareUpdate: [String: SendablePlistValue]?
    public var commerce: [String: SendablePlistValue]?
    public var xprotectVersion: String?
    /// Fallback when `xprotect version` isn't available.
    public var xprotectBundleDate: Date?
    public var screenLock: String?
    public var loginWindow: [String: SendablePlistValue]?
    public var kcpasswordExists = false
    /// Labels loaded in the system launchd domain.
    public var systemServices: Set<String> = []
    public var listeningPorts: Set<Int> = []
    public var ardAgentRunning = false
    public var airDropMode: String?
    public var findMy: [String: SendablePlistValue]?
    public var bluetoothServicesEnabled: Bool?
    public var timeMachineDestinations: String?
    public var timeMachine: [String: SendablePlistValue]?
    /// nil = Safari's settings could not be read (Full Disk Access).
    public var safari: [String: SendablePlistValue]?
    public var lockdownEnabled: Bool?
    public var now = Date()

    public init() {}
}

/// Plist values reduced to Sendable cases.
public enum SendablePlistValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case date(Date)
    case array([SendablePlistValue])
    case dictionary([String: SendablePlistValue])

    public init?(_ value: Any) {
        switch value {
        case let n as NSNumber where !(value is String):
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .int(n.intValue)
        case let v as String: self = .string(v)
        case let v as Date: self = .date(v)
        case let v as [Any]: self = .array(v.compactMap(SendablePlistValue.init))
        case let v as [String: Any]: self = .dictionary(v.compactMapValues(SendablePlistValue.init))
        default: return nil
        }
    }

    public static func dictionary(from plist: [String: Any]?) -> [String: SendablePlistValue]? {
        plist?.compactMapValues(SendablePlistValue.init)
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .string(let s): ["1", "true", "yes"].contains(s.lowercased()) ? true : ["0", "false", "no"].contains(s.lowercased()) ? false : nil
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let i): i
        case .bool(let b): b ? 1 : 0
        case .string(let s): Int(s)
        default: nil
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

public enum SecurityChecklist {
    // MARK: Parsers

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off."
    /// ("Encryption in progress" counts as on).
    public static func parseFileVault(_ text: String?) -> Bool? {
        guard let text, !text.isEmpty else { return nil }
        if text.contains("FileVault is On") || text.contains("Encryption in progress") { return true }
        if text.contains("FileVault is Off") || text.contains("Decryption in progress") { return false }
        return nil
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)".
    public static func parseFirewall(_ text: String?) -> Bool? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("state = 1") || lower.contains("state = 2") || lower.contains("is enabled") || lower.contains("blocking all") { return true }
        if lower.contains("state = 0") || lower.contains("is disabled") { return false }
        return nil
    }

    /// `--getstealthmode`: "Firewall stealth mode is on" (older: "Stealth mode enabled").
    public static func parseStealth(_ text: String?) -> Bool? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("mode is on") || lower.contains("mode enabled") { return true }
        if lower.contains("mode is off") || lower.contains("mode disabled") { return false }
        return nil
    }

    /// `--getblockall`: "Firewall has block all state set to enabled."
    public static func parseBlockAll(_ text: String?) -> Bool? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("set to enabled") || lower.contains("block all enabled") || lower.contains("dropping all") { return true }
        if lower.contains("set to disabled") || lower.contains("block all disabled") { return false }
        return nil
    }

    /// `spctl --status`: "assessments enabled".
    public static func parseGatekeeper(_ text: String?) -> Bool? {
        guard let text, !text.isEmpty else { return nil }
        if text.contains("assessments enabled") { return true }
        if text.contains("assessments disabled") { return false }
        return nil
    }

    /// `csrutil status`: "System Integrity Protection status: enabled."
    /// A custom configuration ("enabled (Custom Configuration)" or
    /// "unknown") counts as off: parts of it are disabled.
    public static func parseSIP(_ text: String?) -> Bool? {
        guard let text, let range = text.range(of: "status:") else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        if rest.hasPrefix("enabled") { return !text.contains("Custom Configuration") }
        if rest.hasPrefix("disabled") || rest.hasPrefix("unknown") { return false }
        return nil
    }

    /// `sysadminctl -screenLock status` (printed on stderr):
    /// "screenLock delay is 300 seconds", "screenLock delay is immediate",
    /// "screenLock is off". Returns the delay in seconds, -1 when off.
    public static func parseScreenLock(_ text: String?) -> Int? {
        guard let text, let range = text.range(of: "screenLock") else { return nil }
        let rest = text[range.upperBound...].lowercased()
        if rest.contains("is off") || rest.contains("disabled") { return -1 }
        if rest.contains("immediate") { return 0 }
        if let delay = rest.range(of: "delay is ") {
            return Int(rest[delay.upperBound...].prefix(while: \.isNumber))
        }
        return nil
    }

    /// `xprotect version`: "Version: 5372 Installed: 2026-11-11 07:58:51 +0000".
    public static func parseXProtect(_ text: String?) -> (version: String, installed: Date?)? {
        guard let text, let v = text.range(of: "Version:") else { return nil }
        let afterVersion = text[v.upperBound...].trimmingCharacters(in: .whitespaces)
        let version = String(afterVersion.prefix(while: { !$0.isWhitespace }))
        guard !version.isEmpty else { return nil }
        var installed: Date?
        if let i = text.range(of: "Installed:") {
            let dateText = text[i.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            installed = formatter.date(from: String(dateText.prefix(25)))
        }
        return (version, installed)
    }

    /// `netstat -anv -p tcp` LISTEN rows → local ports on all interfaces.
    public static func parseListeningPorts(_ text: String) -> Set<Int> {
        var ports = Set<Int>()
        for raw in text.split(whereSeparator: \.isNewline) where raw.contains("LISTEN") {
            let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4 else { continue }
            let local = fields[3]
            // Only wildcard listeners are reachable from the network.
            guard local.hasPrefix("*."), let dot = local.lastIndex(of: "."), let port = Int(local[local.index(after: dot)...]) else { continue }
            ports.insert(port)
        }
        return ports
    }

    // MARK: Evaluate

    public static func evaluate(_ p: SecurityProbe) -> [SecurityCheckResult] {
        let on = UIText.t("Attivo", "On")
        let off = UIText.t("Disattivo", "Off")
        let unreadable = UIText.t("Non è stato possibile leggerlo", "Could not be read")
        var results: [SecurityCheckResult] = []
        func add(_ kind: SecurityCheckKind, _ state: SecurityCheckState, _ status: String, _ note: String? = nil) {
            results.append(SecurityCheckResult(kind: kind, state: state, status: status, note: note))
        }
        func onOff(_ kind: SecurityCheckKind, _ value: Bool?, goodWhenOn: Bool, badState: SecurityCheckState = .fail) {
            guard let value else { return add(kind, .unknown, unreadable) }
            add(kind, value == goodWhenOn ? .pass : badState, value ? on : off)
        }

        onOff(.fileVault, parseFileVault(p.fdesetup), goodWhenOn: true)
        let firewall = parseFirewall(p.firewallGlobal)
        onOff(.firewall, firewall, goodWhenOn: true)
        if firewall == false {
            add(.firewallStealth, .info, off, UIText.t("Attiva prima il firewall.", "Turn on the firewall first."))
        } else {
            onOff(.firewallStealth, parseStealth(p.firewallStealth), goodWhenOn: true, badState: .warning)
        }
        onOff(.gatekeeper, parseGatekeeper(p.spctl), goodWhenOn: true)
        onOff(.sip, parseSIP(p.csrutil), goodWhenOn: true)

        // Updates. Missing keys mean macOS's defaults: check, download and
        // install security data are on; installing macOS updates is off.
        if let su = p.softwareUpdate {
            let check = su["AutomaticCheckEnabled"]?.bool ?? true
            let download = su["AutomaticDownload"]?.bool ?? true
            let install = su["AutomaticallyInstallMacOSUpdates"]?.bool ?? false
            let pending = su["LastRecommendedUpdatesAvailable"]?.int ?? 0
            let pendingNote = pending > 0 ? UIText.t("Aggiornamenti in attesa: \(pending)", "Updates waiting: \(pending)") : nil
            if !check {
                add(.automaticUpdates, .fail, UIText.t("Controllo automatico disattivato", "Automatic check is off"), pendingNote)
            } else if !download || !install {
                add(.automaticUpdates, .warning,
                    install ? UIText.t("Non scarica in automatico", "Doesn't download automatically")
                            : UIText.t("Controlla ma non installa da solo", "Checks but doesn't install by itself"), pendingNote)
            } else {
                add(.automaticUpdates, pending > 0 ? .warning : .pass, UIText.t("Scarica e installa da solo", "Downloads and installs by itself"), pendingNote)
            }
            let critical = su["CriticalUpdateInstall"]?.bool ?? true
            let config = su["ConfigDataInstall"]?.bool ?? true
            if critical && config {
                add(.securityResponses, .pass, on)
            } else {
                add(.securityResponses, .fail, off,
                    config ? nil : UIText.t("Senza file di sistema, XProtect non riceve le nuove definizioni.",
                                            "Without system files, XProtect doesn't get new definitions."))
            }
        } else {
            add(.automaticUpdates, .unknown, unreadable)
            add(.securityResponses, .unknown, unreadable)
        }

        let xprotect = parseXProtect(p.xprotectVersion)
        if let installed = xprotect?.installed ?? p.xprotectBundleDate {
            let days = max(0, Int(p.now.timeIntervalSince(installed) / 86_400))
            let formatted = installed.formatted(.dateTime.day().month(.abbreviated).year().locale(UIText.locale))
            let status = xprotect.map { UIText.t("Versione \($0.version), aggiornata il \(formatted)", "Version \($0.version), updated \(formatted)") }
                ?? UIText.t("Aggiornata il \(formatted)", "Updated \(formatted)")
            add(.xprotect, days <= 30 ? .pass : days <= 90 ? .warning : .fail, status,
                days > 30 ? UIText.t("Giorni dall'ultimo aggiornamento: \(days)", "Days since the last update: \(days)") : nil)
        } else {
            add(.xprotect, .unknown, unreadable)
        }

        if let commerce = p.commerce, let auto = commerce["AutoUpdate"]?.bool {
            add(.appUpdates, auto ? .pass : .warning, auto ? on : off)
        } else {
            add(.appUpdates, .unknown, UIText.t("Impostazione mai cambiata", "Setting never changed"))
        }

        // Access
        if let delay = parseScreenLock(p.screenLock) {
            switch delay {
            case -1: add(.screenLock, .fail, UIText.t("Non chiede la password", "Doesn't ask for the password"))
            case 0: add(.screenLock, .pass, UIText.t("Subito", "Immediately"))
            case ...300: add(.screenLock, .pass, UIText.t("Dopo \(Self.minutes(delay))", "After \(Self.minutes(delay))"))
            default: add(.screenLock, .warning, UIText.t("Dopo \(Self.minutes(delay))", "After \(Self.minutes(delay))"),
                         UIText.t("Meglio 5 minuti o meno.", "5 minutes or less is better."))
            }
        } else {
            add(.screenLock, .unknown, unreadable)
        }
        let autoLoginUser = p.loginWindow?["autoLoginUser"]?.string
        if autoLoginUser != nil || p.kcpasswordExists {
            add(.autoLogin, .fail, autoLoginUser.map { UIText.t("Attivo per «\($0)»", "On for “\($0)”") } ?? on)
        } else if p.loginWindow == nil {
            add(.autoLogin, .unknown, unreadable)
        } else {
            add(.autoLogin, .pass, off)
        }
        if let loginWindow = p.loginWindow {
            let guest = loginWindow["GuestEnabled"]?.bool ?? false
            add(.guestAccount, guest ? .fail : .pass, guest ? on : off)
            let hints = loginWindow["RetriesUntilHint"]?.int ?? 0
            add(.passwordHints, hints > 0 ? .warning : .pass,
                hints > 0 ? UIText.t("Mostrati dopo \(hints) tentativi", "Shown after \(hints) attempts") : off)
        } else {
            add(.guestAccount, .unknown, unreadable)
            add(.passwordHints, .unknown, unreadable)
        }

        // Sharing
        func service(_ kind: SecurityCheckKind, labels: [String], ports: [Int], extra: Bool = false) {
            let active = extra || labels.contains(where: p.systemServices.contains) || ports.contains(where: p.listeningPorts.contains)
            add(kind, active ? .fail : .pass, active ? on : off)
        }
        service(.remoteLogin, labels: ["com.openssh.sshd"], ports: [22])
        service(.screenSharing, labels: ["com.apple.screensharing"], ports: [5900])
        // PrivilegeProxy is loaded on demand even when Remote Management is
        // off; only a running ARDAgent or its port mean it is on.
        service(.remoteManagement, labels: [], ports: [3283], extra: p.ardAgentRunning)
        service(.fileSharing, labels: ["com.apple.smbd", "com.apple.AppleFileServer"], ports: [445, 548])
        switch p.airDropMode?.lowercased() {
        case "everyone": add(.airDrop, .warning, UIText.t("Tutti", "Everyone"),
                             UIText.t("Chiunque nelle vicinanze può mandarti file.", "Anyone nearby can send you files."))
        case "off": add(.airDrop, .pass, UIText.t("Disattivo", "Off"))
        case "contacts only", "contactsonly": add(.airDrop, .pass, UIText.t("Solo contatti", "Contacts only"))
        case nil: add(.airDrop, .pass, UIText.t("Solo contatti (predefinito)", "Contacts only (default)"))
        default: add(.airDrop, .info, p.airDropMode ?? "")
        }
        let bluetooth = p.bluetoothServicesEnabled ?? false
        add(.bluetoothSharing, bluetooth ? .warning : .pass, bluetooth ? on : off)

        // Recovery
        if let enabled = p.findMy?["FMMEnabled"]?.bool {
            add(.findMy, enabled ? .pass : .fail, enabled ? on : off)
        } else {
            add(.findMy, .unknown, unreadable)
        }
        results.append(timeMachineResult(p))

        // Safari: on by default, so a missing key means on.
        if let safari = p.safari {
            let open = safari["AutoOpenSafeDownloads"]?.bool ?? true
            add(.safariSafeFiles, open ? .warning : .pass, open ? on : off)
        } else {
            add(.safariSafeFiles, .unknown, UIText.t("Serve l'accesso completo al disco per leggerlo", "Full Disk Access is needed to read it"))
        }

        // Information
        if let blockAll = parseBlockAll(p.firewallBlockAll) {
            add(.firewallBlockAll, .info, blockAll ? on : off)
        } else {
            add(.firewallBlockAll, .info, unreadable)
        }
        add(.lockdownMode, .info, p.lockdownEnabled == true ? on : off)

        let order = SecurityCheckKind.allCases
        return results.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    static func timeMachineResult(_ p: SecurityProbe) -> SecurityCheckResult {
        let destinations = p.timeMachineDestinations ?? ""
        let configured = destinations.contains("ID") || destinations.contains("Name")
            || !((p.timeMachine?["Destinations"]).flatMap { if case .array(let a) = $0 { a } else { nil } } ?? []).isEmpty
        guard configured else {
            if destinations.contains("No destinations") || p.timeMachine != nil {
                return SecurityCheckResult(kind: .timeMachine, state: .fail, status: UIText.t("Nessun backup configurato", "No backup set up"))
            }
            return SecurityCheckResult(kind: .timeMachine, state: .unknown, status: UIText.t("Non è stato possibile leggerlo", "Could not be read"))
        }
        var latest: Date?
        var encrypted: Bool?
        if case .array(let list)? = p.timeMachine?["Destinations"] {
            for case .dictionary(let destination) in list {
                if case .array(let dates)? = destination["SnapshotDates"] {
                    for case .date(let d) in dates where latest == nil || d > latest! { latest = d }
                }
                if let state = destination["LastKnownEncryptionState"]?.string {
                    encrypted = (encrypted ?? true) && state == "Encrypted"
                }
            }
        }
        guard let latest else {
            return SecurityCheckResult(kind: .timeMachine, state: .info, status: UIText.t("Configurato", "Set up"),
                                       note: UIText.t("La data dell'ultimo backup richiede l'accesso completo al disco.",
                                                      "The last backup date needs Full Disk Access."))
        }
        let days = Int(p.now.timeIntervalSince(latest) / 86_400)
        let formatted = latest.formatted(.dateTime.day().month(.abbreviated).year().locale(UIText.locale))
        let note = encrypted == false ? UIText.t("Il disco di backup non è cifrato.", "The backup disk is not encrypted.") : nil
        let state: SecurityCheckState = days > 14 ? .fail : (days > 7 || encrypted == false) ? .warning : .pass
        return SecurityCheckResult(kind: .timeMachine, state: state,
                                   status: UIText.t("Ultimo backup: \(formatted)", "Last backup: \(formatted)"), note: note)
    }

    static func minutes(_ seconds: Int) -> String {
        seconds < 60 ? UIText.t("\(seconds) secondi", "\(seconds) seconds")
            : seconds == 60 ? UIText.t("1 minuto", "1 minute")
            : UIText.t("\(seconds / 60) minuti", "\(seconds / 60) minutes")
    }

    // MARK: Score

    /// 0…100: passed weight (warnings count half) over the weight of every
    /// check that could be read. Information-only checks don't count.
    public static func score(_ results: [SecurityCheckResult]) -> Int {
        var total = 0.0
        var earned = 0.0
        for result in results where result.kind.weight > 0 {
            let weight = Double(result.kind.weight)
            switch result.state {
            case .pass: total += weight; earned += weight
            case .warning: total += weight; earned += weight / 2
            case .fail: total += weight
            case .info, .unknown: break
            }
        }
        guard total > 0 else { return 0 }
        return Int((earned / total * 100).rounded())
    }

    // MARK: Guides

    private static let privacyPane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    private static let sharingPane = "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    private static let usersPane = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
    private static let lockPane = "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
    private static let updatePane = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    private static let firewallPane = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
    private static let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    public static func guide(for kind: SecurityCheckKind) -> SecurityCheckGuide {
        switch kind {
        case .fileVault:
            SecurityCheckGuide(
                why: UIText.t("FileVault cifra il disco: se il Mac viene perso o rubato, nessuno può leggere i tuoi file senza la password.",
                              "FileVault encrypts the disk: if your Mac is lost or stolen, nobody can read your files without the password."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Privacy e sicurezza › FileVault.", "Open System Settings › Privacy & Security › FileVault."),
                        UIText.t("Fai clic su «Attiva…» e scegli come recuperare la password (account iCloud o chiave di recupero).", "Click “Turn On…” and choose how to recover the password (iCloud account or recovery key)."),
                        UIText.t("La cifratura avviene in background: puoi continuare a usare il Mac.", "Encryption runs in the background: you can keep using your Mac.")],
                paneURL: "\(privacyPane)?FileVault", command: nil, adminFix: nil)
        case .firewall:
            SecurityCheckGuide(
                why: UIText.t("Il firewall blocca le connessioni in entrata non richieste, utile soprattutto sulle Wi-Fi pubbliche.",
                              "The firewall blocks unwanted incoming connections, especially useful on public Wi-Fi."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Rete › Firewall.", "Open System Settings › Network › Firewall."),
                        UIText.t("Attiva l'interruttore «Firewall».", "Turn on the “Firewall” switch.")],
                paneURL: firewallPane, command: "sudo \(firewallTool) --setglobalstate on",
                adminFix: "\(firewallTool) --setglobalstate on")
        case .firewallStealth:
            SecurityCheckGuide(
                why: UIText.t("In modalità invisibile il Mac non risponde ai «ping» e alle scansioni: chi cerca computer vulnerabili sulla stessa rete non lo vede.",
                              "In stealth mode the Mac doesn't answer pings and scans: people looking for vulnerable computers on the same network don't see it."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Rete › Firewall › Opzioni….", "Open System Settings › Network › Firewall › Options…."),
                        UIText.t("Attiva «Abilita modalità invisibile».", "Turn on “Enable stealth mode”.")],
                paneURL: firewallPane, command: "sudo \(firewallTool) --setstealthmode on",
                adminFix: "\(firewallTool) --setstealthmode on")
        case .gatekeeper:
            SecurityCheckGuide(
                why: UIText.t("Senza Gatekeeper il Mac apre anche app non verificate, il modo più comune in cui arrivano i malware.",
                              "Without Gatekeeper your Mac opens unverified apps too, the most common way malware gets in."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Privacy e sicurezza.", "Open System Settings › Privacy & Security."),
                        UIText.t("In «Sicurezza» scegli «App Store e sviluppatori identificati».", "Under “Security”, choose “App Store & Known Developers”.")],
                paneURL: "\(privacyPane)?Security", command: "sudo spctl --global-enable", adminFix: "/usr/sbin/spctl --global-enable")
        case .sip:
            SecurityCheckGuide(
                why: UIText.t("La Protezione dell'integrità di sistema impedisce ai malware di modificare macOS. Se l'hai disattivata tu per sviluppo, riattivala quando hai finito.",
                              "System Integrity Protection stops malware from modifying macOS. If you turned it off for development, turn it back on when you're done."),
                steps: [UIText.t("Spegni il Mac. Tieni premuto il tasto di accensione finché compare «Opzioni», poi fai clic su Continua.", "Shut down your Mac. Press and hold the power button until “Options” appears, then click Continue."),
                        UIText.t("Dal menu Utility apri Terminale.", "From the Utilities menu, open Terminal."),
                        UIText.t("Digita il comando qui sotto, premi Invio e riavvia.", "Type the command below, press Return and restart.")],
                paneURL: nil, command: "csrutil enable", adminFix: nil)
        case .automaticUpdates:
            SecurityCheckGuide(
                why: UIText.t("Gli aggiornamenti chiudono le falle che i malware sfruttano. Installarli da soli evita di restare indietro per settimane.",
                              "Updates close the holes malware exploits. Installing them automatically avoids falling weeks behind."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Aggiornamento software.", "Open System Settings › General › Software Update."),
                        UIText.t("Fai clic su (i) accanto a «Aggiornamenti automatici».", "Click (i) next to “Automatic updates”."),
                        UIText.t("Attiva «Scarica nuovi aggiornamenti quando disponibili» e «Installa aggiornamenti macOS».", "Turn on “Download new updates when available” and “Install macOS updates”.")],
                paneURL: updatePane, command: nil, adminFix: nil)
        case .securityResponses:
            SecurityCheckGuide(
                why: UIText.t("Apple manda correzioni urgenti (Risposte di sicurezza rapide) e nuove definizioni XProtect separatamente da macOS: se sono spente, il Mac non le riceve.",
                              "Apple ships urgent fixes (Rapid Security Responses) and new XProtect definitions separately from macOS: if they're off, the Mac doesn't get them."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Aggiornamento software.", "Open System Settings › General › Software Update."),
                        UIText.t("Fai clic su (i) accanto a «Aggiornamenti automatici».", "Click (i) next to “Automatic updates”."),
                        UIText.t("Attiva «Installa risposte di sicurezza e file di sistema».", "Turn on “Install Security Responses and system files”.")],
                paneURL: updatePane, command: nil, adminFix: nil)
        case .xprotect:
            SecurityCheckGuide(
                why: UIText.t("XProtect è l'antimalware integrato di macOS. Riconosce solo i malware che conosce: definizioni vecchie lasciano passare quelli nuovi.",
                              "XProtect is macOS's built-in antimalware. It only recognises malware it knows: old definitions let new ones through."),
                steps: [UIText.t("Controlla che «Installa risposte di sicurezza e file di sistema» sia attivo (vedi sopra).", "Make sure “Install Security Responses and system files” is on (see above)."),
                        UIText.t("Collega il Mac a internet e lascialo acceso: macOS scarica le definizioni da solo.", "Keep the Mac online and awake: macOS downloads the definitions by itself."),
                        UIText.t("Per forzare il controllo, incolla il comando qui sotto nel Terminale.", "To force a check, paste the command below into Terminal.")],
                paneURL: updatePane, command: "sudo xprotect update", adminFix: nil)
        case .appUpdates:
            SecurityCheckGuide(
                why: UIText.t("Le app vecchie hanno falle note. Il Mac App Store può aggiornarle da solo.",
                              "Old apps have known holes. The Mac App Store can update them by itself."),
                steps: [UIText.t("Apri l'App Store e scegli App Store › Impostazioni.", "Open the App Store and choose App Store › Settings."),
                        UIText.t("Attiva «Aggiornamenti automatici».", "Turn on “Automatic Updates”."),
                        UIText.t("Per le app scaricate dal web, usa la sezione Aggiornamenti di Mac Mop.", "For apps downloaded from the web, use Mac Mop's Updater.")],
                paneURL: nil, command: nil, adminFix: nil)
        case .screenLock:
            SecurityCheckGuide(
                why: UIText.t("Se il Mac non chiede la password quando si risveglia, chiunque passi può usarlo mentre sei via.",
                              "If the Mac doesn't ask for the password when it wakes, anyone passing by can use it while you're away."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Schermata di blocco.", "Open System Settings › Lock Screen."),
                        UIText.t("In «Richiedi password dopo l'avvio del salvaschermo o lo spegnimento del monitor» scegli «Immediatamente» o al massimo 5 minuti.", "Set “Require password after screen saver begins or display is turned off” to “Immediately” or 5 minutes at most.")],
                paneURL: lockPane, command: nil, adminFix: nil)
        case .autoLogin:
            SecurityCheckGuide(
                why: UIText.t("Con il login automatico chi accende il Mac entra nel tuo account senza password, e la password è salvata in modo recuperabile.",
                              "With automatic login, whoever turns on the Mac gets into your account without a password, and the password is stored in a recoverable way."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Utenti e gruppi.", "Open System Settings › Users & Groups."),
                        UIText.t("In «Login automatico come» scegli «Disattivo».", "Set “Automatically log in as” to “Off”.")],
                paneURL: usersPane, command: nil, adminFix: nil)
        case .guestAccount:
            SecurityCheckGuide(
                why: UIText.t("L'account ospite permette a chiunque di usare il Mac senza password. Raramente serve.",
                              "The guest account lets anyone use the Mac without a password. It's rarely needed."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Utenti e gruppi.", "Open System Settings › Users & Groups."),
                        UIText.t("Fai clic su (i) accanto a «Utente ospite» e disattiva «Consenti agli ospiti di accedere».", "Click (i) next to “Guest User” and turn off “Allow guests to log in to this computer”.")],
                paneURL: usersPane, command: nil,
                adminFix: "/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow GuestEnabled -bool false")
        case .remoteLogin:
            SecurityCheckGuide(
                why: UIText.t("Il login remoto apre il Terminale del Mac alla rete. Se non lo usi tu, è una porta lasciata aperta.",
                              "Remote Login opens the Mac's Terminal to the network. If you don't use it, it's a door left open."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Condivisione.", "Open System Settings › General › Sharing."),
                        UIText.t("Disattiva «Login remoto».", "Turn off “Remote Login”.")],
                paneURL: sharingPane, command: nil, adminFix: nil)
        case .screenSharing:
            SecurityCheckGuide(
                why: UIText.t("La condivisione schermo permette di vedere e controllare il Mac dalla rete. Tienila spenta quando non serve.",
                              "Screen Sharing lets others see and control the Mac over the network. Keep it off when not needed."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Condivisione.", "Open System Settings › General › Sharing."),
                        UIText.t("Disattiva «Condivisione schermo».", "Turn off “Screen Sharing”.")],
                paneURL: sharingPane, command: nil, adminFix: nil)
        case .remoteManagement:
            SecurityCheckGuide(
                why: UIText.t("La gestione remota (Apple Remote Desktop) dà il controllo completo del Mac a distanza. È normale solo su Mac aziendali.",
                              "Remote Management (Apple Remote Desktop) gives full remote control of the Mac. It's only normal on company Macs."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Condivisione.", "Open System Settings › General › Sharing."),
                        UIText.t("Disattiva «Gestione remota».", "Turn off “Remote Management”.")],
                paneURL: sharingPane, command: nil, adminFix: nil)
        case .fileSharing:
            SecurityCheckGuide(
                why: UIText.t("La condivisione file rende cartelle del Mac accessibili dalla rete. Spegnila quando non la usi.",
                              "File Sharing makes Mac folders reachable over the network. Turn it off when you don't use it."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Condivisione.", "Open System Settings › General › Sharing."),
                        UIText.t("Disattiva «Condivisione file».", "Turn off “File Sharing”.")],
                paneURL: sharingPane, command: nil, adminFix: nil)
        case .airDrop:
            SecurityCheckGuide(
                why: UIText.t("Con AirDrop aperto a tutti, sconosciuti nelle vicinanze possono mandarti file e immagini indesiderate.",
                              "With AirDrop open to everyone, strangers nearby can send you unwanted files and images."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › AirDrop e Handoff.", "Open System Settings › General › AirDrop & Handoff."),
                        UIText.t("In «AirDrop» scegli «Solo contatti» o «Nessuno».", "Set “AirDrop” to “Contacts Only” or “No One”.")],
                paneURL: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension", command: nil, adminFix: nil)
        case .bluetoothSharing:
            SecurityCheckGuide(
                why: UIText.t("La condivisione Bluetooth permette ad altri dispositivi di mandare o sfogliare file sul Mac.",
                              "Bluetooth Sharing lets other devices send or browse files on the Mac."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Generali › Condivisione.", "Open System Settings › General › Sharing."),
                        UIText.t("Disattiva «Condivisione Bluetooth».", "Turn off “Bluetooth Sharing”.")],
                paneURL: sharingPane, command: nil, adminFix: nil)
        case .findMy:
            SecurityCheckGuide(
                why: UIText.t("Dov'è il mio Mac ti permette di localizzare, bloccare o inizializzare il Mac se lo perdi, e impedisce a un ladro di riattivarlo.",
                              "Find My Mac lets you locate, lock or erase the Mac if you lose it, and stops a thief from reactivating it."),
                steps: [UIText.t("Apri Impostazioni di Sistema e fai clic sul tuo nome › iCloud.", "Open System Settings and click your name › iCloud."),
                        UIText.t("Apri «Dov'è il mio Mac» e attivalo.", "Open “Find My Mac” and turn it on.")],
                paneURL: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings", command: nil, adminFix: nil)
        case .passwordHints:
            SecurityCheckGuide(
                why: UIText.t("Il suggerimento della password è visibile a chiunque sbagli la password alla schermata di login, e spesso la rivela.",
                              "The password hint is shown to anyone who gets the password wrong at the login window, and often gives it away."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Schermata di blocco.", "Open System Settings › Lock Screen."),
                        UIText.t("Disattiva «Mostra suggerimenti password».", "Turn off “Show password hints”.")],
                paneURL: lockPane, command: nil,
                adminFix: "/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow RetriesUntilHint -int 0")
        case .timeMachine:
            SecurityCheckGuide(
                why: UIText.t("Un backup recente è l'unica difesa contro ransomware, guasti del disco e cancellazioni sbagliate. Cifrarlo protegge i dati se il disco viene rubato.",
                              "A recent backup is the only defence against ransomware, disk failure and mistaken deletions. Encrypting it protects the data if the disk is stolen."),
                steps: [UIText.t("Collega un disco esterno o scegli un disco di rete.", "Connect an external disk or choose a network disk."),
                        UIText.t("Apri Impostazioni di Sistema › Generali › Time Machine e fai clic su «Aggiungi disco di backup».", "Open System Settings › General › Time Machine and click “Add Backup Disk”."),
                        UIText.t("Attiva «Codifica backup» quando te lo chiede.", "Turn on “Encrypt Backup” when asked.")],
                paneURL: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension", command: nil, adminFix: nil)
        case .safariSafeFiles:
            SecurityCheckGuide(
                why: UIText.t("Safari apre da solo PDF, immagini e archivi scaricati. Un file «sicuro» preparato ad arte può sfruttare una falla senza che tu lo apra.",
                              "Safari opens downloaded PDFs, images and archives by itself. A crafted “safe” file can exploit a flaw without you opening it."),
                steps: [UIText.t("Apri Safari e scegli Safari › Impostazioni › Generali.", "Open Safari and choose Safari › Settings › General."),
                        UIText.t("Disattiva «Apri i file \"sicuri\" dopo averli scaricati».", "Turn off “Open \"safe\" files after downloading”.")],
                paneURL: nil, command: nil, adminFix: nil)
        case .firewallBlockAll:
            SecurityCheckGuide(
                why: UIText.t("Blocca tutto il traffico in entrata tranne quello essenziale. Molto sicuro, ma impedisce condivisioni e alcuni servizi: utile su reti pubbliche.",
                              "Blocks all incoming traffic except the essentials. Very safe, but stops sharing and some services: useful on public networks."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Rete › Firewall › Opzioni….", "Open System Settings › Network › Firewall › Options…."),
                        UIText.t("Attiva «Blocca tutte le connessioni in entrata» se lo desideri.", "Turn on “Block all incoming connections” if you want.")],
                paneURL: firewallPane, command: nil, adminFix: nil)
        case .lockdownMode:
            SecurityCheckGuide(
                why: UIText.t("Una protezione estrema per chi potrebbe essere bersaglio di attacchi mirati (giornalisti, attivisti). Limita molte funzioni: la maggior parte delle persone non ne ha bisogno.",
                              "Extreme protection for people who may be targeted by sophisticated attacks (journalists, activists). It limits many features: most people don't need it."),
                steps: [UIText.t("Apri Impostazioni di Sistema › Privacy e sicurezza.", "Open System Settings › Privacy & Security."),
                        UIText.t("Scorri fino a «Modalità di isolamento».", "Scroll to “Lockdown Mode”.")],
                paneURL: "\(privacyPane)?LockdownMode", command: nil, adminFix: nil)
        }
    }
}
