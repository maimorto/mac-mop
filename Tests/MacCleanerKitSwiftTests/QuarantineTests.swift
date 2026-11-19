import Foundation
import Darwin
import Testing
@testable import MacCleanerKit

@Suite("Malware quarantine")
struct QuarantineTests {
    private let root = URL(filePath: "/Users/u/Library/Application Support/Mac Cleaner/Quarantine")
    private let date = Date(timeIntervalSince1970: 1_794_383_931) // 2026-11-11

    @Test func destinationUsesDayFolderAndUniqueNames() {
        let item = URL(filePath: "/Users/u/Downloads/Installer.app")
        let first = MalwareQuarantine.destination(for: item, date: date, root: root) { _ in false }
        #expect(first.path(percentEncoded: false).hasSuffix("/Quarantine/2026-11-11/Installer.app"))
        var taken: Set<String> = [first.path(percentEncoded: false)]
        let second = MalwareQuarantine.destination(for: item, date: date, root: root) { taken.contains($0) }
        #expect(second.lastPathComponent == "Installer 2.app")
        taken.insert(second.path(percentEncoded: false))
        let third = MalwareQuarantine.destination(for: item, date: date, root: root) { taken.contains($0) }
        #expect(third.lastPathComponent == "Installer 3.app")
        let bare = MalwareQuarantine.destination(for: URL(filePath: "/tmp/.helper"), date: date, root: root) { _ in false }
        #expect(bare.lastPathComponent == ".helper")
    }

    @Test func insideQuarantineIsStrict() {
        let base = root.path(percentEncoded: false)
        #expect(MalwareQuarantine.isInsideQuarantine(base + "/2026-11-11/x.app", root: root))
        #expect(!MalwareQuarantine.isInsideQuarantine(base, root: root))
        #expect(!MalwareQuarantine.isInsideQuarantine(base + "/../../../../etc/passwd", root: root))
        #expect(!MalwareQuarantine.isInsideQuarantine("/Users/u/Library/Application Support/Mac Cleaner/QuarantineX/a", root: root))
        #expect(!MalwareQuarantine.isInsideQuarantine("relative/path", root: root))
    }

    @Test func disarmedModeClearsOnlyExecuteBits() {
        #expect(MalwareQuarantine.disarmedMode(0o755) == 0o644)
        #expect(MalwareQuarantine.disarmedMode(0o4711) == 0o4600)
        #expect(MalwareQuarantine.disarmedMode(0o600) == 0o600)
    }

    @Test func quarantineValueFormat() {
        let value = MalwareQuarantine.quarantineValue(date: date)
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        #expect(parts.count == 4)
        #expect(parts[0] == "0081")
        #expect(UInt32(parts[1], radix: 16) == UInt32(date.timeIntervalSince1970))
    }

    /// Real files, in a fresh temp folder only.
    @Test func disarmThenRearmRestoresPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "w3-quarantine-\(UUID().uuidString)")
        let app = dir.appending(path: "Thing.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = app.appending(path: "Thing")
        let plain = dir.appending(path: "Thing.app/Contents/Info.plist")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: exe)
        try Data("<plist/>".utf8).write(to: plain)
        chmod(exe.path(percentEncoded: false), 0o755)
        chmod(plain.path(percentEncoded: false), 0o644)

        let bundle = dir.appending(path: "Thing.app")
        MalwareQuarantine.disarm(bundle, now: date)
        #expect(mode(exe) == 0o644)
        #expect(mode(plain) == 0o644)
        #expect(getxattr(bundle.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)

        MalwareQuarantine.rearm(bundle)
        #expect(mode(exe) == 0o755)
        #expect(mode(plain) == 0o644)
        #expect(getxattr(exe.path(percentEncoded: false), MalwareQuarantine.originalModeAttribute, nil, 0, 0, XATTR_NOFOLLOW) < 0)
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path(percentEncoded: false), &info)
        return info.st_mode & 0o7777
    }
}

@Suite("Scheduled malware scan")
struct ScheduledMalwareScanPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_794_383_931)

    @Test func dueAfterAWeekOrNeverScanned() {
        #expect(MalwareScanSchedule.isDue(enabled: true, lastScan: nil, now: now))
        #expect(MalwareScanSchedule.isDue(enabled: true, lastScan: now.addingTimeInterval(-8 * 86_400), now: now))
        #expect(!MalwareScanSchedule.isDue(enabled: true, lastScan: now.addingTimeInterval(-2 * 86_400), now: now))
    }

    @Test func disabledIsNeverDue() {
        #expect(!MalwareScanSchedule.isDue(enabled: false, lastScan: nil, now: now))
    }

    @Test func clockSetBackIsDue() {
        #expect(MalwareScanSchedule.isDue(enabled: true, lastScan: now.addingTimeInterval(5 * 86_400), now: now))
    }
}
