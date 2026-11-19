import CryptoKit
import Foundation

// Compiled XProtect YARA rules: rule table, global string/variant tables,
// atom index, the scanning loop and the condition evaluator.
//
// Scanning one file:
// 1. Prefilter: every rule's condition is evaluated with string matches
//    *unknown* (three-valued logic). Header checks (`Macho`, `uint32(0)`),
//    `filesize` bounds and hash guards usually decide most rules here.
// 2. If some rule is still undecided, the strings those rules need are
//    searched in one pass over the bytes (atoms → verification).
// 3. Undecided rules are evaluated again with the real matches.

struct XPYRule: Sendable {
    var name: String
    var description: String?
    var source: XProtectYaraSource
    var isPrivate: Bool
    var meta: [String: String]
    var condition: XPYExpr
    /// Global string ids, indexed by rule-local string index.
    var stringIDs: [Int]
    /// True if the rule references a string (or rule) that may find fewer
    /// matches than YARA; only allowed in positive positions.
    var underApproximate: Bool
    /// `filesize` bounds implied by the top-level `and` chain: outside
    /// them the rule is false without evaluating anything.
    var minSize: Int64 = 0
    var maxSize: Int64 = .max

    static func sizeBounds(_ e: XPYExpr) -> (Int64, Int64) {
        switch e {
        case .and(let a, let b):
            let x = sizeBounds(a), y = sizeBounds(b)
            return (max(x.0, y.0), min(x.1, y.1))
        case .bin(let op, .filesize, .int(let k)):
            switch op {
            case .lt: return (0, k - 1)
            case .le: return (0, k)
            case .eq: return (k, k)
            case .gt: return (k + 1, .max)
            case .ge: return (k, .max)
            default: return (0, .max)
            }
        case .bin(let op, .int(let k), .filesize):
            switch op {
            case .gt: return (0, k - 1)
            case .ge: return (0, k)
            case .eq: return (k, k)
            case .lt: return (k + 1, .max)
            case .le: return (k, .max)
            default: return (0, .max)
            }
        default:
            return (0, .max)
        }
    }
}

struct XPYRuleInfo: Sendable {
    var name: String
    var description: String?
    var source: XProtectYaraSource
    var isPrivate: Bool
    var line: Int
    /// nil when supported.
    var skipReason: String?
}

struct XPYAtomEntry {
    var variant: Int32
    var lo: Int32
    var hi: Int32
}

/// Immutable after init; buffers are owned and freed in deinit.
final class XPYEngine: @unchecked Sendable {
    let rules: [XPYRule]
    let infos: [XPYRuleInfo]
    /// Global strings.
    let strings: [XPYCompiledString]
    /// Flattened variants: (string id, variant).
    let variantString: [Int32]
    let variants: [XPYVariant]
    // Flat per-variant data for the hot verification path.
    // kind: 0 fixed, 1 hex, 2 regex; flags: bit0 fullword, bit1 wide.
    let vKind: UnsafeMutableBufferPointer<UInt8>
    let vFlags: UnsafeMutableBufferPointer<UInt8>
    let vStart: UnsafeMutableBufferPointer<Int32>
    let vLength: UnsafeMutableBufferPointer<Int32>
    let fixedBytes: UnsafeMutableBufferPointer<UInt8>
    let fixedMaskBytes: UnsafeMutableBufferPointer<UInt8>

    // Tier A (4-byte atoms): bitmap prefilter + open-addressing table.
    let aBitmapBits: Int
    let aBitmap: UnsafeMutableBufferPointer<UInt64>
    let aSlotBits: Int
    let aSlots: UnsafeMutableBufferPointer<Int32>   // index into aKeys, -1 empty
    let aKeys: UnsafeMutableBufferPointer<UInt32>
    let aStart: UnsafeMutableBufferPointer<Int32>   // entries range per key (count+1)
    // Tier B (2-byte atoms) and tier C (1-byte atoms): direct tables.
    let bBitmap: UnsafeMutableBufferPointer<UInt64> // 65536 bits
    let bStart: UnsafeMutableBufferPointer<Int32>   // 65537
    let cStart: UnsafeMutableBufferPointer<Int32>   // 257
    let entries: UnsafeMutableBufferPointer<XPYAtomEntry>
    /// Per string: which tiers its atoms use (bit0 A, bit1 B, bit2 C).
    let stringTiers: [UInt8]

    init(rules: [XPYRule], infos: [XPYRuleInfo], strings: [XPYCompiledString]) {
        self.rules = rules
        self.infos = infos
        self.strings = strings
        var vString: [Int32] = []
        var vars: [XPYVariant] = []
        var fv: [UInt8] = []
        var fm: [UInt8] = []
        var kinds: [UInt8] = [], flags: [UInt8] = [], vstarts: [Int32] = [], vlens: [Int32] = []
        var aAtoms: [UInt32: [XPYAtomEntry]] = [:]
        var bAtoms: [[XPYAtomEntry]] = Array(repeating: [], count: 65536)
        var cAtoms: [[XPYAtomEntry]] = Array(repeating: [], count: 256)
        var tiers: [UInt8] = []
        for (sid, s) in strings.enumerated() {
            var t: UInt8 = 0
            for (v, atom) in zip(s.variants, s.atoms) {
                let vid = Int32(vars.count)
                vars.append(v)
                vString.append(Int32(sid))
                vstarts.append(Int32(fv.count))
                flags.append((v.fullword ? 1 : 0) | (v.wide ? 2 : 0))
                switch v.program {
                case .fixed(let values, let masks):
                    kinds.append(0); vlens.append(Int32(values.count)); fv += values; fm += masks
                case .hex: kinds.append(1); vlens.append(0)
                case .regex: kinds.append(2); vlens.append(0)
                }
                let e = XPYAtomEntry(variant: vid, lo: Int32(atom.lo), hi: Int32(atom.hi))
                for key in Set(atom.keys) {
                    switch atom.length {
                    case 4: aAtoms[key, default: []].append(e); t |= 1
                    case 2: bAtoms[Int(key)].append(e); t |= 2
                    default: cAtoms[Int(key)].append(e); t |= 4
                    }
                }
            }
            tiers.append(t)
        }
        variantString = vString
        variants = vars
        func buffer<T>(_ a: [T], _ zero: T) -> UnsafeMutableBufferPointer<T> {
            let b = UnsafeMutableBufferPointer<T>.allocate(capacity: max(1, a.count))
            b.initialize(repeating: zero)
            for (k, x) in a.enumerated() { b[k] = x }
            return b
        }
        vKind = buffer(kinds, 0); vFlags = buffer(flags, 0); vStart = buffer(vstarts, 0); vLength = buffer(vlens, 0)
        fixedBytes = buffer(fv, 0); fixedMaskBytes = buffer(fm, 0)
        stringTiers = tiers

        var flat: [XPYAtomEntry] = []
        // Tier A
        let keys = aAtoms.keys.sorted()
        var starts: [Int32] = []
        for k in keys { starts.append(Int32(flat.count)); flat.append(contentsOf: aAtoms[k]!) }
        starts.append(Int32(flat.count))
        var slotBits = 4
        while (1 << slotBits) < keys.count * 2 { slotBits += 1 }
        aSlotBits = slotBits
        aBitmapBits = max(16, min(23, slotBits + 6))
        aBitmap = .allocate(capacity: 1 << (aBitmapBits - 6)); aBitmap.initialize(repeating: 0)
        aSlots = .allocate(capacity: 1 << slotBits); aSlots.initialize(repeating: -1)
        aKeys = .allocate(capacity: max(1, keys.count)); aKeys.initialize(repeating: 0)
        aStart = .allocate(capacity: starts.count)
        _ = aStart.initialize(from: starts)
        for (idx, k) in keys.enumerated() {
            aKeys[idx] = k
            let h = k &* 0x9E37_79B1
            let bm = Int(h >> UInt32(32 - aBitmapBits))
            aBitmap[bm >> 6] |= 1 << UInt64(bm & 63)
            var slot = Int(h >> UInt32(32 - slotBits))
            while aSlots[slot] != -1 { slot = (slot + 1) & ((1 << slotBits) - 1) }
            aSlots[slot] = Int32(idx)
        }
        // Tier B
        bBitmap = .allocate(capacity: 1024); bBitmap.initialize(repeating: 0)
        bStart = .allocate(capacity: 65537)
        for k in 0..<65536 {
            bStart[k] = Int32(flat.count)
            if !bAtoms[k].isEmpty { bBitmap[k >> 6] |= 1 << UInt64(k & 63); flat.append(contentsOf: bAtoms[k]) }
        }
        bStart[65536] = Int32(flat.count)
        // Tier C
        cStart = .allocate(capacity: 257)
        for k in 0..<256 { cStart[k] = Int32(flat.count); flat.append(contentsOf: cAtoms[k]) }
        cStart[256] = Int32(flat.count)
        entries = .allocate(capacity: max(1, flat.count))
        _ = entries.initialize(from: flat)
    }

    deinit {
        aBitmap.deallocate(); aSlots.deallocate(); aKeys.deallocate(); aStart.deallocate()
        bBitmap.deallocate(); bStart.deallocate(); cStart.deallocate(); entries.deallocate()
        vKind.deallocate(); vFlags.deallocate(); vStart.deallocate(); vLength.deallocate()
        fixedBytes.deallocate(); fixedMaskBytes.deallocate()
    }

    // MARK: - Scanning

    /// YARA stops a scan with an error when one string has more matches.
    static let maxMatchesPerString = 1_000_000

    struct ScanResult {
        var matches: [Int: [Int]]  // string id → sorted unique offsets
        var overflow: Bool
        var verifications: Int
    }

    /// One atom occurrence: position and the range of atom entries to try.
    struct AtomHit {
        var pos: Int
        var from: Int32
        var to: Int32
    }

    static let hitBufferSize = 4096

    /// Searches the strings of `rules` (compiled rule indexes).
    func scan(_ base: UnsafePointer<UInt8>, _ n: Int, rules ruleIndexes: [Int]) -> ScanResult {
        var tierMask: UInt8 = 0
        var stringNeeded = [Bool](repeating: false, count: strings.count)
        for r in ruleIndexes {
            for sid in rules[r].stringIDs where !stringNeeded[sid] {
                stringNeeded[sid] = true
                tierMask |= stringTiers[sid]
            }
        }

        var matches: [Int: [Int]] = [:]
        var unsorted = Set<Int>()
        var overflow = false
        var verifications = 0

        let hits = UnsafeMutablePointer<AtomHit>.allocate(capacity: Self.hitBufferSize)
        defer { hits.deallocate() }
        var i = 0
        while i < n {
            let (next, count) = findAtoms(base, n, from: i, tiers: tierMask, into: hits, capacity: Self.hitBufferSize)
            i = next
            for h in 0..<count {
                let hit = hits[h]
                var e = Int(hit.from)
                while e < Int(hit.to) {
                    let entry = entries[e]
                    e += 1
                    let v = Int(entry.variant)
                    let sid = Int(variantString[v])
                    if !stringNeeded[sid] { continue }
                    var s = hit.pos - Int(entry.hi)
                    let last = hit.pos - Int(entry.lo)
                    if s < 0 { s = 0 }
                    while s <= last {
                        verifications += 1
                        if verify(v, base, n, s) {
                            matches[sid, default: []].withLast { list in
                                if list.count >= Self.maxMatchesPerString { overflow = true; return }
                                if let l = list.last, l >= s { unsorted.insert(sid) }
                                list.append(s)
                            }
                        }
                        s += 1
                    }
                }
            }
        }
        for sid in unsorted {
            matches[sid] = Array(Set(matches[sid]!)).sorted()
        }
        return ScanResult(matches: matches, overflow: overflow, verifications: verifications)
    }

    /// The hot loop: finds atom occurrences from `start`, stops when the
    /// buffer is full. Returns the next position to resume from and the
    /// number of hits written. Kept free of closures and captured state so
    /// the compiler keeps everything in registers.
    @inline(never)
    func findAtoms(_ base: UnsafePointer<UInt8>, _ n: Int, from start: Int, tiers: UInt8,
                   into hits: UnsafeMutablePointer<AtomHit>, capacity: Int) -> (Int, Int) {
        let useA = tiers & 1 != 0, useB = tiers & 2 != 0, useC = tiers & 4 != 0
        let bmShift = UInt32(32 - aBitmapBits)
        let slotShift = UInt32(32 - aSlotBits)
        let slotMask = (1 << aSlotBits) - 1
        let aBitmap = self.aBitmap.baseAddress!, aSlots = self.aSlots.baseAddress!
        let aKeys = self.aKeys.baseAddress!, aStart = self.aStart.baseAddress!
        let bBitmap = self.bBitmap.baseAddress!, bStart = self.bStart.baseAddress!, cStart = self.cStart.baseAddress!
        let limit = capacity - 3 // up to 3 hits per position
        var count = 0
        var i = start
        let raw = UnsafeRawPointer(base)
        if n >= 4 {
            let last = n - 4
            while i <= last {
                if count >= limit { return (i, count) }
                let w = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)
                if useA {
                    let h = w &* 0x9E37_79B1
                    let bm = Int(h >> bmShift)
                    if aBitmap[bm >> 6] & (1 << UInt64(bm & 63)) != 0 {
                        var slot = Int(h >> slotShift)
                        while true {
                            let k = Int(aSlots[slot])
                            if k < 0 { break }
                            if aKeys[k] == w {
                                hits[count] = AtomHit(pos: i, from: aStart[k], to: aStart[k + 1])
                                count += 1
                                break
                            }
                            slot = (slot + 1) & slotMask
                        }
                    }
                }
                if useB {
                    let k = Int(w & 0xFFFF)
                    if bBitmap[k >> 6] & (1 << UInt64(k & 63)) != 0 {
                        hits[count] = AtomHit(pos: i, from: bStart[k], to: bStart[k + 1])
                        count += 1
                    }
                }
                if useC {
                    let k = Int(w & 0xFF)
                    let a = cStart[k], b = cStart[k + 1]
                    if a != b { hits[count] = AtomHit(pos: i, from: a, to: b); count += 1 }
                }
                i += 1
            }
        }
        // Tail: fewer than 4 bytes left; only 2- and 1-byte atoms fit.
        while i < n {
            if count >= limit { return (i, count) }
            if useB, i + 1 < n {
                let k = Int(base[i]) | Int(base[i + 1]) << 8
                if bBitmap[k >> 6] & (1 << UInt64(k & 63)) != 0 {
                    hits[count] = AtomHit(pos: i, from: bStart[k], to: bStart[k + 1])
                    count += 1
                }
            }
            if useC {
                let k = Int(base[i])
                let a = cStart[k], b = cStart[k + 1]
                if a != b { hits[count] = AtomHit(pos: i, from: a, to: b); count += 1 }
            }
            i += 1
        }
        return (n, count)
    }

    @inline(__always)
    func verify(_ v: Int, _ base: UnsafePointer<UInt8>, _ n: Int, _ s: Int) -> Bool {
        if vKind[v] == 0 {
            let len = Int(vLength[v])
            guard s >= 0, s + len <= n else { return false }
            let start = Int(vStart[v])
            var k = 0
            while k < len {
                if base[s + k] & fixedMaskBytes[start + k] != fixedBytes[start + k] { return false }
                k += 1
            }
            let f = vFlags[v]
            if f & 1 != 0 { return XPYVerify.fullwordOK(base, n, s, len, wide: f & 2 != 0) }
            return true
        }
        switch variants[v].program {
        case .fixed:
            return false
        case .hex(let toks):
            return XPYVerify.hex(base, n, s, toks)
        case .regex(let prog):
            return prog.matches(base, n, at: s)
        }
    }
}

// MARK: - Evaluation

/// Three-valued (plus YARA's "undefined") values.
enum XPYVal {
    case int(Int64)
    case bool(Bool)
    case text([UInt8])
    /// YARA's undefined (out-of-range read, missing match index, …).
    case undef
    /// Prefilter only: depends on string matches not yet searched.
    case unknown
}

enum XPYTri { case t, f, u, k } // true, false, undefined, unknown

struct XPYEvalContext {
    let base: UnsafePointer<UInt8>?
    let size: Int
    /// nil in the prefilter.
    var matches: [Int: [Int]]?
    var evaluateHashes: Bool
    var precomputedSHA256: String?
    var hashCache: [String: String] = [:]
    /// Rule memo: nil = not evaluated.
    var ruleResults: [XPYTri?]
    var loopVars: [Int64] = []
    var currentString: [Int] = []
    var stringIDStack: [[Int]] = []
}

enum XPYEvaluator {
    static let maxLoopIterations = 1_000_000

    static func tri(_ v: XPYVal) -> XPYTri {
        switch v {
        case .bool(let b): return b ? .t : .f
        case .int(let i): return i != 0 ? .t : .f
        case .text(let s): return s.isEmpty ? .f : .t
        case .undef: return .u
        case .unknown: return .k
        }
    }

    static func val(_ t: XPYTri) -> XPYVal {
        switch t {
        case .t: return .bool(true)
        case .f: return .bool(false)
        case .u: return .undef
        case .k: return .unknown
        }
    }

    static func evalRule(_ idx: Int, _ engine: XPYEngine, _ c: inout XPYEvalContext) -> XPYTri {
        if let r = c.ruleResults[idx] { return r }
        let rule = engine.rules[idx]
        c.stringIDStack.append(rule.stringIDs)
        let savedLoop = c.loopVars, savedCurrent = c.currentString
        c.loopVars = []
        c.currentString = []
        var r = tri(eval(rule.condition, engine, &c))
        c.loopVars = savedLoop
        c.currentString = savedCurrent
        c.stringIDStack.removeLast()
        if r == .u { r = .f } // a rule's result is always a boolean
        c.ruleResults[idx] = r
        return r
    }

    static func globalID(_ ref: XPYStrRef, _ c: XPYEvalContext) -> Int? {
        switch ref {
        case .local(let i): return c.stringIDStack.last?[i]
        case .current: return c.currentString.last
        }
    }

    /// Matches for a string, or nil if unknown (prefilter).
    static func offsets(_ ref: XPYStrRef, _ c: XPYEvalContext) -> [Int]? {
        guard let m = c.matches, let id = globalID(ref, c) else { return nil }
        return m[id] ?? []
    }

    static func int(_ e: XPYExpr, _ engine: XPYEngine, _ c: inout XPYEvalContext) -> XPYVal {
        eval(e, engine, &c)
    }

    static func eval(_ e: XPYExpr, _ engine: XPYEngine, _ c: inout XPYEvalContext) -> XPYVal {
        switch e {
        case .int(let i): return .int(i)
        case .bool(let b): return .bool(b)
        case .text(let s): return .text(s)
        case .filesize: return .int(Int64(c.size))
        case .rule(let idx): return val(evalRule(idx, engine, &c))
        case .loopVar(let slot): return slot < c.loopVars.count ? .int(c.loopVars[slot]) : .undef
        case .found(let ref):
            guard let o = offsets(ref, c) else { return .unknown }
            return .bool(!o.isEmpty)
        case .at(let ref, let offE):
            let off = eval(offE, engine, &c)
            guard case .int(let x) = off else { return off.isUnknown ? .unknown : .undef }
            guard let o = offsets(ref, c) else { return .unknown }
            return .bool(binarySearch(o, Int(clamping: x)))
        case .inRange(let ref, let loE, let hiE):
            let lo = eval(loE, engine, &c), hi = eval(hiE, engine, &c)
            guard case .int(let l) = lo, case .int(let h) = hi else {
                return (lo.isUnknown || hi.isUnknown) ? .unknown : .undef
            }
            guard let o = offsets(ref, c) else { return .unknown }
            return .bool(countInRange(o, l, h) > 0)
        case .count(let ref):
            guard let o = offsets(ref, c) else { return .unknown }
            return .int(Int64(o.count))
        case .countIn(let ref, let loE, let hiE):
            let lo = eval(loE, engine, &c), hi = eval(hiE, engine, &c)
            guard case .int(let l) = lo, case .int(let h) = hi else {
                return (lo.isUnknown || hi.isUnknown) ? .unknown : .undef
            }
            guard let o = offsets(ref, c) else { return .unknown }
            return .int(Int64(countInRange(o, l, h)))
        case .offset(let ref, let idxE):
            let idx = eval(idxE, engine, &c)
            guard case .int(let i) = idx else { return idx.isUnknown ? .unknown : .undef }
            guard let o = offsets(ref, c) else { return .unknown }
            guard i >= 1, i <= Int64(o.count) else { return .undef }
            return .int(Int64(o[Int(i) - 1]))
        case .length(let ref, let idxE):
            let idx = eval(idxE, engine, &c)
            guard case .int(let i) = idx else { return idx.isUnknown ? .unknown : .undef }
            guard let o = offsets(ref, c), let id = globalID(ref, c) else { return .unknown }
            guard i >= 1, i <= Int64(o.count), let len = engine.strings[id].fixedLength else { return .undef }
            return .int(Int64(len))
        case .read(let width, let be, let signed, let offE):
            let off = eval(offE, engine, &c)
            guard case .int(let x) = off else { return off.isUnknown ? .unknown : .undef }
            guard let base = c.base, x >= 0, x <= Int64(c.size - width) else { return .undef }
            let o = Int(x)
            var v: UInt64 = 0
            for k in 0..<width {
                let byte = UInt64(base[o + k])
                v |= be ? byte << UInt64(8 * (width - 1 - k)) : byte << UInt64(8 * k)
            }
            if signed {
                let shift = UInt64(64 - 8 * width)
                return .int(Int64(bitPattern: v << shift) >> Int64(shift))
            }
            return .int(Int64(v))
        case .not(let x):
            switch tri(eval(x, engine, &c)) {
            case .t: return .bool(false)
            case .f: return .bool(true)
            case .u: return .undef
            case .k: return .unknown
            }
        case .neg(let x):
            let v = eval(x, engine, &c)
            guard case .int(let i) = v else { return v.isUnknown ? .unknown : .undef }
            return .int(0 &- i)
        case .bitNot(let x):
            let v = eval(x, engine, &c)
            guard case .int(let i) = v else { return v.isUnknown ? .unknown : .undef }
            return .int(~i)
        case .and(let a, let b):
            // YARA: undefined operand → false.
            let ta = tri(eval(a, engine, &c))
            if ta == .f || ta == .u { return .bool(false) }
            let tb = tri(eval(b, engine, &c))
            if tb == .f || tb == .u { return .bool(false) }
            if ta == .k || tb == .k { return .unknown }
            return .bool(true)
        case .or(let a, let b):
            // YARA: undefined operand → the other operand.
            let ta = tri(eval(a, engine, &c))
            if ta == .t { return .bool(true) }
            let tb = tri(eval(b, engine, &c))
            if tb == .t { return .bool(true) }
            if ta == .k || tb == .k { return .unknown }
            if ta == .u && tb == .u { return .undef }
            return .bool(false)
        case .bin(let op, let a, let b):
            return binary(op, eval(a, engine, &c), eval(b, engine, &c))
        case .of(let q, let set):
            if c.matches == nil { return .unknown }
            let needed: Int
            switch quantifierCount(q, set.count, engine, &c) {
            case .some(let n): needed = n
            case .none: return .undef
            }
            var hits = 0
            for s in set where !(offsets(.local(s), c) ?? []).isEmpty { hits += 1 }
            if case .none = q { return .bool(hits == 0) }
            return .bool(hits >= needed)
        case .forOf(let q, let set, let body):
            var results: [XPYTri] = []
            for s in set {
                guard let id = globalID(.local(s), c) else { return .unknown }
                c.currentString.append(id)
                results.append(tri(eval(body, engine, &c)))
                c.currentString.removeLast()
            }
            return quantify(q, results, engine, &c)
        case .forIn(let q, let slot, let iter, let body):
            var items: [Int64] = []
            switch iter {
            case .range(let loE, let hiE):
                let lo = eval(loE, engine, &c), hi = eval(hiE, engine, &c)
                guard case .int(let l) = lo, case .int(let h) = hi else {
                    return (lo.isUnknown || hi.isUnknown) ? .unknown : .undef
                }
                // Empty range: undefined (behaves as false; never true).
                guard l <= h else { return .undef }
                guard h - l < Int64(maxLoopIterations) else { return .undef }
                return quantifyRange(q, l, h, slot, body, engine, &c)
            case .list(let es):
                for ie in es {
                    let v = eval(ie, engine, &c)
                    switch v {
                    case .int(let i): items.append(i)
                    case .unknown: return .unknown
                    default: return .undef
                    }
                }
            }
            var results: [XPYTri] = []
            for it in items {
                setLoopVar(slot, it, &c)
                results.append(tri(eval(body, engine, &c)))
            }
            c.loopVars.removeLast(max(0, c.loopVars.count - slot))
            return quantify(q, results, engine, &c)
        case .hash(let alg, let offE, let lenE):
            let off = eval(offE, engine, &c), len = eval(lenE, engine, &c)
            guard case .int(let o) = off, case .int(let l) = len else {
                return (off.isUnknown || len.isUnknown) ? .unknown : .undef
            }
            return hash(alg, o, l, &c)
        }
    }

    static func setLoopVar(_ slot: Int, _ v: Int64, _ c: inout XPYEvalContext) {
        if c.loopVars.count > slot { c.loopVars.removeLast(c.loopVars.count - slot) }
        while c.loopVars.count < slot { c.loopVars.append(0) }
        c.loopVars.append(v)
    }

    static func quantifyRange(_ q: XPYQuant, _ lo: Int64, _ hi: Int64, _ slot: Int, _ body: XPYExpr,
                              _ engine: XPYEngine, _ c: inout XPYEvalContext) -> XPYVal {
        let total = Int(hi - lo + 1)
        guard let need = quantifierCount(q, total, engine, &c) else { return .undef }
        var trues = 0, unknowns = 0, done = 0
        var result: XPYVal?
        var i = lo
        while i <= hi {
            setLoopVar(slot, i, &c)
            let t = tri(eval(body, engine, &c))
            done += 1
            if t == .t { trues += 1 } else if t == .k { unknowns += 1 }
            let remaining = total - done
            switch q {
            case .none:
                if trues > 0 { result = .bool(false) }
            default:
                if trues >= need { result = .bool(true) }
                else if trues + unknowns + remaining < need { result = .bool(false) }
            }
            if result != nil { break }
            i += 1
        }
        c.loopVars.removeLast(max(0, c.loopVars.count - slot))
        if let result { return result }
        if case .none = q { return unknowns > 0 ? .unknown : .bool(true) }
        return unknowns > 0 ? .unknown : .bool(trues >= need)
    }

    /// Number of true items required (`none` → 0 with special handling).
    static func quantifierCount(_ q: XPYQuant, _ total: Int, _ engine: XPYEngine, _ c: inout XPYEvalContext) -> Int? {
        switch q {
        case .all: return total
        case .any: return 1
        case .none: return 0
        case .atLeast(let e):
            guard case .int(let n) = eval(e, engine, &c) else { return nil }
            return Int(clamping: n)
        }
    }

    static func quantify(_ q: XPYQuant, _ results: [XPYTri], _ engine: XPYEngine, _ c: inout XPYEvalContext) -> XPYVal {
        if results.isEmpty { return .undef }
        let trues = results.filter { $0 == .t }.count
        let unknowns = results.filter { $0 == .k }.count
        if case .none = q {
            if trues > 0 { return .bool(false) }
            return unknowns > 0 ? .unknown : .bool(true)
        }
        guard let need = quantifierCount(q, results.count, engine, &c) else { return .undef }
        if trues >= need { return .bool(true) }
        if trues + unknowns >= need { return .unknown }
        return .bool(false)
    }

    static func binary(_ op: XPYBinOp, _ a: XPYVal, _ b: XPYVal) -> XPYVal {
        if a.isUnknown || b.isUnknown { return .unknown }
        switch (a, b) {
        case (.int(let x), .int(let y)):
            switch op {
            case .add: return .int(x &+ y)
            case .sub: return .int(x &- y)
            case .mul: return .int(x &* y)
            case .div: return y == 0 ? .undef : .int(x == .min && y == -1 ? .min : x / y)
            case .mod: return y == 0 ? .undef : .int(x == .min && y == -1 ? 0 : x % y)
            case .band: return .int(x & y)
            case .bor: return .int(x | y)
            case .bxor: return .int(x ^ y)
            case .shl: return y < 0 ? .undef : .int(y >= 64 ? 0 : x << y)
            case .shr: return y < 0 ? .undef : .int(y >= 64 ? 0 : x >> y)
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            case .lt: return .bool(x < y)
            case .le: return .bool(x <= y)
            case .gt: return .bool(x > y)
            case .ge: return .bool(x >= y)
            }
        case (.text(let x), .text(let y)):
            switch op {
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            default: return .undef
            }
        case (.bool(let x), .bool(let y)):
            switch op {
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            default: return .undef
            }
        default:
            return .undef
        }
    }

    static func hash(_ alg: XPYHashAlg, _ off: Int64, _ len: Int64, _ c: inout XPYEvalContext) -> XPYVal {
        guard c.evaluateHashes, let base = c.base, off >= 0, len >= 0, off <= Int64(c.size), len <= Int64(c.size) - off else {
            return .undef
        }
        if alg == .sha256, off == 0, len == Int64(c.size), let pre = c.precomputedSHA256 {
            return .text(Array(pre.lowercased().utf8))
        }
        let key = "\(alg)-\(off)-\(len)"
        if let h = c.hashCache[key] { return .text(Array(h.utf8)) }
        let buf = UnsafeRawBufferPointer(start: base + Int(off), count: Int(len))
        let hex: String
        switch alg {
        case .md5: hex = Insecure.MD5.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        case .sha1: hex = Insecure.SHA1.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        case .sha256: hex = SHA256.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        }
        c.hashCache[key] = hex
        return .text(Array(hex.utf8))
    }

    static func binarySearch(_ a: [Int], _ x: Int) -> Bool {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo < a.count && a[lo] == x
    }

    static func countInRange(_ a: [Int], _ l: Int64, _ h: Int64) -> Int {
        guard l <= h else { return 0 }
        func lowerBound(_ x: Int64) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int64(a[mid]) < x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        return lowerBound(h == .max ? h : h + 1) - lowerBound(l)
    }
}

extension XPYVal {
    var isUnknown: Bool { if case .unknown = self { return true } else { return false } }
}

// MARK: - Monotonicity (for under-approximated strings)

enum XPYMonotonicity {
    /// True if every use of `strings` (rule-local indexes) and of
    /// `underRules` is "finding more makes the rule more likely to match":
    /// plain `$a`, membership in `all/any/N of`, or `for … of` with a body
    /// that only tests `$`, all under an even number of `not`s.
    static func positiveOnly(_ e: XPYExpr, strings: Set<Int>, underRules: Set<Int>, positive: Bool = true) -> Bool {
        func touches(_ e: XPYExpr) -> Bool {
            switch e {
            case .found(.local(let i)), .count(.local(let i)), .offset(.local(let i), _), .length(.local(let i), _):
                return strings.contains(i)
            case .at(.local(let i), let x), .inRange(.local(let i), let x, _), .countIn(.local(let i), let x, _):
                return strings.contains(i) || touches(x)
            case .rule(let r): return underRules.contains(r)
            case .of(_, let set): return set.contains { strings.contains($0) }
            case .forOf(_, let set, let b): return set.contains { strings.contains($0) } || touches(b)
            case .not(let x), .neg(let x), .bitNot(let x), .read(_, _, _, let x): return touches(x)
            case .and(let a, let b), .or(let a, let b), .bin(_, let a, let b), .hash(_, let a, let b): return touches(a) || touches(b)
            case .forIn(_, _, let it, let b):
                switch it {
                case .range(let a, let c): return touches(a) || touches(c) || touches(b)
                case .list(let xs): return xs.contains(where: touches) || touches(b)
                }
            default: return false
            }
        }
        switch e {
        case .found(.local(let i)): return !strings.contains(i) || positive
        case .rule(let r): return !underRules.contains(r) || positive
        case .of(let q, let set):
            guard set.contains(where: { strings.contains($0) }) else { return true }
            if case .none = q { return false }
            return positive
        case .not(let x): return positiveOnly(x, strings: strings, underRules: underRules, positive: !positive)
        case .and(let a, let b), .or(let a, let b):
            return positiveOnly(a, strings: strings, underRules: underRules, positive: positive)
                && positiveOnly(b, strings: strings, underRules: underRules, positive: positive)
        default:
            return !touches(e)
        }
    }
}


extension Array {
    /// Mutates in place (no copy-on-write through a dictionary subscript).
    @inline(__always) mutating func withLast(_ body: (inout [Element]) -> Void) { body(&self) }
}
