import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Installed packages: pkgutil parsing and removal plan")
struct PackageReceiptsTests {
    let info = """
    package-id: com.logitech.LogiRightSightForWebcams.pkg
    version: 0
    volume: /
    location: Library/Application Support/Logitech.localized/LogiRightSightForWebcams
    install-time: 1765921756
    """

    @Test func parsesPkgInfo() throws {
        let r = try #require(PackageReceipts.parseInfo(info))
        #expect(r.packageID == "com.logitech.LogiRightSightForWebcams.pkg")
        #expect(r.version == "0")
        #expect(r.installDate == Date(timeIntervalSince1970: 1765921756))
        #expect(r.root == "/Library/Application Support/Logitech.localized/LogiRightSightForWebcams/")
        #expect(r.absolutePath("LogiRightSight.app/Contents") ==
                "/Library/Application Support/Logitech.localized/LogiRightSightForWebcams/LogiRightSight.app/Contents")
        #expect(r.vendor == "logitech")
    }

    @Test func emptyLocationAndHomeVolume() {
        let r = PackageReceipt(packageID: "x.y", version: "1", volume: "/Users/me/", location: "", installDate: nil)
        #expect(r.absolutePath("Library/Foo") == "/Users/me/Library/Foo")
        let root = PackageReceipt(packageID: "x.y", version: "1", volume: "/", location: "", installDate: nil)
        #expect(root.absolutePath("./usr/local/bin/tool") == "/usr/local/bin/tool")
    }

    @Test func rejectsGarbage() {
        #expect(PackageReceipts.parseInfo("No receipt for 'x' found at '/'.") == nil)
    }

    @Test func listSkipsAppleByDefault() {
        let out = "com.apple.pkg.Core\ncom.teamviewer.x\n\nnet.whatsapp.WhatsApp\nCOM.APPLE.pkg.X\n"
        #expect(PackageReceipts.parseList(out, includeApple: false) == ["com.teamviewer.x", "net.whatsapp.WhatsApp"])
        #expect(PackageReceipts.parseList(out, includeApple: true).count == 4)
    }

    @Test func vendorGrouping() {
        #expect(PackageReceipts.vendor(of: "com.teamviewer.AuthorizationPlugin") == "teamviewer")
        #expect(PackageReceipts.vendor(of: "TeamViewerUninstaller") == "TeamViewerUninstaller")
        #expect(PackageReceipts.vendor(of: "dev.fka.textream") == "fka")
        let rs = ["com.teamviewer.b", "com.teamviewer.a", "net.mullvad.vpn"].map {
            PackageReceipt(packageID: $0, version: "", volume: "/", location: "", installDate: nil)
        }
        let groups = PackageReceipts.groupedByVendor(rs)
        #expect(groups.map(\.vendor) == ["mullvad", "teamviewer"])
        #expect(groups[1].receipts.map(\.packageID) == ["com.teamviewer.a", "com.teamviewer.b"])
    }

    @Test func applePackagesHaveNoPlan() {
        let r = PackageReceipt(packageID: "com.apple.pkg.Core", version: "", volume: "/", location: "", installDate: nil)
        #expect(PackageReceipts.removalPlan(receipt: r, files: ["/x"], directories: [], otherPackagesPaths: [],
                                            home: "/Users/me", existing: { _ in true }) == nil)
    }

    @Test func planSplitsUserSystemSharedAndProtected() throws {
        let r = PackageReceipt(packageID: "com.vendor.tool", version: "1", volume: "/", location: "", installDate: nil)
        let files = ["/usr/local/bin/tool", "/Users/me/Library/Application Support/Tool/data",
                     "/usr/local/lib/libshared.dylib", "/System/Library/Extensions/bad.kext/x", "/gone"]
        let dirs = ["/usr/local", "/usr/local/bin", "/Library/Application Support/Tool", "/Library/Application Support/Tool/sub",
                    "/Applications", "/Users/me/Library", "/Users/me/Library/Application Support",
                    "/Users/me/Library/Application Support/Tool"]
        let plan = try #require(PackageReceipts.removalPlan(
            receipt: r, files: files, directories: dirs,
            otherPackagesPaths: ["/usr/local/lib/libshared.dylib"],
            home: "/Users/me", existing: { $0 != "/gone" }))
        #expect(plan.userFiles == ["/Users/me/Library/Application Support/Tool/data"])
        #expect(plan.systemFiles == ["/usr/local/bin/tool"])
        #expect(plan.sharedFiles == ["/usr/local/lib/libshared.dylib"])
        #expect(plan.protectedPaths.contains("/System/Library/Extensions/bad.kext/x"))
        #expect(plan.protectedPaths.contains("/usr/local"))
        #expect(plan.protectedPaths.contains("/Applications"))
        #expect(plan.protectedPaths.contains("/Users/me/Library/Application Support"))
        // Own folders only, deepest first.
        #expect(plan.directories == ["/Users/me/Library/Application Support/Tool",
                                     "/Library/Application Support/Tool/sub",
                                     "/Library/Application Support/Tool"])
    }

    @Test func forbiddenPaths() {
        #expect(PackageReceipts.isForbidden("/System/Library/x"))
        #expect(PackageReceipts.isForbidden("/usr/bin/python3"))
        #expect(PackageReceipts.isForbidden("/Library/../System/x"))
        #expect(PackageReceipts.isForbidden("/Library"))
        #expect(!PackageReceipts.isForbidden("/usr/local/bin/tool"))
        #expect(!PackageReceipts.isForbidden("/Library/LaunchDaemons/com.vendor.plist"))
    }

    @Test func shellQuoting() {
        #expect(PackageReceipts.shellQuote("/a b/c") == "'/a b/c'")
        #expect(PackageReceipts.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func adminScriptBackupNeverUsesRecursiveDelete() {
        let s = PackageReceipts.adminScript(packageID: "com.vendor.tool", systemFiles: ["/usr/local/bin/tool"],
                                            directories: ["/Library/Application Support/Tool"],
                                            action: .backup(folder: "/Users/me/Backup"), owner: "me")
        #expect(s.contains("/bin/mv -f '/usr/local/bin/tool' '/Users/me/Backup/usr/local/bin/tool'"))
        #expect(s.contains("/bin/rmdir '/Library/Application Support/Tool'"))
        #expect(s.hasSuffix("/usr/sbin/pkgutil --forget 'com.vendor.tool'"))
        #expect(!s.contains("rm -r"))
        #expect(!s.contains("rm -f"))
        let d = PackageReceipts.adminScript(packageID: "p", systemFiles: ["/x"], directories: [], action: .delete)
        #expect(d.hasPrefix("/bin/rm -f '/x'"))
    }
}
