import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Security checklist: parsers, evaluation, score")
struct SecurityChecklistTests {
    @Test func parsers() {
        #expect(SecurityChecklist.parseFileVault("FileVault is On.\n") == true)
        #expect(SecurityChecklist.parseFileVault("FileVault is Off.\n") == false)
        #expect(SecurityChecklist.parseFileVault("Encryption in progress: Percent completed = 12") == true)
        #expect(SecurityChecklist.parseFileVault("") == nil)

        #expect(SecurityChecklist.parseFirewall("Firewall is enabled. (State = 1)") == true)
        #expect(SecurityChecklist.parseFirewall("Firewall is disabled. (State = 0)") == false)
        #expect(SecurityChecklist.parseStealth("Firewall stealth mode is off") == false)
        #expect(SecurityChecklist.parseStealth("Stealth mode enabled") == true)
        #expect(SecurityChecklist.parseBlockAll("Firewall has block all state set to disabled.") == false)

        #expect(SecurityChecklist.parseGatekeeper("assessments enabled\n") == true)
        #expect(SecurityChecklist.parseGatekeeper("assessments disabled\n") == false)

        #expect(SecurityChecklist.parseSIP("System Integrity Protection status: enabled.") == true)
        #expect(SecurityChecklist.parseSIP("System Integrity Protection status: disabled.") == false)
        #expect(SecurityChecklist.parseSIP("System Integrity Protection status: enabled (Custom Configuration).") == false)

        #expect(SecurityChecklist.parseScreenLock("2026-11-19 sysadminctl[1:2] screenLock delay is 300 seconds") == 300)
        #expect(SecurityChecklist.parseScreenLock("screenLock delay is immediate") == 0)
        #expect(SecurityChecklist.parseScreenLock("screenLock is off") == -1)
        #expect(SecurityChecklist.parseScreenLock("garbage") == nil)

        let xp = SecurityChecklist.parseXProtect("Version: 5372 Installed: 2026-11-11 07:58:51 +0000\n")
        #expect(xp?.version == "5372")
        #expect(xp?.installed == Date(timeIntervalSince1970: 1_794_383_931))
    }

    @Test func listeningPorts() {
        let text = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  *.22                   *.*                    LISTEN
        tcp6       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  127.0.0.1.445          *.*                    LISTEN
        tcp4       0      0  10.0.0.2.51234         17.1.1.1.443           ESTABLISHED
        """
        #expect(SecurityChecklist.parseListeningPorts(text) == [22, 5900])
    }

    func goodProbe() -> SecurityProbe {
        var p = SecurityProbe()
        p.now = Date(timeIntervalSince1970: 1_794_383_931 + 5 * 86_400)
        p.fdesetup = "FileVault is On."
        p.firewallGlobal = "Firewall is enabled. (State = 1)"
        p.firewallStealth = "Firewall stealth mode is on"
        p.firewallBlockAll = "Firewall has block all state set to disabled."
        p.spctl = "assessments enabled"
        p.csrutil = "System Integrity Protection status: enabled."
        p.softwareUpdate = ["AutomaticallyInstallMacOSUpdates": .bool(true)]
        p.commerce = ["AutoUpdate": .bool(true)]
        p.xprotectVersion = "Version: 5372 Installed: 2026-11-11 07:58:51 +0000"
        p.screenLock = "screenLock delay is immediate"
        p.loginWindow = ["GuestEnabled": .bool(false)]
        p.findMy = ["FMMEnabled": .int(1)]
        p.timeMachine = ["Destinations": .array([.dictionary([
            "SnapshotDates": .array([.date(Date(timeIntervalSince1970: 1_794_383_931 + 4 * 86_400))]),
            "LastKnownEncryptionState": .string("Encrypted"),
        ])])]
        p.safari = ["AutoOpenSafeDownloads": .bool(false)]
        return p
    }

    @Test func everythingOnScoresHundred() {
        let results = SecurityChecklist.evaluate(goodProbe())
        #expect(results.count == SecurityCheckKind.allCases.count)
        #expect(results.count >= 15)
        let bad = results.filter(\.needsAttention)
        #expect(bad.isEmpty, "\(bad.map { "\($0.kind) \($0.status)" })")
        #expect(SecurityChecklist.score(results) == 100)
    }

    @Test func problemsAreFlagged() {
        var p = goodProbe()
        p.fdesetup = "FileVault is Off."
        p.loginWindow = ["autoLoginUser": .string("a"), "GuestEnabled": .bool(true), "RetriesUntilHint": .int(3)]
        p.systemServices = ["com.openssh.sshd"]
        p.listeningPorts = [445]
        p.airDropMode = "Everyone"
        p.softwareUpdate = ["AutomaticCheckEnabled": .bool(false), "ConfigDataInstall": .bool(false)]
        p.screenLock = "screenLock is off"
        p.timeMachine = ["PreferencesVersion": .int(6)]
        p.timeMachineDestinations = "tmutil: No destinations configured."
        let results = Dictionary(uniqueKeysWithValues: SecurityChecklist.evaluate(p).map { ($0.kind, $0) })
        #expect(results[.fileVault]?.state == .fail)
        #expect(results[.autoLogin]?.state == .fail)
        #expect(results[.guestAccount]?.state == .fail)
        #expect(results[.passwordHints]?.state == .warning)
        #expect(results[.remoteLogin]?.state == .fail)
        #expect(results[.fileSharing]?.state == .fail)
        #expect(results[.screenSharing]?.state == .pass)
        #expect(results[.airDrop]?.state == .warning)
        #expect(results[.automaticUpdates]?.state == .fail)
        #expect(results[.securityResponses]?.state == .fail)
        #expect(results[.screenLock]?.state == .fail)
        #expect(results[.timeMachine]?.state == .fail)
        #expect(SecurityChecklist.score(Array(results.values)) < 50)
    }

    @Test func unknownsDontCountAndStaleXProtectIsFlagged() {
        var p = SecurityProbe()
        p.now = Date(timeIntervalSince1970: 1_794_383_931 + 120 * 86_400)
        p.xprotectVersion = "Version: 5372 Installed: 2026-11-11 07:58:51 +0000"
        let results = Dictionary(uniqueKeysWithValues: SecurityChecklist.evaluate(p).map { ($0.kind, $0) })
        #expect(results[.fileVault]?.state == .unknown)
        #expect(results[.safariSafeFiles]?.state == .unknown)
        #expect(results[.xprotect]?.state == .fail)
        #expect(results[.firewallStealth]?.state == .unknown)
    }

    @Test func stealthIsInfoWhenFirewallOff() {
        var p = goodProbe()
        p.firewallGlobal = "Firewall is disabled. (State = 0)"
        let results = Dictionary(uniqueKeysWithValues: SecurityChecklist.evaluate(p).map { ($0.kind, $0) })
        #expect(results[.firewall]?.state == .fail)
        #expect(results[.firewallStealth]?.state == .info)
    }

    @Test func everyCheckHasAGuide() {
        for kind in SecurityCheckKind.allCases {
            let guide = SecurityChecklist.guide(for: kind)
            #expect(!guide.why.isEmpty)
            #expect(!guide.steps.isEmpty)
            if let pane = guide.paneURL { #expect(pane.hasPrefix("x-apple.systempreferences:")) }
            #expect(guide.adminFix.map { !$0.contains("sudo") } ?? true, "adminFix runs through the password prompt, no sudo")
        }
    }

    @Test func plistValueBridging() {
        let values = SendablePlistValue.dictionary(from: ["b": true, "i": 3, "s": "x", "d": Date(timeIntervalSince1970: 0)])
        #expect(values?["b"] == .bool(true))
        #expect(values?["i"] == .int(3))
        #expect(values?["s"]?.string == "x")
        #expect(values?["d"] == .date(Date(timeIntervalSince1970: 0)))
        #expect(values?["i"]?.bool == true)
    }
}
