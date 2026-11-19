import Foundation
import Darwin

// Measures System Data categories read-only. "Every byte counted once":
//  • a root nested inside another category's root is measured only by its own
//    category (the outer walk skips it), and a root listed twice counts once;
//  • a file with several hard links is counted at its first path only (one
//    inode table shared by the whole scan, like `du`);
//  • symlinks are never followed and walks never cross into another volume.
// Directory listings use getattrlistbulk(2): one system call returns a whole
// directory's names, types, sizes, inode numbers and link counts.

public struct SystemDataItem: Identifiable, Hashable, Sendable, Codable {
    public let path: String
    public var bytes: UInt64
    public let isDirectory: Bool
    /// Mac Mop may move it to the Trash (Safe/Review "trash" category, writable, not kept).
    public let removable: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: UInt64, isDirectory: Bool, removable: Bool) {
        self.path = path
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.removable = removable
    }
}

public struct SystemDataMeasurement: Sendable {
    public let category: SystemDataCategoryID
    public var bytes: UInt64
    /// Largest first.
    public var items: [SystemDataItem]
    /// Roots that exist but could not be listed (no Full Disk Access, or root-only).
    public var unreadableRoots: [String]
    /// Some folders inside could not be read, so the size is a lower bound.
    public var partial: Bool
    /// At least one root exists on this Mac.
    public var present: Bool

    public init(category: SystemDataCategoryID, bytes: UInt64 = 0, items: [SystemDataItem] = [],
                unreadableRoots: [String] = [], partial: Bool = false, present: Bool = false) {
        self.category = category
        self.bytes = bytes
        self.items = items
        self.unreadableRoots = unreadableRoots
        self.partial = partial
        self.present = present
    }

    public var removableBytes: UInt64 { items.filter(\.removable).reduce(0) { $0 &+ $1.bytes } }
}

/// One root to walk, with the deeper roots of other categories it must skip.
public struct SystemDataRootPlan: Equatable, Sendable {
    public let category: SystemDataCategoryID
    public let root: String
    public let excludes: Set<String>
}

public enum SystemDataPlanner {
    public static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func isInside(_ path: String, _ ancestor: String) -> Bool {
        ancestor == "/" ? path != "/" : path.hasPrefix(ancestor + "/")
    }

    /// Duplicate roots are kept by the first category that lists them; a root
    /// nested inside another root is excluded from the outer walk.
    public static func plan(_ categories: [SystemDataCategory]) -> [SystemDataRootPlan] {
        var seen = Set<String>()
        var ordered: [(SystemDataCategoryID, String)] = []
        for c in categories {
            for r in c.roots.map(normalize) where seen.insert(r).inserted {
                ordered.append((c.id, r))
            }
        }
        let all = ordered.map(\.1)
        return ordered.map { id, root in
            SystemDataRootPlan(category: id, root: root, excludes: Set(all.filter { isInside($0, root) }))
        }
    }
}

public final class SystemDataWalker: @unchecked Sendable {
    private let lock = NSLock()
    /// Multi-link files: owner = lowest unit index that reached them, so the
    /// attribution is the same on every scan whatever the thread timing.
    private var links: [HardLinkTracker.Identity: (unit: Int, size: UInt64)] = [:]
    private var _items = 0
    private var _cancelled = false

    public init() {}

    public var itemsVisited: Int { lock.lock(); defer { lock.unlock() }; return _items }
    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    /// Size to add now; multi-link files are deferred to `linkedBytes()`.
    private func counted(_ e: Entry, unit: Int) -> UInt64 {
        guard e.linkCount > 1, e.fileID != 0 else { return e.size }
        let id = HardLinkTracker.Identity(device: UInt64(UInt32(bitPattern: e.device)), inode: e.fileID)
        lock.lock()
        if let cur = links[id] { if unit < cur.unit { links[id] = (unit, e.size) } } else { links[id] = (unit, e.size) }
        lock.unlock()
        return 0
    }

    /// Bytes of multi-link files per owning unit, each inode once.
    private func linkedBytes() -> [Int: UInt64] {
        lock.lock(); defer { lock.unlock() }
        var out: [Int: UInt64] = [:]
        for v in links.values { out[v.unit, default: 0] &+= v.size }
        return out
    }

    // MARK: Categories

    private struct Unit {
        let category: SystemDataCategoryID
        let path: String
        let isDirectory: Bool
        let device: dev_t
        let excludes: Set<String>
        let fileBytes: UInt64
        let removable: Bool
    }

    /// Blocking: call from a background queue, never from Swift concurrency's pool.
    public func measure(_ categories: [SystemDataCategory]) -> [SystemDataCategoryID: SystemDataMeasurement] {
        var out: [SystemDataCategoryID: SystemDataMeasurement] = [:]
        for c in categories { out[c.id] = SystemDataMeasurement(category: c.id) }
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var units: [Unit] = []

        for plan in SystemDataPlanner.plan(categories) {
            guard let cat = byID[plan.category] else { continue }
            var st = stat()
            guard lstat(plan.root, &st) == 0 else { continue }           // not on this Mac
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { continue }   // symlinks are not followed
            out[cat.id]?.present = true
            let canTrash = cat.action == .trash
            if kind == S_IFREG {
                let e = Entry(name: "", type: 1, size: UInt64(st.st_blocks) * 512, device: st.st_dev,
                              fileID: UInt64(st.st_ino), linkCount: UInt32(st.st_nlink))
                units.append(Unit(category: cat.id, path: plan.root, isDirectory: false, device: st.st_dev, excludes: [],
                                  fileBytes: counted(e, unit: units.count), removable: canTrash && Self.removable(plan.root, keep: cat.keepNames)))
                continue
            }
            switch cat.granularity {
            case .roots:
                guard Self.list(plan.root) != nil else { out[cat.id]?.unreadableRoots.append(plan.root); continue }
                units.append(Unit(category: cat.id, path: plan.root, isDirectory: true, device: st.st_dev, excludes: plan.excludes,
                                  fileBytes: 0, removable: canTrash && Self.removable(plan.root, keep: cat.keepNames)))
            case .children:
                guard let entries = Self.list(plan.root) else { out[cat.id]?.unreadableRoots.append(plan.root); continue }
                for e in entries {
                    let path = plan.root + "/" + e.name
                    if plan.excludes.contains(path) { continue }
                    if e.type == 2, e.device == st.st_dev {
                        units.append(Unit(category: cat.id, path: path, isDirectory: true, device: st.st_dev, excludes: plan.excludes,
                                          fileBytes: 0, removable: canTrash && Self.removable(path, keep: cat.keepNames)))
                    } else if e.type == 1 {
                        units.append(Unit(category: cat.id, path: path, isDirectory: false, device: st.st_dev, excludes: [],
                                          fileBytes: counted(e, unit: units.count), removable: canTrash && Self.removable(path, keep: cat.keepNames)))
                    }
                }
            }
        }

        // Largest-looking work first is unknowable; interleave so one huge
        // folder does not leave the other threads idle at the end.
        var results = [(UInt64, Bool)](repeating: (0, false), count: units.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: units.count) { i in
            let u = units[i]
            let r: (UInt64, Bool) = u.isDirectory
                ? walk(u.path, device: u.device, excludes: u.excludes, parallelDepth: 1, unit: i)
                : (u.fileBytes, false)
            resultsLock.lock(); results[i] = r; resultsLock.unlock()
        }

        let linked = linkedBytes()
        for (i, u) in units.enumerated() {
            let bytes = results[i].0 &+ (linked[i] ?? 0)
            let partial = results[i].1
            out[u.category]?.bytes &+= bytes
            if partial { out[u.category]?.partial = true }
            if bytes > 0 || u.isDirectory {
                out[u.category]?.items.append(SystemDataItem(path: u.path, bytes: bytes, isDirectory: u.isDirectory, removable: u.removable))
            }
        }
        for k in out.keys { out[k]?.items.sort { $0.bytes > $1.bytes } }
        return out
    }

    /// Writable parent (and, for sticky folders like /Library/Caches, owned by
    /// us), not kept by the category, and accepted by SafetyGuard.
    static func removable(_ path: String, keep: Set<String>) -> Bool {
        let name = (path as NSString).lastPathComponent
        if keep.contains(name) { return false }
        let parent = (path as NSString).deletingLastPathComponent
        guard access(parent, W_OK) == 0 else { return false }
        var ps = stat(), st = stat()
        if stat(parent, &ps) == 0, ps.st_mode & S_ISVTX != 0 {
            guard lstat(path, &st) == 0, st.st_uid == getuid() else { return false }
        }
        return (try? SafetyGuard().validatePath(URL(fileURLWithPath: path))) != nil
    }

    // MARK: Home folders (What Grew)

    /// Sizes of the home folder's top-level folders and their subfolders
    /// ("Library", "Library/Caches", …), skipping entries below `minimum`.
    public func folderSizes(home: String, minimum: UInt64 = 10 * 1024 * 1024) -> [String: UInt64] {
        var st = stat()
        guard lstat(home, &st) == 0, let top = Self.list(home) else { return [:] }
        let device = st.st_dev
        struct Sub { let parent: String; let rel: String; let path: String }
        var subs: [Sub] = []
        var looseBytes: [String: UInt64] = [:]
        var looseUnit: [String: Int] = [:]
        for e in top where e.type == 2 && e.device == device {
            let path = home + "/" + e.name
            guard let entries = Self.list(path) else { continue }
            var loose: UInt64 = 0
            for c in entries {
                if c.type == 2, c.device == device {
                    subs.append(Sub(parent: e.name, rel: e.name + "/" + c.name, path: path + "/" + c.name))
                } else if c.type == 1 {
                    loose &+= counted(c, unit: -1 - looseBytes.count)
                }
            }
            looseUnit[e.name] = -1 - looseBytes.count
            looseBytes[e.name] = loose
        }
        var sizes = [UInt64](repeating: 0, count: subs.count)
        let l = NSLock()
        DispatchQueue.concurrentPerform(iterations: subs.count) { i in
            let b = walk(subs[i].path, device: device, excludes: [], parallelDepth: 1, unit: i).0
            l.lock(); sizes[i] = b; l.unlock()
        }
        let linked = linkedBytes()
        for (name, u) in looseUnit { looseBytes[name, default: 0] &+= linked[u] ?? 0 }
        for i in sizes.indices { sizes[i] &+= linked[i] ?? 0 }
        var out: [String: UInt64] = [:]
        var totals = looseBytes
        for (i, s) in subs.enumerated() {
            totals[s.parent, default: 0] &+= sizes[i]
            if sizes[i] >= minimum { out[s.rel] = sizes[i] }
        }
        for (k, v) in totals where v >= minimum { out[k] = v }
        return out
    }

    // MARK: Walk

    /// Total allocated bytes under `path`, and whether some folder was unreadable.
    func walk(_ path: String, device: dev_t, excludes: Set<String>, parallelDepth: Int, unit: Int) -> (UInt64, Bool) {
        guard !cancelled else { return (0, false) }
        guard let entries = Self.list(path) else { return (0, true) }
        var bytes: UInt64 = 0
        var subdirs: [String] = []
        for e in entries {
            switch e.type {
            case 2:
                let child = path + "/" + e.name
                if e.device == device, excludes.isEmpty || !excludes.contains(child) { subdirs.append(child) }
            case 1:
                bytes &+= counted(e, unit: unit)
            default:
                continue
            }
        }
        lock.lock(); _items += entries.count; lock.unlock()
        var partial = false
        if parallelDepth > 0, subdirs.count > 1 {
            var parts = [(UInt64, Bool)](repeating: (0, false), count: subdirs.count)
            let l = NSLock()
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                let r = walk(subdirs[i], device: device, excludes: excludes, parallelDepth: parallelDepth - 1, unit: unit)
                l.lock(); parts[i] = r; l.unlock()
            }
            for p in parts { bytes &+= p.0; partial = partial || p.1 }
        } else {
            for s in subdirs {
                let r = walk(s, device: device, excludes: excludes, parallelDepth: 0, unit: unit)
                bytes &+= r.0
                partial = partial || r.1
            }
        }
        return (bytes, partial)
    }

    // MARK: getattrlistbulk

    struct Entry {
        let name: String
        let type: UInt32       // 1 regular file, 2 directory, 5 symlink
        let size: UInt64       // allocated bytes
        let device: dev_t
        let fileID: UInt64
        let linkCount: UInt32
    }

    private static let bufferSize = 256 * 1024

    /// Nil when the directory cannot be opened (missing, not a directory, or no permission).
    static func list(_ path: String) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var req = attrlist()
        req.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        // RETURNED_ATTRS | ERROR | NAME | DEVID | OBJTYPE | FILEID
        req.commonattr = 0x8000_0000 | 0x2000_0000 | 0x0000_0001 | 0x0000_0002 | 0x0000_0008 | 0x0200_0000
        // LINKCOUNT | ALLOCSIZE
        req.fileattr = 0x0000_0001 | 0x0000_0004

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var out: [Entry] = []

        while true {
            let n = getattrlistbulk(fd, &req, buffer, bufferSize, 0)
            if n < 0 { return out.isEmpty ? nil : out }
            if n == 0 { break }
            var entry = buffer
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let common = field.loadUnaligned(as: UInt32.self)
                let file = (field + 12).loadUnaligned(as: UInt32.self)
                field += 20 // attribute_set_t

                var failed = false
                if common & 0x2000_0000 != 0 { failed = field.loadUnaligned(as: UInt32.self) != 0; field += 4 }
                var name = ""
                if common & 0x0000_0001 != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    let len = Int((field + 4).loadUnaligned(as: UInt32.self))
                    let p = (field + offset).assumingMemoryBound(to: UInt8.self)
                    name = String(decoding: UnsafeBufferPointer(start: p, count: max(0, len - 1)), as: UTF8.self)
                    field += 8
                }
                var device: dev_t = 0
                if common & 0x0000_0002 != 0 { device = field.loadUnaligned(as: dev_t.self); field += 4 }
                var type: UInt32 = 0
                if common & 0x0000_0008 != 0 { type = field.loadUnaligned(as: UInt32.self); field += 4 }
                var fileID: UInt64 = 0
                if common & 0x0200_0000 != 0 { fileID = field.loadUnaligned(as: UInt64.self); field += 8 }
                var links: UInt32 = 1
                if file & 0x0000_0001 != 0 { links = field.loadUnaligned(as: UInt32.self); field += 4 }
                var size: UInt64 = 0
                if file & 0x0000_0004 != 0 { size = UInt64(max(0, field.loadUnaligned(as: Int64.self))) }
                if !failed, !name.isEmpty {
                    out.append(Entry(name: name, type: type, size: size, device: device, fileID: fileID, linkCount: links))
                }
                entry += length
            }
        }
        return out
    }
}
