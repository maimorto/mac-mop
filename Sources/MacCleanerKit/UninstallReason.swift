import Foundation

/// Why a leftover file was linked to an app, and how sure we are.
///
/// Each associated file in the Uninstaller carries one of these so the user
/// sees *why* it was matched ("its name is the app's bundle identifier") and
/// so low-confidence matches start unchecked. Pure: everything the decision
/// needs is passed in.
public enum UninstallMatchReason: Hashable, Sendable {
    /// The app's preferences file: `<bundle id>.plist` in Preferences.
    case preferencesDomain
    /// The app's sandbox container: `Containers/<bundle id>`.
    case sandboxContainer
    /// A shared App Group the app's signature declares.
    case appGroup(String)
    /// A launch agent/daemon whose program lives inside the app bundle.
    case launchItemProgram(String)
    /// The exact bundle identifier is the file name (or its stem).
    case bundleIDExact
    /// A name that starts with the bundle identifier (`com.foo.app.helper`).
    case bundleIDPrefix
    /// The bundle identifier plus an extra part that is not a helper
    /// (`com.google.Chrome.canary`): often a different edition of the app.
    case relatedBundleID(String)
    /// The bundle identifier without a helper/agent suffix.
    case baseBundleID
    /// A group container or file prefixed with the developer's team ID, but not
    /// declared by this app (often shared by sibling apps from the same vendor).
    case teamIdentifier(String)
    /// The file or folder is named exactly like the app.
    case appNameExact
    /// The app's name appears as a word inside the file name.
    case appNameWord
    /// The last two components of the bundle id (`google.chrome`).
    case bundleIDComponents
    /// The app name with spaces/punctuation removed (`googlechrome`).
    case normalizedName
    /// The app name with its version number stripped.
    case versionStrippedName

    public var explanation: String {
        switch self {
        case .preferencesDomain:
            UIText.t("È il file delle preferenze dell'app (dominio uguale al suo identificativo).",
                     "It is the app's preferences file (domain equals its bundle identifier).")
        case .sandboxContainer:
            UIText.t("È il contenitore sandbox dell'app, creato da macOS per lei.",
                     "It is the app's sandbox container, created by macOS for it.")
        case .appGroup(let group):
            UIText.t("Gruppo di app dichiarato nella firma dell'app: \(group). Potrebbe essere condiviso con altre app dello stesso sviluppatore.",
                     "App group declared in the app's signature: \(group). It may be shared with other apps from the same developer.")
        case .launchItemProgram(let program):
            UIText.t("Avvia un programma che si trova dentro l'app: \(program)",
                     "It launches a program inside the app: \(program)")
        case .bundleIDExact:
            UIText.t("Il nome coincide con l'identificativo dell'app.",
                     "Its name is the app's bundle identifier.")
        case .bundleIDPrefix:
            UIText.t("Il nome inizia con l'identificativo dell'app.",
                     "Its name starts with the app's bundle identifier.")
        case .relatedBundleID(let suffix):
            UIText.t("Inizia con l'identificativo dell'app ma aggiunge \"\(suffix)\": potrebbe essere un'altra edizione (beta, canary…).",
                     "It starts with the app's bundle identifier but adds \"\(suffix)\": it may be a different edition (beta, canary…).")
        case .baseBundleID:
            UIText.t("Il nome contiene l'identificativo dell'app senza il suffisso helper.",
                     "Its name contains the app's bundle identifier without the helper suffix.")
        case .teamIdentifier(let team):
            UIText.t("Inizia con l'ID sviluppatore \(team), ma l'app non lo dichiara: può appartenere a un'altra app dello stesso sviluppatore.",
                     "It starts with developer ID \(team), but the app does not declare it: it may belong to another app from the same developer.")
        case .appNameExact:
            UIText.t("Ha esattamente lo stesso nome dell'app.",
                     "It has exactly the same name as the app.")
        case .appNameWord:
            UIText.t("Il nome dell'app compare nel nome del file.",
                     "The app's name appears in the file name.")
        case .bundleIDComponents:
            UIText.t("Contiene la parte finale dell'identificativo dell'app.",
                     "It contains the last part of the app's bundle identifier.")
        case .normalizedName:
            UIText.t("Contiene il nome dell'app scritto senza spazi.",
                     "It contains the app's name written without spaces.")
        case .versionStrippedName:
            UIText.t("Contiene il nome dell'app senza numero di versione: corrispondenza debole.",
                     "It contains the app's name without its version number: a weak match.")
        }
    }
}

public enum MatchConfidence: Int, Comparable, Sendable, CaseIterable {
    case low = 0, medium, high

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .high: UIText.t("Sicuro", "Certain")
        case .medium: UIText.t("Probabile", "Likely")
        case .low: UIText.t("Incerto", "Uncertain")
        }
    }

    /// Low-confidence matches start unchecked: the user opts in.
    public var selectedByDefault: Bool { self >= .medium }
}

public struct LeftoverMatch: Hashable, Sendable {
    public let reason: UninstallMatchReason
    public let confidence: MatchConfidence

    public init(reason: UninstallMatchReason, confidence: MatchConfidence) {
        self.reason = reason
        self.confidence = confidence
    }
}

/// Facts about an app used to explain matches (beyond `AppInfo`).
public struct LeftoverContext: Sendable {
    public var teamIdentifier: String?
    /// `com.apple.security.application-groups` from the app's entitlements.
    public var appGroups: [String]

    public init(teamIdentifier: String? = nil, appGroups: [String] = []) {
        self.teamIdentifier = teamIdentifier
        self.appGroups = appGroups
    }
}

public enum LeftoverExplainer {
    /// Explain why `fileName` (found in `librarySubdirectory`, e.g.
    /// "Preferences" or "LaunchDaemons") belongs to `app`. Returns the
    /// strongest reason, or nil when nothing links it to the app.
    ///
    /// `launchProgram` is the Program / ProgramArguments[0] of a launchd plist,
    /// when the file is one.
    public static func explain(
        fileName: String,
        librarySubdirectory: String,
        app: AppInfo,
        context: LeftoverContext = LeftoverContext(),
        launchProgram: String? = nil
    ) -> LeftoverMatch? {
        let bundleID = app.bundleIdentifier.lowercased()
        let lower = fileName.lowercased()
        let stem = stripKnownExtensions(lower)
        let appPath = app.path.path(percentEncoded: false)

        // Launch items pointing into the bundle are certain, whatever their name.
        if let program = launchProgram, !appPath.isEmpty,
           program == appPath || program.hasPrefix(appPath.hasSuffix("/") ? appPath : appPath + "/") {
            return LeftoverMatch(reason: .launchItemProgram(program), confidence: .high)
        }

        if !bundleID.isEmpty {
            if librarySubdirectory == "Preferences", stem == bundleID {
                return LeftoverMatch(reason: .preferencesDomain, confidence: .high)
            }
            if librarySubdirectory == "Containers", stem == bundleID {
                return LeftoverMatch(reason: .sandboxContainer, confidence: .high)
            }
        }

        if librarySubdirectory == "Group Containers",
           let group = context.appGroups.first(where: { $0.lowercased() == lower }) {
            // A group the app declares. Certain when it carries the app's own
            // id; otherwise likely, since sibling apps can share it.
            let own = !bundleID.isEmpty && lower.contains(bundleID)
            return LeftoverMatch(reason: .appGroup(group), confidence: own ? .high : .medium)
        }

        if !bundleID.isEmpty {
            if stem == bundleID {
                return LeftoverMatch(reason: .bundleIDExact, confidence: .high)
            }
            if lower.hasPrefix(bundleID + ".") || lower.hasPrefix(bundleID + "-") || lower.hasPrefix(bundleID + "_") {
                let rest = stem.dropFirst(bundleID.count + 1)
                let next = rest.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
                if next.isEmpty || helperTokens.contains(where: { next.hasPrefix($0) }) {
                    return LeftoverMatch(reason: .bundleIDPrefix, confidence: .high)
                }
                return LeftoverMatch(reason: .relatedBundleID(String(rest)), confidence: .low)
            }
            if wordMatch(bundleID, in: fileName) {
                return LeftoverMatch(reason: .bundleIDPrefix, confidence: .high)
            }
            let base = baseBundleID(bundleID)
            if base != bundleID, base.split(separator: ".").count >= 3, wordMatch(base, in: fileName) {
                return LeftoverMatch(reason: .baseBundleID, confidence: .medium)
            }
        }

        if let team = context.teamIdentifier, team.count >= 6,
           lower.hasPrefix(team.lowercased() + ".") {
            return LeftoverMatch(reason: .teamIdentifier(team), confidence: .low)
        }

        let names = [app.name, app.path.deletingPathExtension().lastPathComponent]
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 3 && $0 != "app" }
        if names.contains(stem) {
            return LeftoverMatch(reason: .appNameExact, confidence: .medium)
        }
        if let name = names.first(where: { wordMatch($0, in: fileName) }) {
            // Long or multi-word names rarely collide; short ones ("Arc",
            // "Notes") do.
            let distinctive = name.count >= 6 || name.contains(" ")
            return LeftoverMatch(reason: .appNameWord, confidence: distinctive ? .medium : .low)
        }

        let components = bundleID.split(separator: ".")
        if components.count >= 3 {
            let last2 = components.suffix(2).joined(separator: ".")
            if wordMatch(last2, in: fileName) {
                return LeftoverMatch(reason: .bundleIDComponents, confidence: .medium)
            }
        }

        let normalized = app.name.lowercased().filter(\.isLetter)
        if normalized.count >= 3, normalized != names.first, wordMatch(normalized, in: fileName) {
            return LeftoverMatch(reason: .normalizedName, confidence: normalized.count >= 8 ? .medium : .low)
        }

        let stripped = app.name.replacingOccurrences(of: "\\d+(\\.\\d+)*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        if stripped.count >= 3, stripped != "app", wordMatch(stripped, in: fileName) {
            return LeftoverMatch(reason: .versionStrippedName, confidence: .low)
        }
        return nil
    }

    /// Suffixes a vendor puts on its own app's helpers, logs and data, as
    /// opposed to a sibling edition (`.beta`, `.canary`, `.for.testing`).
    static let helperTokens = ["helper", "agent", "daemon", "launcher", "updater", "update", "xpc", "login",
                               "crashpad", "shipit", "extension", "widget", "share", "plugin", "service",
                               "notification", "framework", "cache", "log", "data", "settings", "prefs",
                               "savedstate", "binarycookies", "lockfile", "sfl", "storage", "db", "sqlite", "state"]

    static func baseBundleID(_ id: String) -> String {
        var base = id
        for suffix in [".helper", ".agent", ".daemon", ".launcher", ".updater"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return base
    }

    static func stripKnownExtensions(_ name: String) -> String {
        var s = name
        for ext in [".plist", ".savedstate", ".binarycookies", ".lockfile", ".log", ".app", ".prefpane", ".plugin", ".framework"]
            where s.hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        return s
    }

    /// Whole-word match, the same rule the finder uses (AppMatching).
    static func wordMatch(_ pattern: String, in fileName: String) -> Bool {
        AppMatching.filenameMatches(fileName, patterns: [pattern])
    }
}
