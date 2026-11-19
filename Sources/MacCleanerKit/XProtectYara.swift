import Foundation

// Public face of the XProtect YARA engine.
//
// `XProtectDatabase` only uses XProtect's exact-hash rules. This evaluates
// the string / byte-pattern rules too (the bulk of XProtect.yara, plus all of
// XPScripts.yr, Apple's AppleScript-stealer rules), with a YARA-subset engine
// that is exact on what it supports and skips everything else:
//
// - Rules using a feature we don't implement are skipped, never loosened.
// - Strings whose matching could find *fewer* matches than YARA (capped
//   unbounded hex jumps) are only allowed where that can only make the rule
//   match less often.
// - XPScripts.yr rules are written for scripts that `osascript` runs, so by
//   default they're only applied to script-like files (see
//   `XProtectYaraScanOptions.scriptRulesScope`).
//
// Nothing here deletes or moves anything; callers get rule names.

/// Which XProtect rule file a rule came from.
public enum XProtectYaraSource: String, Sendable, Hashable, CaseIterable {
    /// `XProtect.yara`: binaries, installers, scripts on disk.
    case xprotect = "XProtect.yara"
    /// `XPScripts.yr`: AppleScript / JXA run through `osascript`.
    case scripts = "XPScripts.yr"
    /// ESET's public YARA rules (github.com/eset/malware-ioc, BSD-2-Clause),
    /// bundled with the app. Third-party rules: hits are listed for review.
    case eset = "ESET malware-ioc"

    /// Apple's own rule files (vs. third-party rules bundled with the app).
    public var isApple: Bool { self == .xprotect || self == .scripts }
}

/// Third-party YARA rule files shipped in the app bundle, with their source.
public enum ExtraYaraRules {
    /// Bundled rule files: folder in the app's Resources, file name, source.
    public static let folder = "YARA"
    public static let files: [(name: String, source: XProtectYaraSource)] = [
        ("eset-keydnap.yar", .eset),
    ]

    /// Reads the bundled rule files from `resources` (the app's
    /// Contents/Resources). Missing files are skipped.
    public static func load(resources: URL?) -> [(XProtectYaraSource, String)] {
        guard let resources else { return [] }
        return files.compactMap { file in
            let url = resources.appending(path: folder).appending(path: file.name)
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
            return (file.source, text)
        }
    }

    /// Where the app looks: the bundle's Resources, or for an unbundled
    /// development build, `Resources/` of the source tree next to `.build`.
    public static var defaultResources: URL? {
        if let res = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: res.appending(path: folder).path(percentEncoded: false)) {
            return res
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<4 {
            guard let d = dir else { break }
            let candidate = d.appending(path: "Resources")
            if FileManager.default.fileExists(atPath: candidate.appending(path: folder).path(percentEncoded: false)) {
                return candidate
            }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }
}

public struct XProtectYaraMatch: Sendable, Hashable {
    /// YARA rule identifier, e.g. `XProtect_MACOS_ODYSSEY_SIA`.
    public let ruleName: String
    /// Apple's family label from `meta: description`, e.g. `MACOS.ODYSSEY.SIA`.
    public let description: String?
    public let source: XProtectYaraSource
    /// Apple marks threat-hunting rules with `HUNT` in the name/description.
    /// They are broader by design; callers may want to present them as
    /// "suspicious" rather than "known malware".
    public let isHuntRule: Bool
    /// The rule needs a whole-file hash to match (an exact-sample rule).
    public let isHashRule: Bool

    /// The family label to show: description when present, else rule name.
    public var family: String { description ?? ruleName }
}

public struct XProtectYaraScanOptions: Sendable {
    public enum ScriptRulesScope: Sendable {
        /// XPScripts.yr rules only on files that look like scripts: compiled
        /// OSA scripts, `#!` scripts, UTF-16 text, or files without NUL bytes
        /// in their first 4 KB.
        case scriptLikeFiles
        case allFiles
        case never
    }

    /// Files larger than this are not scanned at all.
    public var maxFileSize: Int
    /// Evaluate `hash.*()` calls (needed for exact-sample rules).
    public var evaluateHashes: Bool
    /// Lower-case hex SHA-256 of the whole file, if the caller already has it
    /// (saves hashing the file twice).
    public var precomputedSHA256: String?
    public var scriptRulesScope: ScriptRulesScope

    public init(maxFileSize: Int = 50 * 1024 * 1024, evaluateHashes: Bool = true,
                precomputedSHA256: String? = nil, scriptRulesScope: ScriptRulesScope = .scriptLikeFiles) {
        self.maxFileSize = maxFileSize
        self.evaluateHashes = evaluateHashes
        self.precomputedSHA256 = precomputedSHA256
        self.scriptRulesScope = scriptRulesScope
    }

    public static let `default` = XProtectYaraScanOptions()
}

public struct XProtectYaraRuleSummary: Sendable, Hashable {
    public let name: String
    public let description: String?
    public let source: XProtectYaraSource
    public let isPrivate: Bool
    public let line: Int
    /// nil when the rule is evaluated; otherwise the unsupported feature.
    public let skipReason: String?
}

public struct XProtectYaraRuleSet: Sendable {
    let engine: XPYEngine

    /// XProtect bundle version the rules came from (nil for ad-hoc rules).
    public let version: Int?

    /// Every rule found in the rule files (private helper rules included).
    public var ruleCount: Int { engine.infos.count }
    /// Rules that are evaluated (private helper rules included).
    public var supportedCount: Int { engine.rules.count }
    /// Every rule with its source file and skip reason, in file order.
    public var rules: [XProtectYaraRuleSummary] {
        engine.infos.map {
            XProtectYaraRuleSummary(name: $0.name, description: $0.description, source: $0.source,
                                    isPrivate: $0.isPrivate, line: $0.line, skipReason: $0.skipReason)
        }
    }

    /// Skipped rules per unsupported feature.
    public var skippedFeatureCounts: [String: Int] {
        var out: [String: Int] = [:]
        for info in engine.infos { if let r = info.skipReason { out[r, default: 0] += 1 } }
        return out
    }

    /// (total, supported) rule counts per source file.
    public func counts(for source: XProtectYaraSource) -> (total: Int, supported: Int) {
        let infos = engine.infos.filter { $0.source == source }
        return (infos.count, infos.filter { $0.skipReason == nil }.count)
    }

    // MARK: Loading

    /// Where macOS keeps XProtect (same list `XProtectDatabase` reads).
    public static var defaultBundles: [URL] { XProtectDatabase.defaultBundles }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (key: String, set: XProtectYaraRuleSet)?

    /// Compiles the newest installed XProtect bundle's rules, cached by
    /// bundle path + version, so repeated calls are cheap. Thread-safe.
    public static func loadCurrent(bundles: [URL] = defaultBundles,
                                   extraRules: [(XProtectYaraSource, String)]? = nil) -> XProtectYaraRuleSet? {
        var best: (url: URL, version: Int)?
        for bundle in bundles {
            let res = bundle.appending(path: "Contents/Resources")
            guard FileManager.default.isReadableFile(atPath: res.appending(path: "XProtect.yara").path) else { continue }
            let v = bundleVersion(bundle) ?? 0
            if best == nil || v > best!.version { best = (bundle, v) }
        }
        guard let best else { return nil }
        let extras = extraRules ?? ExtraYaraRules.load(resources: ExtraYaraRules.defaultResources)
        let key = "\(best.url.path)#\(best.version)#\(extras.map { "\($0.0.rawValue):\($0.1.utf8.count)" })"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, cached.key == key { return cached.set }
        let res = best.url.appending(path: "Contents/Resources")
        func read(_ name: String) -> String? {
            guard let d = try? Data(contentsOf: res.appending(path: name)) else { return nil }
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        }
        let set = compile(xprotectYara: read("XProtect.yara"), xpScripts: read("XPScripts.yr"),
                          extra: extras, version: best.version == 0 ? nil : best.version)
        cached = (key, set)
        return set
    }

    static func bundleVersion(_ bundle: URL) -> Int? {
        let info = bundle.appending(path: "Contents/Info.plist")
        if let d = try? Data(contentsOf: info),
           let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let s = p["CFBundleShortVersionString"] as? String, let v = Int(s) {
            return v
        }
        if let d = try? Data(contentsOf: bundle.appending(path: "Contents/Resources/XProtect.meta.plist")) {
            return XProtectDatabase.parseMetaVersion(d)
        }
        return nil
    }

    /// Compiles rule text (either file may be nil). Used by `loadCurrent`
    /// and by tests with handcrafted rules.
    /// `extra`: third-party rule files, each tagged with its source; their
    /// rules are compiled with the same engine (unsupported features are
    /// skipped, never loosened).
    public static func compile(xprotectYara: String?, xpScripts: String? = nil,
                               extra: [(XProtectYaraSource, String)] = [], version: Int? = nil) -> XProtectYaraRuleSet {
        var files: [(XProtectYaraSource, String)] = []
        if let xprotectYara { files.append((.xprotect, xprotectYara)) }
        if let xpScripts { files.append((.scripts, xpScripts)) }
        files += extra
        return XProtectYaraRuleSet(engine: XPYCompiler.compile(files), version: version)
    }

    // MARK: Matching

    /// Names of the (public) rules matching the file. Unreadable, non-regular
    /// or oversized files give no matches.
    public func match(fileAt url: URL) -> [String] {
        matches(fileAt: url).map(\.ruleName)
    }

    public func match(data: Data) -> [String] {
        matches(data: data).map(\.ruleName)
    }

    public func matches(fileAt url: URL, options: XProtectYaraScanOptions = .default) -> [XProtectYaraMatch] {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= options.maxFileSize else { return [] }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return matches(data: data, options: options)
    }

    public func matches(data: Data, options: XProtectYaraScanOptions = .default) -> [XProtectYaraMatch] {
        guard data.count <= options.maxFileSize else { return [] }
        if data.isEmpty {
            var one: UInt8 = 0
            return withUnsafePointer(to: &one) { scan($0, 0, options) }
        }
        return data.withUnsafeBytes { raw in
            scan(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, options)
        }
    }

    // MARK: Engine driver

    func scan(_ base: UnsafePointer<UInt8>, _ n: Int, _ options: XProtectYaraScanOptions) -> [XProtectYaraMatch] {
        let rules = engine.rules
        let applyScripts: Bool
        switch options.scriptRulesScope {
        case .allFiles: applyScripts = true
        case .never: applyScripts = false
        case .scriptLikeFiles: applyScripts = Self.isScriptLike(base, n)
        }
        var ctx = XPYEvalContext(base: base, size: n, matches: nil, evaluateHashes: options.evaluateHashes,
                                 precomputedSHA256: options.precomputedSHA256,
                                 ruleResults: Array(repeating: nil, count: rules.count))
        var candidates: [Int] = []
        for (idx, rule) in rules.enumerated() where !rule.isPrivate {
            if rule.source == .scripts && !applyScripts { continue }
            if Int64(n) < rule.minSize || Int64(n) > rule.maxSize { continue }
            candidates.append(idx)
            _ = XPYEvaluator.evalRule(idx, engine, &ctx)
        }
        let undecided = ctx.ruleResults.indices.filter { ctx.ruleResults[$0] == .k }
        if !undecided.isEmpty {
            let result = engine.scan(base, n, rules: undecided)
            // YARA aborts a scan whose string has too many matches.
            if result.overflow { return [] }
            ctx.matches = result.matches
            for idx in undecided { ctx.ruleResults[idx] = nil }
            for idx in candidates where !rules[idx].isPrivate { _ = XPYEvaluator.evalRule(idx, engine, &ctx) }
        }
        var out: [XProtectYaraMatch] = []
        for idx in candidates where ctx.ruleResults[idx] == .t {
            let r = rules[idx]
            let hunt = r.name.uppercased().contains("HUNT") || (r.description?.uppercased().hasPrefix("HUNT") ?? false)
            out.append(XProtectYaraMatch(ruleName: r.name, description: r.description, source: r.source,
                                         isHuntRule: hunt, isHashRule: Self.usesHash(r.condition)))
        }
        return out
    }

    static func usesHash(_ e: XPYExpr) -> Bool {
        switch e {
        case .hash: return true
        case .not(let x), .neg(let x), .bitNot(let x), .read(_, _, _, let x), .at(_, let x), .offset(_, let x), .length(_, let x):
            return usesHash(x)
        case .and(let a, let b), .or(let a, let b), .bin(_, let a, let b), .inRange(_, let a, let b), .countIn(_, let a, let b):
            return usesHash(a) || usesHash(b)
        case .forOf(_, _, let b), .forIn(_, _, _, let b): return usesHash(b)
        default: return false
        }
    }

    /// Compiled OSA script, `#!` script, UTF-16 BOM, or no NUL bytes in the
    /// first 4 KB.
    static func isScriptLike(_ base: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        guard n > 0 else { return false }
        func startsWith(_ s: String) -> Bool {
            let b = Array(s.utf8)
            guard n >= b.count else { return false }
            for k in 0..<b.count where base[k] != b[k] { return false }
            return true
        }
        if startsWith("#!") || startsWith("FasdUAS") || startsWith("JsOsaDAS") { return true }
        if n >= 2, (base[0] == 0xFF && base[1] == 0xFE) || (base[0] == 0xFE && base[1] == 0xFF) { return true }
        let probe = min(n, 4096)
        for k in 0..<probe where base[k] == 0 { return false }
        return true
    }
}

// MARK: - Compiler

enum XPYCompiler {
    static func compile(_ files: [(XProtectYaraSource, String)]) -> XPYEngine {
        var rules: [XPYRule] = []
        var infos: [XPYRuleInfo] = []
        var strings: [XPYCompiledString] = []
        for (source, text) in files {
            let parsed = XPYaraFileParser.parse(text)
            let imports = Set(parsed.imports)
            let unknownImports = imports.subtracting(["hash"])
            let hasGlobal = parsed.rules.contains { $0.isGlobal }
            var nameToIndex: [String: Int] = [:]
            var seenNames = Set<String>()
            for pr in parsed.rules {
                func skip(_ reason: String) {
                    infos.append(XPYRuleInfo(name: pr.name, description: pr.meta["description"], source: source,
                                             isPrivate: pr.isPrivate, line: pr.line, skipReason: reason))
                }
                if let u = pr.unsupported { skip(u.feature); continue }
                if !seenNames.insert(pr.name).inserted { skip("syntax: duplicate rule name"); continue }
                if hasGlobal { skip("global rule in file"); continue }
                if !parsed.fileLevelUnsupported.isEmpty { skip("file: \(parsed.fileLevelUnsupported[0])"); continue }
                if let m = unknownImports.first { skip("module: \(m)"); continue }
                do {
                    let named = pr.strings.map(\.name).filter { !$0.isEmpty }
                    if Set(named).count != named.count { throw XPYaraUnsupported("syntax: duplicate string name") }
                    let compiled = try pr.strings.map { try XPYStringCompiler.compile($0) }
                    let names = nameToIndex
                    var cp = XPYaraConditionParser(tokens: pr.condition, stringNames: pr.strings.map(\.name),
                                                   imports: imports, ruleIndex: { names[$0] })
                    let condition = try cp.parseCondition()
                    let underStrings = Set(compiled.indices.filter { compiled[$0].underApproximate })
                    let underRules = Set(cp.referencedRules.filter { rules[$0].underApproximate })
                    if !underStrings.isEmpty || !underRules.isEmpty {
                        guard XPYMonotonicity.positiveOnly(condition, strings: underStrings, underRules: underRules) else {
                            throw XPYaraUnsupported("hex: unbounded jump in non-monotone position")
                        }
                    }
                    let base = strings.count
                    strings.append(contentsOf: compiled)
                    let idx = rules.count
                    rules.append(XPYRule(name: pr.name, description: pr.meta["description"], source: source,
                                         isPrivate: pr.isPrivate, meta: pr.meta, condition: condition,
                                         stringIDs: Array(base..<(base + compiled.count)),
                                         underApproximate: !underStrings.isEmpty || !underRules.isEmpty))
                    (rules[idx].minSize, rules[idx].maxSize) = XPYRule.sizeBounds(condition)
                    nameToIndex[pr.name] = idx
                    infos.append(XPYRuleInfo(name: pr.name, description: pr.meta["description"], source: source,
                                             isPrivate: pr.isPrivate, line: pr.line, skipReason: nil))
                } catch let e as XPYaraUnsupported {
                    skip(e.feature)
                } catch {
                    skip("internal")
                }
            }
        }
        return XPYEngine(rules: rules, infos: infos, strings: strings)
    }
}
