import Foundation

/// Apple analytics, advertising and personalisation settings the Apple
/// Privacy page shows, where each value lives and whether Mac Mop may change
/// it.
///
/// Only plain per-user preferences that System Settings itself writes are
/// toggled here (no profiles, no admin rights). Everything else is read when
/// possible and opened in the exact System Settings pane.
///
/// The `com.apple.AdLib` / `com.apple.assistant.support` keys, their on/off
/// values and the DiagnosticMessagesHistory location come from MacSpace's
/// DebloatCatalog (https://github.com/1architect/macspace-releases, MIT,
/// Copyright (c) 2026 1architect). See THIRD_PARTY_NOTICES.md.
public enum ApplePrivacySettings {
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
    }

    public enum Storage: Sendable, Equatable {
        /// A per-user preference (`defaults read <domain> <key>`).
        case userDefaults(domain: String, key: String)
        /// A plist file read directly (system-owned or in an app container).
        case plistFile(path: String, key: String)
        /// No readable value: the row only links to System Settings.
        case none
    }

    public struct Setting: Sendable, Identifiable, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let symbol: String
        public let storage: Storage
        /// Stored value when the feature is on / off. Nil when unknown.
        public let onValue: Value?
        public let offValue: Value?
        /// What a missing key means (macOS writes many of these only after
        /// the first change). Nil = unknown.
        public let missingMeansOn: Bool?
        /// True when Mac Mop may write the value itself (per-user, no admin).
        public let writable: Bool
        /// Where to change it by hand: an `x-apple.systempreferences:` URL,
        /// or an app to open (`/Applications/Safari.app`).
        public let settingsURL: String
        /// Where to find the switch, for rows without a direct link.
        public let settingsPath: String?
        /// Change needs the affected apps to be relaunched.
        public let needsRelaunch: Bool
    }

    public enum State: Sendable, Equatable {
        case on, off, unknown
    }

    // MARK: Panes

    public static let analyticsPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Analytics"
    public static let advertisingPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Advertising"
    public static let locationPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    public static let intelligenceReportPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AppleIntelligenceReport"
    public static let siriPane = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
    public static let spotlightPane = "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"
    public static let keyboardPane = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    static let diagnosticsHistory = "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
    static let safariPrefs = "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"

    public static func catalog(home: String = NSHomeDirectory()) -> [Setting] {
        [
            Setting(id: "ads.personalized",
                    title: UIText.t("Annunci personalizzati di Apple", "Personalized ads from Apple"),
                    detail: UIText.t("Apple usa ciò che fai in App Store, Apple News e Borsa per scegliere gli annunci da mostrarti. Spento: vedi comunque annunci, ma non basati su di te.",
                                     "Apple uses what you do in the App Store, Apple News and Stocks to pick the ads you see. Off: you still see ads, just not based on you."),
                    symbol: "megaphone.fill",
                    storage: .userDefaults(domain: "com.apple.AdLib", key: "allowApplePersonalizedAdvertising"),
                    onValue: .bool(true), offValue: .bool(false), missingMeansOn: true,
                    writable: true, settingsURL: advertisingPane, settingsPath: nil, needsRelaunch: true),
            Setting(id: "siri.improve",
                    title: UIText.t("Migliora Siri e Dettatura", "Improve Siri & Dictation"),
                    detail: UIText.t("Condivide con Apple l'audio e le trascrizioni delle tue richieste a Siri e della dettatura, per farle ascoltare e valutare.",
                                     "Shares audio and transcripts of your Siri and Dictation requests with Apple so they can be reviewed."),
                    symbol: "waveform",
                    storage: .userDefaults(domain: "com.apple.assistant.support", key: "Siri Data Sharing Opt-In Status"),
                    onValue: .int(1), offValue: .int(2), missingMeansOn: nil,
                    writable: true, settingsURL: analyticsPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "analytics.mac",
                    title: UIText.t("Condividi analisi del Mac", "Share Mac Analytics"),
                    detail: UIText.t("Invia ad Apple ogni giorno dati di utilizzo e rapporti sugli arresti anomali. È un'impostazione di sistema: si cambia in Impostazioni (serve la password).",
                                     "Sends Apple daily usage data and crash reports. It's a system-wide setting: change it in Settings (needs your password)."),
                    symbol: "chart.bar.xaxis",
                    storage: .plistFile(path: diagnosticsHistory, key: "AutoSubmit"),
                    onValue: .bool(true), offValue: .bool(false), missingMeansOn: nil,
                    writable: false, settingsURL: analyticsPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "analytics.developers",
                    title: UIText.t("Condividi con gli sviluppatori di app", "Share with app developers"),
                    detail: UIText.t("Gira agli sviluppatori i rapporti sugli arresti anomali delle loro app.",
                                     "Passes crash reports of their apps on to developers."),
                    symbol: "hammer.fill",
                    storage: .plistFile(path: diagnosticsHistory, key: "ThirdPartyDataSubmit"),
                    onValue: .bool(true), offValue: .bool(false), missingMeansOn: nil,
                    writable: false, settingsURL: analyticsPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "analytics.icloud",
                    title: UIText.t("Analisi di iCloud e funzioni vocali", "iCloud and voice-feature analytics"),
                    detail: UIText.t("Nella stessa pagina ci sono “Condividi analisi iCloud” e “Migliora le funzioni vocali assistite”: dati di utilizzo e campioni audio inviati ad Apple.",
                                     "The same page has “Share iCloud Analytics” and “Improve Assistive Voice Features”: usage data and audio samples sent to Apple."),
                    symbol: "icloud.fill",
                    storage: .none, onValue: nil, offValue: nil, missingMeansOn: nil,
                    writable: false, settingsURL: analyticsPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "siri.enabled",
                    title: "Siri",
                    detail: UIText.t("Le richieste a Siri vengono elaborate anche sui server Apple. Da qui puoi anche cancellare la cronologia di Siri e Dettatura.",
                                     "Siri requests are also processed on Apple's servers. From here you can also delete your Siri & Dictation history."),
                    symbol: "mic.fill",
                    storage: .userDefaults(domain: "com.apple.assistant.support", key: "Assistant Enabled"),
                    onValue: .bool(true), offValue: .bool(false), missingMeansOn: false,
                    writable: false, settingsURL: siriPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "dictation",
                    title: UIText.t("Dettatura", "Dictation"),
                    detail: UIText.t("Per le lingue senza modello sul Mac, la voce dettata viene inviata ad Apple per essere trascritta.",
                                     "For languages without an on-Mac model, dictated speech is sent to Apple to be transcribed."),
                    symbol: "mic.badge.plus",
                    storage: .userDefaults(domain: "com.apple.assistant.support", key: "Dictation Enabled"),
                    onValue: .bool(true), offValue: .bool(false), missingMeansOn: false,
                    writable: false, settingsURL: keyboardPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "spotlight.suggestions",
                    title: UIText.t("Suggerimenti e miglioramento di Spotlight", "Spotlight suggestions and improvement"),
                    detail: UIText.t("Spotlight può inviare ad Apple ciò che cerchi per mostrarti risultati dal web, e condividere le ricerche per migliorare il servizio.",
                                     "Spotlight can send what you search for to Apple to show web results, and share searches to improve the service."),
                    symbol: "magnifyingglass",
                    storage: .none, onValue: nil, offValue: nil, missingMeansOn: nil,
                    writable: false, settingsURL: spotlightPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "safari.suggestions",
                    title: UIText.t("Suggerimenti del motore di ricerca in Safari", "Search engine suggestions in Safari"),
                    detail: UIText.t("Mentre scrivi nella barra degli indirizzi, ogni lettera viene inviata al motore di ricerca per proporti suggerimenti.",
                                     "As you type in the address bar, each letter is sent to the search engine to suggest searches."),
                    symbol: "safari.fill",
                    storage: .plistFile(path: home + "/" + safariPrefs, key: "SuppressSearchSuggestions"),
                    onValue: .bool(false), offValue: .bool(true), missingMeansOn: true,
                    writable: false, settingsURL: "/Applications/Safari.app",
                    settingsPath: UIText.t("Safari › Impostazioni › Ricerca", "Safari › Settings › Search"), needsRelaunch: false),
            Setting(id: "safari.universal",
                    title: UIText.t("Suggerimenti di Safari", "Safari Suggestions"),
                    detail: UIText.t("Safari invia ad Apple le tue ricerche, insieme alla posizione approssimativa, per proporre notizie, articoli e siti.",
                                     "Safari sends your searches to Apple, with your approximate location, to suggest news, articles and sites."),
                    symbol: "sparkle.magnifyingglass",
                    storage: .plistFile(path: home + "/" + safariPrefs, key: "UniversalSearchEnabled"),
                    onValue: .bool(true), offValue: .bool(false), missingMeansOn: true,
                    writable: false, settingsURL: "/Applications/Safari.app",
                    settingsPath: UIText.t("Safari › Impostazioni › Ricerca", "Safari › Settings › Search"), needsRelaunch: false),
            Setting(id: "location.system",
                    title: UIText.t("Posizione per servizi di sistema", "Location for system services"),
                    detail: UIText.t("“Luoghi significativi”, suggerimenti e annunci basati sulla posizione e analisi per Apple usano dove ti trovi. In fondo alla lista: Servizi di sistema › Dettagli.",
                                     "“Significant locations”, location-based suggestions and ads, and analytics for Apple use where you are. At the bottom of the list: System Services › Details."),
                    symbol: "location.fill",
                    storage: .none, onValue: nil, offValue: nil, missingMeansOn: nil,
                    writable: false, settingsURL: locationPane, settingsPath: nil, needsRelaunch: false),
            Setting(id: "intelligence.report",
                    title: UIText.t("Resoconto di Apple Intelligence", "Apple Intelligence Report"),
                    detail: UIText.t("Mostra quali richieste sono state inviate a Private Cloud Compute, i server di Apple per l'intelligenza artificiale, e permette di registrarle.",
                                     "Shows which requests were sent to Private Cloud Compute, Apple's AI servers, and lets you log them."),
                    symbol: "doc.text.magnifyingglass",
                    storage: .none, onValue: nil, offValue: nil, missingMeansOn: nil,
                    writable: false, settingsURL: intelligenceReportPane, settingsPath: nil, needsRelaunch: false),
        ]
    }

    // MARK: Reading

    /// Interprets a raw preference value (`Bool`, `NSNumber`, `Int`,
    /// `String`, or nil when the key is missing) for `setting`.
    public static func state(of setting: Setting, raw: Any?) -> State {
        guard let raw else {
            switch setting.missingMeansOn {
            case true?: return .on
            case false?: return .off
            case nil: return .unknown
            }
        }
        guard let value = normalize(raw) else { return .unknown }
        if let on = setting.onValue, matches(value, on) { return .on }
        if let off = setting.offValue, matches(value, off) { return .off }
        return .unknown
    }

    static func normalize(_ raw: Any) -> Value? {
        switch raw {
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            // CFBoolean bridges to NSNumber too; keep it a Bool.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .int(n.intValue)
        case let i as Int: return .int(i)
        case let s as String: return .string(s)
        default: return nil
        }
    }

    /// `defaults` stores booleans written by some tools as 0/1 integers or
    /// "YES"/"NO" strings: compare loosely.
    static func matches(_ value: Value, _ expected: Value) -> Bool {
        switch (value, expected) {
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.int(a), .bool(b)): return (a != 0) == b
        case let (.bool(a), .int(b)): return (a ? 1 : 0) == b
        case let (.string(a), .bool(b)): return ["1", "yes", "true"].contains(a.lowercased()) == b
        case let (.string(a), .int(b)): return Int(a) == b
        case let (.string(a), .string(b)): return a == b
        default: return false
        }
    }

    /// Value to store for a writable setting. Nil for read-only rows.
    public static func value(for setting: Setting, enabled: Bool) -> Value? {
        guard setting.writable else { return nil }
        return enabled ? setting.onValue : setting.offValue
    }

    // MARK: Apple Intelligence

    /// Where macOS keeps the Apple Intelligence language models (~4–18 GB).
    public static let generativeModelsPath = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels"
    /// macOS' feature-eligibility answers. Reading needs Full Disk Access.
    public static let eligibilityPath = "/private/var/db/os_eligibility/eligibility.plist"

    public enum IntelligenceState: Sendable, Equatable {
        /// Apple Intelligence is available on this Mac (it may still be switched off in Settings).
        case available
        /// Not available (language, region or device) and no models on disk.
        case unavailable
        /// Not available, yet the models are still on disk: macOS usually removes them on its own within a day.
        case unavailableModelsPresent
        case unknown
    }

    /// The SIRI_MODE answer from eligibility.plist: 4 = eligible, 2 = not
    /// eligible (values observed by MacSpace and on macOS 27).
    public static func siriModeAnswer(in plist: [String: Any]) -> Int? {
        guard let domain = plist["OS_ELIGIBILITY_DOMAIN_SIRI_MODE"] as? [String: Any] else { return nil }
        return (domain["os_eligibility_answer_t"] as? NSNumber)?.intValue
    }

    public static func intelligenceState(siriModeAnswer: Int?, modelBytes: UInt64?) -> IntelligenceState {
        switch siriModeAnswer {
        case 4?: return .available
        case .some:
            if let modelBytes, modelBytes > 100_000_000 { return .unavailableModelsPresent }
            return modelBytes == nil ? .unknown : .unavailable
        case nil:
            return .unknown
        }
    }
}
