import Foundation
import Darwin
import MacCleanerKit

/// One folder (or large file) in a Space Lens scan. Small files are folded
/// into their folder's `looseSize`/`looseCount` to keep memory low on scans of
/// millions of files.
final class DiskNode: Identifiable, @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    private(set) var size: UInt64
    var children: [DiskNode] = []
    weak var parent: DiskNode?
    var looseSize: UInt64 = 0
    var looseCount: Int = 0
    var fileCount: Int = 0
    private let rootPath: String?

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, size: UInt64, rootPath: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.rootPath = rootPath
    }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path) }

    func add(_ bytes: UInt64) { size &+= bytes }

    /// Live-map nodes only: the size grows while the scan runs.
    func setLiveSize(_ bytes: UInt64) { size = bytes }

    /// Puts back a child removed with `remove(_:)` (its trash move was undone),
    /// keeping children largest first, and updates sizes up the chain.
    func reinsert(_ child: DiskNode) {
        guard !children.contains(where: { $0 === child }) else { return }
        child.parent = self
        let index = children.firstIndex { $0.size < child.size } ?? children.endIndex
        children.insert(child, at: index)
        var node: DiskNode? = self
        while let n = node {
            n.size &+= child.size
            n.fileCount += child.fileCount
            node = n.parent
        }
    }

    /// Removes a child (after it was moved to the Trash) and updates sizes up the chain.
    func remove(_ child: DiskNode) {
        children.removeAll { $0 === child }
        var node: DiskNode? = self
        while let n = node {
            n.size = n.size > child.size ? n.size - child.size : 0
            n.fileCount = max(0, n.fileCount - child.fileCount)
            node = n.parent
        }
    }
}

/// Fast directory walker for Space Lens. Uses getattrlistbulk(2), which returns
/// a whole directory's names, types, allocated sizes, inode numbers and link
/// counts in one system call, instead of one stat per file. The top two levels
/// are walked in parallel on a dedicated queue (never inside Swift
/// concurrency's cooperative pool).
///
/// Every byte is counted once: a hard-linked file (link count > 1) is added
/// only the first time its (device, inode) is seen, and a walk from `/` never
/// enters `/System/Volumes/Data`, the firmlinked second view of the same data
/// (see `FirmlinkPolicy`).
///
/// While it runs, `liveSnapshot()` returns how many bytes each top-level
/// folder holds so far, so Space Lens can draw the map as it fills in.
final class FastDiskScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var _items = 0
    private var _bytes: UInt64 = 0
    private var _cancelled = false
    private let hardLinks = SharedHardLinkTracker()
    private var rootPath = "/"

    /// Live map: one bucket per top-level folder (index = position in `_liveNames`).
    private var _liveNames: [String] = []
    private var _liveBytes: [UInt64] = []
    private var _liveDone: [Bool] = []
    /// Files directly inside the root folder.
    private var _liveLoose: UInt64 = 0

    /// Files below this size are counted but not kept as their own node.
    private let keepFileThreshold: UInt64 = 8 * 1024 * 1024
    /// Folders below this size are folded into their parent.
    private let keepFolderThreshold: UInt64 = 1 * 1024 * 1024

    var progress: (items: Int, bytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (_items, _bytes)
    }

    struct LiveTile: Sendable {
        let name: String
        let bytes: UInt64
        let done: Bool
    }

    /// Cheap copy of the partial totals (a few dozen numbers), safe to call
    /// from any thread while the scan runs.
    func liveSnapshot() -> (tiles: [LiveTile], loose: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let tiles = _liveNames.indices.map { LiveTile(name: _liveNames[$0], bytes: _liveBytes[$0], done: _liveDone[$0]) }
        return (tiles, _liveLoose)
    }

    /// Number of hard-linked files whose extra links were not counted again.
    var hardLinkedFiles: Int { hardLinks.trackedCount }

    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    private func count(_ items: Int, _ bytes: UInt64, bucket: Int) {
        lock.lock()
        _items += items
        _bytes &+= bytes
        if bucket >= 0 { _liveBytes[bucket] &+= bytes } else { _liveLoose &+= bytes }
        lock.unlock()
    }

    private func startLive(_ names: [String]) {
        lock.lock()
        _liveNames = names
        _liveBytes = Array(repeating: 0, count: names.count)
        _liveDone = Array(repeating: false, count: names.count)
        lock.unlock()
    }

    private func finishLive(_ bucket: Int) {
        lock.lock(); if _liveDone.indices.contains(bucket) { _liveDone[bucket] = true }; lock.unlock()
    }

    /// Blocking. Call from a background queue.
    /// - Parameter parallel: false walks on the calling thread only (for
    ///   background measurements that must not load every core).
    func scan(root: URL, parallel: Bool = true) -> DiskNode {
        let path = root.path
        rootPath = path
        let rootNode = DiskNode(name: FileManager.default.displayName(atPath: path), isDirectory: true, size: 0, rootPath: path)
        var st = stat()
        let device = lstat(path, &st) == 0 ? st.st_dev : 0
        fill(rootNode, path: path, device: device, parallelDepth: parallel ? 2 : 0, bucket: -1)
        return rootNode
    }

    // MARK: Walk

    /// `bucket` is the index of the top-level folder this subtree belongs to
    /// (-1 for the root itself), used only for the live map.
    private func fill(_ node: DiskNode, path: String, device: dev_t, parallelDepth: Int, bucket: Int) {
        guard !cancelled, let entries = Self.list(path) else { return }
        var subdirs: [(String, String)] = []
        var files = 0
        var filesBytes: UInt64 = 0
        for e in entries {
            switch e.type {
            case 2: // directory
                let child = path == "/" ? "/" + e.name : path + "/" + e.name
                if e.device == device, !FirmlinkPolicy.shouldSkip(directory: child, scanRoot: rootPath) {
                    subdirs.append((e.name, child))
                }
            case 1: // regular file
                files += 1
                // Extra links of a hard-linked file add no bytes.
                let size = hardLinks.shouldCount(device: UInt64(UInt32(bitPattern: e.device)), inode: e.inode,
                                                 linkCount: e.linkCount) ? e.size : 0
                filesBytes &+= size
                if size >= keepFileThreshold {
                    let f = DiskNode(name: e.name, isDirectory: false, size: size)
                    f.fileCount = 1
                    f.parent = node
                    node.children.append(f)
                } else {
                    node.looseSize &+= size
                    node.looseCount += 1
                }
            default:
                continue // symlinks and special files are not followed or counted
            }
        }
        node.add(filesBytes)
        node.fileCount += files
        let isRoot = bucket < 0
        if isRoot { startLive(subdirs.map(\.0)) }
        count(entries.count, filesBytes, bucket: bucket)

        let children = subdirs.map { DiskNode(name: $0.0, isDirectory: true, size: 0) }
        if parallelDepth > 0, subdirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                fill(children[i], path: subdirs[i].1, device: device, parallelDepth: parallelDepth - 1,
                     bucket: isRoot ? i : bucket)
                if isRoot { finishLive(i) }
            }
        } else {
            for (i, s) in subdirs.enumerated() {
                fill(children[i], path: s.1, device: device, parallelDepth: 0, bucket: isRoot ? i : bucket)
                if isRoot { finishLive(i) }
            }
        }
        for c in children {
            node.add(c.size)
            node.fileCount += c.fileCount
            if c.size >= keepFolderThreshold {
                c.parent = node
                node.children.append(c)
            } else {
                node.looseSize &+= c.size
                node.looseCount += c.fileCount
            }
        }
        node.children.sort { $0.size > $1.size }
    }

    // MARK: getattrlistbulk

    struct Entry {
        let name: String
        let type: UInt32
        let size: UInt64
        let device: dev_t
        let inode: UInt64
        let linkCount: UInt32
    }

    private static let bufferSize = 256 * 1024

    static func list(_ path: String) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var req = attrlist()
        req.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        req.commonattr = 0x8000_0000 | 0x2000_0000 | 0x0000_0001 | 0x0000_0002 | 0x0000_0008 | 0x0200_0000
        //               RETURNED_ATTRS | ERROR | NAME | DEVID | OBJTYPE | FILEID
        req.fileattr = 0x0000_0001 | 0x0000_0004 // ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var out: [Entry] = []

        while true {
            let n = getattrlistbulk(fd, &req, buffer, bufferSize, 0)
            if n <= 0 { break }
            var entry = buffer
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let commonReturned = field.loadUnaligned(as: UInt32.self)
                let fileReturned = (field + 12).loadUnaligned(as: UInt32.self)
                field += 20 // attribute_set_t

                var failed = false
                if commonReturned & 0x2000_0000 != 0 {
                    failed = field.loadUnaligned(as: UInt32.self) != 0
                    field += 4
                }
                var name = ""
                if commonReturned & 0x0000_0001 != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    let len = Int((field + 4).loadUnaligned(as: UInt32.self))
                    let p = (field + offset).assumingMemoryBound(to: UInt8.self)
                    name = String(decoding: UnsafeBufferPointer(start: p, count: max(0, len - 1)), as: UTF8.self)
                    field += 8
                }
                var device: dev_t = 0
                if commonReturned & 0x0000_0002 != 0 {
                    device = field.loadUnaligned(as: dev_t.self)
                    field += 4
                }
                var type: UInt32 = 0
                if commonReturned & 0x0000_0008 != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                // Attributes follow in bitmap order: FILEID is the last common one.
                var inode: UInt64 = 0
                if commonReturned & 0x0200_0000 != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var links: UInt32 = 1
                if fileReturned & 0x0000_0001 != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var size: UInt64 = 0
                if fileReturned & 0x0000_0004 != 0 {
                    size = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                }
                if !failed, !name.isEmpty {
                    out.append(Entry(name: name, type: type, size: size, device: device, inode: inode, linkCount: links))
                }
                entry += length
            }
        }
        return out
    }
}
