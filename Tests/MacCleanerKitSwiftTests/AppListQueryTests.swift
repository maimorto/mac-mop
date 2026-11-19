import Foundation
import Testing
@testable import MacCleanerKit

@Suite("App list sort and filter")
struct AppListQueryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar = Calendar(identifier: .gregorian)

    func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    var sample: [AppListEntry] {
        [
            AppListEntry(id: "/Applications/Zoom.app", name: "zoom.us", bundleIdentifier: "us.zoom.xos", developer: "Zoom Video Communications",
                         bytes: 450_000_000, lastUsed: daysAgo(400), installed: daysAgo(900), source: .developerID),
            AppListEntry(id: "/Applications/Xcode.app", name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", developer: "Apple",
                         bytes: 12_000_000_000, lastUsed: daysAgo(2), installed: daysAgo(30), source: .appStore, isApple: true),
            AppListEntry(id: "/Applications/Écran.app", name: "Écran", bundleIdentifier: "org.example.ecran", developer: nil,
                         bytes: 20_000_000, lastUsed: nil, installed: nil, source: .unsigned, isIntelOnly: true),
            AppListEntry(id: "/Applications/App 10.app", name: "App 10", bundleIdentifier: "com.foo.app10", developer: "Foo",
                         bytes: 150_000_000, lastUsed: daysAgo(100), installed: daysAgo(5), source: .developerID),
            AppListEntry(id: "/Applications/App 9.app", name: "App 9", bundleIdentifier: "com.foo.app9", developer: "foo",
                         bytes: 150_000_000, lastUsed: daysAgo(200), installed: daysAgo(400), source: .developerID, isIntelOnly: true),
        ]
    }

    func names(_ options: AppListOptions, search: String = "") -> [String] {
        AppListQuery.apply(sample, search: search, options: options, now: now, calendar: calendar).map(\.name)
    }

    @Test func sortsByNameNaturallyAndIgnoringAccentsAndCase() {
        #expect(names(AppListOptions(sort: .name)) == ["App 9", "App 10", "Écran", "Xcode", "zoom.us"])
        #expect(names(AppListOptions(sort: .name, ascending: false)) == ["zoom.us", "Xcode", "Écran", "App 10", "App 9"])
    }

    @Test func sortsBySizeLargestFirstWithNameTieBreak() {
        #expect(names(AppListOptions(sort: .size)) == ["Xcode", "zoom.us", "App 9", "App 10", "Écran"])
        #expect(names(AppListOptions(sort: .size, ascending: true)).first == "Écran")
    }

    @Test func missingDatesAlwaysGoLast() {
        let oldestFirst = names(AppListOptions(sort: .lastUsed))
        #expect(oldestFirst == ["zoom.us", "App 9", "App 10", "Xcode", "Écran"])
        let newestFirst = names(AppListOptions(sort: .lastUsed, ascending: false))
        #expect(newestFirst == ["Xcode", "App 10", "App 9", "zoom.us", "Écran"])
        #expect(names(AppListOptions(sort: .installed)) == ["App 10", "Xcode", "App 9", "zoom.us", "Écran"])
    }

    @Test func sortsByDeveloperCaseInsensitiveUnknownLast() {
        let list = names(AppListOptions(sort: .developer))
        #expect(list.prefix(3) == ["Xcode", "App 9", "App 10"])
        #expect(list.last == "Écran")
    }

    @Test func defaultDirectionsFollowTheKey() {
        var options = AppListOptions()
        #expect(options.ascending)
        options.setSort(.size)
        #expect(!options.ascending)
        options.ascending = true
        options.setSort(.size)          // re-picking keeps the user's direction
        #expect(options.ascending)
        options.setSort(.installed)
        #expect(!options.ascending)
    }

    @Test func searchMatchesNameDeveloperAndBundleIDWithoutAccents() {
        #expect(names(AppListOptions(), search: "ecran") == ["Écran"])
        #expect(names(AppListOptions(), search: "video") == ["zoom.us"])
        #expect(names(AppListOptions(), search: "com.foo") == ["App 9", "App 10"])
        #expect(names(AppListOptions(), search: "foo 10") == ["App 10"])
        #expect(names(AppListOptions(), search: "  ").count == 5)
    }

    @Test func sizeThresholds() {
        #expect(names(AppListOptions(size: .over100MB)) == ["App 9", "App 10", "Xcode", "zoom.us"])
        #expect(names(AppListOptions(size: .over1GB)) == ["Xcode"])
    }

    @Test func sourceIntelAndAppleFilters() {
        #expect(names(AppListOptions(sources: [.appStore])) == ["Xcode"])
        #expect(names(AppListOptions(sources: [.appStore, .unsigned])) == ["Écran", "Xcode"])
        #expect(names(AppListOptions(intelOnly: true)) == ["App 9", "Écran"])
        #expect(!names(AppListOptions(hideApple: true)).contains("Xcode"))
        #expect(names(AppListOptions(sources: [.developerID], intelOnly: true)) == ["App 9"])
    }

    @Test func idleFilterNeedsAKnownOldDate() {
        #expect(names(AppListOptions(idle: .threeMonths)) == ["App 9", "App 10", "zoom.us"])
        #expect(names(AppListOptions(idle: .sixMonths)) == ["App 9", "zoom.us"])
        #expect(names(AppListOptions(idle: .twelveMonths)) == ["zoom.us"])
    }

    @Test func optionsRoundTripThroughAppStorageString() {
        let options = AppListOptions(sort: .lastUsed, ascending: false, hideApple: true, size: .over1GB,
                                     sources: [.unsigned, .appStore], intelOnly: true, idle: .sixMonths)
        #expect(AppListOptions(rawValue: options.rawValue) == options)
        #expect(options.activeFilterCount == 5)
        #expect(options.clearingFilters.activeFilterCount == 0)
        #expect(options.clearingFilters.sort == .lastUsed)
        // Unknown or partial JSON falls back to defaults instead of failing.
        #expect(AppListOptions(rawValue: "{\"sort\":\"size\"}") == AppListOptions(sort: .size))
        #expect(AppListOptions(rawValue: "garbage") == nil)
    }

    @Test func sourceMapping() {
        #expect(AppSource.from(signer: .developerID(teamName: "X", teamID: nil), hasAppStoreReceipt: true, bundleIdentifier: "a") == .appStore)
        #expect(AppSource.from(signer: .adHoc, hasAppStoreReceipt: false, bundleIdentifier: "a") == .unsigned)
        #expect(AppSource.from(signer: .unsigned, hasAppStoreReceipt: false, bundleIdentifier: "a") == .unsigned)
        #expect(AppSource.from(signer: .apple, hasAppStoreReceipt: false, bundleIdentifier: "com.apple.Safari") == .apple)
        #expect(AppSource.from(signer: nil, hasAppStoreReceipt: false, bundleIdentifier: "a") == .unknown)
    }

    @Test func developerFromCopyright() {
        #expect(AppDeveloperName.fromCopyright("Copyright © 2010-2024 Foo Software Inc. All rights reserved.") == "Foo Software Inc")
        #expect(AppDeveloperName.fromCopyright("© 2023 Bar GmbH") == "Bar GmbH")
        #expect(AppDeveloperName.fromCopyright("2024") == nil)
        #expect(AppDeveloperName.fromCopyright(nil) == nil)
    }
}
