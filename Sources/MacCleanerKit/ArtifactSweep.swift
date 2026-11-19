import Foundation

/// A file the artifact sweep looked at, with everything already read from
/// disk by the caller (header bytes, mode, xattrs). Pure input.
public struct ArtifactCandidate: Sendable {
    public let url: URL
    public let location: ThreatLocation
    public let size: UInt64
    public let creationDate: Date?
    /// Any execute bit set.
    public let isExecutable: Bool
    public let isMachO: Bool
    /// Starts with `#!`.
    public let hasShebang: Bool
    /// Carries `com.apple.quarantine` (downloaded by a browser / app).
    public let hasQuarantine: Bool

    public init(url: URL, location: ThreatLocation, size: UInt64, creationDate: Date?, isExecutable: Bool,
                isMachO: Bool, hasShebang: Bool, hasQuarantine: Bool) {
        self.url = url
        self.location = location
        self.size = size
        self.creationDate = creationDate
        self.isExecutable = isExecutable
        self.isMachO = isMachO
        self.hasShebang = hasShebang
        self.hasQuarantine = hasQuarantine
    }
}

/// Finds what droppers and stealers leave behind: a fresh unsigned binary
/// in /tmp (`/tmp/update`), a hidden binary in the home folder
/// (`~/.helper`, `~/.agent`), a script that does stealer things, a staging
/// zip (`/tmp/out.zip`). Callers keep the walk shallow (direct children of
/// temp folders, two levels of /Users/Shared, hidden files directly in
/// home), which is where these families write and keeps build folders
/// (go-build, SwiftPM scratch dirs, node-gyp) out of scope.
public enum ArtifactSweep {
    /// Only recent files: an old file in /tmp survived reboots by being
    /// recreated, and the threat is current campaigns.
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public static let maxScriptBytes = 256 * 1024

    /// Names AMOS / Odyssey / MacSync / Poseidon give their archives.
    static let stagingNames: Set<String> = [
        "out", "data", "log", "logs", "osalogging", "archive", "info", "upload", "loot", "stealer", "result",
    ]

    public static func looksLikeStagingArchive(name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".zip") else { return false }
        let base = String(lower.dropLast(4))
        if stagingNames.contains(base) { return true }
        if base.count >= 6, base.allSatisfy(\.isNumber) { return true }
        return ThreatLocation.looksRandom(base)
    }

    public static func evaluate(
        _ candidate: ArtifactCandidate,
        now: Date,
        signature: (URL) -> CodeSignatureStatus,
        readScript: (URL) -> String?
    ) -> [ThreatFinding] {
        guard let created = candidate.creationDate, now.timeIntervalSince(created) <= maxAge,
              candidate.size > 0 else { return [] }
        let name = candidate.url.lastPathComponent
        let path = candidate.url.path(percentEncoded: false)

        if looksLikeStagingArchive(name: name), candidate.location == .temporary || candidate.location == .shared {
            return [ThreatFinding(rule: .stagingArchive, severity: .medium, snippet: ThreatCommandAnalyzer.snippet(path))]
        }

        let inScope: Bool
        switch candidate.location {
        case .temporary, .shared, .hiddenHome(knownTool: false): inScope = true
        default: inScope = false
        }
        guard inScope else { return [] }

        if candidate.isMachO, candidate.isExecutable || candidate.hasQuarantine {
            guard !signature(candidate.url).isTrusted else { return [] }
            // A downloaded (quarantined) unsigned binary in a temp folder,
            // or any unsigned binary hidden directly in home, has no
            // ordinary explanation. A plain unsigned executable in /tmp may
            // be something a developer compiled there: review only.
            let high = candidate.hasQuarantine || candidate.location == .hiddenHome(knownTool: false)
            return [ThreatFinding(rule: .unsignedExecutableDropped, severity: high ? .high : .medium,
                                  snippet: ThreatCommandAnalyzer.snippet(path))]
        }

        if candidate.hasShebang, candidate.isExecutable, candidate.size <= UInt64(maxScriptBytes),
           let script = readScript(candidate.url) {
            return ThreatCommandAnalyzer.analyze(script)
        }
        return []
    }
}

/// A non-removable, informational finding the UI explains rather than
/// offers for removal: a ClickFix command found in shell history (it
/// already ran), or a detection on protected data (wallet, browser profile,
/// Keychain) that is never put in the Trash.
public struct ThreatAdvisory: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        /// A past Terminal command matched a stealer / ClickFix rule.
        case shellHistory
        /// A detection pointed at protected user data; left in place.
        case protectedData
    }

    public let kind: Kind
    public let severity: ThreatSeverity
    public let rule: ThreatRule?
    /// The history file, or the protected item.
    public let path: URL
    /// When the command ran (history), if known.
    public let date: Date?
    /// Masked command, or the detection's family / snippet.
    public let detail: String
    /// For `.protectedData`: which detector matched.
    public let source: MalwareDetectionSource?

    public init(kind: Kind, severity: ThreatSeverity, rule: ThreatRule?, path: URL, date: Date?, detail: String,
                source: MalwareDetectionSource? = nil) {
        self.kind = kind
        self.severity = severity
        self.rule = rule
        self.path = path
        self.date = date
        self.detail = detail
        self.source = source
    }

    public init(historyHit hit: ShellHistoryHit) {
        let top = hit.findings.max { $0.severity < $1.severity }
        self.init(kind: .shellHistory, severity: hit.severity, rule: top?.rule, path: hit.file, date: hit.date,
                  detail: hit.command)
    }

    /// What to do when a stealer may already have run. Shown with history
    /// advisories.
    public static var compromiseGuidance: [String] {
        [
            UIText.t(
                "Se non riconosci questo comando, considera il Mac compromesso: un infostealer potrebbe aver già copiato password, cookie e wallet.",
                "If you don't recognise this command, treat the Mac as compromised: an infostealer may already have copied passwords, cookies and wallets."),
            UIText.t(
                "Da un altro dispositivo, cambia la password del Mac, dell'Apple Account, dell'email e di ogni sito salvato nel browser, e attiva l'autenticazione a due fattori.",
                "From another device, change your Mac, Apple Account and email passwords and those of every site saved in your browser, and turn on two-factor authentication."),
            UIText.t(
                "Sposta subito i fondi crypto in un wallet nuovo creato su un dispositivo pulito: la vecchia frase di recupero va considerata rubata.",
                "Move crypto funds right away to a new wallet created on a clean device: treat the old recovery phrase as stolen."),
            UIText.t(
                "Esci da tutte le sessioni attive (Google, Telegram, social, exchange) per invalidare i cookie rubati.",
                "Log out of every active session (Google, Telegram, social networks, exchanges) to invalidate stolen cookies."),
        ]
    }
}
