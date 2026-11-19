import Foundation
import Darwin
import Testing
@testable import MacCleanerKit

@Suite("First-run installer")
struct InstallerLogicTests {
    private let home = "/Users/u"

    @Test func classifiesDiskImageTranslocationAndApplications() {
        let dmg = InstallLocation.classify(bundlePath: "/Volumes/Mac Mop/Mac Mop.app", home: home,
                                           volumeIsReadOnly: true, volumeHasApplicationsLink: true)
        #expect(dmg == .diskImage(volume: "/Volumes/Mac Mop"))
        #expect(dmg.offersInstaller)

        let rwImage = InstallLocation.classify(bundlePath: "/Volumes/Mac Mop 1/Mac Mop.app", home: home,
                                               volumeIsReadOnly: false, volumeHasApplicationsLink: true)
        #expect(rwImage == .diskImage(volume: "/Volumes/Mac Mop 1"))

        let translocated = InstallLocation.classify(
            bundlePath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/Mac Mop.app", home: home,
            volumeIsReadOnly: false, volumeHasApplicationsLink: false)
        #expect(translocated == .translocated)
        #expect(translocated.offersInstaller)

        #expect(InstallLocation.classify(bundlePath: "/Applications/Mac Mop.app", home: home,
                                         volumeIsReadOnly: false, volumeHasApplicationsLink: false) == .applications)
        #expect(InstallLocation.classify(bundlePath: "/Users/u/Applications/Tools/Mac Mop.app", home: home,
                                         volumeIsReadOnly: false, volumeHasApplicationsLink: false) == .applications)
        // An external drive the user runs apps from is not an installer image.
        let external = InstallLocation.classify(bundlePath: "/Volumes/Archive/Apps/Mac Mop.app", home: home,
                                                volumeIsReadOnly: false, volumeHasApplicationsLink: false)
        #expect(external == .other)
        #expect(!external.offersInstaller)
        #expect(InstallLocation.classify(bundlePath: "/Users/u/Projects/MacCleaner/.build/release/MacCleaner",
                                         home: home, volumeIsReadOnly: false, volumeHasApplicationsLink: false) == .other)
    }

    @Test func volumeRoot() {
        #expect(InstallLocation.volumeRoot(of: "/Volumes/Mac Mop/Mac Mop.app/Contents") == "/Volumes/Mac Mop")
        #expect(InstallLocation.volumeRoot(of: "/Volumes") == nil)
        #expect(InstallLocation.volumeRoot(of: "/Applications/Mac Mop.app") == nil)
    }

    @Test func planPrefersApplicationsAndTrashesExisting() throws {
        let source = URL(fileURLWithPath: "/Volumes/Mac Mop/Mac Mop.app")
        let plan = try #require(InstallPlanner.plan(source: source, override: nil, home: home,
                                                    ejectVolume: "/Volumes/Mac Mop",
                                                    isWritable: { _ in true },
                                                    exists: { $0.path == "/Applications/Mac Mop.app" }))
        #expect(plan.destination.path == "/Applications/Mac Mop.app")
        #expect(plan.temporary.path == "/Applications/.Mac Mop.app.installing")
        #expect(plan.existing?.path == "/Applications/Mac Mop.app")
        #expect(!plan.usesUserApplications)
        #expect(plan.ejectVolume == "/Volumes/Mac Mop")
    }

    @Test func planFallsBackToUserApplications() throws {
        let source = URL(fileURLWithPath: "/Volumes/Mac Mop/Mac Mop.app")
        let plan = try #require(InstallPlanner.plan(source: source, override: nil, home: home, ejectVolume: nil,
                                                    isWritable: { $0.path != "/Applications" }, exists: { _ in false }))
        #expect(plan.destination.path == "/Users/u/Applications/Mac Mop.app")
        #expect(plan.usesUserApplications)
        #expect(plan.existing == nil)
        // Nothing writable: no plan (the UI shows drag-to-install instructions).
        #expect(InstallPlanner.plan(source: source, override: nil, home: home, ejectVolume: nil,
                                    isWritable: { _ in false }, exists: { _ in false }) == nil)
    }

    @Test func planHonoursOverrideAndRefusesSelfInstall() {
        let source = URL(fileURLWithPath: "/Volumes/Mac Mop/Mac Mop.app")
        let plan = InstallPlanner.plan(source: source, override: "/tmp/dest", home: home, ejectVolume: nil,
                                       isWritable: { _ in true }, exists: { _ in false })
        #expect(plan?.destination.path == "/tmp/dest/Mac Mop.app")
        #expect(plan?.usesUserApplications == false)
        let installed = URL(fileURLWithPath: "/Applications/Mac Mop.app")
        #expect(InstallPlanner.plan(source: installed, override: nil, home: home, ejectVolume: nil,
                                    isWritable: { _ in true }, exists: { _ in true }) == nil)
        #expect(InstallPlanner.plan(source: URL(fileURLWithPath: "/tmp/MacCleaner"), override: nil, home: home,
                                    ejectVolume: nil, isWritable: { _ in true }, exists: { _ in false }) == nil)
    }

    @Test func ejectArgumentIsValidated() {
        #expect(InstallerLaunchArgument.ejectVolume(in: ["app", "--kmr-eject-volume", "/Volumes/Mac Mop"]) == "/Volumes/Mac Mop")
        #expect(InstallerLaunchArgument.ejectVolume(in: ["app", "--kmr-eject-volume", "/"]) == nil)
        #expect(InstallerLaunchArgument.ejectVolume(in: ["app", "--kmr-eject-volume", "/Volumes/X/sub"]) == nil)
        #expect(InstallerLaunchArgument.ejectVolume(in: ["app", "--kmr-eject-volume", "/Volumes/.."]) == nil)
        #expect(InstallerLaunchArgument.ejectVolume(in: ["app", "--kmr-eject-volume"]) == nil)
        #expect(InstallerLaunchArgument.ejectVolume(in: ["app"]) == nil)
    }

    @Test func relaunchCommandPassesValuesAsParameters() {
        let args = InstallerLaunchArgument.relaunchCommand(pid: 42, appPath: "/Applications/Mac Mop.app",
                                                           ejectVolume: "/Volumes/Mac Mop")
        #expect(args.count == 6)
        #expect(args[0] == "-c")
        #expect(!args[1].contains("Mac Mop"))
        #expect(Array(args[3...]) == ["42", "/Applications/Mac Mop.app", "/Volumes/Mac Mop"])
    }

    @Test func installerCopiesReplacesAndClearsQuarantine() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kmr-installer-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("image/Mac Mop.app")
        try fm.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("Contents/MacOS/MacCleaner")
        try Data("new".utf8).write(to: exe)
        let q = "0081;00000000;Safari;"
        #expect(setxattr(exe.path, "com.apple.quarantine", q, q.utf8.count, 0, 0) == 0)
        #expect(setxattr(source.path, "com.apple.quarantine", q, q.utf8.count, 0, 0) == 0)

        let dest = root.appendingPathComponent("Applications")
        let old = dest.appendingPathComponent("Mac Mop.app/Contents")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("marker"))

        let trashDir = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let installer = AppBundleInstaller(trash: { url in
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        })
        let plan = try #require(InstallPlanner.plan(source: source, override: dest.path, home: home, ejectVolume: nil,
                                                    isWritable: InstallPlanner.isWritableFolder,
                                                    exists: { fm.fileExists(atPath: $0.path) }))
        #expect(plan.existing != nil)
        var steps: [InstallStep] = []
        let installed = try installer.install(plan) { steps.append($0) }

        #expect(steps == [.copying, .replacing, .finishing, .done])
        let copied = installed.appendingPathComponent("Contents/MacOS/MacCleaner")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "new")
        #expect(getxattr(copied.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        #expect(getxattr(installed.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        #expect(fm.fileExists(atPath: trashDir.appendingPathComponent("Mac Mop.app/Contents/marker").path))
        #expect(!fm.fileExists(atPath: plan.temporary.path))
        // The source on the "disk image" is untouched.
        #expect(getxattr(exe.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
    }

    @Test func failedTrashLeavesPreviousVersionInPlace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kmr-installer-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("image/Mac Mop.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: dest.appendingPathComponent("Mac Mop.app"), withIntermediateDirectories: true)
        struct Refused: Error {}
        let installer = AppBundleInstaller(trash: { _ in throw Refused() })
        let plan = try #require(InstallPlanner.plan(source: source, override: dest.path, home: home, ejectVolume: nil,
                                                    isWritable: { _ in true }, exists: { fm.fileExists(atPath: $0.path) }))
        #expect(throws: Refused.self) { try installer.install(plan) }
        #expect(fm.fileExists(atPath: plan.destination.path))
        #expect(!fm.fileExists(atPath: plan.temporary.path))
    }
}
