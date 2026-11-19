import Foundation

// Compiles YARA strings (text, hex, regex) into match programs, picks a
// search atom for each, and verifies candidate positions.
//
// Every string becomes one or more *variants* (ascii / wide). A variant is:
// - `.fixed`: a fixed-length run of (value, mask) bytes. Plain text strings,
//   nocase (letters get mask 0xDF), wide (interleaved 0x00), and hex strings
//   without jumps or alternatives (wildcard nibbles become masks).
// - `.hex`: hex string with jumps `[n-m]` and/or alternatives `( a | b )`,
//   verified by bounded backtracking.
// - `.regex`: a Thompson-NFA (Pike VM) program, verified with YARA's 4096
//   byte match-length limit.
//
// Atoms: a short run of fixed bytes that every match must contain at a known
// offset (or small offset range) from its start. The scanner finds atom
// occurrences and verifies the variant only there. Atoms are 4 bytes when
// possible (YARA's own atom size), else 2, else 1.

// MARK: - Byte classes

struct XPYByteSet: Hashable, Sendable {
    var w0: UInt64 = 0, w1: UInt64 = 0, w2: UInt64 = 0, w3: UInt64 = 0

    static var all: XPYByteSet { XPYByteSet(w0: ~0, w1: ~0, w2: ~0, w3: ~0) }

    @inline(__always) func contains(_ c: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(c & 63)
        switch c >> 6 {
        case 0: return w0 & bit != 0
        case 1: return w1 & bit != 0
        case 2: return w2 & bit != 0
        default: return w3 & bit != 0
        }
    }

    mutating func insert(_ c: UInt8) {
        let bit = UInt64(1) << UInt64(c & 63)
        switch c >> 6 {
        case 0: w0 |= bit
        case 1: w1 |= bit
        case 2: w2 |= bit
        default: w3 |= bit
        }
    }

    mutating func insert(range lo: UInt8, _ hi: UInt8) {
        guard lo <= hi else { return }
        for c in lo...hi { insert(c) }
    }

    mutating func formUnion(_ o: XPYByteSet) {
        w0 |= o.w0; w1 |= o.w1; w2 |= o.w2; w3 |= o.w3
    }

    var inverted: XPYByteSet { XPYByteSet(w0: ~w0, w1: ~w1, w2: ~w2, w3: ~w3) }

    var count: Int { w0.nonzeroBitCount + w1.nonzeroBitCount + w2.nonzeroBitCount + w3.nonzeroBitCount }

    var members: [UInt8] { (0...255).compactMap { contains(UInt8($0)) ? UInt8($0) : nil } }

    /// Adds the other case of every ASCII letter.
    var caseFolded: XPYByteSet {
        var s = self
        for c in UInt8(0x41)...0x5A where contains(c) || contains(c | 0x20) {
            s.insert(c)
            s.insert(c | 0x20)
        }
        return s
    }

    static let word: XPYByteSet = {
        var s = XPYByteSet()
        s.insert(range: 0x30, 0x39); s.insert(range: 0x41, 0x5A); s.insert(range: 0x61, 0x7A); s.insert(0x5F)
        return s
    }()

    static let digit: XPYByteSet = {
        var s = XPYByteSet()
        s.insert(range: 0x30, 0x39)
        return s
    }()

    static let space: XPYByteSet = {
        var s = XPYByteSet()
        for c: UInt8 in [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D] { s.insert(c) }
        return s
    }()
}

@inline(__always) func xpyIsLetter(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}

@inline(__always) func xpyIsAlnum(_ c: UInt8) -> Bool {
    xpyIsLetter(c) || (c >= 0x30 && c <= 0x39)
}

// MARK: - Hex strings

indirect enum XPYHexTok: Sendable {
    case byte(UInt8, UInt8) // value (pre-masked), mask
    case jump(Int, Int)
    case alt([[XPYHexTok]])
}

enum XPYHexParser {
    /// YARA's maximum for an unbounded jump is not something we can mirror
    /// exactly, so `[n-]` is capped here and the string is flagged as
    /// possibly finding *fewer* matches than YARA (see `underApproximate`).
    static let unboundedJumpCap = 32767

    struct Result {
        var tokens: [XPYHexTok]
        var underApproximate: Bool
    }

    static func parse(_ raw: [UInt8]) throws -> Result {
        // strip comments
        var b: [UInt8] = []
        var i = 0
        while i < raw.count {
            if raw[i] == 0x2F, i + 1 < raw.count, raw[i + 1] == 0x2F {
                while i < raw.count, raw[i] != 0x0A { i += 1 }
            } else if raw[i] == 0x2F, i + 1 < raw.count, raw[i + 1] == 0x2A {
                i += 2
                while i + 1 < raw.count, !(raw[i] == 0x2A && raw[i + 1] == 0x2F) { i += 1 }
                i += 2
            } else {
                b.append(raw[i]); i += 1
            }
        }
        var p = 0
        var under = false
        func skip() { while p < b.count, b[p] == 0x20 || b[p] == 0x09 || b[p] == 0x0A || b[p] == 0x0D { p += 1 } }
        func nib(_ c: UInt8) throws -> (UInt8, UInt8) { // value, mask
            if c == 0x3F { return (0, 0) }
            guard let v = XPYaraLexer.hexValue(c) else { throw XPYaraUnsupported("hex: bad digit") }
            return (v, 0xF)
        }
        func number() throws -> Int? {
            skip()
            var v = 0, digits = 0
            while p < b.count, b[p] >= 0x30, b[p] <= 0x39 {
                v = v * 10 + Int(b[p] - 0x30); p += 1; digits += 1
                if v > 1_000_000 { throw XPYaraUnsupported("hex: jump too large") }
            }
            skip()
            return digits == 0 ? nil : v
        }
        func seq(depth: Int) throws -> [XPYHexTok] {
            var out: [XPYHexTok] = []
            while true {
                skip()
                guard p < b.count else { return out }
                let c = b[p]
                if c == 0x7C || c == 0x29 { return out } // | )
                if c == 0x28 {
                    p += 1
                    var alts: [[XPYHexTok]] = [try seq(depth: depth + 1)]
                    while p < b.count, b[p] == 0x7C { p += 1; alts.append(try seq(depth: depth + 1)) }
                    guard p < b.count, b[p] == 0x29 else { throw XPYaraUnsupported("hex: unbalanced (") }
                    p += 1
                    if alts.contains(where: \.isEmpty) { throw XPYaraUnsupported("hex: empty alternative") }
                    out.append(.alt(alts))
                } else if c == 0x5B {
                    p += 1
                    let lo = try number()
                    var hi = lo
                    if p < b.count, b[p] == 0x2D {
                        p += 1
                        hi = try number()
                        if hi == nil { under = true }
                    }
                    guard p < b.count, b[p] == 0x5D else { throw XPYaraUnsupported("hex: bad jump") }
                    p += 1
                    let l = lo ?? 0
                    let h = hi ?? max(l, unboundedJumpCap)
                    guard l <= h else { throw XPYaraUnsupported("hex: bad jump") }
                    if lo == nil && hi != nil { throw XPYaraUnsupported("hex: bad jump") }
                    out.append(.jump(l, h))
                } else if c == 0x7E {
                    throw XPYaraUnsupported("hex: not operator ~")
                } else {
                    guard p + 1 < b.count else { throw XPYaraUnsupported("hex: odd digits") }
                    let (hv, hm) = try nib(b[p])
                    let (lv, lm) = try nib(b[p + 1])
                    p += 2
                    out.append(.byte(hv << 4 | lv, hm << 4 | lm))
                }
            }
        }
        let toks = try seq(depth: 0)
        skip()
        guard p == b.count else { throw XPYaraUnsupported("hex: syntax") }
        guard !toks.isEmpty else { throw XPYaraUnsupported("hex: empty") }
        if case .jump = toks.first { throw XPYaraUnsupported("hex: starts with jump") }
        if case .jump = toks.last { throw XPYaraUnsupported("hex: ends with jump") }
        return Result(tokens: toks, underApproximate: under)
    }

    /// (min, max) width; max nil when unbounded.
    static func width(_ toks: [XPYHexTok]) -> (Int, Int) {
        var lo = 0, hi = 0
        for t in toks {
            switch t {
            case .byte: lo += 1; hi += 1
            case .jump(let a, let b): lo += a; hi += b
            case .alt(let alts):
                let ws = alts.map(width)
                lo += ws.map(\.0).min()!
                hi += ws.map(\.1).max()!
            }
        }
        return (lo, hi)
    }

    static func isPlain(_ toks: [XPYHexTok]) -> Bool {
        toks.allSatisfy { if case .byte = $0 { return true } else { return false } }
    }
}

// MARK: - Regular expressions

indirect enum XPYRegexNode: Sendable {
    case byte(UInt8, UInt8)
    case set(XPYByteSet)
    case seq([XPYRegexNode])
    case alt([XPYRegexNode])
    case rep(XPYRegexNode, Int, Int?) // min, max (nil = unbounded)
    case wordBoundary(Bool)           // true: \b, false: \B
    case bol, eol
}

enum XPYRegexParser {
    static let maxRepeat = 1000

    static func parse(_ p: [UInt8], caseInsensitive ci: Bool, dotAll: Bool) throws -> XPYRegexNode {
        var i = 0
        func peek() -> UInt8? { i < p.count ? p[i] : nil }

        func charNode(_ c: UInt8) -> XPYRegexNode {
            if ci && xpyIsLetter(c) { return .byte(c & 0xDF, 0xDF) }
            return .byte(c, 0xFF)
        }

        func setNode(_ s: XPYByteSet) -> XPYRegexNode { .set(ci ? s.caseFolded : s) }

        /// Escapes valid both inside and outside classes. Returns a set or a
        /// single byte.
        func escape() throws -> (XPYByteSet?, UInt8?) {
            guard let e = peek() else { throw XPYaraUnsupported("regex: trailing backslash") }
            i += 1
            switch e {
            case 0x77: return (XPYByteSet.word, nil)                 // \w
            case 0x57: return (XPYByteSet.word.inverted, nil)        // \W
            case 0x64: return (XPYByteSet.digit, nil)                // \d
            case 0x44: return (XPYByteSet.digit.inverted, nil)       // \D
            case 0x73: return (XPYByteSet.space, nil)                // \s
            case 0x53: return (XPYByteSet.space.inverted, nil)       // \S
            case 0x74: return (nil, 0x09)
            case 0x6E: return (nil, 0x0A)
            case 0x72: return (nil, 0x0D)
            case 0x66: return (nil, 0x0C)
            case 0x61: return (nil, 0x07)
            case 0x78:
                guard i + 1 < p.count, let h = XPYaraLexer.hexValue(p[i]), let l = XPYaraLexer.hexValue(p[i + 1]) else {
                    throw XPYaraUnsupported("regex: bad \\x")
                }
                i += 2
                return (nil, h << 4 | l)
            default:
                // Escaped punctuation is literal; escaped letters/digits we
                // don't know (\1, \z, \p…) are unsupported.
                if xpyIsAlnum(e) { throw XPYaraUnsupported("regex: escape \\\(Character(UnicodeScalar(e)))") }
                return (nil, e)
            }
        }

        func parseClass() throws -> XPYRegexNode {
            var set = XPYByteSet()
            var negate = false
            if peek() == 0x5E { negate = true; i += 1 }
            var first = true
            while true {
                guard let c = peek() else { throw XPYaraUnsupported("regex: unterminated class") }
                if c == 0x5D && !first { i += 1; break }
                first = false
                var lo: UInt8
                if c == 0x5C {
                    i += 1
                    if peek() == 0x62 { throw XPYaraUnsupported("regex: \\b in class") }
                    let (s, b) = try escape()
                    if let s { set.formUnion(s); continue }
                    lo = b!
                } else {
                    if c == 0x5B, i + 1 < p.count, p[i + 1] == 0x3A { throw XPYaraUnsupported("regex: POSIX class") }
                    lo = c
                    i += 1
                }
                if peek() == 0x2D, i + 1 < p.count, p[i + 1] != 0x5D {
                    i += 1
                    var hi: UInt8
                    if peek() == 0x5C {
                        i += 1
                        let (s, b) = try escape()
                        if s != nil { throw XPYaraUnsupported("regex: class range to set") }
                        hi = b!
                    } else {
                        hi = p[i]
                        i += 1
                    }
                    guard lo <= hi else { throw XPYaraUnsupported("regex: bad range") }
                    set.insert(range: lo, hi)
                } else {
                    set.insert(lo)
                }
            }
            if ci { set = set.caseFolded }
            return .set(negate ? set.inverted : set)
        }

        func parseAtom() throws -> XPYRegexNode {
            let c = p[i]
            switch c {
            case 0x28:
                i += 1
                if peek() == 0x3F { throw XPYaraUnsupported("regex: (? group") }
                let inner = try parseAlt()
                guard peek() == 0x29 else { throw XPYaraUnsupported("regex: unbalanced (") }
                i += 1
                return inner
            case 0x5B:
                i += 1
                return try parseClass()
            case 0x2E:
                i += 1
                var s = XPYByteSet.all
                if !dotAll { s = XPYByteSet(); s.insert(range: 0, 0x09); s.insert(range: 0x0B, 0xFF) }
                return .set(s)
            case 0x5E: i += 1; return .bol
            case 0x24: i += 1; return .eol
            case 0x5C:
                i += 1
                if peek() == 0x62 { i += 1; return .wordBoundary(true) }
                if peek() == 0x42 { i += 1; return .wordBoundary(false) }
                let (s, b) = try escape()
                if let s { return setNode(s) }
                return charNode(b!)
            case 0x2A, 0x2B, 0x3F, 0x7B, 0x7D:
                throw XPYaraUnsupported("regex: misplaced quantifier or brace")
            default:
                i += 1
                return charNode(c)
            }
        }

        func readInt() -> Int? {
            var v = 0, d = 0
            while let c = peek(), c >= 0x30, c <= 0x39 { v = v * 10 + Int(c - 0x30); i += 1; d += 1; if v > 100_000 { return nil } }
            return d == 0 ? nil : v
        }

        func parseQuant(_ atom: XPYRegexNode) throws -> XPYRegexNode {
            guard let c = peek() else { return atom }
            var lo = 0
            var hi: Int?
            switch c {
            case 0x2A: i += 1; lo = 0; hi = nil
            case 0x2B: i += 1; lo = 1; hi = nil
            case 0x3F: i += 1; lo = 0; hi = 1
            case 0x7B:
                i += 1
                let a = readInt()
                if peek() == 0x2C {
                    i += 1
                    let b = readInt()
                    lo = a ?? 0
                    hi = b
                    if a == nil && b == nil { throw XPYaraUnsupported("regex: bad {}") }
                } else {
                    guard let a else { throw XPYaraUnsupported("regex: bad {}") }
                    lo = a; hi = a
                }
                guard peek() == 0x7D else { throw XPYaraUnsupported("regex: bad {}") }
                i += 1
            default:
                return atom
            }
            if let h = hi, h < lo { throw XPYaraUnsupported("regex: bad {}") }
            if lo > maxRepeat || (hi ?? 0) > maxRepeat { throw XPYaraUnsupported("regex: repeat too large") }
            switch atom {
            case .bol, .eol, .wordBoundary: throw XPYaraUnsupported("regex: quantified assertion")
            default: break
            }
            if peek() == 0x3F { i += 1 } // non-greedy: same language for existence checks
            if let n = peek(), n == 0x2A || n == 0x2B || n == 0x3F || n == 0x7B {
                throw XPYaraUnsupported("regex: stacked quantifiers")
            }
            return .rep(atom, lo, hi)
        }

        func parseSeq() throws -> XPYRegexNode {
            var items: [XPYRegexNode] = []
            while let c = peek(), c != 0x7C, c != 0x29 {
                items.append(try parseQuant(try parseAtom()))
            }
            return items.count == 1 ? items[0] : .seq(items)
        }

        func parseAlt() throws -> XPYRegexNode {
            var branches = [try parseSeq()]
            while peek() == 0x7C { i += 1; branches.append(try parseSeq()) }
            return branches.count == 1 ? branches[0] : .alt(branches)
        }

        let root = try parseAlt()
        guard i == p.count else { throw XPYaraUnsupported("regex: unbalanced )") }
        return root
    }
}

/// Pike-VM program.
struct XPYRegexProgram: Sendable {
    enum Inst: Sendable {
        case byte(UInt8, UInt8)
        case set(Int)
        case split(Int, Int)
        case jmp(Int)
        case wordBoundary(Bool)
        case bol, eol
        case match
    }

    var insts: [Inst]
    var sets: [XPYByteSet]

    static let maxInstructions = 20_000
    /// YARA never reports a regex match longer than this (YR_RE_SCAN_LIMIT).
    static let scanLimit = 4096

    static func compile(_ root: XPYRegexNode) throws -> XPYRegexProgram {
        var insts: [Inst] = []
        var sets: [XPYByteSet] = []
        var setIndex: [XPYByteSet: Int] = [:]

        func emit(_ n: XPYRegexNode) throws {
            guard insts.count < maxInstructions else { throw XPYaraUnsupported("regex: program too large") }
            switch n {
            case .byte(let v, let m): insts.append(.byte(v, m))
            case .set(let s):
                let idx: Int
                if let k = setIndex[s] { idx = k } else { idx = sets.count; sets.append(s); setIndex[s] = idx }
                insts.append(.set(idx))
            case .seq(let items): for it in items { try emit(it) }
            case .wordBoundary(let b): insts.append(.wordBoundary(b))
            case .bol: insts.append(.bol)
            case .eol: insts.append(.eol)
            case .alt(let branches):
                var jumpsToEnd: [Int] = []
                for (k, br) in branches.enumerated() {
                    if k < branches.count - 1 {
                        let split = insts.count
                        insts.append(.split(0, 0))
                        try emit(br)
                        jumpsToEnd.append(insts.count)
                        insts.append(.jmp(0))
                        insts[split] = .split(split + 1, insts.count)
                    } else {
                        try emit(br)
                    }
                }
                for j in jumpsToEnd { insts[j] = .jmp(insts.count) }
            case .rep(let x, let lo, let hi):
                for _ in 0..<lo { try emit(x) }
                if let hi {
                    var splits: [Int] = []
                    for _ in lo..<hi {
                        splits.append(insts.count)
                        insts.append(.split(0, 0))
                        try emit(x)
                    }
                    for s in splits { insts[s] = .split(s + 1, insts.count) }
                } else {
                    let loop = insts.count
                    insts.append(.split(0, 0))
                    try emit(x)
                    insts.append(.jmp(loop))
                    insts[loop] = .split(loop + 1, insts.count)
                }
            }
        }
        try emit(root)
        insts.append(.match)
        return XPYRegexProgram(insts: insts, sets: sets)
    }

    /// True if some match starts exactly at `start`.
    func matches(_ base: UnsafePointer<UInt8>, _ n: Int, at start: Int) -> Bool {
        let count = insts.count
        var mark = [Int32](repeating: -1, count: count)
        var clist: [Int] = []
        var nlist: [Int] = []
        clist.reserveCapacity(32)
        nlist.reserveCapacity(32)
        var stack: [Int] = []
        var generation: Int32 = 0
        var found = false

        func isWord(_ pos: Int) -> Bool { pos >= 0 && pos < n && XPYByteSet.word.contains(base[pos]) }

        func add(_ list: inout [Int], _ pc0: Int, _ pos: Int) {
            stack.append(pc0)
            while let pc = stack.popLast() {
                if mark[pc] == generation { continue }
                mark[pc] = generation
                switch insts[pc] {
                case .jmp(let t): stack.append(t)
                case .split(let a, let b): stack.append(b); stack.append(a)
                case .wordBoundary(let want):
                    if (isWord(pos - 1) != isWord(pos)) == want { stack.append(pc + 1) }
                case .bol: if pos == 0 { stack.append(pc + 1) }
                case .eol: if pos == n { stack.append(pc + 1) }
                case .match: found = true
                case .byte, .set: list.append(pc)
                }
            }
        }

        var pos = start
        add(&clist, 0, pos)
        if found { return true }
        let limit = min(n, start + Self.scanLimit)
        while !clist.isEmpty && pos < limit {
            let c = base[pos]
            generation += 1
            nlist.removeAll(keepingCapacity: true)
            for pc in clist {
                switch insts[pc] {
                case .byte(let v, let m):
                    if c & m == v { add(&nlist, pc + 1, pos + 1) }
                case .set(let k):
                    if sets[k].contains(c) { add(&nlist, pc + 1, pos + 1) }
                default: break
                }
                if found { return true }
            }
            swap(&clist, &nlist)
            pos += 1
        }
        return false
    }
}

// MARK: - Variants and atoms

enum XPYProgram: Sendable {
    case fixed(values: [UInt8], masks: [UInt8])
    case hex([XPYHexTok])
    case regex(XPYRegexProgram)
}

struct XPYVariant: Sendable {
    var program: XPYProgram
    var fullword: Bool
    var wide: Bool
    /// Skeleton used for atom selection.
    var skeleton: [XPYSkel]
}

enum XPYSkel: Sendable {
    case byte(UInt8, UInt8)
    case gap(Int, Int)
}

/// A chosen atom: exact byte values (all case/nibble variants enumerated)
/// at offset `lo...hi` from the match start.
struct XPYAtomChoice: Sendable {
    var length: Int          // 1, 2 or 4
    var keys: [UInt32]       // little-endian packed values
    var lo: Int
    var hi: Int
}

enum XPYAtoms {
    /// Approximate rarity (−log2 frequency) of each byte value in macOS
    /// binaries and scripts, measured on /usr/bin, app executables, dylibs
    /// and shell scripts. Higher = rarer = better atom.
    static let rarity: [UInt8] = [
        2,6,7,6,7,8,8,8,7,8,8,9,8,9,9,5,7,9,9,9,8,9,9,8,8,10,9,10,9,10,9,8,
        7,9,10,9,8,9,10,10,8,8,10,10,10,10,9,10,9,8,10,9,9,9,10,10,8,8,9,10,10,9,10,9,
        7,6,8,8,7,7,9,9,5,7,10,10,7,8,9,9,9,10,8,9,8,9,10,9,10,11,10,10,10,9,10,7,
        9,8,8,8,9,7,6,9,9,8,10,9,8,9,8,7,8,9,8,8,7,8,10,10,9,9,10,9,10,9,10,9,
        7,9,10,7,8,8,10,10,9,6,10,6,10,7,11,11,9,8,10,11,8,10,11,9,10,11,10,11,11,11,11,10,
        9,10,11,11,11,11,12,11,9,8,7,11,11,10,12,10,9,11,11,11,9,10,9,10,9,8,10,11,11,10,10,10,
        7,8,9,9,8,8,9,9,9,9,10,10,10,11,10,10,8,9,9,10,10,10,9,10,10,10,10,10,11,11,10,9,
        8,9,9,10,10,9,10,10,7,9,10,9,10,10,10,10,9,9,9,9,9,9,8,9,8,7,9,9,9,8,7,5,
    ]

    static let maxVariantsPerAtom = 16

    static func score(_ v: UInt8, _ m: UInt8) -> Double {
        if m == 0xFF { return Double(rarity[Int(v)]) }
        if m == 0xDF && xpyIsLetter(v | 0x20) {
            return Double(min(rarity[Int(v)], rarity[Int(v | 0x20)])) - 1
        }
        return Double(m.nonzeroBitCount) * 0.6
    }

    /// Enumerates every concrete byte a (value, mask) pair accepts.
    static func expand(_ v: UInt8, _ m: UInt8) -> [UInt8] {
        if m == 0xFF { return [v] }
        var out: [UInt8] = []
        for c in 0...255 where UInt8(c) & m == v { out.append(UInt8(c)) }
        return out
    }

    static func choose(_ skel: [XPYSkel]) -> XPYAtomChoice? {
        // Collect runs of bytes with their offset range.
        struct Run { var bytes: [(UInt8, UInt8)]; var lo: Int; var hi: Int }
        var runs: [Run] = []
        var lo = 0, hi = 0
        var current: Run?
        for el in skel {
            switch el {
            case .byte(let v, let m):
                if current == nil { current = Run(bytes: [], lo: lo, hi: hi) }
                current!.bytes.append((v, m))
                lo += 1; hi += 1
            case .gap(let a, let b):
                if let c = current { runs.append(c); current = nil }
                lo += a; hi += b
            }
        }
        if let c = current { runs.append(c) }

        var best: (score: Double, choice: XPYAtomChoice)?
        for length in [4, 2, 1] {
            for run in runs where run.bytes.count >= length {
                for start in 0...(run.bytes.count - length) {
                    let window = run.bytes[start..<(start + length)]
                    var variants = 1
                    var s = 0.0
                    for (v, m) in window {
                        variants *= 1 << (8 - m.nonzeroBitCount)
                        s += score(v, m)
                    }
                    guard variants <= maxVariantsPerAtom else { continue }
                    let spread = run.hi - run.lo
                    s -= Double(variants).squareRoot() - 1
                    s -= Double(min(spread, 64)) * 0.1
                    if best == nil || s > best!.score {
                        var keys: [UInt32] = [0]
                        for (k, (v, m)) in window.enumerated() {
                            let options = expand(v, m)
                            keys = keys.flatMap { key in options.map { key | UInt32($0) << UInt32(8 * k) } }
                        }
                        best = (s, XPYAtomChoice(length: length, keys: keys,
                                                 lo: run.lo + start, hi: run.hi + start))
                    }
                }
            }
            if best != nil { break }
        }
        return best?.choice
    }

    // MARK: Skeletons

    static func skeleton(hex toks: [XPYHexTok]) -> [XPYSkel] {
        var out: [XPYSkel] = []
        for t in toks {
            switch t {
            case .byte(let v, let m): out.append(.byte(v, m))
            case .jump(let a, let b): out.append(.gap(a, b))
            case .alt(let alts):
                let ws = alts.map(XPYHexParser.width)
                out.append(.gap(ws.map(\.0).min()!, ws.map(\.1).max()!))
            }
        }
        return out
    }

    /// Width (min, max) of a regex node; max nil if unbounded.
    static func width(_ n: XPYRegexNode) -> (Int, Int?) {
        switch n {
        case .byte, .set: return (1, 1)
        case .wordBoundary, .bol, .eol: return (0, 0)
        case .seq(let items):
            var lo = 0
            var hi: Int? = 0
            for it in items {
                let (a, b) = width(it)
                lo += a
                if let h = hi, let b { hi = h + b } else { hi = nil }
            }
            return (lo, hi)
        case .alt(let br):
            let ws = br.map(width)
            let lo = ws.map(\.0).min()!
            let hi: Int? = ws.contains { $0.1 == nil } ? nil : ws.map { $0.1! }.max()!
            return (lo, hi)
        case .rep(let x, let lo, let hi):
            let (a, b) = width(x)
            guard let hi, let b else { return (a * lo, nil) }
            return (a * lo, b * hi)
        }
    }

    /// Mandatory prefix of a regex as bytes/gaps; stops at the first part
    /// with unbounded width.
    static func skeleton(regex root: XPYRegexNode) -> [XPYSkel] {
        var out: [XPYSkel] = []
        var stopped = false

        func single(_ s: XPYByteSet) -> XPYSkel {
            let m = s.members
            if m.count == 1 { return .byte(m[0], 0xFF) }
            if m.count == 2, m[0] ^ m[1] == 0x20, xpyIsLetter(m[0]) { return .byte(m[0] & 0xDF, 0xDF) }
            return .gap(1, 1)
        }

        func walk(_ n: XPYRegexNode) {
            if stopped { return }
            switch n {
            case .byte(let v, let m): out.append(.byte(v, m))
            case .set(let s): out.append(single(s))
            case .wordBoundary, .bol, .eol: break
            case .seq(let items): for it in items { walk(it); if stopped { return } }
            case .alt:
                let (a, b) = width(n)
                if let b { out.append(.gap(a, b)) } else { stopped = true }
            case .rep(let x, let lo, let hi):
                if lo >= 1 {
                    // the first `lo` iterations are mandatory
                    let copies = min(lo, 8)
                    for _ in 0..<copies { walk(x); if stopped { return } }
                    let (a, b) = width(x)
                    if let hi, let b {
                        out.append(.gap(a * (lo - copies), b * (hi - copies)))
                    } else if lo > copies {
                        out.append(.gap(a * (lo - copies), a * (lo - copies)))
                        stopped = true
                    } else {
                        stopped = true
                    }
                } else {
                    let (_, b) = width(n)
                    if let b { out.append(.gap(0, b)) } else { stopped = true }
                }
            }
        }
        walk(root)
        return out
    }

    static func skeleton(fixed values: [UInt8], _ masks: [UInt8]) -> [XPYSkel] {
        zip(values, masks).map { .byte($0, $1) }
    }
}

// MARK: - String compilation

struct XPYCompiledString: Sendable {
    var name: String
    var variants: [XPYVariant]
    var atoms: [XPYAtomChoice]   // one per variant
    /// Length when every variant has the same fixed length (for `!a`).
    var fixedLength: Int?
    /// True when matching may find fewer matches than YARA would (capped
    /// unbounded jumps). Such strings are only allowed where finding fewer
    /// matches can only make the rule match less.
    var underApproximate: Bool
}

enum XPYStringCompiler {
    static let textModifiers: Set<String> = ["ascii", "wide", "nocase", "fullword", "private"]

    static func compile(_ s: XPYParsedString) throws -> XPYCompiledString {
        var variants: [XPYVariant] = []
        var under = false
        let mods = s.modifiers
        switch s.body {
        case .text(let bytes):
            for m in mods where !textModifiers.contains(m) { throw XPYaraUnsupported("string modifier: \(m)") }
            guard !bytes.isEmpty else { throw XPYaraUnsupported("string: empty") }
            let nocase = mods.contains("nocase")
            let wantWide = mods.contains("wide")
            let wantAscii = mods.contains("ascii") || !wantWide
            var values: [UInt8] = []
            var masks: [UInt8] = []
            for c in bytes {
                if nocase && xpyIsLetter(c) { values.append(c & 0xDF); masks.append(0xDF) } else { values.append(c); masks.append(0xFF) }
            }
            if wantAscii {
                variants.append(XPYVariant(program: .fixed(values: values, masks: masks), fullword: mods.contains("fullword"),
                                           wide: false, skeleton: XPYAtoms.skeleton(fixed: values, masks)))
            }
            if wantWide {
                var wv: [UInt8] = [], wm: [UInt8] = []
                for (v, m) in zip(values, masks) { wv += [v, 0]; wm += [m, 0xFF] }
                variants.append(XPYVariant(program: .fixed(values: wv, masks: wm), fullword: mods.contains("fullword"),
                                           wide: true, skeleton: XPYAtoms.skeleton(fixed: wv, wm)))
            }
        case .hex(let raw):
            for m in mods where m != "private" { throw XPYaraUnsupported("hex modifier: \(m)") }
            let r = try XPYHexParser.parse(raw)
            under = r.underApproximate
            if XPYHexParser.isPlain(r.tokens) {
                var values: [UInt8] = [], masks: [UInt8] = []
                for t in r.tokens { if case .byte(let v, let m) = t { values.append(v); masks.append(m) } }
                variants.append(XPYVariant(program: .fixed(values: values, masks: masks), fullword: false, wide: false,
                                           skeleton: XPYAtoms.skeleton(fixed: values, masks)))
            } else {
                variants.append(XPYVariant(program: .hex(r.tokens), fullword: false, wide: false,
                                           skeleton: XPYAtoms.skeleton(hex: r.tokens)))
            }
        case .regex(let body, let ci, let dotAll):
            for m in mods where !["ascii", "nocase", "private"].contains(m) { throw XPYaraUnsupported("regex modifier: \(m)") }
            let root = try XPYRegexParser.parse(body, caseInsensitive: ci || mods.contains("nocase"), dotAll: dotAll)
            let prog = try XPYRegexProgram.compile(root)
            variants.append(XPYVariant(program: .regex(prog), fullword: false, wide: false,
                                       skeleton: XPYAtoms.skeleton(regex: root)))
        }
        var atoms: [XPYAtomChoice] = []
        for v in variants {
            guard let a = XPYAtoms.choose(v.skeleton) else { throw XPYaraUnsupported("pattern: no usable atom") }
            atoms.append(a)
        }
        var fixedLength: Int?
        let lengths = variants.map { v -> Int? in if case .fixed(let vals, _) = v.program { return vals.count } else { return nil } }
        if let f = lengths.first, let f, lengths.allSatisfy({ $0 == f }) { fixedLength = f }
        return XPYCompiledString(name: s.name, variants: variants, atoms: atoms, fixedLength: fixedLength, underApproximate: under)
    }
}

// MARK: - Verification

enum XPYVerify {
    static let hexStepBudget = 200_000

    @inline(__always)
    static func fixed(_ base: UnsafePointer<UInt8>, _ n: Int, _ s: Int,
                      _ values: UnsafeBufferPointer<UInt8>, _ masks: UnsafeBufferPointer<UInt8>) -> Bool {
        let len = values.count
        guard s >= 0, s + len <= n else { return false }
        var k = 0
        while k < len {
            if base[s + k] & masks[k] != values[k] { return false }
            k += 1
        }
        return true
    }

    /// YARA's fullword check (libyara scan.c).
    static func fullwordOK(_ base: UnsafePointer<UInt8>, _ n: Int, _ s: Int, _ len: Int, wide: Bool) -> Bool {
        if wide {
            if s >= 2, base[s - 1] == 0, xpyIsAlnum(base[s - 2]) { return false }
            if s + len + 1 < n, base[s + len + 1] == 0, xpyIsAlnum(base[s + len]) { return false }
        } else {
            if s >= 1, xpyIsAlnum(base[s - 1]) { return false }
            if s + len < n, xpyIsAlnum(base[s + len]) { return false }
        }
        return true
    }

    private final class Cont {
        let seq: [XPYHexTok]
        let index: Int
        let next: Cont?
        init(_ seq: [XPYHexTok], _ index: Int, _ next: Cont?) { self.seq = seq; self.index = index; self.next = next }
    }

    /// True if the hex pattern matches starting at `s`. Bounded backtracking;
    /// if the step budget runs out the answer is "no match" (never a guess
    /// in the matching direction).
    static func hex(_ base: UnsafePointer<UInt8>, _ n: Int, _ s: Int, _ toks: [XPYHexTok]) -> Bool {
        var budget = hexStepBudget
        func m(_ seq: [XPYHexTok], _ i0: Int, _ pos0: Int, _ k: Cont?) -> Bool {
            var i = i0, pos = pos0
            while i < seq.count {
                budget -= 1
                if budget <= 0 { return false }
                switch seq[i] {
                case .byte(let v, let mask):
                    if pos >= n || base[pos] & mask != v { return false }
                    pos += 1
                    i += 1
                case .jump(let lo, let hi):
                    if pos + lo > n { return false }
                    let top = min(hi, n - pos)
                    var g = lo
                    while g <= top {
                        if m(seq, i + 1, pos + g, k) { return true }
                        if budget <= 0 { return false }
                        g += 1
                    }
                    return false
                case .alt(let alts):
                    let k2 = Cont(seq, i + 1, k)
                    for a in alts where m(a, 0, pos, k2) { return true }
                    return false
                }
            }
            if let k { return m(k.seq, k.index, pos, k.next) }
            return true
        }
        guard s >= 0, s < n else { return false }
        return m(toks, 0, s, nil)
    }
}
