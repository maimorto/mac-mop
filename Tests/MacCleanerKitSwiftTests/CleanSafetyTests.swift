import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Clean safety")
struct CleanSafetyTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func disk(dir: Bool = false, inode: UInt64 = 10, device: Int32 = 1, size: UInt64 = 4096,
                      allocated: UInt64 = 4096, mtime: Date? = nil) -> CleanSafety.DiskState {
        CleanSafety.DiskState(isDirectory: dir, inode: inode, device: device, size: size,
                              allocatedSize: allocated, modificationDate: mtime ?? date)
    }

    private func scanned(dir: Bool = false, inode: UInt64 = 10, device: Int32 = 1, size: UInt64 = 4096,
                         mtime: Date? = nil) -> CleanSafety.Fingerprint {
        CleanSafety.Fingerprint(isDirectory: dir, inode: inode, device: device, size: size,
                                allocatedSize: size, modificationDate: mtime ?? date)
    }

    @Test func unchangedFileIsCleaned() {
        #expect(CleanSafety.compare(scanned: scanned(), now: disk()) == nil)
    }

    @Test func missingFile() {
        #expect(CleanSafety.compare(scanned: scanned(), now: nil) == .missing)
    }

    @Test func replacedFileIsSkipped() {
        #expect(CleanSafety.compare(scanned: scanned(), now: disk(inode: 11)) == .changed)
        #expect(CleanSafety.compare(scanned: scanned(), now: disk(device: 2)) == .changed)
    }

    @Test func rewrittenFileIsSkipped() {
        #expect(CleanSafety.compare(scanned: scanned(), now: disk(mtime: date.addingTimeInterval(30))) == .changed)
        #expect(CleanSafety.compare(scanned: scanned(), now: disk(size: 9000, allocated: 12288)) == .changed)
    }

    @Test func subSecondTimestampDriftIsTolerated() {
        #expect(CleanSafety.compare(scanned: scanned(), now: disk(mtime: date.addingTimeInterval(0.4))) == nil)
    }

    @Test func allocatedOrLogicalSizeBothMatch() {
        // Some scanners record allocated size, others the logical size.
        #expect(CleanSafety.compare(scanned: scanned(size: 4096), now: disk(size: 3000, allocated: 4096)) == nil)
        #expect(CleanSafety.compare(scanned: scanned(size: 3000), now: disk(size: 3000, allocated: 4096)) == nil)
    }

    @Test func unknownIdentityFallsBackToDateAndSize() {
        #expect(CleanSafety.compare(scanned: scanned(inode: 0, device: 0), now: disk(inode: 99, device: 7)) == nil)
    }

    @Test func foldersOnlyCompareIdentity() {
        // A cache folder's date and size change constantly: never a reason to skip.
        let folder = scanned(dir: true, size: 900_000_000, mtime: date)
        #expect(CleanSafety.compare(scanned: folder, now: disk(dir: true, size: 192, mtime: date.addingTimeInterval(500))) == nil)
        #expect(CleanSafety.compare(scanned: folder, now: disk(dir: true, inode: 12)) == .changed)
        #expect(CleanSafety.compare(scanned: folder, now: disk(dir: false)) == .changed)
    }

    @Test func runningAppBundles() {
        let running: Set<String> = ["/Applications/Slack.app"]
        #expect(CleanSafety.isInUse(path: "/Applications/Slack.app", runningBundlePaths: running))
        #expect(CleanSafety.isInUse(path: "/Applications/Slack.app/", runningBundlePaths: running))
        #expect(CleanSafety.isInUse(path: "/Applications/Slack.app/Contents/Frameworks", runningBundlePaths: running))
        #expect(!CleanSafety.isInUse(path: "/Applications/Slack Helper.app", runningBundlePaths: running))
        #expect(!CleanSafety.isInUse(path: "/Applications/Slack.app", runningBundlePaths: []))
    }

    @Test func protectedDataRuleSparesOnlyBrowserPrivacy() {
        #expect(!CleanSafety.enforcesProtectedUserData(for: .browserPrivacy))
        #expect(!CleanSafety.enforcesProtectedUserData(for: .systemPrivacy))
        #expect(CleanSafety.enforcesProtectedUserData(for: .appLeftovers))
        #expect(CleanSafety.enforcesProtectedUserData(for: .userCaches))
        #expect(CleanSafety.enforcesProtectedUserData(for: .malware))
        // A browser's own cache folder may be emptied by cache cleanups only.
        let safariCache = "/Users/me/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari"
        #expect(!CleanSafety.enforcesProtectedUserData(for: .userCaches, path: safariCache))
        #expect(CleanSafety.enforcesProtectedUserData(for: .appLeftovers, path: safariCache))
        #expect(CleanSafety.enforcesProtectedUserData(for: .userCaches, path: "/Users/me/Library/Application Support/Exodus"))
    }

    @Test func planGroupsByCategoryAndListsSkips() {
        let plan = CleanSafety.plan([
            (.userCaches, 100, "/a", nil),
            (.userCaches, 50, "/b", nil),
            (.userLogs, 500, "/c", nil),
            (.userLogs, 10, "/d", .changed),
            (.appLeftovers, 70, "/e", .protectedData),
            (.universalBinaries, 30, "/f", nil),
        ])
        #expect(plan.lines.map(\.category) == [.userLogs, .userCaches, .universalBinaries])
        #expect(plan.lines.first { $0.category == .userCaches }?.count == 2)
        #expect(plan.totalCount == 4)
        #expect(plan.totalBytes == 680)
        #expect(plan.lines.first { $0.category == .universalBinaries }?.action == .thinInPlace)
        #expect(plan.skips.count == 2)
        #expect(plan.skipCounts.map(\.reason) == [.changed, .protectedData])
    }

    @Test func dryRunPolicy() {
        #expect(CleanSafety.needsDryRun(hasCleanedBefore: false, alwaysDryRun: false))
        #expect(!CleanSafety.needsDryRun(hasCleanedBefore: true, alwaysDryRun: false))
        #expect(CleanSafety.needsDryRun(hasCleanedBefore: true, alwaysDryRun: true))
    }

    @Test func readsRealDiskState() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cleansafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.txt")
        try Data(repeating: 1, count: 1000).write(to: file)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let state = try #require(CleanSafety.DiskState.read(file.path))
        let fp = CleanSafety.Fingerprint(isDirectory: false, inode: state.inode, device: state.device,
                                         size: UInt64(values.fileSize ?? 0), modificationDate: values.contentModificationDate)
        #expect(CleanSafety.compare(scanned: fp, now: state) == nil)
        try Data(repeating: 2, count: 5000).write(to: file)
        #expect(CleanSafety.compare(scanned: fp, now: CleanSafety.DiskState.read(file.path)) == .changed)
        #expect(CleanSafety.DiskState.read(dir.appending(path: "nope").path) == nil)
    }
}
