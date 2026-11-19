import Foundation
import Testing
@testable import MacCleanerKit

@Suite("System icon paths")
struct SystemIconPathsTests {
    @Test func pathsAreAbsoluteSystemBundles() {
        #expect(Set(SystemIconPaths.all).count == SystemIconPaths.all.count)
        for path in SystemIconPaths.all {
            #expect(path.hasPrefix("/System/"), "\(path)")
            #expect(path.hasSuffix(".app") || path.hasSuffix(".appex"), "\(path)")
        }
    }

    @Test func fallbackOrderIsRespected() {
        let present: Set<String> = ["/b", "/c"]
        #expect(SystemIconPaths.firstExisting(["/a", "/b", "/c"]) { present.contains($0) } == "/b")
        #expect(SystemIconPaths.firstExisting(["/a"]) { present.contains($0) } == nil)
        #expect(SystemIconPaths.firstExisting([]) { _ in true } == nil)
    }

    /// On macOS 26 and later (Tahoe look) every icon the app uses is present.
    @Test func iconsExistOnTahoe() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }
        let missing = SystemIconPaths.all.filter { !FileManager.default.fileExists(atPath: $0) }
        #expect(missing.isEmpty, "missing: \(missing)")
    }
}
