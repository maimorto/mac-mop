import Foundation

// A parser for the subset of YARA that Apple's XProtect rule files use.
//
// Design rule: anything this parser does not understand exactly makes the
// whole rule *unsupported* (it's skipped, with a reason). Nothing is ever
// approximated into a looser rule, because a looser rule means false
// positives in a tool whose follow-up action is moving files to the Trash.
//
// Pieces:
// - `XPYaraLexer`: byte-level tokenizer (comments, strings, numbers, ops).
// - `XPYaraFileParser`: splits a file into rules, parses meta / strings /
//   condition tokens. A rule with a syntax problem is recorded as
//   unsupported and the parser resynchronises at the next `rule` keyword.
// - `XPYaraConditionParser`: Pratt parser from condition tokens to `XPYExpr`.

/// A reason a rule (or a part of it) can't be evaluated faithfully.
struct XPYaraUnsupported: Error, Sendable {
    /// Short feature key used for the skipped-features summary, e.g.
    /// "regex: backreference", "module: pe".
    let feature: String
    init(_ feature: String) { self.feature = feature }
}

// MARK: - Tokens

enum XPYTok: Equatable, Sendable {
    case ident(String)
    case int(Int64)
    case text([UInt8])
    /// `$name`, `$name*`, `$*`, or `$` (anonymous / current string).
    case stringID(String)
    /// `#name` / `#` (count).
    case count(String)
    /// `@name` / `@` (offset).
    case offset(String)
    /// `!name` / `!` (length).
    case length(String)
    case op(String)
}

struct XPYaraLexer {
    let b: [UInt8]
    var i: Int
    let end: Int

    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        b = bytes
        i = start
        self.end = end ?? bytes.count
    }

    static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    static func isIdentChar(_ c: UInt8) -> Bool {
        isIdentStart(c) || (c >= 0x30 && c <= 0x39)
    }

    var atEnd: Bool { i >= end }

    func peekByte(_ offset: Int = 0) -> UInt8? {
        i + offset < end ? b[i + offset] : nil
    }

    /// Skips whitespace and `//` / `/* */` comments.
    mutating func skipTrivia() {
        while i < end {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C {
                i += 1
            } else if c == 0x2F, i + 1 < end, b[i + 1] == 0x2F {
                while i < end, b[i] != 0x0A { i += 1 }
            } else if c == 0x2F, i + 1 < end, b[i + 1] == 0x2A {
                i += 2
                while i + 1 < end, !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                i = min(end, i + 2)
            } else {
                return
            }
        }
    }

    mutating func readIdent() -> String? {
        guard i < end, Self.isIdentStart(b[i]) else { return nil }
        let s = i
        while i < end, Self.isIdentChar(b[i]) { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }

    /// Reads a `"..."` literal with YARA's escapes (`\" \\ \t \n \r \xHH`).
    mutating func readTextLiteral() throws -> [UInt8] {
        guard i < end, b[i] == 0x22 else { throw XPYaraUnsupported("syntax: expected string") }
        i += 1
        var out: [UInt8] = []
        while i < end {
            let c = b[i]
            if c == 0x22 { i += 1; return out }
            if c == 0x0A { throw XPYaraUnsupported("syntax: newline in string") }
            if c == 0x5C {
                guard i + 1 < end else { break }
                let e = b[i + 1]
                switch e {
                case 0x22: out.append(0x22); i += 2
                case 0x5C: out.append(0x5C); i += 2
                case 0x74: out.append(0x09); i += 2
                case 0x6E: out.append(0x0A); i += 2
                case 0x72: out.append(0x0D); i += 2
                case 0x78:
                    guard i + 3 < end, let h = Self.hexValue(b[i + 2]), let l = Self.hexValue(b[i + 3]) else {
                        throw XPYaraUnsupported("string: bad \\x escape")
                    }
                    out.append(h << 4 | l)
                    i += 4
                default:
                    throw XPYaraUnsupported("string: unknown escape")
                }
                continue
            }
            out.append(c)
            i += 1
        }
        throw XPYaraUnsupported("syntax: unterminated string")
    }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    /// Reads one condition token, or nil at the closing `}` of the rule
    /// (which is consumed).
    mutating func nextConditionToken() throws -> XPYTok? {
        skipTrivia()
        guard i < end else { throw XPYaraUnsupported("syntax: unterminated rule") }
        let c = b[i]
        if c == 0x7D { i += 1; return nil } // }
        if Self.isIdentStart(c) { return .ident(readIdent()!) }
        if c >= 0x30 && c <= 0x39 { return .int(try readNumber()) }
        if c == 0x22 { return .text(try readTextLiteral()) }
        if c == 0x24 || c == 0x23 || c == 0x40 || (c == 0x21 && !(i + 1 < end && b[i + 1] == 0x3D)) {
            i += 1
            let s = i
            while i < end, Self.isIdentChar(b[i]) { i += 1 }
            var name = String(decoding: b[s..<i], as: UTF8.self)
            if c == 0x24, i < end, b[i] == 0x2A { name += "*"; i += 1 }
            switch c {
            case 0x24: return .stringID(name)
            case 0x23: return .count(name)
            case 0x40: return .offset(name)
            default: return .length(name)
            }
        }
        let two: [String] = ["==", "!=", "<=", ">=", "<<", ">>", ".."]
        if i + 1 < end {
            let s = String(decoding: b[i..<(i + 2)], as: UTF8.self)
            if two.contains(s) { i += 2; return .op(s) }
        }
        let singles: Set<UInt8> = Set("()[],:.<>+-*\\%&|^~=".utf8)
        if singles.contains(c) {
            i += 1
            return .op(String(UnicodeScalar(c)))
        }
        throw XPYaraUnsupported("syntax: unexpected character in condition")
    }

    /// Decimal, `0x` hex or `0o` octal, with optional `KB` / `MB` suffix.
    mutating func readNumber() throws -> Int64 {
        var value: Int64 = 0
        if i + 1 < end, b[i] == 0x30, b[i + 1] == 0x78 || b[i + 1] == 0x58 {
            i += 2
            var digits = 0
            while i < end, let h = Self.hexValue(b[i]) {
                let (m, o) = value.multipliedReportingOverflow(by: 16)
                guard !o else { throw XPYaraUnsupported("syntax: number overflow") }
                value = m | Int64(h)
                i += 1
                digits += 1
            }
            guard digits > 0 else { throw XPYaraUnsupported("syntax: bad hex number") }
        } else if i + 1 < end, b[i] == 0x30, b[i + 1] == 0x6F {
            i += 2
            var digits = 0
            while i < end, b[i] >= 0x30, b[i] <= 0x37 {
                value = value * 8 + Int64(b[i] - 0x30)
                i += 1
                digits += 1
            }
            guard digits > 0 else { throw XPYaraUnsupported("syntax: bad octal number") }
        } else {
            while i < end, b[i] >= 0x30, b[i] <= 0x39 {
                let (m, o1) = value.multipliedReportingOverflow(by: 10)
                let (a, o2) = m.addingReportingOverflow(Int64(b[i] - 0x30))
                guard !o1, !o2 else { throw XPYaraUnsupported("syntax: number overflow") }
                value = a
                i += 1
            }
        }
        if i + 1 < end, b[i + 1] == 0x42, b[i] == 0x4B || b[i] == 0x4D { // KB / MB
            value *= b[i] == 0x4B ? 1024 : 1024 * 1024
            i += 2
        }
        if i < end, Self.isIdentChar(b[i]) { throw XPYaraUnsupported("syntax: bad number suffix") }
        return value
    }
}

// MARK: - Parsed file model

struct XPYParsedString: Sendable {
    enum Body: Sendable {
        case text([UInt8])
        case hex([UInt8])   // raw bytes between the braces
        case regex([UInt8], caseInsensitive: Bool, dotAll: Bool)
    }

    /// Identifier without the `$`; empty for anonymous strings.
    var name: String
    var body: Body
    var modifiers: Set<String>
}

struct XPYParsedRule: Sendable {
    var name: String
    var isPrivate: Bool
    var isGlobal: Bool
    var meta: [String: String]
    var strings: [XPYParsedString]
    var condition: [XPYTok]
    /// Set when the rule could not be parsed or uses something unsupported
    /// at the syntax level.
    var unsupported: XPYaraUnsupported?
    var line: Int
}

struct XPYParsedFile: Sendable {
    var imports: [String]
    var rules: [XPYParsedRule]
    /// Problems outside rules (e.g. `include`).
    var fileLevelUnsupported: [String]
}

enum XPYaraFileParser {
    static func parse(_ text: String) -> XPYParsedFile {
        parse(Array(text.utf8))
    }

    static func parse(_ bytes: [UInt8]) -> XPYParsedFile {
        var lx = XPYaraLexer(bytes)
        var file = XPYParsedFile(imports: [], rules: [], fileLevelUnsupported: [])
        while true {
            lx.skipTrivia()
            if lx.atEnd { break }
            let ruleStart = lx.i
            guard let word = lx.readIdent() else {
                file.fileLevelUnsupported.append("syntax: stray character at top level")
                resync(&lx)
                continue
            }
            switch word {
            case "import":
                lx.skipTrivia()
                if let lit = try? lx.readTextLiteral() {
                    file.imports.append(String(decoding: lit, as: UTF8.self))
                } else {
                    file.fileLevelUnsupported.append("syntax: bad import")
                    resync(&lx)
                }
            case "include":
                file.fileLevelUnsupported.append("include")
                resync(&lx)
            case "private", "global", "rule":
                lx.i = ruleStart
                file.rules.append(parseRule(&lx, bytes: bytes))
            default:
                file.fileLevelUnsupported.append("syntax: unexpected top-level word")
                resync(&lx)
            }
        }
        return file
    }

    /// Moves to the next line that starts a rule (`rule`, `private rule`, …).
    static func resync(_ lx: inout XPYaraLexer) {
        let b = lx.b
        var i = lx.i
        while i < lx.end {
            // advance to the start of the next line
            while i < lx.end, b[i] != 0x0A { i += 1 }
            i += 1
            var j = i
            while j < lx.end, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
            for kw in ["rule", "private", "global"] {
                let k = Array(kw.utf8)
                if j + k.count < lx.end, Array(b[j..<(j + k.count)]) == k,
                   !XPYaraLexer.isIdentChar(b[j + k.count]) {
                    lx.i = j
                    return
                }
            }
        }
        lx.i = lx.end
    }

    static func lineNumber(_ bytes: [UInt8], at offset: Int) -> Int {
        var n = 1
        for k in 0..<min(offset, bytes.count) where bytes[k] == 0x0A { n += 1 }
        return n
    }

    static func parseRule(_ lx: inout XPYaraLexer, bytes: [UInt8]) -> XPYParsedRule {
        let start = lx.i
        var rule = XPYParsedRule(name: "?", isPrivate: false, isGlobal: false, meta: [:], strings: [],
                                 condition: [], unsupported: nil, line: 0)
        do {
            try parseRuleBody(&lx, into: &rule)
        } catch let e as XPYaraUnsupported {
            rule.unsupported = e
            lx.i = max(lx.i, start + 1)
            resync(&lx)
        } catch {
            rule.unsupported = XPYaraUnsupported("syntax")
            resync(&lx)
        }
        rule.line = lineNumber(bytes, at: start)
        return rule
    }

    private static func parseRuleBody(_ lx: inout XPYaraLexer, into rule: inout XPYParsedRule) throws {
        while true {
            lx.skipTrivia()
            guard let w = lx.readIdent() else { throw XPYaraUnsupported("syntax: expected rule") }
            if w == "private" { rule.isPrivate = true; continue }
            if w == "global" { rule.isGlobal = true; continue }
            guard w == "rule" else { throw XPYaraUnsupported("syntax: expected rule") }
            break
        }
        lx.skipTrivia()
        guard let name = lx.readIdent() else { throw XPYaraUnsupported("syntax: rule name") }
        rule.name = name
        lx.skipTrivia()
        if lx.peekByte() == 0x3A { // tags
            lx.i += 1
            while true {
                lx.skipTrivia()
                if lx.peekByte() == 0x7B { break }
                guard lx.readIdent() != nil else { throw XPYaraUnsupported("syntax: tags") }
            }
        }
        lx.skipTrivia()
        guard lx.peekByte() == 0x7B else { throw XPYaraUnsupported("syntax: expected {") }
        lx.i += 1
        var section = ""
        while true {
            lx.skipTrivia()
            guard let c = lx.peekByte() else { throw XPYaraUnsupported("syntax: unterminated rule") }
            if c == 0x7D { throw XPYaraUnsupported("syntax: rule without condition") }
            if c == 0x24 { // string definition
                guard section == "strings" else { throw XPYaraUnsupported("syntax: string outside strings:") }
                rule.strings.append(try parseStringDef(&lx))
                continue
            }
            let save = lx.i
            guard let word = lx.readIdent() else { throw XPYaraUnsupported("syntax: in rule body") }
            lx.skipTrivia()
            if lx.peekByte() == 0x3A, ["meta", "strings", "condition"].contains(word) {
                lx.i += 1
                section = word
                if word == "condition" {
                    while let tok = try lx.nextConditionToken() { rule.condition.append(tok) }
                    return
                }
                continue
            }
            guard section == "meta" else { lx.i = save; throw XPYaraUnsupported("syntax: in rule body") }
            // meta: key = value
            guard lx.peekByte() == 0x3D else { throw XPYaraUnsupported("syntax: meta") }
            lx.i += 1
            lx.skipTrivia()
            if lx.peekByte() == 0x22 {
                rule.meta[word] = String(decoding: try lx.readTextLiteral(), as: UTF8.self)
            } else if lx.peekByte() == 0x2D || (lx.peekByte().map { $0 >= 0x30 && $0 <= 0x39 } ?? false) {
                var neg = false
                if lx.peekByte() == 0x2D { neg = true; lx.i += 1 }
                let v = try lx.readNumber()
                rule.meta[word] = String(neg ? -v : v)
            } else if let id = lx.readIdent(), id == "true" || id == "false" {
                rule.meta[word] = id
            } else {
                throw XPYaraUnsupported("syntax: meta value")
            }
        }
    }

    private static func parseStringDef(_ lx: inout XPYaraLexer) throws -> XPYParsedString {
        lx.i += 1 // $
        let s = lx.i
        while let c = lx.peekByte(), XPYaraLexer.isIdentChar(c) { lx.i += 1 }
        let name = String(decoding: lx.b[s..<lx.i], as: UTF8.self)
        lx.skipTrivia()
        guard lx.peekByte() == 0x3D else { throw XPYaraUnsupported("syntax: string definition") }
        lx.i += 1
        lx.skipTrivia()
        let body: XPYParsedString.Body
        switch lx.peekByte() {
        case 0x22:
            body = .text(try lx.readTextLiteral())
        case 0x7B:
            lx.i += 1
            let hs = lx.i
            // Comments inside hex strings may contain braces ("{s_1}").
            while let c = lx.peekByte(), c != 0x7D {
                if c == 0x2F, lx.peekByte(1) == 0x2F {
                    while let d = lx.peekByte(), d != 0x0A { lx.i += 1 }
                } else if c == 0x2F, lx.peekByte(1) == 0x2A {
                    lx.i += 2
                    while lx.i + 1 < lx.end, !(lx.b[lx.i] == 0x2A && lx.b[lx.i + 1] == 0x2F) { lx.i += 1 }
                    lx.i = min(lx.end, lx.i + 2)
                } else {
                    lx.i += 1
                }
            }
            guard lx.peekByte() == 0x7D else { throw XPYaraUnsupported("syntax: unterminated hex string") }
            body = .hex(Array(lx.b[hs..<lx.i]))
            lx.i += 1
        case 0x2F:
            lx.i += 1
            var re: [UInt8] = []
            var closed = false
            while let c = lx.peekByte() {
                if c == 0x0A { break }
                if c == 0x5C, let n = lx.peekByte(1) { re.append(c); re.append(n); lx.i += 2; continue }
                if c == 0x2F { lx.i += 1; closed = true; break }
                re.append(c)
                lx.i += 1
            }
            guard closed else { throw XPYaraUnsupported("syntax: unterminated regex") }
            var ci = false, dotAll = false
            while let c = lx.peekByte(), XPYaraLexer.isIdentChar(c) {
                if c == 0x69 { ci = true } else if c == 0x73 { dotAll = true } else {
                    throw XPYaraUnsupported("regex: unknown flag")
                }
                lx.i += 1
            }
            body = .regex(re, caseInsensitive: ci, dotAll: dotAll)
        default:
            throw XPYaraUnsupported("syntax: string value")
        }
        var mods = Set<String>()
        while true {
            let save = lx.i
            lx.skipTrivia()
            guard let c = lx.peekByte(), XPYaraLexer.isIdentStart(c) else { lx.i = save; break }
            let id = lx.readIdent()!
            // The next section keyword (`condition:`) ends the modifier list.
            if ["meta", "strings", "condition"].contains(id) { lx.i = save; break }
            // `xor(1-255)` / `base64("...")` take arguments: unsupported anyway.
            if lx.peekByte() == 0x28 { throw XPYaraUnsupported("string modifier: \(id)") }
            mods.insert(id)
        }
        return XPYParsedString(name: name, body: body, modifiers: mods)
    }
}

// MARK: - Condition AST

enum XPYStrRef: Sendable, Equatable {
    case local(Int)
    /// Anonymous `$` / `#` / `@` / `!` inside `for … of … : (…)`.
    case current
}

enum XPYBinOp: Sendable {
    case add, sub, mul, div, mod, band, bor, bxor, shl, shr
    case eq, ne, lt, le, gt, ge
}

enum XPYHashAlg: Sendable {
    case md5, sha1, sha256
}

indirect enum XPYQuant: Sendable {
    case all, any, none
    case atLeast(XPYExpr)
}

indirect enum XPYIter: Sendable {
    case range(XPYExpr, XPYExpr)
    case list([XPYExpr])
}

indirect enum XPYExpr: Sendable {
    case int(Int64)
    case bool(Bool)
    case text([UInt8])
    case filesize
    /// Index into the compiled rule table.
    case rule(Int)
    case loopVar(Int)
    case found(XPYStrRef)
    case at(XPYStrRef, XPYExpr)
    case inRange(XPYStrRef, XPYExpr, XPYExpr)
    case count(XPYStrRef)
    case countIn(XPYStrRef, XPYExpr, XPYExpr)
    case offset(XPYStrRef, XPYExpr)
    case length(XPYStrRef, XPYExpr)
    case read(width: Int, bigEndian: Bool, signed: Bool, XPYExpr)
    case not(XPYExpr)
    case neg(XPYExpr)
    case bitNot(XPYExpr)
    case and(XPYExpr, XPYExpr)
    case or(XPYExpr, XPYExpr)
    case bin(XPYBinOp, XPYExpr, XPYExpr)
    case of(XPYQuant, [Int])
    case forOf(XPYQuant, [Int], XPYExpr)
    case forIn(XPYQuant, slot: Int, XPYIter, XPYExpr)
    case hash(XPYHashAlg, XPYExpr, XPYExpr)
}

/// Pratt parser for one rule's condition.
struct XPYaraConditionParser {
    let toks: [XPYTok]
    var pos = 0
    /// Rule-local string names in definition order ("" for anonymous).
    let stringNames: [String]
    /// Earlier, supported rules of the same file → compiled rule index.
    let ruleIndex: (String) -> Int?
    let imports: Set<String>
    var loopVars: [String] = []
    /// Depth of `for … of` nesting (anonymous `$` is valid inside).
    var inForOf = 0
    /// Rules referenced (compiled indexes), for dependency analysis.
    var referencedRules: [Int] = []

    init(tokens: [XPYTok], stringNames: [String], imports: Set<String>, ruleIndex: @escaping (String) -> Int?) {
        toks = tokens
        self.stringNames = stringNames
        self.ruleIndex = ruleIndex
        self.imports = imports
    }

    static let modules: Set<String> = ["pe", "elf", "math", "macho", "dotnet", "cuckoo", "magic", "time", "console", "string", "dex", "lnk", "vt"]

    mutating func parseCondition() throws -> XPYExpr {
        let e = try parseExpr(0)
        guard pos == toks.count else { throw XPYaraUnsupported("syntax: trailing condition tokens") }
        return e
    }

    func peek(_ k: Int = 0) -> XPYTok? { pos + k < toks.count ? toks[pos + k] : nil }

    mutating func next() throws -> XPYTok {
        guard pos < toks.count else { throw XPYaraUnsupported("syntax: unexpected end of condition") }
        pos += 1
        return toks[pos - 1]
    }

    mutating func expectOp(_ s: String) throws {
        guard case .op(s)? = peek() else { throw XPYaraUnsupported("syntax: expected \(s)") }
        pos += 1
    }

    mutating func expectIdent(_ s: String) throws {
        guard case .ident(s)? = peek() else { throw XPYaraUnsupported("syntax: expected \(s)") }
        pos += 1
    }

    func isOp(_ s: String, _ k: Int = 0) -> Bool {
        if case .op(s)? = peek(k) { return true }
        return false
    }

    func isIdent(_ s: String, _ k: Int = 0) -> Bool {
        if case .ident(s)? = peek(k) { return true }
        return false
    }

    /// Binding powers, following YARA's grammar precedence table.
    func infixPower() throws -> (Int, String)? {
        guard let t = peek() else { return nil }
        switch t {
        case .ident("or"): return (1, "or")
        case .ident("and"): return (2, "and")
        case .ident("contains"), .ident("icontains"), .ident("startswith"), .ident("istartswith"),
             .ident("endswith"), .ident("iendswith"), .ident("iequals"), .ident("matches"):
            throw XPYaraUnsupported("condition: string operator")
        case .op(let o):
            switch o {
            case "==", "!=": return (4, o)
            case "<", "<=", ">", ">=": return (5, o)
            case "|": return (6, o)
            case "^": return (7, o)
            case "&": return (8, o)
            case "<<", ">>": return (9, o)
            case "+", "-": return (10, o)
            case "*", "\\", "%": return (11, o)
            default: return nil
            }
        default: return nil
        }
    }

    mutating func parseExpr(_ minBP: Int) throws -> XPYExpr {
        var lhs = try parsePrefix()
        while let (bp, op) = try infixPower(), bp >= minBP {
            pos += 1
            let rhs = try parseExpr(bp + 1)
            switch op {
            case "or": lhs = .or(lhs, rhs)
            case "and": lhs = .and(lhs, rhs)
            case "==": lhs = .bin(.eq, lhs, rhs)
            case "!=": lhs = .bin(.ne, lhs, rhs)
            case "<": lhs = .bin(.lt, lhs, rhs)
            case "<=": lhs = .bin(.le, lhs, rhs)
            case ">": lhs = .bin(.gt, lhs, rhs)
            case ">=": lhs = .bin(.ge, lhs, rhs)
            case "|": lhs = .bin(.bor, lhs, rhs)
            case "^": lhs = .bin(.bxor, lhs, rhs)
            case "&": lhs = .bin(.band, lhs, rhs)
            case "<<": lhs = .bin(.shl, lhs, rhs)
            case ">>": lhs = .bin(.shr, lhs, rhs)
            case "+": lhs = .bin(.add, lhs, rhs)
            case "-": lhs = .bin(.sub, lhs, rhs)
            case "*": lhs = .bin(.mul, lhs, rhs)
            case "\\": lhs = .bin(.div, lhs, rhs)
            case "%": lhs = .bin(.mod, lhs, rhs)
            default: throw XPYaraUnsupported("syntax: operator")
            }
        }
        return lhs
    }

    func stringRef(_ name: String) throws -> XPYStrRef {
        if name.isEmpty {
            guard inForOf > 0 else { throw XPYaraUnsupported("syntax: anonymous string outside for-of") }
            return .current
        }
        guard !name.hasSuffix("*"), let idx = stringNames.firstIndex(of: name) else {
            throw XPYaraUnsupported("syntax: undefined string $\(name)")
        }
        return .local(idx)
    }

    /// `them` or `( $a, $b*, … )`.
    mutating func parseStringSet() throws -> [Int] {
        if isIdent("them") {
            pos += 1
            guard !stringNames.isEmpty else { throw XPYaraUnsupported("syntax: them without strings") }
            return Array(stringNames.indices)
        }
        try expectOp("(")
        var set: [Int] = []
        while true {
            guard case .stringID(let name)? = peek() else {
                // `(RuleA, RuleB*)` rule sets (YARA 4.3) aren't supported.
                throw XPYaraUnsupported("condition: rule set in of-expression")
            }
            pos += 1
            if name == "*" {
                set.append(contentsOf: stringNames.indices)
            } else if name.hasSuffix("*") {
                let prefix = String(name.dropLast())
                let hits = stringNames.indices.filter { !stringNames[$0].isEmpty && stringNames[$0].hasPrefix(prefix) }
                guard !hits.isEmpty else { throw XPYaraUnsupported("syntax: empty string set") }
                set.append(contentsOf: hits)
            } else {
                guard let idx = stringNames.firstIndex(of: name), !name.isEmpty else {
                    throw XPYaraUnsupported("syntax: undefined string $\(name)")
                }
                set.append(idx)
            }
            if isOp(",") { pos += 1; continue }
            try expectOp(")")
            break
        }
        var seen = Set<Int>()
        return set.filter { seen.insert($0).inserted }
    }

    mutating func parseRange() throws -> (XPYExpr, XPYExpr) {
        try expectOp("(")
        let lo = try parseExpr(6)
        try expectOp("..")
        let hi = try parseExpr(6)
        try expectOp(")")
        return (lo, hi)
    }

    mutating func parseQuantifier() throws -> XPYQuant {
        let t = try next()
        switch t {
        case .ident("all"): return .all
        case .ident("any"): return .any
        case .ident("none"): return .none
        case .int(let n):
            if isOp("%") { throw XPYaraUnsupported("condition: percentage quantifier") }
            return .atLeast(.int(n))
        default:
            throw XPYaraUnsupported("condition: quantifier expression")
        }
    }

    /// After an of-expression, YARA 4.3 allows `in (range)` / `at offset`.
    func rejectOfSuffix() throws {
        if isIdent("in") || isIdent("at") { throw XPYaraUnsupported("condition: of … in/at") }
    }

    mutating func parsePrefix() throws -> XPYExpr {
        let t = try next()
        switch t {
        case .ident("not"):
            return .not(try parseExpr(3))
        case .ident("defined"):
            throw XPYaraUnsupported("condition: defined")
        case .op("-"):
            return .neg(try parseExpr(12))
        case .op("~"):
            return .bitNot(try parseExpr(12))
        case .op("("):
            let e = try parseExpr(0)
            try expectOp(")")
            return e
        case .ident("true"): return .bool(true)
        case .ident("false"): return .bool(false)
        case .ident("filesize"): return .filesize
        case .ident("entrypoint"): throw XPYaraUnsupported("condition: entrypoint")
        case .text(let s): return .text(s)
        case .int(let n):
            if isOp("%") { throw XPYaraUnsupported("condition: percentage quantifier") }
            if isIdent("of") {
                pos += 1
                let set = try parseStringSet()
                try rejectOfSuffix()
                return .of(.atLeast(.int(n)), set)
            }
            return .int(n)
        case .ident("all"), .ident("any"), .ident("none"):
            pos -= 1
            let q = try parseQuantifier()
            try expectIdent("of")
            let set = try parseStringSet()
            try rejectOfSuffix()
            return .of(q, set)
        case .ident("for"):
            return try parseFor()
        case .stringID(let name):
            let ref = try stringRef(name)
            if isIdent("at") {
                pos += 1
                return .at(ref, try parseExpr(6))
            }
            if isIdent("in") {
                pos += 1
                let (lo, hi) = try parseRange()
                return .inRange(ref, lo, hi)
            }
            return .found(ref)
        case .count(let name):
            let ref = try stringRef(name)
            if isIdent("in") {
                pos += 1
                let (lo, hi) = try parseRange()
                return .countIn(ref, lo, hi)
            }
            return .count(ref)
        case .offset(let name), .length(let name):
            let ref = try stringRef(name)
            var index: XPYExpr = .int(1)
            if isOp("[") {
                pos += 1
                index = try parseExpr(0)
                try expectOp("]")
            }
            if case .offset = t { return .offset(ref, index) }
            return .length(ref, index)
        case .ident(let id):
            if let r = Self.readFunction(id) {
                try expectOp("(")
                let arg = try parseExpr(0)
                try expectOp(")")
                return .read(width: r.0, bigEndian: r.1, signed: r.2, arg)
            }
            if let slot = loopVars.lastIndex(of: id) { return .loopVar(slot) }
            if id == "hash" {
                guard imports.contains("hash") else { throw XPYaraUnsupported("syntax: hash without import") }
                try expectOp(".")
                guard case .ident(let fn) = try next() else { throw XPYaraUnsupported("syntax: hash.") }
                let alg: XPYHashAlg
                switch fn {
                case "md5": alg = .md5
                case "sha1": alg = .sha1
                case "sha256": alg = .sha256
                default: throw XPYaraUnsupported("module: hash.\(fn)")
                }
                try expectOp("(")
                // hash.x("string") (hash of a literal) is a different overload.
                if case .text = peek() { throw XPYaraUnsupported("module: hash of literal") }
                let off = try parseExpr(0)
                try expectOp(",")
                let len = try parseExpr(0)
                try expectOp(")")
                return .hash(alg, off, len)
            }
            if Self.modules.contains(id) || imports.contains(id) { throw XPYaraUnsupported("module: \(id)") }
            if let idx = ruleIndex(id) {
                referencedRules.append(idx)
                return .rule(idx)
            }
            throw XPYaraUnsupported("rule reference: unknown or skipped rule")
        default:
            throw XPYaraUnsupported("syntax: unexpected token")
        }
    }

    static func readFunction(_ id: String) -> (Int, Bool, Bool)? {
        switch id {
        case "uint8": return (1, false, false)
        case "uint16": return (2, false, false)
        case "uint32": return (4, false, false)
        case "uint8be": return (1, true, false)
        case "uint16be": return (2, true, false)
        case "uint32be": return (4, true, false)
        case "int8": return (1, false, true)
        case "int16": return (2, false, true)
        case "int32": return (4, false, true)
        case "int8be": return (1, true, true)
        case "int16be": return (2, true, true)
        case "int32be": return (4, true, true)
        default: return nil
        }
    }

    mutating func parseFor() throws -> XPYExpr {
        let q = try parseQuantifier()
        if isIdent("of") {
            pos += 1
            let set = try parseStringSet()
            try expectOp(":")
            try expectOp("(")
            inForOf += 1
            let body = try parseExpr(0)
            inForOf -= 1
            try expectOp(")")
            return .forOf(q, set, body)
        }
        guard case .ident(let v) = try next(), !["in", "of"].contains(v) else {
            throw XPYaraUnsupported("syntax: for")
        }
        if isOp(",") { throw XPYaraUnsupported("condition: for with several variables") }
        try expectIdent("in")
        let iter: XPYIter
        try expectOp("(")
        let first = try parseExpr(6)
        if isOp("..") {
            pos += 1
            let hi = try parseExpr(6)
            try expectOp(")")
            iter = .range(first, hi)
        } else {
            var items = [first]
            while isOp(",") {
                pos += 1
                items.append(try parseExpr(6))
            }
            try expectOp(")")
            iter = .list(items)
        }
        try expectOp(":")
        try expectOp("(")
        loopVars.append(v)
        let slot = loopVars.count - 1
        let body = try parseExpr(0)
        loopVars.removeLast()
        try expectOp(")")
        return .forIn(q, slot: slot, iter, body)
    }
}
