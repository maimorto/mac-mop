import Foundation

// "Launch items" inventory: every place macOS lets software start itself
// automatically, reduced to a plain list the user can read.
//
// The list of mechanisms and the folders they live in follows
// MacPersistenceChecker (MIT, © 2024 pinperepette,
// https://github.com/Pinperepette/MacPersistenceChecker), extended with
// at jobs, emond, StartupItems, rc files, sudoers, PAM, DYLD injection and
// browser extensions. See THIRD_PARTY_NOTICES.md. The code is our own.

/// One way macOS can start software automatically.
public enum PersistenceMechanism: String, CaseIterable, Codable, Sendable, Comparable {
    case userLaunchAgents
    case systemLaunchAgents
    case launchDaemons
    case backgroundItems
    case legacyLoginItems
    case privilegedHelpers
    case kernelExtensions
    case systemExtensions
    case configurationProfiles
    case cron
    case atJobs
    case periodic
    case emond
    case startupItems
    case rcScripts
    case loginHooks
    case authorizationPlugins
    case directoryServicesPlugins
    case pam
    case sudoers
    case dyldInjection
    case shellStartup
    case spotlightImporters
    case quickLookPlugins
    case appExtensions
    case browserExtensions

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .userLaunchAgents: UIText.t("Agenti del tuo utente", "Your launch agents")
        case .systemLaunchAgents: UIText.t("Agenti per tutti gli utenti", "Launch agents for all users")
        case .launchDaemons: UIText.t("Servizi di sistema (daemon)", "System services (daemons)")
        case .backgroundItems: UIText.t("Elementi di login e in background", "Login and background items")
        case .legacyLoginItems: UIText.t("Elementi di login (vecchio elenco)", "Login items (legacy list)")
        case .privilegedHelpers: UIText.t("Strumenti con privilegi", "Privileged helper tools")
        case .kernelExtensions: UIText.t("Estensioni del kernel", "Kernel extensions")
        case .systemExtensions: UIText.t("Estensioni di sistema", "System extensions")
        case .configurationProfiles: UIText.t("Profili di configurazione", "Configuration profiles")
        case .cron: UIText.t("Operazioni pianificate (cron)", "Scheduled jobs (cron)")
        case .atJobs: UIText.t("Operazioni una tantum (at)", "One-off jobs (at)")
        case .periodic: UIText.t("Script periodici", "Periodic scripts")
        case .emond: UIText.t("Regole emond", "emond rules")
        case .startupItems: UIText.t("StartupItems", "StartupItems")
        case .rcScripts: UIText.t("File di avvio rc / launchd.conf", "rc / launchd.conf startup files")
        case .loginHooks: UIText.t("Hook di login e logout", "Login and logout hooks")
        case .authorizationPlugins: UIText.t("Plug-in di autorizzazione", "Authorization plug-ins")
        case .directoryServicesPlugins: UIText.t("Plug-in di Directory Services", "Directory Services plug-ins")
        case .pam: UIText.t("Moduli PAM", "PAM modules")
        case .sudoers: UIText.t("Regole sudo (sudoers.d)", "sudo rules (sudoers.d)")
        case .dyldInjection: UIText.t("Librerie iniettate (DYLD)", "Injected libraries (DYLD)")
        case .shellStartup: UIText.t("File di avvio del Terminale", "Terminal startup files")
        case .spotlightImporters: UIText.t("Plug-in di Spotlight", "Spotlight importers")
        case .quickLookPlugins: UIText.t("Plug-in di Quick Look", "Quick Look plug-ins")
        case .appExtensions: UIText.t("Estensioni delle app", "App extensions")
        case .browserExtensions: UIText.t("Estensioni dei browser", "Browser extensions")
        }
    }

    public var symbol: String {
        switch self {
        case .userLaunchAgents: "person.crop.circle.badge.clock"
        case .systemLaunchAgents: "person.2.badge.gearshape"
        case .launchDaemons: "gearshape.2.fill"
        case .backgroundItems: "power.circle.fill"
        case .legacyLoginItems: "list.bullet.rectangle"
        case .privilegedHelpers: "lock.shield.fill"
        case .kernelExtensions: "cpu.fill"
        case .systemExtensions: "puzzlepiece.extension.fill"
        case .configurationProfiles: "gear.badge.checkmark"
        case .cron: "clock.arrow.circlepath"
        case .atJobs: "timer"
        case .periodic: "calendar.badge.clock"
        case .emond: "bell.badge"
        case .startupItems: "play.circle"
        case .rcScripts: "doc.text"
        case .loginHooks: "arrow.right.circle.fill"
        case .authorizationPlugins: "person.badge.key.fill"
        case .directoryServicesPlugins: "folder.badge.gearshape"
        case .pam: "key.horizontal.fill"
        case .sudoers: "terminal.fill"
        case .dyldInjection: "syringe.fill"
        case .shellStartup: "apple.terminal.fill"
        case .spotlightImporters: "magnifyingglass"
        case .quickLookPlugins: "eye.fill"
        case .appExtensions: "square.on.square.badge.person.crop"
        case .browserExtensions: "safari.fill"
        }
    }

    /// What this mechanism is, in one or two plain sentences.
    public var explanation: String {
        switch self {
        case .userLaunchAgents:
            UIText.t("Programmi che macOS avvia quando entri nel tuo account. Li installano app come Google, Zoom o Dropbox per aggiornarsi o restare in ascolto. Il malware li usa per ripartire a ogni accesso.",
                     "Programs macOS starts when you log in to your account. Apps like Google, Zoom or Dropbox install them to update themselves or stay ready. Malware uses them to come back at every login.")
        case .systemLaunchAgents:
            UIText.t("Come gli agenti del tuo utente, ma partono per chiunque accede a questo Mac. Installarli richiede la password di amministratore.",
                     "Like your launch agents, but they start for everyone who logs in to this Mac. Installing them requires an administrator password.")
        case .launchDaemons:
            UIText.t("Servizi che girano come root anche prima del login: driver, VPN, antivirus, aggiornamenti. Sono potenti, quindi devono venire da sviluppatori di cui ti fidi.",
                     "Services that run as root even before login: drivers, VPNs, antivirus, updaters. They are powerful, so they should come from developers you trust.")
        case .backgroundItems:
            UIText.t("Le app e i loro aiutanti che macOS elenca in Impostazioni › Generali › Elementi di login. Si possono attivare o disattivare lì.",
                     "Apps and their helpers that macOS lists in Settings › General › Login Items. You can turn them on or off there.")
        case .legacyLoginItems:
            UIText.t("Il vecchio elenco di app da aprire al login, ancora letto per compatibilità.",
                     "The old list of apps to open at login, still read for compatibility.")
        case .privilegedHelpers:
            UIText.t("Piccoli programmi che un'app installa per fare operazioni da amministratore senza chiederti ogni volta la password. Restano anche dopo aver cancellato l'app.",
                     "Small programs an app installs to do administrator tasks without asking for your password each time. They stay even after you delete the app.")
        case .kernelExtensions:
            UIText.t("Driver che girano dentro il cuore di macOS. Sono quasi tutti obsoleti: su Apple Silicon richiedono di abbassare la sicurezza.",
                     "Drivers that run inside the core of macOS. Most are obsolete: on Apple Silicon they require lowering security.")
        case .systemExtensions:
            UIText.t("Il sostituto moderno delle estensioni del kernel: VPN, firewall, antivirus, driver. Si gestiscono in Impostazioni › Generali › Elementi di login ed estensioni.",
                     "The modern replacement for kernel extensions: VPNs, firewalls, antivirus, drivers. Managed in Settings › General › Login Items & Extensions.")
        case .configurationProfiles:
            UIText.t("Profili che impostano regole sul Mac (Wi-Fi aziendale, VPN, restrizioni). Un profilo sconosciuto può dirottare il browser o il DNS: l'adware li usa.",
                     "Profiles that set rules on the Mac (company Wi-Fi, VPN, restrictions). An unknown profile can hijack the browser or DNS: adware uses them.")
        case .cron:
            UIText.t("Comandi ripetuti a orari fissi, un sistema Unix molto vecchio. Oggi poche app lo usano; una voce che non riconosci va controllata.",
                     "Commands repeated at fixed times, a very old Unix system. Few apps use it today; an entry you don't recognise needs a look.")
        case .atJobs:
            UIText.t("Comandi programmati per partire una volta a un'ora precisa. Su macOS è spento di serie.",
                     "Commands scheduled to run once at a given time. Off by default on macOS.")
        case .periodic:
            UIText.t("Script di manutenzione giornalieri, settimanali e mensili. Uno script aggiunto qui gira come root.",
                     "Daily, weekly and monthly maintenance scripts. A script added here runs as root.")
        case .emond:
            UIText.t("Un vecchio servizio di macOS che esegue azioni su eventi. Apple l'ha rimosso; regole presenti qui sono sospette.",
                     "An old macOS service that runs actions on events. Apple removed it; rules found here are suspicious.")
        case .startupItems:
            UIText.t("Il sistema di avvio usato prima di Mac OS X 10.4. macOS non li esegue più, ma la loro presenza è insolita.",
                     "The startup system used before Mac OS X 10.4. macOS no longer runs them, but their presence is unusual.")
        case .rcScripts:
            UIText.t("File di avvio Unix (/etc/rc.local, /etc/launchd.conf). macOS moderno non li usa: se esistono, qualcuno li ha creati.",
                     "Unix startup files (/etc/rc.local, /etc/launchd.conf). Modern macOS doesn't use them: if they exist, someone created them.")
        case .loginHooks:
            UIText.t("Script eseguiti come root a ogni login o logout. Apple li sconsiglia da anni.",
                     "Scripts run as root at every login or logout. Apple has discouraged them for years.")
        case .authorizationPlugins:
            UIText.t("Plug-in che partecipano alla schermata di login e alle richieste di password. Vedono la tua password: devono essere di aziende fidate.",
                     "Plug-ins that take part in the login window and password prompts. They see your password: they must come from trusted companies.")
        case .directoryServicesPlugins:
            UIText.t("Plug-in per collegare il Mac a server di account aziendali. Rari fuori dalle aziende.",
                     "Plug-ins that connect the Mac to company account servers. Rare outside companies.")
        case .pam:
            UIText.t("Moduli che decidono come vengono verificate le password (login, sudo). Un modulo non di Apple può leggerle; sono normali quelli per Touch ID nel Terminale.",
                     "Modules that decide how passwords are checked (login, sudo). A non-Apple module can read them; Touch ID-for-Terminal ones are normal.")
        case .sudoers:
            UIText.t("Regole che permettono a utenti o programmi di usare sudo, a volte senza password.",
                     "Rules that let users or programs use sudo, sometimes without a password.")
        case .dyldInjection:
            UIText.t("Istruzioni che fanno caricare una libreria dentro altri programmi (DYLD_INSERT_LIBRARIES). È una tecnica tipica di malware e cheat.",
                     "Instructions that load a library into other programs (DYLD_INSERT_LIBRARIES). A typical malware and cheat technique.")
        case .shellStartup:
            UIText.t("File che il Terminale esegue a ogni apertura (.zshrc, .zprofile…). Sviluppatori e strumenti come Homebrew li modificano spesso; segnaliamo solo le righe che fanno cose pericolose.",
                     "Files Terminal runs every time it opens (.zshrc, .zprofile…). Developers and tools like Homebrew edit them often; we only flag lines that do dangerous things.")
        case .spotlightImporters:
            UIText.t("Plug-in che leggono il contenuto dei file per la ricerca Spotlight. Partono da soli quando un file cambia.",
                     "Plug-ins that read file contents for Spotlight search. They start by themselves when a file changes.")
        case .quickLookPlugins:
            UIText.t("Plug-in che creano anteprime e miniature nel Finder. Partono quando guardi un file.",
                     "Plug-ins that make previews and thumbnails in Finder. They start when you look at a file.")
        case .appExtensions:
            UIText.t("Estensioni delle app di terze parti: integrazione con il Finder, condivisione, widget. Girano solo quando le usi, tranne quelle del Finder che restano attive.",
                     "Third-party app extensions: Finder integration, sharing, widgets. They run only when used, except Finder ones, which stay active.")
        case .browserExtensions:
            UIText.t("Componenti aggiuntivi di Safari, Chrome, Firefox e simili. Possono leggere le pagine che visiti.",
                     "Add-ons for Safari, Chrome, Firefox and similar. They can read the pages you visit.")
        }
    }

    /// What can't be read without an administrator password, if anything.
    public var adminNote: String? {
        switch self {
        case .cron: UIText.t("Le tabelle cron di altri utenti e di root si leggono solo con la password di amministratore.", "Other users' and root's cron tables can only be read with an administrator password.")
        case .atJobs: UIText.t("Il contenuto dei job si legge solo con la password di amministratore.", "Job contents can only be read with an administrator password.")
        case .configurationProfiles: UIText.t("L'elenco completo dei profili richiede la password di amministratore.", "The full list of profiles requires an administrator password.")
        case .sudoers: UIText.t("Il contenuto delle regole si legge solo con la password di amministratore.", "Rule contents can only be read with an administrator password.")
        case .loginHooks: UIText.t("Gli hook impostati per root si leggono solo con la password di amministratore.", "Hooks set for root can only be read with an administrator password.")
        case .backgroundItems: UIText.t("Se il database di macOS non è leggibile, serve l'accesso completo al disco.", "If macOS's database is not readable, Full Disk Access is needed.")
        default: nil
        }
    }

    /// Mechanisms whose items are rare and powerful: anything non-Apple
    /// there is at least worth a look.
    public var isRareAndPowerful: Bool {
        switch self {
        case .emond, .startupItems, .rcScripts, .loginHooks, .authorizationPlugins, .directoryServicesPlugins,
             .pam, .sudoers, .dyldInjection, .periodic, .atJobs, .configurationProfiles:
            true
        default:
            false
        }
    }
}

/// Who signed the code an item runs.
public struct PersistenceSignature: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Apple's own software.
        case apple
        /// Mac App Store.
        case appStore
        /// Valid Developer ID signature.
        case developerID
        /// Valid signature from an Apple Development certificate: meant for
        /// testing, not distribution (Gatekeeper rejects it from the web).
        case development
        /// Ad-hoc: built locally (or by malware), no identity.
        case adHoc
        /// No signature, or one from an unknown certificate.
        case unsigned
        /// Signed, but changed after signing: cracked, patched or damaged.
        case modified
        /// The developer's certificate was revoked by Apple (malware authors).
        case revoked
        /// Not code (a configuration file, a text rule).
        case notCode
        /// The program the item points to does not exist.
        case missing
        /// Not checked: it sits in a folder macOS protects (Documents,
        /// Desktop, Downloads, iCloud Drive) and reading it would make macOS
        /// ask for permission.
        case unverified
    }

    public var kind: Kind
    public var teamID: String?
    public var teamName: String?
    /// Checked by Apple's notary service. Nil when not applicable / unknown.
    public var notarized: Bool?

    public init(kind: Kind, teamID: String? = nil, teamName: String? = nil, notarized: Bool? = nil) {
        self.kind = kind
        self.teamID = teamID
        self.teamName = teamName
        self.notarized = notarized
    }

    public var isTrusted: Bool { kind == .apple || kind == .appStore || kind == .developerID }

    /// What the behaviour engine (`PersistenceAudit`) expects.
    public var codeSignatureStatus: CodeSignatureStatus {
        switch kind {
        case .apple: .apple
        case .appStore, .developerID: .developerID(team: teamID)
        case .adHoc, .development: .adHoc
        case .unsigned, .modified, .revoked, .notCode, .missing, .unverified: .unsigned
        }
    }

    /// "Google LLC (EQHXZ8M8AV)" out of a leaf certificate's subject summary
    /// like "Developer ID Application: Google LLC (EQHXZ8M8AV)".
    public static func teamName(fromCertificateSummary summary: String) -> String? {
        var name = summary
        for prefix in ["Developer ID Application:", "Developer ID Installer:", "Apple Development:",
                       "Apple Distribution:", "3rd Party Mac Developer Application:", "Mac Developer:"]
        where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }

    /// One short line for a row: "Apple", "Google LLC", "Unsigned"…
    public var shortLabel: String {
        switch kind {
        case .apple: "Apple"
        case .appStore: "Mac App Store"
        case .developerID: teamName ?? teamID ?? UIText.t("Sviluppatore identificato", "Identified developer")
        case .development: UIText.t("Certificato di sviluppo: \(teamName ?? teamID ?? "?")", "Development certificate: \(teamName ?? teamID ?? "?")")
        case .adHoc: UIText.t("Firma locale (ad-hoc)", "Locally signed (ad-hoc)")
        case .unsigned: UIText.t("Non firmato", "Unsigned")
        case .modified:
            if let name = teamName ?? teamID { UIText.t("Firma non valida (\(name))", "Invalid signature (\(name))") }
            else { UIText.t("Firma non valida", "Invalid signature") }
        case .revoked: UIText.t("Certificato revocato", "Revoked certificate")
        case .notCode: UIText.t("File di configurazione", "Configuration file")
        case .missing: UIText.t("Programma mancante", "Program missing")
        case .unverified: UIText.t("Non verificato", "Not verified")
        }
    }

    /// Longer explanation for the detail view.
    public var explanation: String {
        switch kind {
        case .apple:
            UIText.t("Software di Apple.", "Apple software.")
        case .appStore:
            UIText.t("Scaricato dal Mac App Store e controllato da Apple.", "Downloaded from the Mac App Store and checked by Apple.")
        case .developerID:
            notarized == true
                ? UIText.t("Firmato da uno sviluppatore registrato presso Apple e autenticato (notarizzato) da Apple.",
                           "Signed by a developer registered with Apple and notarized by Apple.")
                : UIText.t("Firmato da uno sviluppatore registrato presso Apple, ma non autenticato (notarizzato). Normale per software vecchio.",
                           "Signed by a developer registered with Apple, but not notarized. Normal for older software.")
        case .development:
            UIText.t("Firmato con un certificato da sviluppatore pensato per i test, non per distribuire app: Gatekeeper non lo accetterebbe se scaricato da internet. Capita con piccoli progetti open source; verifica di riconoscerlo.",
                     "Signed with a developer certificate meant for testing, not for distributing apps: Gatekeeper would reject it if downloaded from the internet. It happens with small open-source projects; check you recognise it.")
        case .adHoc:
            UIText.t("Firmato sul posto, senza identità: normale per strumenti compilati da te (Homebrew, progetti), insolito per un'app scaricata.",
                     "Signed on the spot with no identity: normal for tools you built (Homebrew, projects), unusual for a downloaded app.")
        case .unsigned:
            UIText.t("Nessuna firma valida: non si sa chi l'ha creato.", "No valid signature: nobody knows who made it.")
        case .modified:
            UIText.t("È stato modificato dopo la firma dello sviluppatore: succede con app craccate o «patchate» (un modo comune di diffondere malware), con plug-in aggiunti dentro l'app o con file danneggiati. Reinstallalo dal sito ufficiale.",
                     "It was changed after the developer signed it: this happens with cracked or patched apps (a common way to spread malware), with add-ons put inside the app, or with damaged files. Reinstall it from the official site.")
        case .revoked:
            UIText.t("Apple ha revocato il certificato dello sviluppatore, di solito perché distribuiva malware.",
                     "Apple revoked the developer's certificate, usually because it distributed malware.")
        case .notCode:
            UIText.t("È un file di testo o di impostazioni, non un programma.", "It is a text or settings file, not a program.")
        case .missing:
            UIText.t("Il programma indicato non esiste più: probabilmente un resto di un'app disinstallata.",
                     "The program it points to no longer exists: probably a leftover of an uninstalled app.")
        case .unverified:
            UIText.t("Si trova in una cartella protetta (Documenti, Scrivania, Download, iCloud Drive): concedi l'accesso completo al disco per verificarne la firma. Un programma di avvio lì è insolito.",
                     "It sits in a protected folder (Documents, Desktop, Downloads, iCloud Drive): grant Full Disk Access to check its signature. A launch program there is unusual.")
        }
    }
}

/// How worried the user should be about an item.
public enum PersistenceRisk: String, Codable, Sendable, Comparable, CaseIterable {
    case safe
    case review
    case suspicious

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var label: String {
        switch self {
        case .safe: UIText.t("Sicuro", "Safe")
        case .review: UIText.t("Da controllare", "Review")
        case .suspicious: UIText.t("Sospetto", "Suspicious")
        }
    }
}

/// One thing that starts automatically.
public struct PersistenceItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable across scans: mechanism + the file or identifier it lives in.
    public var id: String
    public var mechanism: PersistenceMechanism
    public var name: String
    /// The file that sets it up (plist, crontab, rc file…), if any.
    public var path: String?
    /// The program or bundle that runs, if known.
    public var program: String?
    public var arguments: [String]
    public var label: String?
    public var signature: PersistenceSignature
    public var addedDate: Date?
    /// Nil when macOS has no on/off notion for it or it can't be read.
    public var enabled: Bool?
    public var running: Bool
    public var risk: PersistenceRisk
    /// Plain-language reasons for `risk`, most important first.
    public var reasons: [String]
    /// Extra facts for the detail view ("Starts at login", "Kept alive"…).
    public var facts: [String]
    /// True when the item is off because the user switched it off in
    /// System Settings › Login Items (only Settings can switch it back on).
    /// Optional so snapshots saved before this field still decode.
    public var disabledInSettings: Bool?

    public init(id: String, mechanism: PersistenceMechanism, name: String, path: String? = nil, program: String? = nil,
                arguments: [String] = [], label: String? = nil, signature: PersistenceSignature = .init(kind: .notCode),
                addedDate: Date? = nil, enabled: Bool? = nil, running: Bool = false, risk: PersistenceRisk = .safe,
                reasons: [String] = [], facts: [String] = []) {
        self.id = id
        self.mechanism = mechanism
        self.name = name
        self.path = path
        self.program = program
        self.arguments = arguments
        self.label = label
        self.signature = signature
        self.addedDate = addedDate
        self.enabled = enabled
        self.running = running
        self.risk = risk
        self.reasons = reasons
        self.facts = facts
    }

    /// Apple's own software (used by the "non-Apple only" filter).
    public var isApple: Bool {
        if signature.kind == .apple { return true }
        if signature.kind == .notCode, let path, path.hasPrefix("/System/") { return true }
        if let label, label.hasPrefix("com.apple."), signature.kind == .apple { return true }
        return false
    }
}

/// Result of one inventory run.
public struct PersistenceInventory: Codable, Sendable {
    public var date: Date
    public var items: [PersistenceItem]
    /// Mechanisms that could not be read fully, with the reason.
    public var limits: [PersistenceMechanism: String]

    public init(date: Date = Date(), items: [PersistenceItem], limits: [PersistenceMechanism: String] = [:]) {
        self.date = date
        self.items = items
        self.limits = limits
    }

    public func items(for mechanism: PersistenceMechanism) -> [PersistenceItem] {
        items.filter { $0.mechanism == mechanism }
    }
}

// MARK: - Risk

/// Turns signature + behaviour findings into Safe / Review / Suspicious with
/// plain-language reasons. Pure.
public enum PersistenceRiskAssessor {
    public struct Input: Sendable {
        public var mechanism: PersistenceMechanism
        public var signature: PersistenceSignature
        /// From `PersistenceAudit` / `ThreatCommandAnalyzer`.
        public var findings: [ThreatFinding]
        /// Where the program lives (drop zones raise the risk).
        public var location: ThreatLocation?
        /// DYLD_INSERT_LIBRARIES or similar in the item's environment.
        public var injectsLibraries: Bool
        /// The item is a configuration entry whose mere presence is unusual
        /// (rc.local, emond rule, login hook…).
        public var unusualPresence: Bool

        public init(mechanism: PersistenceMechanism, signature: PersistenceSignature, findings: [ThreatFinding] = [],
                    location: ThreatLocation? = nil, injectsLibraries: Bool = false, unusualPresence: Bool = false) {
            self.mechanism = mechanism
            self.signature = signature
            self.findings = findings
            self.location = location
            self.injectsLibraries = injectsLibraries
            self.unusualPresence = unusualPresence
        }
    }

    public static func assess(_ input: Input) -> (risk: PersistenceRisk, reasons: [String]) {
        var risk = PersistenceRisk.safe
        var reasons: [String] = []
        func raise(_ to: PersistenceRisk, _ reason: String) {
            if to > risk { risk = to }
            reasons.append(reason)
        }

        for finding in input.findings.sorted(by: { $0.severity > $1.severity }) {
            raise(finding.severity == .high ? .suspicious : .review, "\(finding.rule.title): \(finding.rule.explanation)")
        }
        if input.injectsLibraries {
            raise(.suspicious, UIText.t("Fa caricare una libreria dentro altri programmi (DYLD_INSERT_LIBRARIES).",
                                        "Loads a library into other programs (DYLD_INSERT_LIBRARIES)."))
        }
        switch input.signature.kind {
        case .revoked:
            raise(.suspicious, input.signature.explanation)
        case .unsigned, .modified:
            raise(.review, input.signature.explanation)
        case .adHoc, .development:
            raise(.review, input.signature.explanation)
        case .missing, .unverified:
            raise(.review, input.signature.explanation)
        case .apple, .appStore, .developerID, .notCode:
            break
        }
        if let location = input.location, location.isDropZone, !input.signature.isTrusted, input.signature.kind != .notCode {
            raise(.review, UIText.t("Il programma è in una cartella nascosta o temporanea, dove di solito non stanno le app.",
                                    "The program is in a hidden or temporary folder, where apps don't usually live."))
        }
        if input.unusualPresence {
            raise(.review, UIText.t("macOS non usa più questo meccanismo: se c'è, qualcuno l'ha aggiunto.",
                                    "macOS no longer uses this mechanism: if it is here, someone added it."))
        } else if input.mechanism.isRareAndPowerful, input.signature.kind != .apple, risk == .safe, !input.signature.isTrusted {
            raise(.review, UIText.t("Meccanismo raro e potente: verifica di riconoscere chi l'ha installato.",
                                    "A rare, powerful mechanism: check you recognise who installed it."))
        }
        if reasons.isEmpty {
            reasons.append(input.signature.kind == .apple
                ? UIText.t("Fa parte di macOS.", "Part of macOS.")
                : input.signature.isTrusted
                    ? UIText.t("Firmato da uno sviluppatore identificato e nessun comportamento sospetto.",
                               "Signed by an identified developer, no suspicious behaviour.")
                    : UIText.t("Nessun comportamento sospetto trovato.", "No suspicious behaviour found."))
        }
        return (risk, reasons)
    }
}

// MARK: - Snapshot (before/after install diff)

/// The inventory saved by "Take snapshot", compared later to see what an
/// installer added.
public struct PersistenceSnapshot: Codable, Sendable {
    public var date: Date
    public var items: [PersistenceItem]

    public init(date: Date = Date(), items: [PersistenceItem]) {
        self.date = date
        self.items = items
    }

    public struct Diff: Sendable {
        public var added: [PersistenceItem]
        public var removed: [PersistenceItem]
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// Items present now and not in the snapshot, and vice versa. Matched
    /// by id; an item whose program changed counts as removed + added.
    public func compare(with current: [PersistenceItem]) -> Diff {
        func key(_ item: PersistenceItem) -> String { item.id + "\u{1}" + (item.program ?? "") }
        let before = Set(items.map(key))
        let now = Set(current.map(key))
        return Diff(
            added: current.filter { !before.contains(key($0)) }.sorted { ($0.mechanism, $0.name) < ($1.mechanism, $1.name) },
            removed: items.filter { !now.contains(key($0)) }.sorted { ($0.mechanism, $0.name) < ($1.mechanism, $1.name) })
    }

    public static var defaultURL: URL {
        MCConstants.userAppSupport.appending(path: MCConstants.dataFolderName).appending(path: "persistence-snapshot.json")
    }

    public func save(to url: URL = Self.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL = defaultURL) -> PersistenceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistenceSnapshot.self, from: data)
    }
}
