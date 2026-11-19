import Foundation
import Testing
@testable import MacCleanerKit

@Suite("System Data: catalog, dedupe, growth")
struct SystemDataTests {
    let env = SystemDataCatalog.Environment(
        home: "/Users/t",
        assetFolders: ["com_apple_MobileAsset_UAF_FM_GenerativeModels", "com_apple_MobileAsset_LinguisticData"],
        applications: ["Install macOS Tahoe.app", "Safari.app", "Install Xcode.app"],
        userTempDirs: ["/private/var/folders/ab/xyz/C"])

    // MARK: Catalog

    @Test func everyCategoryOnceWithText() {
        let cats = SystemDataCatalog.categories(env)
        #expect(Set(cats.map(\.id)).count == cats.count)
        #expect(Set(cats.map(\.id)) == Set(SystemDataCategoryID.allCases))
        for c in cats {
            #expect(!SystemDataCatalog.title(c.id).isEmpty)
            #expect(!SystemDataCatalog.explanation(c.id).isEmpty)
            #expect(!SystemDataCatalog.guidance(c.id).isEmpty)
        }
    }

    @Test func protectedNeverCleanable() {
        for c in SystemDataCatalog.categories(env) where c.safety == .protected {
            #expect(c.action == .info, "\(c.id) is protected but offers \(c.action)")
            #expect(!c.isSafelyCleanable)
        }
        let ids = Dictionary(uniqueKeysWithValues: SystemDataCatalog.categories(env).map { ($0.id, $0) })
        #expect(ids[.appleIntelligence]?.safety == .protected)
        #expect(ids[.vmSwap]?.safety == .protected)
        #expect(ids[.iosBackups]?.safety == .review)
        #expect(ids[.userCaches]?.isSafelyCleanable == true)
        #expect(ids[.virtualMachines]?.action == .reveal)
        #expect(ids[.purgeable]?.countsInTotal == false)
    }

    @Test func dynamicRoots() {
        let ids = Dictionary(uniqueKeysWithValues: SystemDataCatalog.categories(env).map { ($0.id, $0) })
        #expect(ids[.appleIntelligence]?.roots == ["/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels"])
        #expect(ids[.installers]?.roots == ["/Library/Updates", "/Applications/Install macOS Tahoe.app"])
        #expect(ids[.tempFiles]?.roots == ["/private/var/folders/ab/xyz/C"])
        #expect(ids[.userCaches]?.roots == ["/Users/t/Library/Caches"])
        #expect(ids[.devCaches]?.roots.contains("/Users/t/Library/Caches/Homebrew") == true)
    }

    @Test func backupSummary() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let s = SystemDataCatalog.backupSummary(infoPlist: ["Device Name": "iPhone di Anna", "Last Backup Date": date, "Product Type": "iPhone15,2"])
        #expect(s.name == "iPhone di Anna")
        #expect(s.date == date)
        #expect(s.model == "iPhone15,2")
        #expect(SystemDataCatalog.backupSummary(infoPlist: ["Display Name": "iPad"]).name == "iPad")
    }

    @Test func assetNames() {
        #expect(SystemDataCatalog.assetDisplayName("com_apple_MobileAsset_UAF_SearchQueryUnderstanding") == "Search Query Understanding")
        #expect(SystemDataCatalog.assetDisplayName("com_apple_MobileAsset_UAF_Siri_PlatformAssets") == "Siri Platform Assets")
        #expect(SystemDataCatalog.assetDisplayName("PreinstalledAssetsV2") == "PreinstalledAssetsV2")
        #expect(!SystemDataCatalog.assetDisplayName("com_apple_MobileAsset_UAF_FM_GenerativeModels").contains("_"))
    }

    // MARK: Plan (every byte counted once)

    @Test func nestedRootsExcludedFromOuterWalk() {
        let plans = SystemDataPlanner.plan(SystemDataCatalog.categories(env))
        let caches = plans.first { $0.root == "/Users/t/Library/Caches" }
        #expect(caches?.category == .userCaches)
        #expect(caches?.excludes.contains("/Users/t/Library/Caches/Homebrew") == true)
        #expect(caches?.excludes.contains("/Users/t/Library/Caches/pip") == true)
        let containers = plans.first { $0.root == "/Users/t/Library/Containers" }
        #expect(containers?.excludes.contains("/Users/t/Library/Containers/com.utmapp.UTM") == true)
        #expect(containers?.excludes.contains("/Users/t/Library/Containers/com.apple.mail/Data/Library/Mail Downloads") == true)
        let assets = plans.first { $0.root == "/System/Library/AssetsV2" }
        #expect(assets?.excludes == ["/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels"])
    }

    @Test func duplicateRootsCountOnce() {
        let a = SystemDataCategory(id: .userLogs, safety: .safe, action: .trash, roots: ["/x/logs/"])
        let b = SystemDataCategory(id: .systemLogs, safety: .safe, action: .trash, roots: ["/x/logs", "/x/other"])
        let plans = SystemDataPlanner.plan([a, b])
        #expect(plans.map(\.root) == ["/x/logs", "/x/other"])
        #expect(plans.first?.category == .userLogs)
        #expect(SystemDataPlanner.isInside("/x/logs2", "/x/logs") == false)
        #expect(SystemDataPlanner.isInside("/x/logs/a", "/x/logs"))
    }

    // MARK: Walker on a real temporary tree

    @Test func walkerCountsHardLinksOnceAndSkipsNestedRoots() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "sysdata-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        let outer = base + "/Outer", inner = outer + "/Inner", other = base + "/Other"
        for d in [outer + "/A", inner, other] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let payload = Data(repeating: 7, count: 1_000_000)
        try payload.write(to: URL(fileURLWithPath: outer + "/A/big.bin"))
        try payload.write(to: URL(fileURLWithPath: inner + "/inner.bin"))
        try fm.linkItem(atPath: outer + "/A/big.bin", toPath: other + "/hardlink.bin")
        try fm.createSymbolicLink(atPath: outer + "/A/loop", withDestinationPath: base)

        let cats = [
            SystemDataCategory(id: .userCaches, safety: .safe, action: .trash, roots: [outer], keepNames: ["A"]),
            SystemDataCategory(id: .systemCaches, safety: .safe, action: .trash, roots: [inner]),
            SystemDataCategory(id: .userLogs, safety: .safe, action: .trash, roots: [other]),
            SystemDataCategory(id: .xcodeArchives, safety: .review, action: .trash, roots: [base + "/missing"]),
        ]
        let m = SystemDataWalker().measure(cats)
        let fileBytes = m[.systemCaches]!.bytes
        #expect(fileBytes >= 1_000_000)
        // Outer holds big.bin only (Inner belongs to systemCaches; the symlink is not followed).
        #expect(m[.userCaches]!.bytes == fileBytes)
        #expect(m[.userCaches]!.items.map(\.name) == ["A"])
        #expect(m[.userCaches]!.items.first?.removable == false)   // kept by name
        // The hard link to big.bin was already counted.
        #expect(m[.userLogs]!.bytes == 0)
        #expect(m[.userLogs]!.present)
        #expect(m[.xcodeArchives]!.present == false)
        let total = m.values.reduce(UInt64(0)) { $0 + $1.bytes }
        #expect(total == 2 * fileBytes)
    }

    @Test func folderSizesTwoLevels() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "sysdata-home-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: home + "/Library/Caches/x", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: URL(fileURLWithPath: home + "/Library/Caches/x/f"))
        let sizes = SystemDataWalker().folderSizes(home: home, minimum: 1_000_000)
        #expect(sizes["Library/Caches"] ?? 0 >= 2_000_000)
        #expect(sizes["Library"] == sizes["Library/Caches"])
        #expect(sizes["Library/Caches/x"] == nil)
    }

    // MARK: Growth

    @Test func baselinePrefersAnHourOld() {
        let now = Date(timeIntervalSince1970: 100_000)
        let h = [SystemDataSnapshot(date: now.addingTimeInterval(-86_400), categories: [:]),
                 SystemDataSnapshot(date: now.addingTimeInterval(-7_200), categories: [:]),
                 SystemDataSnapshot(date: now.addingTimeInterval(-60), categories: [:]),
                 SystemDataSnapshot(date: now, categories: [:])]
        #expect(SystemDataHistory.baseline(in: h, now: now)?.date == now.addingTimeInterval(-7_200))
        let recentOnly = [h[2], h[3]]
        #expect(SystemDataHistory.baseline(in: recentOnly, now: now)?.date == now.addingTimeInterval(-60))
        #expect(SystemDataHistory.baseline(in: [h[3]], now: now) == nil)
    }

    @Test func growthTopAndThreshold() {
        let gb: UInt64 = 1_000_000_000
        let old: [String: UInt64] = ["a": gb, "b": gb, "c": gb, "shrink": 5 * gb]
        let new: [String: UInt64] = ["a": 3 * gb, "b": gb + 10_000_000, "c": 2 * gb, "shrink": gb, "new": gb / 2]
        let g = SystemDataHistory.growth(from: old, to: new, kind: .category)
        #expect(g.map(\.key) == ["a", "c", "new"])
        #expect(g.first?.delta == Int64(2 * gb))
        #expect(SystemDataHistory.growth(from: [:], to: new, kind: .category).isEmpty)
        #expect(SystemDataHistory.growth(from: old, to: new, kind: .category, limit: 1).count == 1)
    }

    @Test func folderGrowthPrefersSpecificChild() {
        let gb: UInt64 = 1_000_000_000
        let old: [String: UInt64] = ["Library": 10 * gb, "Library/Caches": gb, "Documents": gb]
        let new: [String: UInt64] = ["Library": 12 * gb, "Library/Caches": 3 * gb, "Documents": 2 * gb]
        let g = SystemDataHistory.growth(from: old, to: new, kind: .folder)
        #expect(g.map(\.key) == ["Library/Caches", "Documents"])
    }

    @Test func historyAppendMergesAndTrims() {
        var h: [SystemDataSnapshot] = []
        for i in 0..<70 { h = SystemDataHistory.appending(.init(date: Date(timeIntervalSince1970: Double(i)), categories: [:]), to: h) }
        #expect(h.count == SystemDataHistory.maxSnapshots)
        let last = Date(timeIntervalSince1970: 69)
        h = SystemDataHistory.appending(.init(date: last, categories: ["x": 1], folders: ["F": 2]), to: h)
        #expect(h.count == SystemDataHistory.maxSnapshots)
        #expect(h.last?.folders == ["F": 2])

        let url = FileManager.default.temporaryDirectory.appending(path: "sysdata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        SystemDataHistory.save(h, to: url)
        #expect(SystemDataHistory.load(from: url) == h)
    }
}
