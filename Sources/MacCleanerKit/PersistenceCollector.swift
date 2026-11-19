import Foundation

/// Builds the launch-items inventory from unprivileged sources only: plist
/// folders, `launchctl print` / `print-disabled`, the Login Items database
/// when it is readable, `pluginkit`, `systemextensionsctl list`,
/// `crontab -l`, `atq`. Nothing here asks for a password: what needs one is
/// reported in `PersistenceInventory.limits` instead.
public struct PersistenceCollector: Sendable {
    public var home: URL
    public var uid: UInt32
    public var signature: @Sendable (URL) -> PersistenceSignature
    /// Without it, files in folders macOS protects are never touched (not
    /// even their dates): reading them would pop a permission prompt.
    public var hasFullDiskAccess: Bool

    public init(home: URL = MCConstants.home, uid: UInt32 = getuid(),
                hasFullDiskAccess: Bool = PersistenceCollector.detectFullDiskAccess(),
                signature: @escaping @Sendable (URL) -> PersistenceSignature = { PersistenceCodeSigning.signature(of: $0) }) {
        self.home = home
        self.uid = uid
        self.hasFullDiskAccess = hasFullDiskAccess
        self.signature = signature
    }

    /// Opening the system TCC database fails silently without Full Disk
    /// Access (no prompt), so it is a safe probe.
    public static func detectFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Folders where touching a file makes macOS ask the user for
    /// permission (Documents, Desktop, Downloads, iCloud Drive, media
    /// libraries, other apps' containers, external volumes).
    public static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        if path.hasPrefix("/Volumes/") { return true }
        guard path.hasPrefix(home + "/") else { return false }
        let rest = String(path.dropFirst(home.count + 1))
        let protected = ["Desktop/", "Documents/", "Downloads/", "Pictures/", "Movies/", "Music/",
                         "Library/Mobile Documents/", "Library/Containers/", "Library/Group Containers/",
                         "Library/Mail/", "Library/Messages/", "Library/Safari/", "Library/Calendars/",
                         "Library/Application Support/AddressBook/", "Library/Application Support/com.apple.TCC/",
                         "Library/CloudStorage/"]
        return protected.contains { rest.hasPrefix($0) || rest + "/" == $0 }
    }

    func mayTouch(_ path: String) -> Bool {
        hasFullDiskAccess || !Self.isPrivacyProtected(path, home: homePath)
    }

    /// An item before its signature is read and its risk assessed.
    struct Draft {
        var item: PersistenceItem
        var signatureURL: URL?
        var launchRecord: LaunchItemRecord?
        var findings: [ThreatFinding] = []
        var injects = false
        var unusual = false
        /// The signature to use when it can't be read from a file.
        var fixedSignature: PersistenceSignature?
    }

    private var fm: FileManager { .default }
    private var homePath: String { home.path(percentEncoded: false) }

    public func collect(progress: @escaping @Sendable (String) -> Void = { _ in }) async -> PersistenceInventory {
        var limits: [PersistenceMechanism: String] = [:]
        progress(UIText.t("Lettura dei servizi di avvio…", "Reading launch services…"))
        async let guiServices = run("/bin/launchctl", ["print", "gui/\(uid)"])
        async let systemServices = run("/bin/launchctl", ["print", "system"])
        async let guiDisabled = run("/bin/launchctl", ["print-disabled", "gui/\(uid)"])
        async let systemDisabled = run("/bin/launchctl", ["print-disabled", "system"])
        async let crontab = run("/usr/bin/crontab", ["-l"])
        async let atq = run("/usr/bin/atq", [])
        async let plugins = run("/usr/bin/pluginkit", ["-mAvvv"], timeout: .seconds(30))
        async let sysexts = run("/usr/bin/systemextensionsctl", ["list"])
        async let dyldEnv = run("/bin/launchctl", ["getenv", "DYLD_INSERT_LIBRARIES"])

        let running = LaunchctlParser.services(await guiServices ?? "")
            .merging(LaunchctlParser.services(await systemServices ?? "")) { $0 || $1 }
        let userOverrides = LaunchctlParser.disabledOverrides(await guiDisabled ?? "")
        let systemOverrides = LaunchctlParser.disabledOverrides(await systemDisabled ?? "")

        let btm = readBTM()
        if btm == nil {
            limits[.backgroundItems] = UIText.t("Il database degli elementi di login non è leggibile: concedi l'accesso completo al disco per vederlo. L'elenco completo con «sfltool dumpbtm» richiede la password di amministratore.",
                                                "The Login Items database is not readable: grant Full Disk Access to see it. The full list via “sfltool dumpbtm” requires an administrator password.")
        }
        let btmByPlist = Dictionary((btm ?? []).compactMap { r in r.url.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })

        var drafts: [Draft] = []
        drafts += launchItems(running: running, userOverrides: userOverrides, systemOverrides: systemOverrides, btmByPlist: btmByPlist)
        let listedPlists = Set(drafts.compactMap(\.item.path))
        drafts += backgroundItems(btm ?? [], listedPlists: listedPlists)
        drafts += legacyLoginItems(excluding: Set(drafts.compactMap(\.item.program)))
        drafts += privilegedHelpers()
        progress(UIText.t("Lettura di estensioni e plug-in…", "Reading extensions and plug-ins…"))
        drafts += kernelExtensions()
        drafts += systemExtensions(await sysexts ?? "")
        drafts += configurationProfiles()
        drafts += cronJobs(await crontab ?? "")
        drafts += atJobs(await atq ?? "")
        drafts += periodicScripts()
        drafts += legacyStartup()
        drafts += loginHooks()
        drafts += bundles(in: ["/Library/Security/SecurityAgentPlugins"], extensions: ["bundle", "plugin"], mechanism: .authorizationPlugins)
        drafts += bundles(in: ["/Library/DirectoryServices/PlugIns"], extensions: ["dsplug", "plugin"], mechanism: .directoryServicesPlugins)
        drafts += pamModules()
        drafts += sudoersRules()
        drafts += dyldInjection(launchctlEnv: await dyldEnv ?? "")
        drafts += shellStartupFiles()
        drafts += bundles(in: ["/Library/Spotlight", "\(homePath)/Library/Spotlight"], extensions: ["mdimporter"], mechanism: .spotlightImporters)
        drafts += bundles(in: ["/Library/QuickLook", "\(homePath)/Library/QuickLook"], extensions: ["qlgenerator"], mechanism: .quickLookPlugins)
        drafts += appExtensions(await plugins ?? "")

        for mechanism in PersistenceMechanism.allCases where limits[mechanism] == nil {
            if let note = mechanism.adminNote, mechanism != .backgroundItems { limits[mechanism] = note }
        }

        progress(UIText.t("Verifica delle firme…", "Checking signatures…"))
        for index in drafts.indices {
            if let url = drafts[index].signatureURL, drafts[index].fixedSignature == nil, !mayTouch(url.path(percentEncoded: false)) {
                drafts[index].fixedSignature = PersistenceSignature(kind: .unverified)
            }
        }
        let urls = Array(Set(drafts.compactMap { $0.fixedSignature == nil ? $0.signatureURL : nil }))
        let signer = signature
        let lock = NSLock()
        nonisolated(unsafe) var signatures: [URL: PersistenceSignature] = [:]
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let result = signer(urls[index])
            lock.withLock { signatures[urls[index]] = result }
        }
        let resolved = signatures
        let items = drafts.map { finalize($0, signatures: resolved) }
            .sorted { ($0.mechanism, $1.risk, $0.name.lowercased()) < ($1.mechanism, $0.risk, $1.name.lowercased()) }
        return PersistenceInventory(items: items, limits: limits)
    }

    // MARK: - Finalize

    func finalize(_ draft: Draft, signatures: [URL: PersistenceSignature]) -> PersistenceItem {
        var item = draft.item
        let sig = draft.fixedSignature ?? draft.signatureURL.map { signatures[$0] ?? signature($0) } ?? PersistenceSignature(kind: .notCode)
        item.signature = sig
        var findings = draft.findings
        var location: ThreatLocation?
        if let record = draft.launchRecord {
            let allowed: @Sendable (URL) -> Bool = { [hasFullDiskAccess, homePath] url in
                hasFullDiskAccess || !Self.isPrivacyProtected(url.path(percentEncoded: false), home: homePath)
            }
            let env = PersistenceAudit.Environment(
                home: home,
                signature: { url in
                    guard allowed(url) else { return .unsigned }
                    return (signatures[url] ?? PersistenceCodeSigning.signature(of: url)).codeSignatureStatus
                },
                fileExists: { allowed($0) && FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) },
                fileKinds: { allowed($0) ? MalwareFileKind.kinds(of: Self.readHeader($0)) : [] },
                readScript: { allowed($0) ? Self.readScript($0) : nil })
            findings += PersistenceAudit.audit(record, environment: env).map(\.finding)
        }
        if let program = item.program, program.hasPrefix("/") {
            location = ThreatLocation.classify(program, home: homePath)
        }
        let assessed = PersistenceRiskAssessor.assess(.init(
            mechanism: item.mechanism, signature: sig, findings: Array(Set(findings)),
            location: location, injectsLibraries: draft.injects, unusualPresence: draft.unusual))
        item.risk = assessed.risk
        item.reasons = assessed.reasons
        return item
    }

    // MARK: - launchd

    func launchItems(running: [String: Bool], userOverrides: [String: Bool], systemOverrides: [String: Bool],
                     btmByPlist: [String: BTMRecord]) -> [Draft] {
        let folders: [(String, PersistenceMechanism, LaunchItemRecord.Scope)] = [
            ("\(homePath)/Library/LaunchAgents", .userLaunchAgents, .userAgent),
            ("/Library/LaunchAgents", .systemLaunchAgents, .systemAgent),
            ("/Library/LaunchDaemons", .launchDaemons, .systemDaemon),
        ]
        var drafts: [Draft] = []
        for (folder, mechanism, scope) in folders {
            for url in contents(of: folder) where url.pathExtension == "plist" {
                let path = url.path(percentEncoded: false)
                guard let plist = Self.readPlist(url) else {
                    drafts.append(Draft(item: PersistenceItem(id: "\(mechanism.rawValue):\(path)", mechanism: mechanism,
                                                              name: url.deletingPathExtension().lastPathComponent, path: path,
                                                              addedDate: creationDate(url),
                                                              facts: [UIText.t("File non leggibile o danneggiato", "File unreadable or damaged")]),
                                        unusual: false))
                    continue
                }
                let record = LaunchItemRecord(plistURL: url, plist: plist, scope: scope)
                let label = record.label ?? url.deletingPathExtension().lastPathComponent
                let (effective, _) = PersistenceAudit.effectiveProgram(record.arguments)
                let programURL = effective ?? record.arguments.first.flatMap(PersistenceAudit.absoluteURL)
                var enabled = !(plist["Disabled"] as? Bool ?? false)
                let overrides = scope == .systemDaemon ? systemOverrides : userOverrides
                if let disabled = overrides[label] { enabled = !disabled }
                let btmRecord = btmByPlist[path]
                if let btmRecord, !btmRecord.isEnabled { enabled = false }
                var facts = LaunchPlistInspector.facts(plist)
                if btmRecord?.isEnabled == false {
                    facts.append(UIText.t("Disattivato in Impostazioni › Elementi di login", "Turned off in Settings › Login Items"))
                }
                let name = btmRecord?.name ?? Self.appName(in: programURL?.path(percentEncoded: false)) ?? label
                let injected = LaunchPlistInspector.injectedLibraries(plist)
                var item = PersistenceItem(
                    id: "\(mechanism.rawValue):\(path)", mechanism: mechanism, name: name, path: path,
                    program: programURL?.path(percentEncoded: false), arguments: record.arguments, label: label,
                    addedDate: creationDate(url), enabled: enabled, running: running[label] ?? false, facts: facts)
                if btmRecord?.isEnabled == false { item.disabledInSettings = true }
                if programURL == nil, record.arguments.isEmpty {
                    item.facts.append(UIText.t("Non indica nessun programma da avviare", "Doesn't name a program to start"))
                }
                drafts.append(Draft(item: item, signatureURL: programURL, launchRecord: record,
                                    injects: !injected.isEmpty,
                                    fixedSignature: programURL == nil ? PersistenceSignature(kind: .notCode) : nil))
                if !injected.isEmpty {
                    var dyld = item
                    dyld.id = "\(PersistenceMechanism.dyldInjection.rawValue):\(path)"
                    dyld.mechanism = .dyldInjection
                    dyld.facts = injected.map { ThreatCommandAnalyzer.snippet($0) }
                    drafts.append(Draft(item: dyld, signatureURL: programURL, injects: true,
                                        fixedSignature: programURL == nil ? PersistenceSignature(kind: .notCode) : nil))
                }
            }
        }
        return drafts
    }

    // MARK: - Login Items database

    /// Records from the newest BackgroundItems-v*.btm files, nil when none
    /// can be read (needs Full Disk Access on some systems).
    func readBTM() -> [BTMRecord]? {
        let folder = "/private/var/db/com.apple.backgroundtaskmanagement"
        let files = contents(of: folder).filter { $0.pathExtension == "btm" }
        func version(_ url: URL) -> Int {
            let name = url.lastPathComponent
            guard let range = name.range(of: "-v") else { return 0 }
            return Int(name[range.upperBound...].prefix(while: \.isNumber)) ?? 0
        }
        guard let newest = files.map(version).max() else { return nil }
        var records: [BTMRecord] = []
        var seen = Set<String>()
        var readAny = false
        for file in files where version(file) == newest {
            guard let data = try? Data(contentsOf: file) else { continue }
            readAny = true
            for record in BTMArchive.records(from: data) where seen.insert(record.identifier).inserted {
                records.append(record)
            }
        }
        return readAny ? records : nil
    }

    func backgroundItems(_ records: [BTMRecord], listedPlists: Set<String>) -> [Draft] {
        records.compactMap { record in
            if let url = record.url, listedPlists.contains(url) { return nil }
            // Background app refresh entries name no program: nothing to show.
            guard let program = record.executablePath ?? record.url else { return nil }
            if PersistencePluginKitParser.isSystemPath(program) { return nil }
            // Sign-check the bundle (app, helper, plug-in) when there is one.
            let target = record.url.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? record.executablePath
            var facts = [record.kindLabel]
            if let developer = record.developerName { facts.append(UIText.t("Sviluppatore: \(developer)", "Developer: \(developer)")) }
            var item = PersistenceItem(
                id: "\(PersistenceMechanism.backgroundItems.rawValue):\(record.identifier)", mechanism: .backgroundItems,
                name: record.name ?? record.bundleIdentifier ?? record.identifier, path: record.url, program: program,
                label: record.bundleIdentifier, addedDate: creationDate(URL(filePath: program)),
                enabled: record.isEnabled, facts: facts)
            if !record.isEnabled { item.disabledInSettings = true }
            return Draft(item: item, signatureURL: target.map { URL(filePath: $0) },
                         fixedSignature: target == nil ? PersistenceSignature(kind: .notCode) : nil)
        }
    }

    func legacyLoginItems(excluding programs: Set<String>) -> [Draft] {
        let url = home.appending(path: "Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm")
        guard let data = try? Data(contentsOf: url) else { return [] }
        var drafts: [Draft] = []
        for bookmark in BTMArchive.bookmarks(from: data) {
            guard let values = try? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark),
                  let path = values.path, !programs.contains(path), !programs.contains(path + "/") else { continue }
            let item = PersistenceItem(
                id: "\(PersistenceMechanism.legacyLoginItems.rawValue):\(path)", mechanism: .legacyLoginItems,
                name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, path: url.path(percentEncoded: false),
                program: path, addedDate: creationDate(URL(filePath: path)))
            drafts.append(Draft(item: item, signatureURL: URL(filePath: path)))
        }
        return drafts
    }

    // MARK: - Helpers, extensions, profiles

    func privilegedHelpers() -> [Draft] {
        contents(of: "/Library/PrivilegedHelperTools").filter { !isDirectory($0) }.map { url in
            let path = url.path(percentEncoded: false)
            return Draft(item: PersistenceItem(id: "\(PersistenceMechanism.privilegedHelpers.rawValue):\(path)", mechanism: .privilegedHelpers,
                                               name: url.lastPathComponent, path: path, program: path, addedDate: creationDate(url)),
                         signatureURL: url)
        }
    }

    func kernelExtensions() -> [Draft] {
        contents(of: "/Library/Extensions").filter { $0.pathExtension == "kext" }.map { url in
            let path = url.path(percentEncoded: false)
            return Draft(item: PersistenceItem(id: "\(PersistenceMechanism.kernelExtensions.rawValue):\(path)", mechanism: .kernelExtensions,
                                               name: url.deletingPathExtension().lastPathComponent, path: path, program: path,
                                               addedDate: creationDate(url)),
                         signatureURL: url)
        }
    }

    func systemExtensions(_ output: String) -> [Draft] {
        // The app that ships each extension (for the signer's name).
        var owners: [String: String] = [:]
        for app in contents(of: "/Applications") where app.pathExtension == "app" {
            for ext in contents(of: app.appending(path: "Contents/Library/SystemExtensions").path(percentEncoded: false)) {
                owners[ext.deletingPathExtension().lastPathComponent] = app.path(percentEncoded: false)
            }
        }
        return SystemExtensionsParser.parse(output).map { entry in
            let owner = owners[entry.bundleID]
            var facts = [entry.category.replacingOccurrences(of: "_", with: " ")]
            if !entry.state.isEmpty { facts.append(entry.state) }
            let item = PersistenceItem(
                id: "\(PersistenceMechanism.systemExtensions.rawValue):\(entry.bundleID)", mechanism: .systemExtensions,
                name: entry.name.isEmpty ? entry.bundleID : entry.name, path: owner, program: owner,
                label: entry.bundleID, enabled: entry.enabled && !entry.state.contains("disabled"), running: entry.active, facts: facts)
            return Draft(item: item, signatureURL: owner.map { URL(filePath: $0) },
                         fixedSignature: owner == nil ? PersistenceSignature(kind: .developerID, teamID: entry.teamID) : nil)
        }
    }

    /// Without a password only managed preferences pushed by profiles are
    /// visible (/Library/Managed Preferences).
    func configurationProfiles() -> [Draft] {
        let root = "/Library/Managed Preferences"
        var files = contents(of: root).filter { $0.pathExtension == "plist" }
        for folder in contents(of: root) where isDirectory(folder) {
            files += contents(of: folder.path(percentEncoded: false)).filter { $0.pathExtension == "plist" }
        }
        return files.map { url in
            let path = url.path(percentEncoded: false)
            let item = PersistenceItem(
                id: "\(PersistenceMechanism.configurationProfiles.rawValue):\(path)", mechanism: .configurationProfiles,
                name: url.deletingPathExtension().lastPathComponent, path: path, addedDate: creationDate(url),
                facts: [UIText.t("Impostazione imposta da un profilo installato", "Setting enforced by an installed profile")])
            return Draft(item: item, unusual: false, fixedSignature: PersistenceSignature(kind: .notCode))
        }
    }

    // MARK: - Scheduled jobs and legacy startup

    func cronJobs(_ userCrontab: String) -> [Draft] {
        var drafts: [Draft] = []
        func add(_ entries: [CrontabEntry], source: String) {
            for entry in entries {
                let first = entry.command.split(separator: " ").first.map(String.init)
                let program = first.flatMap(PersistenceAudit.absoluteURL)
                let item = PersistenceItem(
                    id: "\(PersistenceMechanism.cron.rawValue):\(source):\(entry.schedule) \(entry.command)",
                    mechanism: .cron, name: (first as NSString?)?.lastPathComponent ?? entry.command,
                    path: source, program: program?.path(percentEncoded: false),
                    arguments: [ThreatCommandAnalyzer.snippet(entry.command)],
                    facts: [UIText.t("Orario: \(entry.schedule)", "Schedule: \(entry.schedule)")])
                drafts.append(Draft(item: item, signatureURL: program, findings: ThreatCommandAnalyzer.analyze(entry.command),
                                    fixedSignature: program == nil ? PersistenceSignature(kind: .notCode) : nil))
            }
        }
        add(CrontabParser.parse(userCrontab), source: "crontab -l")
        if let text = try? String(contentsOfFile: "/etc/crontab", encoding: .utf8) {
            add(CrontabParser.parse(text, systemWide: true), source: "/etc/crontab")
        }
        return drafts
    }

    func atJobs(_ output: String) -> [Draft] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            let job = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? line
            return Draft(item: PersistenceItem(id: "\(PersistenceMechanism.atJobs.rawValue):\(job)", mechanism: .atJobs,
                                               name: UIText.t("Job \(job)", "Job \(job)"), facts: [line]),
                         unusual: true, fixedSignature: PersistenceSignature(kind: .notCode))
        }
    }

    /// Script names macOS shipped in /etc/periodic.
    static let applePeriodicScripts: Set<String> = [
        "100.clean-logs", "110.clean-tmps", "130.clean-msgs", "140.clean-rwho", "199.rotate-fax", "310.accounting",
        "400.status-disks", "420.status-network", "430.status-rwho", "999.local", "310.locate", "320.whatis", "200.accounting",
    ]

    func periodicScripts() -> [Draft] {
        var drafts: [Draft] = []
        for base in ["/etc/periodic", "/usr/local/etc/periodic"] {
            for period in ["daily", "weekly", "monthly"] {
                for url in contents(of: "\(base)/\(period)") where !isDirectory(url) {
                    let path = url.path(percentEncoded: false)
                    let apple = base == "/etc/periodic" && Self.applePeriodicScripts.contains(url.lastPathComponent)
                    drafts.append(scriptDraft(url, mechanism: .periodic, unusual: !apple,
                                              fact: UIText.t("Periodo: \(period)", "Period: \(period)"),
                                              signature: PersistenceSignature(kind: apple ? .apple : .notCode), id: path))
                }
            }
        }
        for path in ["/etc/periodic.conf.local", "/etc/daily.local", "/etc/weekly.local", "/etc/monthly.local"]
        where fm.fileExists(atPath: path) {
            drafts.append(scriptDraft(URL(filePath: path), mechanism: .periodic, unusual: true, fact: nil,
                                      signature: PersistenceSignature(kind: .notCode), id: path))
        }
        return drafts
    }

    func legacyStartup() -> [Draft] {
        var drafts: [Draft] = []
        for url in contents(of: "/etc/emond.d/rules") + contents(of: "/private/var/db/emondClients") {
            drafts.append(scriptDraft(url, mechanism: .emond, unusual: true, fact: nil,
                                      signature: PersistenceSignature(kind: .notCode), id: url.path(percentEncoded: false)))
        }
        for url in contents(of: "/Library/StartupItems") + contents(of: "/System/Library/StartupItems") {
            let path = url.path(percentEncoded: false)
            drafts.append(Draft(item: PersistenceItem(id: "\(PersistenceMechanism.startupItems.rawValue):\(path)", mechanism: .startupItems,
                                                      name: url.lastPathComponent, path: path, program: path, addedDate: creationDate(url)),
                                unusual: true, fixedSignature: PersistenceSignature(kind: .notCode)))
        }
        for path in ["/etc/rc.local", "/etc/rc.shutdown.local", "/etc/launchd.conf", "/etc/rc.server"]
        where fm.fileExists(atPath: path) {
            drafts.append(scriptDraft(URL(filePath: path), mechanism: .rcScripts, unusual: true, fact: nil,
                                      signature: PersistenceSignature(kind: .notCode), id: path))
        }
        return drafts
    }

    func loginHooks() -> [Draft] {
        var drafts: [Draft] = []
        for plistPath in ["/Library/Preferences/com.apple.loginwindow.plist", "\(homePath)/Library/Preferences/com.apple.loginwindow.plist"] {
            guard let plist = Self.readPlist(URL(filePath: plistPath)) else { continue }
            for hook in LoginHookParser.hooks(plist) {
                let script = URL(filePath: hook.script)
                var findings: [ThreatFinding] = ThreatCommandAnalyzer.analyze(hook.script)
                if mayTouch(hook.script), let text = Self.readScript(script) { findings += ThreatCommandAnalyzer.analyze(text) }
                let item = PersistenceItem(
                    id: "\(PersistenceMechanism.loginHooks.rawValue):\(plistPath):\(hook.kind)", mechanism: .loginHooks,
                    name: hook.kind, path: plistPath, program: hook.script, addedDate: creationDate(script))
                drafts.append(Draft(item: item, signatureURL: hook.script.hasPrefix("/") ? script : nil, findings: findings,
                                    unusual: true, fixedSignature: hook.script.hasPrefix("/") ? nil : PersistenceSignature(kind: .notCode)))
            }
        }
        return drafts
    }

    // MARK: - Authentication

    func pamModules() -> [Draft] {
        let shipped = Set(contents(of: "/usr/lib/pam").map(\.lastPathComponent))
        guard !shipped.isEmpty else { return [] }
        var drafts: [Draft] = []
        for file in contents(of: "/etc/pam.d") where !isDirectory(file) && !file.lastPathComponent.hasSuffix(".template") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for module in Set(PAMParser.thirdPartyModules(text, shipped: shipped)) {
                let resolved = module.hasPrefix("/") ? module : "/usr/local/lib/pam/\(module)"
                let exists = fm.fileExists(atPath: resolved)
                let path = file.path(percentEncoded: false)
                let item = PersistenceItem(
                    id: "\(PersistenceMechanism.pam.rawValue):\(path):\(module)", mechanism: .pam,
                    name: (module as NSString).lastPathComponent, path: path, program: exists ? resolved : module,
                    addedDate: creationDate(file),
                    facts: [UIText.t("Usato da: \(file.lastPathComponent)", "Used by: \(file.lastPathComponent)")])
                drafts.append(Draft(item: item, signatureURL: exists ? URL(filePath: resolved) : nil,
                                    fixedSignature: exists ? nil : PersistenceSignature(kind: .missing)))
            }
        }
        return drafts
    }

    func sudoersRules() -> [Draft] {
        contents(of: "/etc/sudoers.d").map { url in
            let path = url.path(percentEncoded: false)
            return Draft(item: PersistenceItem(id: "\(PersistenceMechanism.sudoers.rawValue):\(path)", mechanism: .sudoers,
                                               name: url.lastPathComponent, path: path, addedDate: creationDate(url)),
                         unusual: false, fixedSignature: PersistenceSignature(kind: .notCode))
        }
    }

    func dyldInjection(launchctlEnv: String) -> [Draft] {
        var drafts: [Draft] = []
        let value = launchctlEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            drafts.append(Draft(item: PersistenceItem(id: "\(PersistenceMechanism.dyldInjection.rawValue):launchctl", mechanism: .dyldInjection,
                                                      name: "launchctl setenv", program: value,
                                                      facts: [ThreatCommandAnalyzer.snippet("DYLD_INSERT_LIBRARIES=\(value)")]),
                                injects: true, fixedSignature: PersistenceSignature(kind: .notCode)))
        }
        for app in contents(of: "/Applications") + contents(of: "\(homePath)/Applications") where app.pathExtension == "app" {
            guard let plist = Self.readPlist(app.appending(path: "Contents/Info.plist")) else { continue }
            let injected = LaunchPlistInspector.injectedLibraries(plist)
            guard !injected.isEmpty else { continue }
            let path = app.path(percentEncoded: false)
            drafts.append(Draft(item: PersistenceItem(id: "\(PersistenceMechanism.dyldInjection.rawValue):\(path)", mechanism: .dyldInjection,
                                                      name: app.deletingPathExtension().lastPathComponent, path: path, program: path,
                                                      addedDate: creationDate(app), facts: injected.map { ThreatCommandAnalyzer.snippet($0) }),
                                signatureURL: app, injects: true))
        }
        return drafts
    }

    static let shellStartupNames = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".bash_profile", ".bashrc", ".bash_login", ".profile"]
    static let systemShellStartupFiles = ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin", "/etc/profile", "/etc/bashrc"]

    func shellStartupFiles() -> [Draft] {
        let paths = Self.shellStartupNames.map { "\(homePath)/\($0)" } + Self.systemShellStartupFiles
        return paths.compactMap { path in
            let url = URL(filePath: path)
            guard Self.isRegularFile(path), let text = Self.readScript(url) else { return nil }
            let flags = ShellStartupAudit.flaggedLines(text)
            var facts: [String] = []
            var findings: [ThreatFinding] = []
            for flag in flags.prefix(12) {
                facts.append(UIText.t("Riga \(flag.lineNumber): \(flag.snippet)", "Line \(flag.lineNumber): \(flag.snippet)"))
                facts += flag.notes
                findings += flag.findings
            }
            let injects = flags.contains { !$0.notes.isEmpty && $0.severity == .high }
            if flags.isEmpty {
                facts.append(UIText.t("Nessuna riga pericolosa", "No dangerous lines"))
            }
            let item = PersistenceItem(id: "\(PersistenceMechanism.shellStartup.rawValue):\(path)", mechanism: .shellStartup,
                                       name: (path as NSString).lastPathComponent, path: path,
                                       addedDate: creationDate(url), facts: facts)
            var draft = Draft(item: item, findings: findings, injects: injects, fixedSignature: PersistenceSignature(kind: .notCode))
            // A redefined sudo has no analyzer rule: carry it as a medium note.
            if findings.isEmpty, !injects, flags.contains(where: { !$0.notes.isEmpty }) {
                draft.findings = [ThreatFinding(rule: .passwordVerification, severity: .medium,
                                                snippet: flags.first { !$0.notes.isEmpty }!.snippet)]
            }
            return draft
        }
    }

    // MARK: - Plug-ins

    func bundles(in folders: [String], extensions: Set<String>, mechanism: PersistenceMechanism) -> [Draft] {
        folders.flatMap { contents(of: $0) }.filter { extensions.contains($0.pathExtension) }.map { url in
            let path = url.path(percentEncoded: false)
            return Draft(item: PersistenceItem(id: "\(mechanism.rawValue):\(path)", mechanism: mechanism,
                                               name: url.deletingPathExtension().lastPathComponent, path: path, program: path,
                                               addedDate: creationDate(url)),
                         signatureURL: url)
        }
    }

    func appExtensions(_ output: String) -> [Draft] {
        PersistencePluginKitParser.parse(output).filter { !PersistencePluginKitParser.isSystemPath($0.path) }.map { entry in
            // Sign-check the app that ships the extension (shared by its
            // siblings, so it is read once).
            let owner = Self.containingApp(entry.path) ?? entry.path
            let ownerName = Self.appName(in: entry.path)
            let name = [ownerName, entry.displayName].compactMap { $0 }.uniqued().joined(separator: " – ")
            let item = PersistenceItem(
                id: "\(PersistenceMechanism.appExtensions.rawValue):\(entry.identifier)", mechanism: .appExtensions,
                name: name.isEmpty ? entry.identifier : name, path: entry.path, program: owner, label: entry.identifier,
                addedDate: creationDate(URL(filePath: entry.path)), enabled: entry.enabled,
                facts: [PersistencePluginKitParser.kindLabel(sdk: entry.sdk)])
            return Draft(item: item, signatureURL: URL(filePath: owner))
        }
    }

    // MARK: - File helpers

    func scriptDraft(_ url: URL, mechanism: PersistenceMechanism, unusual: Bool, fact: String?,
                     signature: PersistenceSignature, id: String) -> Draft {
        let path = url.path(percentEncoded: false)
        let findings = Self.readScript(url).map { ThreatCommandAnalyzer.analyze($0) } ?? []
        let item = PersistenceItem(id: "\(mechanism.rawValue):\(id)", mechanism: mechanism, name: url.lastPathComponent,
                                   path: path, program: path, addedDate: creationDate(url), facts: fact.map { [$0] } ?? [])
        return Draft(item: item, findings: findings, unusual: unusual, fixedSignature: signature)
    }

    func contents(of folder: String) -> [URL] {
        ((try? fm.contentsOfDirectory(at: URL(filePath: folder), includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                                      options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    func creationDate(_ url: URL) -> Date? {
        guard mayTouch(url.path(percentEncoded: false)) else { return nil }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    func run(_ path: String, _ args: [String], timeout: Duration = .seconds(15)) async -> String? {
        let outcome = await BoundedProcess.run(path, args, timeout: timeout)
        guard case .exited = outcome else { return nil }
        return outcome.stdoutText
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            || (stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG)
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard isRegularFile(url.path(percentEncoded: false)), let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func readHeader(_ url: URL) -> Data {
        guard isRegularFile(url.path(percentEncoded: false)), let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)) ?? Data()
    }

    /// Bounded text of a script; nil for binaries and non-regular files.
    static func readScript(_ url: URL) -> String? {
        guard isRegularFile(url.path(percentEncoded: false)), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ArtifactSweep.maxScriptBytes), !data.isEmpty,
              !MalwareFileKind.kinds(of: data).contains(.machO), !data.prefix(4096).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `/Applications/Zoom.app/Contents/…` → `/Applications/Zoom.app` (the outermost app).
    static func containingApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// "Zoom" for anything inside /Applications/zoom.us.app → "zoom.us".
    static func appName(in path: String?) -> String? {
        guard let path, let app = containingApp(path) else { return nil }
        return ((app as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

extension BTMArchive {
    /// Bookmark blobs of the legacy login items list (backgrounditems.btm).
    public static func bookmarks(from data: Data) -> [Data] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return [] }
        var flattener = Flattener(objects: objects)
        var found: [Data] = []
        for object in objects {
            guard let dict = object as? [String: Any], let value = dict["bookmark"] else { continue }
            let resolved = flattener.resolve(value)
            if let data = resolved as? Data { found.append(data) }
            else if let dict = resolved as? [String: Any], let data = dict["data"] as? Data ?? dict["NS.data"] as? Data { found.append(data) }
        }
        return found
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
