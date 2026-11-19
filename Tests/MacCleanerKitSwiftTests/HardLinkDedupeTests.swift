import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Hard links and firmlinks are counted once")
struct HardLinkDedupeTests {
    @Test func singleLinkFilesAlwaysCount() {
        let t = SharedHardLinkTracker()
        #expect(t.shouldCount(device: 1, inode: 5, linkCount: 1))
        #expect(t.shouldCount(device: 1, inode: 5, linkCount: 1))
        #expect(t.trackedCount == 0)
    }

    @Test func hardLinksCountOnce() {
        let t = SharedHardLinkTracker()
        #expect(t.shouldCount(device: 1, inode: 7, linkCount: 3))
        #expect(!t.shouldCount(device: 1, inode: 7, linkCount: 3))
        #expect(!t.shouldCount(device: 1, inode: 7, linkCount: 3))
        // Same inode number on another volume is another file.
        #expect(t.shouldCount(device: 2, inode: 7, linkCount: 2))
        #expect(t.trackedCount == 2)
    }

    @Test func unknownInodeIsNeverDeduplicated() {
        let t = SharedHardLinkTracker()
        #expect(t.shouldCount(device: 1, inode: 0, linkCount: 2))
        #expect(t.shouldCount(device: 1, inode: 0, linkCount: 2))
    }

    @Test func concurrentWalkersAgreeOnOneWinner() async {
        let t = SharedHardLinkTracker()
        let wins = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask { (0..<100).reduce(0) { n, i in n + (t.shouldCount(device: 1, inode: UInt64(i + 1), linkCount: 2) ? 1 : 0) } }
            }
            return await group.reduce(0, +)
        }
        #expect(wins == 100)
    }

    @Test func realHardLinksViaTracker() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hardlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a"), b = dir.appending(path: "b")
        try Data(count: 10_000).write(to: a)
        try FileManager.default.linkItem(at: a, to: b)
        var tracker = HardLinkTracker()
        let links = try a.resourceValues(forKeys: [.linkCountKey]).linkCount
        #expect(links == 2)
        let first = tracker.shouldCount(a, linkCount: links)
        let second = tracker.shouldCount(b, linkCount: links)
        #expect(first)
        #expect(!second)
    }

    @Test func firmlinkedDataVolumeIsSkippedFromRoot() {
        #expect(FirmlinkPolicy.shouldSkip(directory: "/System/Volumes/Data", scanRoot: "/"))
        #expect(FirmlinkPolicy.shouldSkip(directory: "/System/Volumes/Data/", scanRoot: "/System"))
        #expect(!FirmlinkPolicy.shouldSkip(directory: "/System/Volumes/Data", scanRoot: "/System/Volumes/Data"))
        #expect(!FirmlinkPolicy.shouldSkip(directory: "/System/Volumes/Data/Users", scanRoot: "/System/Volumes/Data"))
        #expect(!FirmlinkPolicy.shouldSkip(directory: "/Users", scanRoot: "/"))
        #expect(!FirmlinkPolicy.shouldSkip(directory: "/System/Volumes/Preboot", scanRoot: "/"))
    }
}
