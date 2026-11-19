import SwiftUI
import MacCleanerKit

/// One row of the sidebar search: a module, or a setting inside a Settings pane.
struct SidebarSearchHit: Identifiable, Hashable {
    enum Target: Hashable {
        case module(SidebarItem)
        case settings(SettingsPane)
    }

    let id: String
    let title: String
    let subtitle: String
    let target: Target
}

/// Search data for the sidebar field: titles in the app language plus
/// keywords in Italian and English (and a few other common languages), so
/// "cache", "cestino", "doublons" or "login" all find the right page.
@MainActor
enum SidebarSearch {
    static func hits(for query: String) -> [SidebarSearchHit] {
        guard !SearchMatcher.tokens(query).isEmpty else { return [] }
        let modules = SidebarItem.allCases.map { item in
            (hit: SidebarSearchHit(id: "m." + item.deepLinkID, title: item.displayTitle,
                                   subtitle: item == .settings ? "" : item.group.title, target: .module(item)),
             fields: [item.displayTitle, item.tabTitle, item.group.title] + item.searchKeywords)
        }
        let settings = settingsEntries.map { entry in
            (hit: SidebarSearchHit(id: "s." + entry.id, title: entry.title,
                                   subtitle: KMR.t("Impostazioni", "Settings") + " › " + entry.pane.title,
                                   target: .settings(entry.pane)),
             fields: [entry.title, entry.pane.title] + entry.keywords)
        }
        let ranked = SearchMatcher.ranked(modules + settings, query: query) { $0.fields }
        return ranked.map(\.hit)
    }

    private struct SettingEntry {
        let id: String
        let pane: SettingsPane
        let title: String
        let keywords: [String]
    }

    private static var settingsEntries: [SettingEntry] {
        [
            SettingEntry(id: "login", pane: .general, title: KMR.t("Apri al login", "Open at login"),
                         keywords: ["avvio", "startup", "login", "launch", "accensione"]),
            SettingEntry(id: "sounds", pane: .general, title: KMR.t("Effetti sonori", "Sound effects"),
                         keywords: ["suoni", "audio", "sounds", "mute", "silenzio"]),
            SettingEntry(id: "appearance", pane: .general, title: KMR.t("Aspetto", "Appearance"),
                         keywords: ["tema", "scuro", "chiaro", "dark", "light", "mode", "theme"]),
            SettingEntry(id: "language", pane: .general, title: KMR.t("Lingua", "Language"),
                         keywords: ["lingua", "language", "idioma", "langue", "sprache", "italiano", "english"]),
            SettingEntry(id: "updates", pane: .general, title: KMR.t("Aggiornamento software", "Software Update"),
                         keywords: ["update", "aggiornamenti", "versione", "version", "nuova versione"]),
            SettingEntry(id: "menubar", pane: .menuBar, title: KMR.t("Mostra nella barra dei menu", "Show in menu bar"),
                         keywords: ["menu bar", "barra", "icona", "widget", "cpu", "ram", "memoria", "batteria", "battery", "rete", "network"]),
            SettingEntry(id: "alerts", pane: .alerts, title: KMR.t("Avvisi", "Alerts"),
                         keywords: ["notifiche", "notifications", "memoria sotto pressione", "memory pressure", "swap"]),
            SettingEntry(id: "autoclean", pane: .cleanup, title: KMR.t("Pulizia automatica", "Automatic cleanup"),
                         keywords: ["automatica", "automatic", "pianifica", "schedule", "ogni giorno", "daily", "weekly"]),
            SettingEntry(id: "preview", pane: .cleanup, title: KMR.t("Mostra un'anteprima prima di ogni pulizia", "Preview before every cleanup"),
                         keywords: ["anteprima", "simulazione", "dry run", "prova", "preview"]),
            SettingEntry(id: "keeplangs", pane: .cleanup, title: KMR.t("Lingue da conservare", "Languages to keep"),
                         keywords: ["localizzazioni", "lproj", "languages", "file di lingua"]),
            SettingEntry(id: "excluded", pane: .cleanup, title: KMR.t("Cartelle escluse", "Excluded folders"),
                         keywords: ["escludi", "exclude", "ignora", "ignore", "whitelist", "proteggi", "protect"]),
            SettingEntry(id: "realtime", pane: .security, title: KMR.t("Protezione in tempo reale", "Real-time protection"),
                         keywords: ["tempo reale", "realtime", "monitor", "antivirus", "malware"]),
            SettingEntry(id: "clipboard", pane: .security, title: KMR.t("Controllo degli appunti", "Clipboard guard"),
                         keywords: ["appunti", "clipboard", "incolla", "paste", "wallet", "crypto"]),
            SettingEntry(id: "malwaredb", pane: .security, title: KMR.t("Database malware", "Malware databases"),
                         keywords: ["xprotect", "malwarebazaar", "firme", "signatures", "hash", "chiave", "api key"]),
            SettingEntry(id: "about", pane: .about, title: KMR.t("Informazioni", "About"),
                         keywords: ["versione", "version", "licenza", "license", "codice sorgente", "source", "segnala", "issue", "bug"]),
        ]
    }
}

extension SidebarItem {
    /// Extra search words (Italian, English and a few common other languages).
    var searchKeywords: [String] {
        switch self {
        case .smartScan: ["panoramica", "overview", "home", "scansione", "scan", "salute", "health", "tutto"]
        case .systemJunk: ["cache", "log", "registri", "spazzatura", "junk", "temporanei", "temp", "sistema", "system", "xcode", "localizzazioni"]
        case .mailAttachments: ["mail", "allegati", "attachments", "email", "posta", "outlook", "spark"]
        case .trashBins: ["cestino", "trash", "svuota", "empty", "papierkorb", "corbeille", "papelera"]
        case .malwareRemoval: ["malware", "virus", "antivirus", "minacce", "threats", "adware", "trojan", "quarantena", "xprotect"]
        case .privacy: ["privacy", "cookie", "cronologia browser", "history", "safari", "chrome", "firefox", "tracce", "traces"]
        case .wifiNetworks: ["wifi", "wi-fi", "reti", "networks", "password"]
        case .appPermissions: ["permessi", "permissions", "fotocamera", "camera", "microfono", "microphone", "accessibilità", "tcc"]
        case .optimization: ["login", "elementi di login", "login items", "avvio", "startup", "agenti", "launch agents", "velocità", "speed"]
        case .maintenance: ["manutenzione", "maintenance", "dns", "spotlight", "reindicizza", "script", "ram", "purge"]
        case .uninstaller: ["disinstalla", "uninstall", "rimuovi app", "remove app", "app", "applicazioni", "avanzi", "leftovers", "deinstallieren", "désinstaller", "desinstalar"]
        case .unusedApps: ["inutilizzate", "unused", "mai aperte", "never opened", "vecchie app"]
        case .extensions: ["estensioni", "extensions", "plugin", "widget", "preference pane", "quick look"]
        case .updater: ["aggiornamenti", "updates", "update", "versioni", "sparkle", "app store"]
        case .spaceLens: ["mappa", "map", "spazio", "space", "disco", "disk", "cartelle", "folders", "treemap", "dimensioni", "size"]
        case .largeOldFiles: ["grandi", "large", "vecchi", "old", "file pesanti", "big files"]
        case .duplicates: ["duplicati", "duplicates", "copie", "copies", "doppioni", "doublons", "duplicados", "doppelt"]
        case .shredder: ["distruggi", "shred", "elimina definitivamente", "secure erase", "cancella sicuro", "trita"]
        case .storageExtras: ["spazio extra", "istantanee", "snapshots", "time machine", "docker", "installer", "simulatori", "simulators", "ios backup"]
        case .browserExtensions: ["estensioni browser", "browser extensions", "add-on", "safari", "chrome", "firefox"]
        case .ports: ["porte", "ports", "rete", "network", "listening", "server", "lsof"]
        case .packages: ["pacchetti", "packages", "pkg", "receipts", "ricevute", "installer"]
        case .applePrivacy: ["apple", "privacy", "siri", "analisi", "analytics", "pubblicità", "ads", "apple intelligence"]
        case .securityCheck: ["sicurezza", "security", "firewall", "filevault", "gatekeeper", "sip", "controllo"]
        case .persistence: ["avvio automatico", "persistence", "launch daemons", "launch agents", "login", "background items", "elementi in background"]
        case .systemData: ["dati di sistema", "system data", "altro", "other", "spazio occupato", "storage"]
        case .diskHogs: ["sviluppo", "developer", "node_modules", "xcode", "derived data", "homebrew", "npm", "docker", "cache sviluppo"]
        case .projectJunk: ["progetti", "projects", "build", "node_modules", "target", "artefatti", "artifacts"]
        case .cleanHistory: ["cronologia", "history", "ripristina", "restore", "annulla", "undo", "recupera", "cestino"]
        case .settings: ["impostazioni", "settings", "preferenze", "preferences", "opzioni", "options", "einstellungen", "réglages", "ajustes"]
        }
    }
}
