import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Uninstaller: why each leftover matched")
struct UninstallReasonTests {
    let chrome = AppInfo(bundleIdentifier: "com.google.Chrome", name: "Google Chrome",
                         path: URL(filePath: "/Applications/Google Chrome.app"))
    let arc = AppInfo(bundleIdentifier: "company.thebrowser.Browser", name: "Arc",
                      path: URL(filePath: "/Applications/Arc.app"))
    let word = AppInfo(bundleIdentifier: "com.microsoft.Word", name: "Microsoft Word",
                       path: URL(filePath: "/Applications/Microsoft Word.app"))

    func explain(_ name: String, _ dir: String, _ app: AppInfo,
                 context: LeftoverContext = LeftoverContext(), program: String? = nil) -> LeftoverMatch? {
        LeftoverExplainer.explain(fileName: name, librarySubdirectory: dir, app: app, context: context, launchProgram: program)
    }

    @Test func preferencesDomainIsCertain() {
        let m = explain("com.google.Chrome.plist", "Preferences", chrome)
        #expect(m == LeftoverMatch(reason: .preferencesDomain, confidence: .high))
    }

    @Test func sandboxContainerIsCertain() {
        #expect(explain("com.google.Chrome", "Containers", chrome)?.reason == .sandboxContainer)
    }

    @Test func bundleIDPrefixIsCertain() {
        let m = explain("com.google.Chrome.helper.plist", "LaunchAgents", chrome)
        #expect(m?.reason == .bundleIDPrefix)
        #expect(m?.confidence == .high)
        #expect(explain("com.google.Chrome.savedState", "Saved Application State", chrome)?.reason == .bundleIDExact)
    }

    @Test func siblingEditionIsNotCertain() {
        // Chrome for Testing / Canary are different apps sharing the prefix.
        let m = explain("com.google.chrome.for.testing.plist", "Preferences", chrome)
        #expect(m?.reason == .relatedBundleID("for.testing"))
        #expect(m?.confidence == .low)
        #expect(explain("com.google.Chrome.canary", "Application Support", chrome)?.confidence == .low)
        #expect(explain("com.google.Chrome.ShipIt", "Caches", chrome)?.confidence == .high)
    }

    @Test func launchItemPointingIntoBundleWins() {
        let program = "/Applications/Google Chrome.app/Contents/MacOS/updater"
        let m = explain("com.whatever.agent.plist", "LaunchAgents", chrome, program: program)
        #expect(m == LeftoverMatch(reason: .launchItemProgram(program), confidence: .high))
        // A sibling folder with a shared prefix must not count.
        #expect(explain("x.plist", "LaunchAgents", chrome, program: "/Applications/Google Chrome.app2/x") == nil)
    }

    @Test func declaredAppGroupIsLikelyNotCertain() {
        let ctx = LeftoverContext(teamIdentifier: "UBF8T346G9", appGroups: ["UBF8T346G9.Office"])
        let m = explain("UBF8T346G9.Office", "Group Containers", word, context: ctx)
        #expect(m == LeftoverMatch(reason: .appGroup("UBF8T346G9.Office"), confidence: .medium))
    }

    @Test func undeclaredTeamPrefixIsLowAndUnchecked() {
        let ctx = LeftoverContext(teamIdentifier: "UBF8T346G9", appGroups: [])
        let m = explain("UBF8T346G9.OneDriveSyncClient", "Group Containers", word, context: ctx)
        #expect(m?.reason == .teamIdentifier("UBF8T346G9"))
        #expect(m?.confidence == .low)
        #expect(m?.confidence.selectedByDefault == false)
    }

    @Test func exactAppNameFolderIsLikely() {
        let m = explain("Google Chrome", "Application Support", chrome)
        #expect(m == LeftoverMatch(reason: .appNameExact, confidence: .medium))
        #expect(m?.confidence.selectedByDefault == true)
    }

    @Test func shortNameWordMatchIsUncertain() {
        // "Arc" inside a longer name is weak: it could be anything.
        let m = explain("Arc Helper Data", "Application Support", arc)
        #expect(m?.reason == .appNameWord)
        #expect(m?.confidence == .low)
    }

    @Test func distinctiveNameWordMatchIsLikely() {
        let m = explain("Google Chrome Crashpad", "Application Support", chrome)
        #expect(m?.reason == .appNameWord)
        #expect(m?.confidence == .medium)
    }

    @Test func unrelatedFileHasNoReason() {
        #expect(explain("com.apple.archiveutility.plist", "Preferences", arc) == nil)
        #expect(explain("Firefox", "Application Support", chrome) == nil)
    }

    @Test func confidenceOrderingAndDefaults() {
        #expect(MatchConfidence.low < .medium && MatchConfidence.medium < .high)
        #expect(MatchConfidence.high.selectedByDefault)
        #expect(!MatchConfidence.low.selectedByDefault)
    }

    @Test func everyReasonExplainsItself() {
        let reasons: [UninstallMatchReason] = [.preferencesDomain, .sandboxContainer, .appGroup("g"), .launchItemProgram("/p"),
                                               .bundleIDExact, .bundleIDPrefix, .relatedBundleID("beta"), .baseBundleID, .teamIdentifier("T"),
                                               .appNameExact, .appNameWord, .bundleIDComponents, .normalizedName, .versionStrippedName]
        #expect(reasons.allSatisfy { !$0.explanation.isEmpty })
    }
}
