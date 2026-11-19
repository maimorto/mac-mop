import Foundation

// What macOS lumps into "System Data" (System Settings › General › Storage),
// split into categories that can each be measured, explained and, where it
// is safe, cleaned. Paths and wording are our own, from Apple's documentation
// and from inspecting macOS 26/27; no third-party list was copied.

/// How much care a System Data category needs.
public enum SystemDataSafety: String, CaseIterable, Codable, Sendable {
    /// Rebuilt or re-downloaded on demand: Mac Mop can move it to the Trash.
    case safe
    /// Your data or something you may still want: check before removing.
    case review
    /// Managed by macOS: never removed by Mac Mop, only explained.
    case protected
}

/// What Mac Mop can do with a category.
public enum SystemDataAction: String, Codable, Sendable {
    /// Selected items go to the Trash through the normal clean flow (undo in Cleanup History).
    case trash
    /// Needs the administrator password (local Time Machine snapshots).
    case adminSnapshots
    /// Show in Finder and explain the steps; the owning app should clean it.
    case reveal
    /// Nothing to do here: explanation and system steps only.
    case info
    /// Handled by the Trash module.
    case openTrash
}

/// Granularity of the rows listed under a category.
public enum SystemDataGranularity: String, Sendable {
    /// Each entry directly inside a root is a row (e.g. one folder per app in Caches).
    case children
    /// Each root is a single row (e.g. the Homebrew cache).
    case roots
}

public enum SystemDataCategoryID: String, CaseIterable, Codable, Sendable {
    case timeMachine, purgeable, vmSwap, appleIntelligence, systemAssets, aerials
    case userCaches, systemCaches, tempFiles, userLogs, systemLogs, unifiedLogs, spotlight
    case iosBackups, xcodeDerivedData, xcodeDeviceSupport, xcodeArchives, simulatorCaches, simulatorDevices
    case installers, mailDownloads, messages, mediaAnalysis, virtualMachines, devCaches, pnpmStore
    case appContainers, trash
}

public struct SystemDataCategory: Identifiable, Sendable {
    public let id: SystemDataCategoryID
    public let safety: SystemDataSafety
    public let action: SystemDataAction
    public let roots: [String]
    public let granularity: SystemDataGranularity
    /// Entry names that are counted but never offered for cleaning.
    public let keepNames: Set<String>
    /// False for figures that overlap other categories (purgeable space).
    public let countsInTotal: Bool

    public init(id: SystemDataCategoryID, safety: SystemDataSafety, action: SystemDataAction, roots: [String] = [],
                granularity: SystemDataGranularity = .children, keepNames: Set<String> = [], countsInTotal: Bool = true) {
        self.id = id
        self.safety = safety
        self.action = action
        self.roots = roots
        self.granularity = granularity
        self.keepNames = keepNames
        self.countsInTotal = countsInTotal
    }

    /// Only Safe categories that Mac Mop can move to the Trash count as "safely reclaimable".
    public var isSafelyCleanable: Bool { safety == .safe && action == .trash }
}

public enum SystemDataCatalog {
    /// Inputs that depend on the Mac, injected so the catalog is testable.
    public struct Environment: Sendable {
        public var home: String
        /// Folder names inside /System/Library/AssetsV2.
        public var assetFolders: [String]
        /// Entry names inside /Applications.
        public var applications: [String]
        /// This user's DARWIN_USER_CACHE_DIR / DARWIN_USER_TEMP_DIR.
        public var userTempDirs: [String]

        public init(home: String, assetFolders: [String] = [], applications: [String] = [], userTempDirs: [String] = []) {
            self.home = home
            self.assetFolders = assetFolders
            self.applications = applications
            self.userTempDirs = userTempDirs
        }

        public static func live() -> Environment {
            let fm = FileManager.default
            func confDir(_ name: Int32) -> String? {
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard confstr(name, &buf, buf.count) > 0 else { return nil }
                let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                // /var/folders/… → /private/var/folders/… so it dedupes with other roots.
                let p = s.hasSuffix("/") ? String(s.dropLast()) : s
                return p.hasPrefix("/var/") ? "/private" + p : p
            }
            return Environment(
                home: NSHomeDirectory(),
                assetFolders: (try? fm.contentsOfDirectory(atPath: "/System/Library/AssetsV2")) ?? [],
                applications: (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [],
                userTempDirs: [confDir(_CS_DARWIN_USER_CACHE_DIR), confDir(_CS_DARWIN_USER_TEMP_DIR)].compactMap { $0 })
        }
    }

    /// Apple Intelligence and other on-device model packs ("Unified Asset Framework").
    public static func isAppleIntelligenceAsset(_ folder: String) -> Bool {
        folder.hasPrefix("com_apple_MobileAsset_UAF_")
    }

    /// "com_apple_MobileAsset_UAF_FM_GenerativeModels" → "Generative models";
    /// unknown packs are prettified ("Search Query Understanding").
    public static func assetDisplayName(_ folder: String) -> String {
        var key = folder
        for prefix in ["com_apple_MobileAsset_UAF_", "com_apple_MobileAsset_"] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count)); break
        }
        switch key {
        case "FM_GenerativeModels": return UIText.t("Modelli generativi di Apple Intelligence", "Apple Intelligence generative models")
        case "FM_Visual": return UIText.t("Modelli visivi di Apple Intelligence", "Apple Intelligence visual models")
        case "Siri_Understanding": return UIText.t("Comprensione del linguaggio di Siri", "Siri language understanding")
        case "Siri_TextToSpeech": return UIText.t("Voci di Siri", "Siri voices")
        case "LinguisticData": return UIText.t("Dati linguistici", "Linguistic data")
        case "IF_Planner": return UIText.t("Pianificatore di Apple Intelligence", "Apple Intelligence planner")
        case "Photos_SpatialPhotosRelive": return UIText.t("Foto spaziali", "Spatial photos")
        default:
            guard key != folder else { return folder }
            // "SearchQueryUnderstanding" / "Siri_PlatformAssets" → words.
            var out = ""
            for ch in key {
                if ch == "_" { out += " "; continue }
                if ch.isUppercase, let last = out.last, last.isLowercase { out += " " }
                out.append(ch)
            }
            return out
        }
    }

    public static func isMacOSInstaller(_ app: String) -> Bool {
        app.hasPrefix("Install macOS") && app.hasSuffix(".app")
    }

    public static func categories(_ env: Environment) -> [SystemDataCategory] {
        let h = env.home
        let lib = h + "/Library"
        let assets = "/System/Library/AssetsV2"
        let dev = lib + "/Developer"
        return [
            .init(id: .timeMachine, safety: .review, action: .adminSnapshots),
            .init(id: .purgeable, safety: .protected, action: .info, countsInTotal: false),
            .init(id: .vmSwap, safety: .protected, action: .info,
                  roots: ["/System/Volumes/VM", "/private/var/vm"]),
            .init(id: .appleIntelligence, safety: .protected, action: .info,
                  roots: env.assetFolders.filter(isAppleIntelligenceAsset).sorted().map { "\(assets)/\($0)" },
                  granularity: .roots),
            .init(id: .systemAssets, safety: .protected, action: .info, roots: [assets]),
            .init(id: .aerials, safety: .review, action: .trash,
                  roots: [lib + "/Application Support/com.apple.wallpaper/aerials/videos",
                          "/Library/Application Support/com.apple.idleassetsd/Customer"]),
            .init(id: .devCaches, safety: .safe, action: .trash,
                  roots: [lib + "/Caches/Homebrew", lib + "/Caches/pip", lib + "/Caches/uv", lib + "/Caches/pnpm"]
                    + [h + "/.npm/_cacache", h + "/.cache/uv", h + "/.cache/pnpm", lib + "/Caches/Yarn",
                       lib + "/Caches/go-build", h + "/.bun/install/cache", h + "/.cargo/registry/cache",
                       h + "/.gradle/caches", lib + "/Caches/CocoaPods", lib + "/Caches/org.swift.swiftpm"],
                  granularity: .roots),
            .init(id: .pnpmStore, safety: .review, action: .info,
                  roots: [lib + "/pnpm/store", h + "/.local/share/pnpm/store", h + "/.pnpm-store"], granularity: .roots),
            .init(id: .userCaches, safety: .safe, action: .trash, roots: [lib + "/Caches"],
                  keepNames: ["com.spotify.client", "org.gradle", "ms-playwright", "com.apple.HomeKit", "com.apple.homed",
                              "CloudKit", "com.apple.bird", "com.apple.containermanagerd", "FamilyCircle"]),
            .init(id: .systemCaches, safety: .safe, action: .trash, roots: ["/Library/Caches"]),
            .init(id: .tempFiles, safety: .protected, action: .info, roots: env.userTempDirs, granularity: .roots),
            .init(id: .userLogs, safety: .safe, action: .trash, roots: [lib + "/Logs"],
                  keepNames: [MCConstants.dataFolderName]),
            .init(id: .systemLogs, safety: .safe, action: .trash, roots: ["/Library/Logs", "/private/var/log"]),
            .init(id: .unifiedLogs, safety: .protected, action: .info,
                  roots: ["/private/var/db/diagnostics", "/private/var/db/uuidtext"], granularity: .roots),
            .init(id: .spotlight, safety: .protected, action: .info,
                  roots: [lib + "/Metadata/CoreSpotlight", "/System/Volumes/Data/.Spotlight-V100"], granularity: .roots),
            .init(id: .iosBackups, safety: .review, action: .trash, roots: [lib + "/Application Support/MobileSync/Backup"]),
            .init(id: .xcodeDerivedData, safety: .safe, action: .trash, roots: [dev + "/Xcode/DerivedData"]),
            .init(id: .xcodeDeviceSupport, safety: .safe, action: .trash,
                  roots: ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { "\(dev)/Xcode/\($0) DeviceSupport" }),
            .init(id: .xcodeArchives, safety: .review, action: .trash, roots: [dev + "/Xcode/Archives"]),
            .init(id: .simulatorCaches, safety: .safe, action: .trash, roots: [dev + "/CoreSimulator/Caches"]),
            .init(id: .simulatorDevices, safety: .review, action: .info,
                  roots: [dev + "/CoreSimulator/Devices", "/Library/Developer/CoreSimulator"], granularity: .roots),
            .init(id: .installers, safety: .review, action: .trash,
                  roots: ["/Library/Updates"] + env.applications.filter(isMacOSInstaller).sorted().map { "/Applications/\($0)" },
                  granularity: .roots),
            .init(id: .mailDownloads, safety: .safe, action: .trash,
                  roots: [lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads", lib + "/Mail Downloads"]),
            .init(id: .messages, safety: .review, action: .reveal, roots: [lib + "/Messages/Attachments"], granularity: .roots),
            .init(id: .mediaAnalysis, safety: .protected, action: .info,
                  roots: ["com.apple.mediaanalysisd", "com.apple.photoanalysisd", "com.apple.wallpaper.agent"]
                    .map { "\(lib)/Containers/\($0)" }, granularity: .roots),
            .init(id: .virtualMachines, safety: .review, action: .reveal,
                  roots: [lib + "/Containers/com.utmapp.UTM", lib + "/Containers/com.docker.docker",
                          lib + "/Group Containers/HUAQ24HBR6.dev.orbstack", h + "/.orbstack", h + "/.colima", h + "/.lima",
                          h + "/Parallels", h + "/Virtual Machines.localized", h + "/.local/share/containers",
                          lib + "/Containers/com.parallels.desktop.console"],
                  granularity: .roots),
            .init(id: .appContainers, safety: .review, action: .reveal,
                  roots: [lib + "/Containers", lib + "/Group Containers"]),
            .init(id: .trash, safety: .safe, action: .openTrash, roots: [h + "/.Trash"], granularity: .roots),
        ]
    }

    // MARK: Text

    public static func title(_ id: SystemDataCategoryID) -> String {
        switch id {
        case .timeMachine: UIText.t("Istantanee locali di Time Machine", "Local Time Machine snapshots")
        case .purgeable: UIText.t("Spazio eliminabile da macOS", "Purgeable space")
        case .vmSwap: UIText.t("Memoria virtuale e stop", "Virtual memory and sleep image")
        case .appleIntelligence: UIText.t("Apple Intelligence e modelli sul dispositivo", "Apple Intelligence and on-device models")
        case .systemAssets: UIText.t("Risorse scaricate da macOS", "Assets downloaded by macOS")
        case .aerials: UIText.t("Video degli sfondi Aerial", "Aerial wallpaper videos")
        case .userCaches: UIText.t("Cache delle app", "App caches")
        case .systemCaches: UIText.t("Cache di sistema", "System caches")
        case .tempFiles: UIText.t("File temporanei", "Temporary files")
        case .userLogs: UIText.t("Log delle app", "App logs")
        case .systemLogs: UIText.t("Log e rapporti di sistema", "System logs and reports")
        case .unifiedLogs: UIText.t("Registro unificato di macOS", "macOS unified log")
        case .spotlight: UIText.t("Indice di Spotlight", "Spotlight index")
        case .iosBackups: UIText.t("Backup di iPhone e iPad", "iPhone and iPad backups")
        case .xcodeDerivedData: UIText.t("Xcode: DerivedData", "Xcode: DerivedData")
        case .xcodeDeviceSupport: UIText.t("Xcode: supporto dispositivi", "Xcode: Device Support")
        case .xcodeArchives: UIText.t("Xcode: archivi", "Xcode: Archives")
        case .simulatorCaches: UIText.t("Simulatori: cache", "Simulators: caches")
        case .simulatorDevices: UIText.t("Simulatori: dispositivi e runtime", "Simulators: devices and runtimes")
        case .installers: UIText.t("Installer di macOS e aggiornamenti", "macOS installers and updates")
        case .mailDownloads: UIText.t("Allegati aperti in Mail", "Attachments opened in Mail")
        case .messages: UIText.t("Allegati di Messaggi", "Messages attachments")
        case .mediaAnalysis: UIText.t("Analisi di foto e video", "Photo and video analysis")
        case .virtualMachines: UIText.t("Macchine virtuali e Docker", "Virtual machines and Docker")
        case .devCaches: UIText.t("Cache degli strumenti di sviluppo", "Developer tool caches")
        case .pnpmStore: UIText.t("Archivio pacchetti di pnpm", "pnpm package store")
        case .appContainers: UIText.t("Dati delle app (contenitori)", "App data (containers)")
        case .trash: UIText.t("Cestino", "Trash")
        }
    }

    /// One plain sentence: what it is.
    public static func explanation(_ id: SystemDataCategoryID) -> String {
        switch id {
        case .timeMachine: UIText.t("Punti di ripristino orari che Time Machine tiene sul Mac quando il disco di backup non è collegato.", "Hourly restore points Time Machine keeps on the Mac while the backup disk is not connected.")
        case .purgeable: UIText.t("Copie di file iCloud, cache e istantanee che macOS elimina da solo quando serve spazio.", "iCloud file copies, caches and snapshots macOS removes by itself when space is needed.")
        case .vmSwap: UIText.t("File di scambio della memoria e immagine dello stop: macOS li crea e li ridimensiona mentre lavori.", "Memory swap files and the sleep image: macOS creates and resizes them while you work.")
        case .appleIntelligence: UIText.t("Modelli linguistici e di immagini che Apple Intelligence e Siri usano sul Mac senza internet.", "Language and image models Apple Intelligence and Siri use on the Mac without the internet.")
        case .systemAssets: UIText.t("Dizionari, voci, lingue e altre risorse che macOS scarica quando servono.", "Dictionaries, voices, languages and other resources macOS downloads when needed.")
        case .aerials: UIText.t("Video in 4K degli sfondi e salvaschermo Aerial scaricati sul Mac.", "4K videos of the Aerial wallpapers and screen savers downloaded to the Mac.")
        case .userCaches: UIText.t("File temporanei che le app ricreano da sole alla prossima apertura.", "Temporary files apps recreate by themselves next time they open.")
        case .systemCaches: UIText.t("Cache condivise tra gli utenti, ricreate da macOS.", "Caches shared by all users, recreated by macOS.")
        case .tempFiles: UIText.t("Cartelle temporanee delle app in uso: macOS le svuota al riavvio.", "Temporary folders of running apps: macOS empties them at restart.")
        case .userLogs: UIText.t("Diagnostica scritta dalle app per risolvere problemi passati.", "Diagnostics apps wrote to troubleshoot past problems.")
        case .systemLogs: UIText.t("Log di sistema e rapporti di arresto anomalo; macOS ne scrive di nuovi.", "System logs and crash reports; macOS keeps writing new ones.")
        case .unifiedLogs: UIText.t("Il registro di sistema di macOS: si ruota da solo e non va toccato.", "macOS's system log: it rotates by itself and must not be touched.")
        case .spotlight: UIText.t("L'indice che rende istantanea la ricerca di Spotlight.", "The index that makes Spotlight search instant.")
        case .iosBackups: UIText.t("Copie complete di iPhone o iPad fatte dal Finder: per alcuni potrebbe essere l'unico backup.", "Full copies of an iPhone or iPad made by the Finder: for some it may be the only backup.")
        case .xcodeDerivedData: UIText.t("Risultati di compilazione di Xcode, rigenerati alla prossima build.", "Xcode build products, regenerated on the next build.")
        case .xcodeDeviceSupport: UIText.t("Simboli copiati dai dispositivi collegati; Xcode li ricopia quando ricolleghi il dispositivo.", "Symbols copied from connected devices; Xcode copies them again when you reconnect the device.")
        case .xcodeArchives: UIText.t("Build archiviate per la distribuzione, con i simboli per leggere i crash.", "Builds archived for distribution, with the symbols to read crash reports.")
        case .simulatorCaches: UIText.t("Cache dei simulatori di Xcode, ricreate quando servono.", "Xcode simulator caches, recreated when needed.")
        case .simulatorDevices: UIText.t("Simulatori creati da Xcode con le loro app e i runtime di iOS scaricati.", "Simulators created by Xcode with their apps, and downloaded iOS runtimes.")
        case .installers: UIText.t("Installer completi di macOS e aggiornamenti scaricati ma non ancora installati.", "Full macOS installers and updates downloaded but not installed yet.")
        case .mailDownloads: UIText.t("Copie degli allegati aperti da Mail; il messaggio originale resta nella casella.", "Copies of attachments opened from Mail; the original message stays in the mailbox.")
        case .messages: UIText.t("Foto, video e file ricevuti in Messaggi.", "Photos, videos and files received in Messages.")
        case .mediaAnalysis: UIText.t("Risultati dell'analisi di volti, oggetti e testo in Foto, rifatti da macOS se mancano.", "Results of face, object and text analysis in Photos, redone by macOS if missing.")
        case .virtualMachines: UIText.t("Dischi virtuali di UTM, Parallels, Docker, OrbStack e simili: crescono e non si restringono da soli.", "Virtual disks of UTM, Parallels, Docker, OrbStack and similar: they grow and do not shrink by themselves.")
        case .devCaches: UIText.t("Pacchetti scaricati da Homebrew, npm, pip, Yarn, Cargo e simili; si riscaricano quando servono.", "Packages downloaded by Homebrew, npm, pip, Yarn, Cargo and similar; downloaded again when needed.")
        case .pnpmStore: UIText.t("I pacchetti di pnpm, collegati ai progetti con hard link: qui ogni file è contato una volta.", "pnpm's packages, hard-linked into projects: each file is counted once here.")
        case .appContainers: UIText.t("Documenti, cache e impostazioni delle app dell'App Store e di sistema.", "Documents, caches and settings of App Store and system apps.")
        case .trash: UIText.t("File eliminati che occupano ancora spazio finché non svuoti il Cestino.", "Deleted files that still use space until you empty the Trash.")
        }
    }

    /// What Mac Mop can do, or the steps to follow by hand.
    public static func guidance(_ id: SystemDataCategoryID) -> String {
        switch id {
        case .timeMachine: UIText.t("macOS le elimina da solo dopo 24 ore o quando serve spazio. Mac Mop può eliminarle subito con la password di amministratore; i backup sul disco esterno non vengono toccati.", "macOS removes them by itself after 24 hours or when space is needed. Mac Mop can delete them now with the administrator password; backups on the external disk are not touched.")
        case .purgeable: UIText.t("Non serve fare nulla: questo spazio conta già come disponibile per le app.", "Nothing to do: this space already counts as available for apps.")
        case .vmSwap: UIText.t("Chiudi le app che usano molta memoria o riavvia il Mac: i file di scambio si riducono da soli. Non eliminarli.", "Quit apps that use lots of memory or restart the Mac: swap files shrink by themselves. Do not delete them.")
        case .appleIntelligence: UIText.t("Per recuperare questo spazio disattiva Apple Intelligence in Impostazioni di Sistema › Apple Intelligence e Siri; macOS rimuove i modelli nei giorni seguenti. Mac Mop non li tocca: sono protetti dal sistema.", "To reclaim this space, turn off Apple Intelligence in System Settings › Apple Intelligence & Siri; macOS removes the models over the following days. Mac Mop does not touch them: the system protects them.")
        case .systemAssets: UIText.t("Gestite da macOS, che rimuove quelle non usate. Puoi eliminare voci e lingue in Impostazioni › Accessibilità › Contenuto letto ad alta voce.", "Managed by macOS, which removes unused ones. You can delete voices and languages in Settings › Accessibility › Spoken Content.")
        case .aerials: UIText.t("Mac Mop può spostare nel Cestino i video della tua cartella; macOS riscarica quello che usi come sfondo. I video in /Library sono di sistema: per ridurli scegli uno sfondo non Aerial e disattiva il download automatico in Impostazioni › Sfondo.", "Mac Mop can move the videos in your folder to the Trash; macOS downloads again the one you use as wallpaper. Videos in /Library belong to the system: to reduce them pick a non-Aerial wallpaper and turn off automatic download in Settings › Wallpaper.")
        case .userCaches, .systemCaches, .simulatorCaches, .xcodeDerivedData, .xcodeDeviceSupport, .devCaches:
            UIText.t("Mac Mop può spostarle nel Cestino: si ricreano da sole. Puoi annullare da Cronologia pulizie.", "Mac Mop can move them to the Trash: they rebuild themselves. You can undo from Cleanup History.")
        case .mailDownloads, .userLogs, .systemLogs:
            UIText.t("Mac Mop può spostarli nel Cestino. Puoi annullare da Cronologia pulizie.", "Mac Mop can move them to the Trash. You can undo from Cleanup History.")
        case .tempFiles: UIText.t("Non eliminarli mentre le app sono aperte: riavvia il Mac e macOS li svuota.", "Do not delete them while apps are open: restart the Mac and macOS empties them.")
        case .unifiedLogs: UIText.t("Nessuna azione: macOS mantiene il registro entro una dimensione fissa.", "No action: macOS keeps the log within a fixed size.")
        case .spotlight: UIText.t("Se è molto grande puoi ricostruirlo: Impostazioni › Spotlight › Privacy, aggiungi e rimuovi il disco.", "If it is very large you can rebuild it: Settings › Spotlight › Privacy, add and remove the disk.")
        case .iosBackups: UIText.t("Controlla nome e data del dispositivo: se hai un backup più recente o su iCloud, Mac Mop può spostare quello vecchio nel Cestino.", "Check the device name and date: if you have a newer backup or one in iCloud, Mac Mop can move the old one to the Trash.")
        case .xcodeArchives: UIText.t("Tieni gli archivi delle versioni pubblicate se devi leggere i loro crash; gli altri possono andare nel Cestino.", "Keep archives of released versions if you need to read their crash reports; the others can go to the Trash.")
        case .simulatorDevices: UIText.t("Elimina i simulatori inutilizzati con «xcrun simctl delete unavailable» e i runtime in Xcode › Impostazioni › Componenti.", "Delete unused simulators with \"xcrun simctl delete unavailable\" and runtimes in Xcode › Settings › Components.")
        case .installers: UIText.t("Gli installer di macOS in Applicazioni possono andare nel Cestino se non ti servono per installare. /Library/Updates è gestita da Aggiornamento Software.", "macOS installers in Applications can go to the Trash if you do not need them to install. /Library/Updates is managed by Software Update.")
        case .messages: UIText.t("Apri Messaggi › Impostazioni e scegli di conservare i messaggi per 1 anno, oppure elimina gli allegati grandi da Gestisci archiviazione.", "Open Messages › Settings and keep messages for 1 year, or delete large attachments from Manage Storage.")
        case .mediaAnalysis: UIText.t("Gestita da macOS. Non eliminarla: verrebbe rifatta consumando batteria per giorni.", "Managed by macOS. Do not delete it: it would be redone, using battery for days.")
        case .virtualMachines: UIText.t("Elimina le macchine virtuali e le immagini dall'app che le ha create (per Docker: Spazio extra › Pulisci). Mac Mop non le tocca.", "Delete virtual machines and images from the app that created them (for Docker: Extra space › Clean). Mac Mop does not touch them.")
        case .pnpmStore: UIText.t("Esegui «pnpm store prune» nel Terminale: rimuove solo i pacchetti non usati da nessun progetto.", "Run \"pnpm store prune\" in Terminal: it removes only packages no project uses.")
        case .appContainers: UIText.t("Sono dati delle app: libera spazio dalle impostazioni di ogni app (per esempio la cache di Telegram o WhatsApp) o disinstalla le app che non usi.", "This is app data: free space from each app's settings (for example the Telegram or WhatsApp cache) or uninstall apps you do not use.")
        case .trash: UIText.t("Svuota il Cestino dalla sezione Cestini. È definitivo.", "Empty the Trash from the Trash Bins section. It is permanent.")
        }
    }

    // MARK: iOS backups

    /// Device name and last backup date from a backup's Info.plist.
    public static func backupSummary(infoPlist: [String: Any]) -> (name: String?, date: Date?, model: String?) {
        let name = (infoPlist["Device Name"] as? String) ?? (infoPlist["Display Name"] as? String)
        return (name, infoPlist["Last Backup Date"] as? Date, infoPlist["Product Type"] as? String)
    }
}
