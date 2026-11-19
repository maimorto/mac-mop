import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Extra YARA rules (ESET)")
struct ExtraYaraTests {
    /// Resources/YARA in the source tree.
    private static var resources: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources")
    }

    private static var esetRules: [(XProtectYaraSource, String)] { ExtraYaraRules.load(resources: resources) }

    @Test func bundledRulesLoadWithLicenseHeader() throws {
        let rules = Self.esetRules
        #expect(rules.count == ExtraYaraRules.files.count)
        #expect(rules.first?.0 == .eset)
        #expect(rules.first?.1.contains("two-clause BSD") == true)
        let license = try String(contentsOf: Self.resources.appending(path: "YARA/LICENSE-ESET-malware-ioc.txt"), encoding: .utf8)
        #expect(license.contains("ESET spol. s r.o."))
    }

    @Test func allEsetRulesCompile() {
        let set = XProtectYaraRuleSet.compile(xprotectYara: nil, extra: Self.esetRules)
        #expect(set.counts(for: .eset).total == 3)
        #expect(set.counts(for: .eset).supported == 3)
        #expect(set.skippedFeatureCounts.isEmpty)
    }

    @Test func matchesSyntheticSampleWithSourceTag() {
        let set = XProtectYaraRuleSet.compile(xprotectYara: nil, extra: Self.esetRules)
        let sample = Data("xx icloudsyncd yy killall Terminal zz".utf8)
        let hits = set.matches(data: sample)
        #expect(hits.map(\.ruleName) == ["keydnap_downloader"])
        #expect(hits.first?.source == .eset)
        #expect(hits.first?.source.isApple == false)
        #expect(hits.first?.family == "OSX/Keydnap Downloader")
        // `not $upx_magic`: a real UPX file is not the Keydnap packer.
        let upx = Data("This file is packed with the UPX ASS7 UPX!".utf8)
        #expect(set.matches(data: upx).isEmpty)
        #expect(set.matches(data: Data("This file is packed with the UPX ASS7".utf8)).map(\.ruleName) == ["keydnap_backdoor_packer"])
    }

    @Test func appleAndExtraRulesCompileTogether() {
        let apple = #"rule a { strings: $x = "applething" condition: $x }"#
        let set = XProtectYaraRuleSet.compile(xprotectYara: apple, extra: Self.esetRules)
        #expect(set.counts(for: .xprotect).supported == 1)
        #expect(set.counts(for: .eset).supported == 3)
        #expect(set.matches(data: Data("applething".utf8)).first?.source == .xprotect)
    }

    /// Zero hits on clean system binaries (a bounded sample).
    @Test func noHitsOnCleanSystemBinaries() throws {
        let set = XProtectYaraRuleSet.compile(xprotectYara: nil, extra: Self.esetRules)
        var scanned = 0
        for dir in ["/bin", "/usr/bin", "/usr/sbin", "/usr/libexec"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted().prefix(150) {
                let url = URL(filePath: dir).appending(path: name)
                let hits = set.matches(fileAt: url)
                #expect(hits.isEmpty, "\(url.path): \(hits.map(\.ruleName))")
                scanned += 1
            }
        }
        #expect(scanned > 100)
    }
}
