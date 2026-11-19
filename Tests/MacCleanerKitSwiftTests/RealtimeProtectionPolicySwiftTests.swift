import Testing
@testable import MacCleanerKit

@Suite("Real-time protection policy")
struct RealtimeProtectionPolicySwiftTests {
    let home = "/Users/tester"
    var policy: RealtimeWatchPolicy {
        .standard(home: home, tmpDir: "/var/folders/ab/xyz/T/")
    }

    @Test func launchItemsOnlyDirectPlists() {
        #expect(policy.inspectionTarget(for: "\(home)/Library/LaunchAgents/com.evil.plist") == "\(home)/Library/LaunchAgents/com.evil.plist")
        #expect(policy.inspectionTarget(for: "/Library/LaunchDaemons/com.evil.plist") == "/Library/LaunchDaemons/com.evil.plist")
        #expect(policy.inspectionTarget(for: "\(home)/Library/LaunchAgents/notes.txt") == nil)
        #expect(policy.inspectionTarget(for: "\(home)/Library/LaunchAgents/sub/x.plist") == nil)
        #expect(policy.isLaunchItem("/Library/LaunchAgents/com.evil.plist"))
        #expect(!policy.isLaunchItem("\(home)/Downloads/com.evil.plist"))
    }

    @Test func bundlesCollapse() {
        #expect(policy.inspectionTarget(for: "\(home)/Downloads/Evil.app/Contents/MacOS/Evil") == "\(home)/Downloads/Evil.app")
        #expect(policy.inspectionTarget(for: "\(home)/Downloads/Folder/Evil.app/Contents/Info.plist") == "\(home)/Downloads/Folder/Evil.app")
    }

    @Test func depthLimits() {
        #expect(policy.inspectionTarget(for: "\(home)/Downloads/a/b/c.sh") == nil)
        #expect(policy.inspectionTarget(for: "\(home)/Library/Application Support/Genio") == "\(home)/Library/Application Support/Genio")
        #expect(policy.inspectionTarget(for: "\(home)/Library/Application Support/Google/Chrome/Default/Cookies") == nil)
        #expect(policy.inspectionTarget(for: "\(home)/Documents/x.app") == nil)
        #expect(policy.inspectionTarget(for: "\(home)/Downloads") == nil)
    }

    @Test func transientAndJunkIgnored() {
        #expect(policy.inspectionTarget(for: "\(home)/Downloads/big.dmg.crdownload") == nil)
        #expect(policy.inspectionTarget(for: "\(home)/Downloads/big.dmg.download/big.dmg") == nil)
        #expect(policy.inspectionTarget(for: "\(home)/Downloads/.DS_Store") == nil)
    }

    @Test func tempFoldersResolved() {
        // FSEvents reports /private/var/...; TMPDIR is configured as /var/...
        #expect(policy.inspectionTarget(for: "/private/var/folders/ab/xyz/T/payload") == "/private/var/folders/ab/xyz/T/payload")
        #expect(policy.inspectionTarget(for: "/private/tmp/.hidden/stealer") == "/private/tmp/.hidden/stealer")
        #expect(policy.inspectionTarget(for: "/Users/Shared/x.command") == "/Users/Shared/x.command")
    }

    @Test func coalesceDedupesAndDropsSelf() {
        let raw = [
            "\(home)/Downloads/Evil.app/Contents/MacOS/Evil",
            "\(home)/Downloads/Evil.app/Contents/Info.plist",
            "\(home)/Library/Application Support/Mac Cleaner",
            "\(home)/Downloads/other.pkg",
        ]
        let out = policy.coalescedTargets(raw) { path in
            MalwareSignatures.isSelf(path: path, home: home, bundleIDLookup: { _ in nil })
        }
        #expect(out == ["\(home)/Downloads/Evil.app", "\(home)/Downloads/other.pkg"])
    }

    @Test func deduperAlertsOncePerPathAndReason() {
        var d = RealtimeAlertDeduper()
        let first = d.shouldAlert(RealtimeMalwareAlert(path: "/x", name: "x", reason: "r1"))
        let repeated = d.shouldAlert(RealtimeMalwareAlert(path: "/x", name: "x", reason: "r1"))
        let otherReason = d.shouldAlert(RealtimeMalwareAlert(path: "/x", name: "x", reason: "r2"))
        let otherPath = d.shouldAlert(RealtimeMalwareAlert(path: "/y", name: "y", reason: "r1"))
        #expect(first && !repeated && otherReason && otherPath)
    }
}
