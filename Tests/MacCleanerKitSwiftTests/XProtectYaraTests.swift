import CryptoKit
import Foundation
import Testing
@testable import MacCleanerKit

@Suite("XProtect YARA engine")
struct XProtectYaraTests {
    // MARK: Helpers

    private func set(_ rules: String, scripts: String? = nil) -> XProtectYaraRuleSet {
        XProtectYaraRuleSet.compile(xprotectYara: rules, xpScripts: scripts)
    }

    private func rule(name: String = "r", strings: String = "", _ condition: String, imports: String = "") -> String {
        """
        \(imports)
        rule \(name)
        {
            meta:
                description = "TEST.\(name)"
            \(strings.isEmpty ? "" : "strings:\n" + strings)
            condition:
                \(condition)
        }
        """
    }

    private func matches(_ s: XProtectYaraRuleSet, _ bytes: [UInt8], _ options: XProtectYaraScanOptions = .default) -> [String] {
        s.matches(data: Data(bytes), options: options).map(\.ruleName)
    }

    private func matches(_ s: XProtectYaraRuleSet, _ text: String, _ options: XProtectYaraScanOptions = .default) -> [String] {
        matches(s, Array(text.utf8), options)
    }

    private func skipReason(_ s: XProtectYaraRuleSet, _ name: String = "r") -> String? {
        s.rules.first { $0.name == name }?.skipReason
    }

    // MARK: Text strings

    @Test func plainTextAllOfThemAndFilesize() {
        let s = set(rule(strings: "$a = \"connectToProxy\"\n$b = \"heartbeat\"", "all of them and filesize < 1KB"))
        #expect(s.supportedCount == 1)
        #expect(matches(s, "xx connectToProxy yy heartbeat") == ["r"])
        #expect(matches(s, "xx connectToProxy yy").isEmpty)
        #expect(matches(s, "connectToProxy heartbeat" + String(repeating: " ", count: 2000)).isEmpty)
    }

    @Test func caseSensitiveByDefault() {
        let s = set(rule(strings: "$a = \"Telegram\"", "$a"))
        #expect(matches(s, "TELEGRAM").isEmpty)
        #expect(matches(s, "my Telegram") == ["r"])
    }

    @Test func nocase() {
        let s = set(rule(strings: "$a = \"Telegram Data\" nocase", "$a"))
        #expect(matches(s, "tElEgRaM dAtA") == ["r"])
        #expect(matches(s, "Telegram_Data").isEmpty)
    }

    @Test func wideAndAscii() {
        let wideOnly = set(rule(strings: "$a = \"Keychain\" wide", "$a"))
        let utf16 = Array("x Keychain y".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(matches(wideOnly, utf16) == ["r"])
        #expect(matches(wideOnly, "Keychain").isEmpty)
        let both = set(rule(strings: "$a = \"Keychain\" wide ascii", "$a"))
        #expect(matches(both, utf16) == ["r"])
        #expect(matches(both, "Keychain") == ["r"])
        let wideNocase = set(rule(strings: "$a = \"Keychain\" wide nocase", "$a"))
        let upper = Array("KEYCHAIN".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(matches(wideNocase, upper) == ["r"])
    }

    @Test func fullword() {
        let s = set(rule(strings: "$a = \"dscl\" fullword", "$a"))
        #expect(matches(s, "run dscl . -authonly") == ["r"])
        #expect(matches(s, "dscl") == ["r"])
        #expect(matches(s, "xdscl").isEmpty)
        #expect(matches(s, "dscl2").isEmpty)
        #expect(matches(s, "(dscl)") == ["r"])
    }

    @Test func escapesInTextStrings() {
        let s = set(rule(strings: #"$a = "\xff Go buildinf:""# + "\n" + #"$b = "say \"hi\"\n""#, "$a and $b"))
        #expect(matches(s, [0xFF] + Array(" Go buildinf: say \"hi\"\n".utf8)) == ["r"])
    }

    @Test func overlappingMatchesAreCounted() {
        let s = set(rule(strings: "$a = \"aaaa\"", "#a == 3"))
        #expect(matches(s, "aaaaaa") == ["r"]) // offsets 0, 1, 2
        let t = set(rule(strings: "$a = \"ab\"", "#a == 2"))     // 2-byte atom path
        #expect(matches(t, "ab ab") == ["r"])
        #expect(matches(t, "ab") == [])
    }

    // MARK: Hex strings

    @Test func hexWildcardsAndNibbles() {
        let s = set(rule(strings: "$a = { 48 8B ?? 4? ?F 00 }", "$a"))
        #expect(matches(s, [0x01, 0x48, 0x8B, 0x77, 0x41, 0x3F, 0x00]) == ["r"])
        #expect(matches(s, [0x48, 0x8B, 0x77, 0x51, 0x3F, 0x00]).isEmpty) // 5? ≠ 4?
        #expect(matches(s, [0x48, 0x8B, 0x77, 0x41, 0x3E, 0x00]).isEmpty) // ?E ≠ ?F
    }

    @Test func hexJumps() {
        let s = set(rule(strings: "$a = { DE AD BE EF [2-4] CA FE }", "$a"))
        #expect(matches(s, [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 0xCA, 0xFE]) == ["r"])
        #expect(matches(s, [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 0xCA, 0xFE]) == ["r"])
        #expect(matches(s, [0xDE, 0xAD, 0xBE, 0xEF, 1, 0xCA, 0xFE]).isEmpty)
        #expect(matches(s, [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 0xCA, 0xFE]).isEmpty)
        let exact = set(rule(strings: "$a = { 11 22 33 44 [3] 55 }", "$a"))
        #expect(matches(exact, [0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0x55]) == ["r"])
        #expect(matches(exact, [0x11, 0x22, 0x33, 0x44, 0, 0, 0x55]).isEmpty)
    }

    @Test func hexAlternatives() {
        let s = set(rule(strings: "$a = { 66 0F ( 41 0F | 6F ) 38 00 C1 }", "$a"))
        #expect(matches(s, [0x66, 0x0F, 0x41, 0x0F, 0x38, 0x00, 0xC1]) == ["r"])
        #expect(matches(s, [0x66, 0x0F, 0x6F, 0x38, 0x00, 0xC1]) == ["r"])
        #expect(matches(s, [0x66, 0x0F, 0x6E, 0x38, 0x00, 0xC1]).isEmpty)
    }

    @Test func hexWithComments() {
        let s = set(rule(strings: "$a = {\n 0f b6 95 ?? ?? ?? ??  // movzx edx, byte [rbp-0x130 {s_1}]\n 30 11 }", "$a"))
        #expect(s.supportedCount == 1)
        #expect(matches(s, [0x0F, 0xB6, 0x95, 1, 2, 3, 4, 0x30, 0x11]) == ["r"])
    }

    @Test func unboundedJumpOnlyWherePositive() {
        let pos = set(rule(strings: "$a = { AA BB CC DD [-] EE FF }", "$a"))
        #expect(pos.supportedCount == 1)
        #expect(matches(pos, [0xAA, 0xBB, 0xCC, 0xDD] + [UInt8](repeating: 7, count: 500) + [0xEE, 0xFF]) == ["r"])
        let neg = set(rule(strings: "$a = { AA BB CC DD [-] EE FF }", "not $a"))
        #expect(neg.supportedCount == 0)
        let count = set(rule(strings: "$a = { AA BB CC DD [-] EE FF }", "#a < 2"))
        #expect(count.supportedCount == 0)
    }

    // MARK: Regular expressions

    @Test func regexBasics() {
        let s = set(rule(strings: #"$a = /https?:\/\/[a-z0-9\-\.]+\/ledger\/start\/[a-f0-9]{8}/"#, "$a"))
        #expect(s.supportedCount == 1)
        #expect(matches(s, "GET http://evil-host.example/ledger/start/deadbeef ok") == ["r"])
        #expect(matches(s, "GET https://x.io/ledger/start/deadbee") .isEmpty) // only 7 hex digits
        #expect(matches(s, "GET https://X.IO/ledger/start/deadbeef").isEmpty)   // case-sensitive class
    }

    @Test func regexCaseInsensitiveAndAlternation() {
        let s = set(rule(strings: #"$a = /func_[a-z0-9]{1,12}(\(| &)/i"#, "$a"))
        #expect(matches(s, "FUNC_Abc9(") == ["r"])
        #expect(matches(s, "func_x &") == ["r"])
        #expect(matches(s, "func_(").isEmpty)
        #expect(matches(s, "func_abc)").isEmpty)
    }

    @Test func regexRepeatedGroupWithoutLiteralPrefix() {
        let s = set(rule(strings: #"$a = /([A-Z]{1}\=\"[a-z]{1}\"\;){3,}/"#, "$a"))
        #expect(s.supportedCount == 1)
        #expect(matches(s, #"x A="b";C="d";E="f"; y"#) == ["r"])
        #expect(matches(s, #"x A="b";C="d"; y"#).isEmpty)
    }

    @Test func regexDotDoesNotMatchNewline() {
        let s = set(rule(strings: #"$a = /config.Build[A-Za-z]{3}Address/"#, "$a"))
        #expect(matches(s, "config_BuildXyzAddress") == ["r"])
        #expect(matches(s, "config\nBuildXyzAddress").isEmpty)
    }

    @Test func unsupportedRegexIsSkipped() {
        #expect(skipReason(set(rule(strings: #"$a = /(a)\1/"#, "$a"))) != nil)        // backreference
        #expect(skipReason(set(rule(strings: #"$a = /[a-z]+foo/"#, "$a"))) != nil)     // no fixed atom
    }

    // MARK: Conditions

    @Test func quantifiersOverStringSets() {
        let strings = "$a1 = \"alpha\"\n$a2 = \"bravo\"\n$a3 = \"charlie\"\n$b1 = \"delta\""
        let s = set(rule(strings: strings, "2 of ($a*) and any of ($b*)"))
        #expect(matches(s, "alpha charlie delta") == ["r"])
        #expect(matches(s, "alpha delta").isEmpty)
        #expect(matches(s, "alpha bravo").isEmpty)
        let none = set(rule(strings: strings, "none of ($a*) and $b1"))
        #expect(matches(none, "delta") == ["r"])
        #expect(matches(none, "delta alpha").isEmpty)
        let anyThem = set(rule(strings: strings, "any of them"))
        #expect(matches(anyThem, "bravo") == ["r"])
        let nThem = set(rule(strings: strings, "3 of them"))
        #expect(matches(nThem, "alpha bravo delta") == ["r"])
        #expect(matches(nThem, "alpha bravo").isEmpty)
    }

    @Test func countsOffsetsAndRanges() {
        let s = set(rule(strings: "$a = \"tick\"\n$b = \"MAGIC\"", "#a > 2 and $b at 0 and $a in (5..10) and @a[2] == 10"))
        #expect(matches(s, "MAGICtick.tick.tick") == ["r"])   // a at 5, 10, 15
        #expect(matches(s, "MAGICtick.tick").isEmpty)         // only 2 ticks
        #expect(matches(s, "xMAGICtick.tick.tick").isEmpty)   // MAGIC not at 0
        let countIn = set(rule(strings: "$a = \"tick\"", "#a in (0..9) == 2"))
        #expect(matches(countIn, "ticktick..tick") == ["r"])
    }

    @Test func atWithFilesizeArithmetic() {
        let s = set(rule(strings: "$h = \"FasdUAS\"\n$t = { FA DE DE AD }", "$h at 0 and $t at (filesize - 4)"))
        #expect(matches(s, Array("FasdUAS 1.101.10".utf8) + [0xFA, 0xDE, 0xDE, 0xAD]) == ["r"])
        #expect(matches(s, Array("FasdUAS 1.101.10".utf8) + [0xFA, 0xDE, 0xDE, 0xAD, 0]).isEmpty)
    }

    @Test func integerReads() {
        let macho: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]
        let le = set(rule("uint32(0) == 0xfeedfacf and uint16(4) == 0x000c"))
        #expect(matches(le, macho) == ["r"])
        let be = set(rule("uint32be(0) == 0xcffaedfe and uint8(7) == 1 and int8(0) == -49"))
        #expect(matches(be, macho) == ["r"])
        let nested = set(rule("uint8(uint8(7)) == 0xFA"))
        #expect(matches(nested, macho) == ["r"])
    }

    @Test func undefinedReadsNeverMatch() {
        let s = set(rule("uint32(100) == 0 or uint32(100) != 0"))
        #expect(matches(s, [0, 0, 0, 0]).isEmpty)
        let n = set(rule("not (uint32(100) == 0)"))
        #expect(matches(n, [0, 0, 0, 0]).isEmpty)   // not undefined is undefined
        let and = set(rule("not (uint32(100) == 0 and true)"))
        #expect(matches(and, [0, 0, 0, 0]) == ["r"]) // undefined and x → false
    }

    @Test func booleanOperatorsAndPrecedence() {
        let strings = "$a = \"aa\"\n$b = \"bb\"\n$c = \"cc\""
        let s = set(rule(strings: strings, "$a or $b and $c"))  // and binds tighter
        #expect(matches(s, "aa") == ["r"])
        #expect(matches(s, "bb").isEmpty)
        #expect(matches(s, "bb cc") == ["r"])
        let p = set(rule(strings: strings, "($a or $b) and not $c"))
        #expect(matches(p, "bb") == ["r"])
        #expect(matches(p, "bb cc").isEmpty)
        let arith = set(rule(strings: strings, "#a + #b * 2 == 5"))
        #expect(matches(arith, "aa.bb.bb") == ["r"])
        let kb = set(rule("filesize < 1KB and 2 * 512 == 1KB and 0x10 == 16 and 1MB == 1048576"))
        #expect(matches(kb, "x") == ["r"])
    }

    @Test func forOfAnonymousString() {
        let s = set(rule(strings: "$a1 = \"#!/bin/sh\"\n$a2 = \"#!/bin/zsh\"\n$b = \"curl\"", "for any of ($a*) : ($ at 0) and $b"))
        #expect(matches(s, "#!/bin/zsh\ncurl x | sh") == ["r"])
        #expect(matches(s, "\n#!/bin/zsh\ncurl x | sh").isEmpty)
        let count = set(rule(strings: "$a1 = \"xy\"\n$a2 = \"zw\"", "for all of ($a*) : (# >= 2)"))
        #expect(matches(count, "xy xy zw zw") == ["r"])
        #expect(matches(count, "xy xy zw").isEmpty)
    }

    @Test func forInRangeLoops() {
        let s = set(rule("for all i in (0..3) : (uint8(i) == 0x41)"))
        #expect(matches(s, "AAAAB") == ["r"])
        #expect(matches(s, "AABA").isEmpty)
        let offsets = set(rule(strings: "$a = \"ab\"", "for 2 i in (1..#a - 1) : (@a[i] + 3 == @a[i + 1])"))
        #expect(matches(offsets, "ab.ab.ab") == ["r"])
        #expect(matches(offsets, "ab.ab..ab").isEmpty)
        let list = set(rule("for any i in (1, 2, 3) : (uint8(i) == 0x5A)"))
        #expect(matches(list, "aaZ") == ["r"])
    }

    @Test func ruleReferencesAndPrivateRules() {
        let text = """
        private rule Macho
        {
            condition:
                uint32(0) == 0xfeedfacf
        }
        rule child
        {
            strings:
                $a = "steal"
            condition:
                Macho and $a
        }
        rule notMacho
        {
            strings:
                $a = "steal"
            condition:
                not Macho and $a
        }
        """
        let s = set(text)
        #expect(s.ruleCount == 3 && s.supportedCount == 3)
        let macho: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE] + Array(" steal".utf8)
        #expect(matches(s, macho) == ["child"])           // private rule not reported
        #expect(matches(s, "steal") == ["notMacho"])
    }

    @Test func tagsAndMetaAreAccepted() {
        let s = set("rule tagged : adware dropper {\n meta:\n description = \"X\"\n n = 4\n b = true\n strings:\n $a = \"zz\"\n condition:\n $a\n}")
        #expect(matches(s, "zz") == ["tagged"])
        #expect(s.matches(data: Data("zz".utf8)).first?.description == "X")
    }

    // MARK: Hash module

    @Test func hashRules() {
        let data = Data("EICAR-like harmless sample".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let s = set(rule("filesize == \(data.count) and hash.sha256(0, filesize) == \"\(digest)\"", imports: "import \"hash\""))
        #expect(s.matches(data: data).map(\.ruleName) == ["r"])
        #expect(s.matches(data: data).first?.isHashRule == true)
        #expect(s.matches(data: Data("other".utf8)).isEmpty)
        // A precomputed digest is used instead of hashing.
        #expect(s.matches(data: data, options: .init(precomputedSHA256: String(repeating: "0", count: 64))).isEmpty)
        #expect(s.matches(data: data, options: .init(evaluateHashes: false)).isEmpty)
        // hash without the import is not valid YARA
        #expect(set(rule("hash.sha256(0, filesize) == \"\(digest)\"")).supportedCount == 0)
    }

    // MARK: Unsupported features are skipped, never loosened

    @Test func unsupportedFeaturesSkipRules() {
        #expect(skipReason(set(rule("pe.number_of_sections == 1", imports: "import \"pe\""))) != nil)
        #expect(skipReason(set(rule(strings: "$a = \"abc\" xor", "$a"))) != nil)
        #expect(skipReason(set(rule(strings: "$a = \"abc\" base64", "$a"))) != nil)
        #expect(skipReason(set(rule(strings: "$a = \"abcd\"\n$b = \"efgh\"", "50% of them"))) != nil)
        #expect(skipReason(set(rule(strings: "$a = { ~00 11 22 33 }", "$a"))) != nil)
        #expect(skipReason(set(rule(strings: "$a = \"abcd\"", "$a and math.entropy(0, filesize) > 7"))) != nil)
        #expect(skipReason(set(rule(strings: "$a = { ?? ?? ?? }", "$a"))) != nil) // no atom
        // A rule depending on a skipped rule is skipped too.
        let dep = set(rule(name: "base", "pe.is_dll()", imports: "import \"pe\"") + rule(name: "user", strings: "$a = \"abcd\"", "base or $a"))
        #expect(skipReason(dep, "user") != nil)
        #expect(dep.supportedCount == 0)
        #expect(dep.match(data: Data("abcd".utf8)).isEmpty)
    }

    @Test func syntaxErrorResynchronises() {
        let text = "rule broken {\n condition:\n $nope\n}\n" + rule(name: "ok", strings: "$a = \"fine\"", "$a")
        let s = set(text)
        #expect(skipReason(s, "broken") != nil)
        #expect(skipReason(s, "ok") == nil)
        #expect(matches(s, "fine") == ["ok"])
    }

    // MARK: Script rules scope

    @Test func scriptRulesOnlyOnScriptLikeFiles() {
        let s = set(rule(name: "bin", strings: "$a = \"marker\"", "$a"),
                    scripts: rule(name: "script", strings: "$a = \"marker\"", "$a"))
        let text = "do shell script \"marker\""
        let found = s.matches(data: Data(text.utf8))
        #expect(Set(found.map(\.ruleName)) == ["bin", "script"])
        #expect(found.first { $0.ruleName == "script" }?.source == .scripts)
        let binary: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0] + Array("marker".utf8)
        #expect(matches(s, binary) == ["bin"])
        #expect(Set(matches(s, binary, .init(scriptRulesScope: .allFiles))) == ["bin", "script"])
        #expect(matches(s, text, .init(scriptRulesScope: .never)) == ["bin"])
    }

    @Test func fileSizeLimitAndFiles() throws {
        let s = set(rule(strings: "$a = \"needle\"", "$a"))
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpyara-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appending(path: "a.txt")
        try Data("hay needle hay".utf8).write(to: f)
        #expect(s.match(fileAt: f) == ["r"])
        #expect(s.matches(fileAt: f, options: .init(maxFileSize: 4)).isEmpty)
        #expect(s.match(fileAt: dir).isEmpty)                         // directory
        #expect(s.match(fileAt: dir.appending(path: "missing")).isEmpty)
        #expect(s.match(data: Data()).isEmpty)
    }

    @Test func concurrentScansAreIndependent() {
        let s = set(rule(strings: "$a = \"needle\"", "#a == 2"))
        let hits = Data("needle needle".utf8), miss = Data("needle".utf8)
        let results = UnsafeMutableBufferPointer<Bool>.allocate(capacity: 64)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            results[i] = s.match(data: i.isMultiple(of: 2) ? hits : miss) == (i.isMultiple(of: 2) ? ["r"] : [])
        }
        #expect(results.allSatisfy { $0 })
    }

    // MARK: Real XProtect rules (skipped when the bundle is absent)

    @Test func realRulesCompileAndIgnoreCleanData() throws {
        guard let real = XProtectYaraRuleSet.loadCurrent() else { return }
        #expect(real.ruleCount > 500)
        #expect(Double(real.supportedCount) / Double(real.ruleCount) > 0.9)
        #expect(real.counts(for: .scripts).total > 0)
        // cached
        #expect(XProtectYaraRuleSet.loadCurrent()?.engine === real.engine)
        let clean = "#!/bin/sh\necho hello world\nls -la /tmp\n"
        #expect(real.match(data: Data(clean.utf8)).isEmpty)
        #expect(real.match(data: Data(repeating: 0, count: 100_000)).isEmpty)
    }

    /// Harmless text that satisfies Apple's XProtect_MACOS_OSASCRIPT_COTAAP
    /// script rule (five plain strings, `all of them and filesize < 1MB`).
    @Test func realScriptRulePositive() throws {
        guard let real = XProtectYaraRuleSet.loadCurrent(),
              real.rules.contains(where: { $0.name == "XProtect_MACOS_OSASCRIPT_COTAAP" && $0.skipReason == nil }) else { return }
        let text = """
        -- test fixture, not a script anyone runs
        set a to "Telegram Data"
        set b to "Telegram Desktop"
        set c to "OpenVPN Connect"
        set d to "OpenVPN Connect/profiles/"
        set e to "Telegram Desktop/tdata/"
        """
        let found = real.matches(data: Data(text.utf8))
        #expect(found.contains { $0.ruleName == "XProtect_MACOS_OSASCRIPT_COTAAP" && $0.source == .scripts })
    }
}
