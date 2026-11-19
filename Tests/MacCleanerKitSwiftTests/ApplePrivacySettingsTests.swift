import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Apple privacy settings")
struct ApplePrivacySettingsTests {
    let catalog = ApplePrivacySettings.catalog(home: "/Users/alice")

    private func setting(_ id: String) -> ApplePrivacySettings.Setting {
        catalog.first { $0.id == id }!
    }

    @Test func catalogHasAboutAdozenUniqueRows() {
        #expect(catalog.count >= 10)
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        for s in catalog {
            #expect(s.settingsURL.hasPrefix("x-apple.systempreferences:") || s.settingsURL.hasPrefix("/Applications/"))
            // Writable rows need both values and a per-user domain.
            if s.writable {
                #expect(s.onValue != nil && s.offValue != nil)
                if case .userDefaults = s.storage {} else { Issue.record("\(s.id) writable but not a user default") }
            }
        }
    }

    @Test func onlyPlainUserPreferencesAreWritable() {
        #expect(Set(catalog.filter(\.writable).map(\.id)) == ["ads.personalized", "siri.improve"])
    }

    @Test func personalizedAds() {
        let ads = setting("ads.personalized")
        #expect(ApplePrivacySettings.state(of: ads, raw: NSNumber(value: false)) == .off)
        #expect(ApplePrivacySettings.state(of: ads, raw: true) == .on)
        #expect(ApplePrivacySettings.state(of: ads, raw: 0) == .off)       // `defaults write … -int 0`
        #expect(ApplePrivacySettings.state(of: ads, raw: "YES") == .on)
        #expect(ApplePrivacySettings.state(of: ads, raw: nil) == .on)      // macOS default
        #expect(ApplePrivacySettings.value(for: ads, enabled: false) == .bool(false))
    }

    @Test func improveSiriUsesOneAndTwo() {
        let siri = setting("siri.improve")
        #expect(ApplePrivacySettings.state(of: siri, raw: 2) == .off)
        #expect(ApplePrivacySettings.state(of: siri, raw: 1) == .on)
        #expect(ApplePrivacySettings.state(of: siri, raw: 0) == .unknown)  // never asked
        #expect(ApplePrivacySettings.state(of: siri, raw: nil) == .unknown)
        #expect(ApplePrivacySettings.value(for: siri, enabled: false) == .int(2))
        #expect(ApplePrivacySettings.value(for: siri, enabled: true) == .int(1))
    }

    @Test func safariSuggestionsAreInverted() {
        let s = setting("safari.suggestions")
        #expect(ApplePrivacySettings.state(of: s, raw: true) == .off)     // SuppressSearchSuggestions = YES
        #expect(ApplePrivacySettings.state(of: s, raw: nil) == .on)
        #expect(ApplePrivacySettings.value(for: s, enabled: false) == nil) // read-only
    }

    @Test func linkOnlyRowsAreUnknown() {
        #expect(ApplePrivacySettings.state(of: setting("spotlight.suggestions"), raw: nil) == .unknown)
    }

    @Test func appleIntelligenceState() {
        let plist: [String: Any] = ["OS_ELIGIBILITY_DOMAIN_SIRI_MODE": ["os_eligibility_answer_t": NSNumber(value: 2)]]
        #expect(ApplePrivacySettings.siriModeAnswer(in: plist) == 2)
        #expect(ApplePrivacySettings.siriModeAnswer(in: [:]) == nil)
        #expect(ApplePrivacySettings.intelligenceState(siriModeAnswer: 4, modelBytes: 0) == .available)
        #expect(ApplePrivacySettings.intelligenceState(siriModeAnswer: 2, modelBytes: 18_000_000_000) == .unavailableModelsPresent)
        #expect(ApplePrivacySettings.intelligenceState(siriModeAnswer: 2, modelBytes: 0) == .unavailable)
        #expect(ApplePrivacySettings.intelligenceState(siriModeAnswer: nil, modelBytes: 5) == .unknown)
    }
}
