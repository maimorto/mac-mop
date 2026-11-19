import Foundation
import Testing
@testable import MacCleanerKit

@Suite("App Trust: plain-language summary")
struct AppTrustTests {
    @Test func signerClassification() {
        #expect(AppSigner.classify(isSigned: false, isValid: false, isAdHoc: false, leafCommonName: nil, teamID: nil) == .unsigned)
        #expect(AppSigner.classify(isSigned: true, isValid: true, isAdHoc: true, leafCommonName: nil, teamID: nil) == .adHoc)
        #expect(AppSigner.classify(isSigned: true, isValid: false, isAdHoc: false, leafCommonName: "x", teamID: nil) == .invalid)
        #expect(AppSigner.classify(isSigned: true, isValid: true, isAdHoc: false,
                                   leafCommonName: "Apple Mac OS Application Signing", teamID: "57T9237FN3") == .appStore)
        #expect(AppSigner.classify(isSigned: true, isValid: true, isAdHoc: false,
                                   leafCommonName: "Software Signing", teamID: nil) == .apple)
        let dev = AppSigner.classify(isSigned: true, isValid: true, isAdHoc: false,
                                     leafCommonName: "Developer ID Application: Nordvpn S.A. (W5W395V82Y)", teamID: nil)
        #expect(dev == .developerID(teamName: "Nordvpn S.A.", teamID: "W5W395V82Y"))
        #expect(dev.title == "Nordvpn S.A. (W5W395V82Y)")
    }

    @Test func spctlParsing() throws {
        let ok = try #require(GatekeeperAssessment.parse("""
        /Applications/NordVPN.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: Nordvpn S.A. (W5W395V82Y)
        """))
        #expect(ok.accepted && ok.isNotarized)
        let store = try #require(GatekeeperAssessment.parse("WhatsApp.app: accepted\nsource=Mac App Store\n"))
        #expect(store.isNotarized)
        let bad = try #require(GatekeeperAssessment.parse("/tmp/x.app: rejected\nsource=Unnotarized Developer ID\n"))
        #expect(!bad.accepted && !bad.isNotarized)
        #expect(GatekeeperAssessment.parse("spctl: error") == nil)
    }

    @Test func quarantineParsing() throws {
        let q = try #require(QuarantineOrigin.parse(quarantine: "0083;5f3c1a2b;Safari;1234-ABCD",
                                                    whereFroms: ["https://github.com/x/y/releases/a.dmg", "https://github.com/x/y"]))
        #expect(q.agent == "Safari")
        #expect(q.date == Date(timeIntervalSince1970: 0x5f3c1a2b))
        #expect(q.sourceHost == "github.com")
        #expect(!q.userApproved)
        #expect(QuarantineOrigin.parse(quarantine: "00c3;5f3c1a2b;;")?.userApproved == true)
        #expect(QuarantineOrigin.parse(quarantine: "garbage") == nil)
    }

    @Test func architecture() {
        #expect(AppArchitecture.from(hasARM64: true, hasX86_64: true) == .universal)
        #expect(AppArchitecture.from(hasARM64: false, hasX86_64: true) == .intel)
        #expect(AppArchitecture.from(hasARM64: true, hasX86_64: false) == .appleSilicon)
    }

    @Test func capabilitiesFromEntitlementsAndUsageKeys() {
        let caps = AppCapability.requested(
            entitlementKeys: ["com.apple.security.device.camera", "com.apple.security.network.client", "com.apple.security.app-sandbox"],
            infoPlistKeys: ["NSMicrophoneUsageDescription", "NSAppleEventsUsageDescription", "CFBundleName"])
        #expect(Set(caps) == [.camera, .microphone, .appleEvents, .network])
        // Sensitive first.
        #expect(caps.last == .network)
    }

    func report(_ signer: AppSigner, gk: GatekeeperAssessment? = nil, stapled: Bool = false, revoked: Bool = false) -> AppTrustReport {
        AppTrustReport(signer: signer, gatekeeper: gk, hasStapledTicket: stapled, isRevoked: revoked,
                       hardenedRuntime: true, sandboxed: false, quarantine: nil, architecture: .universal,
                       capabilities: [], lastOpened: nil, size: 0)
    }

    @Test func verdicts() {
        let dev = AppSigner.developerID(teamName: "X", teamID: "T")
        #expect(report(.apple).verdict == .trusted)
        #expect(report(.appStore).verdict == .trusted)
        #expect(report(dev, gk: GatekeeperAssessment(accepted: true, source: "Notarized Developer ID", origin: nil)).verdict == .trusted)
        #expect(report(dev, stapled: true).verdict == .trusted)
        #expect(report(dev, gk: GatekeeperAssessment(accepted: false, source: "Unnotarized Developer ID", origin: nil)).verdict == .review)
        #expect(report(.adHoc).verdict == .review)
        #expect(report(.unsigned).verdict == .warning)
        #expect(report(dev, stapled: true, revoked: true).verdict == .warning)
        #expect(!report(dev).verdictExplanation.isEmpty)
    }
}
