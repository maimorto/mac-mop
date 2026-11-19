import Foundation

/// What a code signature says about a file. Produced by an injected lookup
/// (the app uses SecStaticCode; tests use a table).
public enum CodeSignatureStatus: Sendable, Equatable {
    /// Signed by Apple itself (system software).
    case apple
    /// Valid Developer ID or Mac App Store signature, not revoked.
    case developerID(team: String?)
    /// Ad-hoc signed: any binary built locally or by malware has this.
    case adHoc
    /// No signature, or one that is invalid or revoked.
    case unsigned

    public var isTrusted: Bool {
        switch self {
        case .apple, .developerID: true
        case .adHoc, .unsigned: false
        }
    }
}

/// Where a file lives, as far as malware is concerned.
public enum ThreatLocation: Sendable, Equatable {
    /// /tmp, /private/tmp, /var/tmp, /var/folders (incl. $TMPDIR).
    case temporary
    /// /Users/Shared: world-writable, a favourite drop spot.
    case shared
    /// A hidden folder or file in the home folder (`~/.helper`,
    /// `~/.x/agent`). `knownTool` for the dot-folders developer tools own
    /// (`~/.local`, `~/.cargo`, `~/.docker`…), which are graded down.
    case hiddenHome(knownTool: Bool)
    /// `~/Library/Application Support/<vendor>/…`; `randomName` when the
    /// vendor folder's name looks generated (`x7k2m9qp`, a long hex string).
    case applicationSupport(randomName: Bool)
    /// Elsewhere in the home folder (~/bin, ~/Projects…): the user's own.
    case otherUser
    /// Outside the home folder and not a drop zone.
    case system

    public var isDropZone: Bool {
        switch self {
        case .temporary, .shared, .hiddenHome, .applicationSupport: true
        case .otherUser, .system: false
        }
    }

    /// Dot-folders created by developer tools; programs there are often
    /// ad-hoc signed builds, so they are never more than `.medium`.
    public static let developerDotFolders: Set<String> = [
        ".local", ".cargo", ".rustup", ".bun", ".deno", ".volta", ".nvm", ".fnm", ".pyenv", ".rbenv",
        ".asdf", ".npm", ".npm-global", ".pnpm", ".yarn", ".docker", ".orbstack", ".colima", ".lima",
        ".rd", ".ollama", ".codex", ".claude", ".config", ".gem", ".sdkman", ".jenv", ".goenv",
        ".nix-profile", ".dotnet", ".fly", ".vscode", ".cursor", ".gradle", ".m2", ".krew", ".kube",
        ".mint", ".swiftpm", ".fzf", ".oh-my-zsh", ".mise", ".proto", ".zinit", ".tmux", ".vim",
    ]

    public static func classify(_ path: String, home: String) -> ThreatLocation {
        let p = (path as NSString).standardizingPath
        let lower = p.lowercased()
        for prefix in ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/", "/private/var/folders/"]
        where lower.hasPrefix(prefix) {
            return .temporary
        }
        if lower.hasPrefix("/users/shared/") { return .shared }
        let h = (home as NSString).standardizingPath
        guard p.hasPrefix(h + "/") else { return .system }
        let components = p.dropFirst(h.count + 1).split(separator: "/").map(String.init)
        if let hidden = components.first(where: { $0.hasPrefix(".") }) {
            let known = components.first.map { developerDotFolders.contains($0.lowercased()) } ?? false
            return .hiddenHome(knownTool: known && hidden == components.first)
        }
        if components.count >= 3, components[0] == "Library", components[1] == "Application Support" {
            return .applicationSupport(randomName: looksRandom(components[2]))
        }
        return .otherUser
    }

    /// Generated-looking names: a long hex string or UUID, letters mixed
    /// with many digits, or a run of five consonants. Real vendor folders
    /// ("Google", "JetBrains", "com.docker.docker") don't look like this.
    public static func looksRandom(_ name: String) -> Bool {
        let base = ((name as NSString).deletingPathExtension).lowercased()
        guard (6...64).contains(base.count) else { return false }
        if base.count >= 12, base.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        guard base.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let digits = base.filter(\.isNumber).count
        let letters = base.count - digits
        if base.count >= 8, letters > 0, digits * 4 >= base.count { return true }
        var run = 0
        for c in base {
            if c.isLetter, !"aeiouy".contains(c) {
                run += 1
                if run >= 5 { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}

/// A launch agent / daemon plist, reduced to what the audit needs.
public struct LaunchItemRecord: Sendable {
    public enum Scope: Sendable, Equatable {
        case userAgent    // ~/Library/LaunchAgents
        case systemAgent  // /Library/LaunchAgents
        case systemDaemon // /Library/LaunchDaemons
    }

    public let plistURL: URL
    public let label: String?
    /// `Program` (if any) followed by `ProgramArguments`, as launchd runs it.
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let scope: Scope

    public init(plistURL: URL, label: String?, arguments: [String], runAtLoad: Bool, keepAlive: Bool, scope: Scope) {
        self.plistURL = plistURL
        self.label = label
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.scope = scope
    }

    public init(plistURL: URL, plist: [String: Any], scope: Scope) {
        var args = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String {
            // With both keys launchd execs Program and passes ProgramArguments
            // as argv (argv[0] included); what runs is Program.
            if args.isEmpty { args = [program] } else { args[0] = program }
        }
        let keepAlive: Bool
        if let flag = plist["KeepAlive"] as? Bool { keepAlive = flag } else { keepAlive = plist["KeepAlive"] is [String: Any] }
        self.init(
            plistURL: plistURL,
            label: plist["Label"] as? String,
            arguments: args,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            scope: scope
        )
    }
}

/// One persistence problem: the plist to remove, and optionally the program
/// it starts (offered too when it is a payload in a drop zone).
public struct PersistenceFinding: Sendable, Hashable {
    public let plistURL: URL
    /// The program or script the finding is about, if any.
    public let program: URL?
    /// Also offer `program` for removal (never a directory, never outside a
    /// drop zone).
    public let removesProgram: Bool
    public let finding: ThreatFinding
}

/// Audits launch agents and daemons. Pure: every disk / signature access
/// goes through `Environment`, and the signature lookup is only called for
/// programs that are already suspicious by location or label (SecStaticCode
/// with a revocation check is not free).
public enum PersistenceAudit {
    public struct Environment: Sendable {
        public var home: URL
        public var signature: @Sendable (URL) -> CodeSignatureStatus
        public var fileExists: @Sendable (URL) -> Bool
        public var fileKinds: @Sendable (URL) -> Set<MalwareFileKind>
        /// A script's text, bounded by the caller; nil for binaries.
        public var readScript: @Sendable (URL) -> String?

        public init(
            home: URL,
            signature: @escaping @Sendable (URL) -> CodeSignatureStatus,
            fileExists: @escaping @Sendable (URL) -> Bool,
            fileKinds: @escaping @Sendable (URL) -> Set<MalwareFileKind>,
            readScript: @escaping @Sendable (URL) -> String?
        ) {
            self.home = home
            self.signature = signature
            self.fileExists = fileExists
            self.fileKinds = fileKinds
            self.readScript = readScript
        }
    }

    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "osascript",
        "python", "python3", "perl", "ruby", "node", "env",
    ]

    /// The code a launch item really runs: the script handed to an
    /// interpreter (`/bin/bash ~/.x/run.sh` → `~/.x/run.sh`), else the
    /// program. `inlineCode` when the interpreter gets `-c` / `-e` code.
    static func effectiveProgram(_ args: [String]) -> (program: URL?, inlineCode: Bool) {
        var rest = args[...]
        while let first = rest.first {
            let name = (first as NSString).lastPathComponent.lowercased()
            let isInterpreter = interpreters.contains(name) || name.hasPrefix("python")
            guard isInterpreter else { break }
            rest = rest.dropFirst()
            if name == "env" {
                rest = rest.drop(while: { $0.hasPrefix("-") || $0.contains("=") })
                continue
            }
            for argument in rest {
                if ["-c", "-e", "-ce", "-ec"].contains(argument) { return (nil, true) }
                if argument.hasPrefix("-") { continue }
                return (absoluteURL(argument), false)
            }
            return (nil, false)
        }
        return (rest.first.flatMap(absoluteURL), false)
    }

    /// Absolute, `..`-free paths only (same rule as `MalwareRemovalTarget`).
    static func absoluteURL(_ path: String) -> URL? {
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return URL(filePath: path)
    }

    public static func audit(_ item: LaunchItemRecord, environment env: Environment) -> [PersistenceFinding] {
        guard !item.arguments.isEmpty else { return [] }
        var results: [PersistenceFinding] = []

        // 1. What the arguments do (`/bin/sh -c "curl … | sh"`).
        for finding in ThreatCommandAnalyzer.analyze(arguments: item.arguments) {
            results.append(PersistenceFinding(plistURL: item.plistURL, program: nil, removesProgram: false, finding: finding))
        }

        let (program, inlineCode) = effectiveProgram(item.arguments)
        let home = env.home.path(percentEncoded: false)
        let existing = program.flatMap { env.fileExists($0) ? $0 : nil }
        var signatureCache: CodeSignatureStatus?
        func signature(_ url: URL) -> CodeSignatureStatus {
            if let signatureCache { return signatureCache }
            let status = env.signature(url)
            signatureCache = status
            return status
        }

        // 2. An Apple label on code Apple didn't sign. Apple's own launch
        // items live in /System/Library; a com.apple.* item in a Library
        // folder running inline shell code or non-Apple code is an impostor.
        let label = (item.label ?? item.plistURL.deletingPathExtension().lastPathComponent).lowercased()
        if label.hasPrefix("com.apple.") {
            if inlineCode {
                results.append(PersistenceFinding(
                    plistURL: item.plistURL, program: nil, removesProgram: false,
                    finding: ThreatFinding(rule: .launchItemFakeApple, severity: .high, snippet: snippet(item.label ?? label))))
            } else if let existing, signature(existing) != .apple {
                let location = ThreatLocation.classify(existing.path(percentEncoded: false), home: home)
                results.append(PersistenceFinding(
                    plistURL: item.plistURL, program: existing, removesProgram: location.isDropZone,
                    finding: ThreatFinding(rule: .launchItemFakeApple, severity: .high,
                                           snippet: snippet("\(item.label ?? label) → \(existing.path(percentEncoded: false))"))))
            }
        }

        guard let existing else { return results }
        let path = existing.path(percentEncoded: false)
        let location = ThreatLocation.classify(path, home: home)
        guard location.isDropZone else { return results }

        // 3. A script in a drop zone: read what it does.
        let kinds = env.fileKinds(existing)
        let isMachO = kinds.contains(.machO)
        if !isMachO, let script = env.readScript(existing) {
            for finding in ThreatCommandAnalyzer.analyze(script) {
                results.append(PersistenceFinding(
                    plistURL: item.plistURL, program: existing, removesProgram: true, finding: finding))
            }
        }

        // 4. Unsigned code started from a drop zone. Signed Developer ID
        // helpers (Google, Microsoft, Docker…) are never flagged here.
        guard !signature(existing).isTrusted else { return results }
        let severity: ThreatSeverity?
        switch location {
        case .temporary:
            // Temp folders are wiped; nothing legitimate persists from them.
            severity = .high
        case .shared, .hiddenHome(knownTool: false):
            severity = isMachO ? .high : .medium
        case .hiddenHome(knownTool: true):
            severity = .medium
        case .applicationSupport(let randomName):
            if isMachO {
                severity = randomName ? .high : .medium
            } else {
                severity = (item.runAtLoad || item.keepAlive) ? .medium : nil
            }
        case .otherUser, .system:
            severity = nil
        }
        if let severity {
            results.append(PersistenceFinding(
                plistURL: item.plistURL, program: existing, removesProgram: severity == .high,
                finding: ThreatFinding(rule: .launchItemSuspiciousLocation, severity: severity,
                                       snippet: snippet(abbreviate(path, home: home)))))
        }
        return results
    }

    static func snippet(_ text: String) -> String { ThreatCommandAnalyzer.snippet(text) }

    static func abbreviate(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
