import Foundation

// A persistent record of every launch item Mac Mop turned off or moved to the
// Trash, so the user can always find it again and undo it in one click, even
// after a relaunch or when the item no longer shows up in a scan.

/// How Mac Mop turned an item off, which decides how to undo it.
public enum PersistenceDisableMethod: String, Codable, Sendable {
    /// `launchctl disable gui/<uid>/<label>`: plist untouched, no password.
    case launchctl
    /// `launchctl disable system/<label>` with the administrator password.
    case launchctlAdmin
    /// The plist went to the Trash through the clean flow (Cleanup History).
    case movedToTrash
    /// A login item (System Settings › Login Items › "Open at Login") was
    /// removed; undo adds the app back to the list.
    case removedLoginItem
}

/// What "Re-enable" does for a record or an item.
public enum PersistenceUndoAction: Equatable, Sendable {
    case reenable
    case reenableWithPassword
    case restoreFromTrash
    /// Add the app back to "Open at Login".
    case readdLoginItem
    /// Mac Mop can't flip it: open System Settings › Login Items.
    case openLoginItemsSettings
    case none
}

public struct DisabledLaunchItemRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { item.id }
    /// The item as it was when Mac Mop turned it off.
    public var item: PersistenceItem
    public var method: PersistenceDisableMethod
    public var date: Date
    /// Where the plist landed in the Trash, when known.
    public var trashPath: String?

    public init(item: PersistenceItem, method: PersistenceDisableMethod, date: Date = Date(), trashPath: String? = nil) {
        var snapshot = item
        snapshot.enabled = false
        snapshot.running = false
        self.item = snapshot
        self.method = method
        self.date = date
        self.trashPath = trashPath
    }

    /// The plist's original location.
    public var originalPath: String? { item.path }

    public var undoAction: PersistenceUndoAction {
        switch method {
        case .launchctl: .reenable
        case .launchctlAdmin: .reenableWithPassword
        case .movedToTrash: .restoreFromTrash
        case .removedLoginItem: .readdLoginItem
        }
    }

    /// Record for a removed "Open at Login" app, with the same id the
    /// inventory uses, so a later scan that lists it again clears the record.
    public static func removedLoginItem(name: String, appPath: String, date: Date = Date()) -> DisabledLaunchItemRecord {
        let item = PersistenceItem(id: "\(PersistenceMechanism.legacyLoginItems.rawValue):\(appPath)", mechanism: .legacyLoginItems,
                                   name: name, program: appPath)
        return DisabledLaunchItemRecord(item: item, method: .removedLoginItem, date: date)
    }

    /// Plain-language "how to undo", also stored for people reading the file.
    public var undoHint: String {
        switch method {
        case .launchctl:
            UIText.t("Premi «Riattiva»: macOS lo riavvia subito e ad ogni accesso. Il file non è mai stato spostato.",
                     "Press “Re-enable”: macOS starts it again now and at every login. The file was never moved.")
        case .launchctlAdmin:
            UIText.t("Premi «Riattiva» e inserisci la password di amministratore. Il file non è mai stato spostato.",
                     "Press “Re-enable” and enter the administrator password. The file was never moved.")
        case .movedToTrash:
            UIText.t("Premi «Ripristina»: il file torna dal Cestino al suo posto e viene riattivato. Lo trovi anche in Cronologia pulizie.",
                     "Press “Restore”: the file goes back from the Trash to where it was and is started again. It is also in Cleanup History.")
        case .removedLoginItem:
            UIText.t("Premi «Riattiva»: l'app torna tra gli elementi che si aprono all'accesso. Nessun file è stato toccato.",
                     "Press “Re-enable”: the app goes back to the items that open at login. No file was touched.")
        }
    }
}

/// Where a record stands compared with a fresh scan.
public enum DisabledLaunchItemState: Equatable, Sendable {
    /// Still there and still off.
    case disabled
    /// The plist is in the Trash (moved by Mac Mop).
    case inTrash
    /// Removed from "Open at Login"; the app is still installed.
    case removed
    /// Neither in the scan nor in the Trash (app uninstalled, Trash emptied).
    case gone
}

public enum DisabledLaunchItems {
    /// Newest first, one record per item id.
    public static func upserting(_ record: DisabledLaunchItemRecord, into records: [DisabledLaunchItemRecord]) -> [DisabledLaunchItemRecord] {
        [record] + records.filter { $0.id != record.id }
    }

    public static func removing(id: String, from records: [DisabledLaunchItemRecord]) -> [DisabledLaunchItemRecord] {
        records.filter { $0.id != id }
    }

    /// Drops records whose item is back on in a fresh scan (re-enabled from
    /// here, by its app, or restored by hand from Cleanup History).
    public static func reconciled(_ records: [DisabledLaunchItemRecord], with items: [PersistenceItem]) -> [DisabledLaunchItemRecord] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return records.filter { record in
            guard let current = byID[record.id] else { return true }
            return current.enabled == false
        }
    }

    public static func state(of record: DisabledLaunchItemRecord, inScan ids: Set<String>,
                             fileExists: (String) -> Bool) -> DisabledLaunchItemState {
        if ids.contains(record.id) { return .disabled }
        if record.method == .removedLoginItem {
            guard let app = record.item.program else { return .gone }
            return fileExists(app) ? .removed : .gone
        }
        if record.method == .movedToTrash {
            if let trash = record.trashPath, fileExists(trash) { return .inTrash }
            // No exact Trash path (older record): trust Cleanup History to find it.
            if record.trashPath == nil { return .inTrash }
        }
        return .gone
    }

    /// Records whose item a scan no longer lists, as dimmed placeholder rows
    /// so they stay visible "in place" under their mechanism.
    public static func placeholders(for records: [DisabledLaunchItemRecord], inScan ids: Set<String>) -> [PersistenceItem] {
        records.filter { !ids.contains($0.id) }.map(\.item)
    }

    /// Undo route for an item that is off right now, whether or not Mac Mop
    /// turned it off.
    public static func undoAction(for item: PersistenceItem, record: DisabledLaunchItemRecord?) -> PersistenceUndoAction {
        if let record { return record.undoAction }
        guard item.enabled == false else { return .none }
        if item.disabledInSettings == true || item.mechanism == .backgroundItems || item.mechanism == .legacyLoginItems {
            return .openLoginItemsSettings
        }
        switch item.mechanism {
        case .userLaunchAgents, .systemLaunchAgents: return .reenable
        case .launchDaemons: return .reenableWithPassword
        default: return .none
        }
    }

    /// Items turned off in System Settings › Login Items (Mac Mop can't turn
    /// them back on itself; it links there).
    public static func disabledInSettings(_ items: [PersistenceItem]) -> [PersistenceItem] {
        items.filter { $0.enabled == false && ($0.disabledInSettings == true || $0.mechanism == .backgroundItems) }
    }
}

/// JSON file in Application Support › <data folder>. Small; read and written
/// on each change.
public struct DisabledLaunchItemStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = DisabledLaunchItemStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        MCConstants.userAppSupport.appending(path: MCConstants.dataFolderName).appending(path: "disabled-launch-items.json")
    }

    public func load() -> [DisabledLaunchItemRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DisabledLaunchItemRecord].self, from: data)) ?? []
    }

    public func save(_ records: [DisabledLaunchItemRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: [.atomic])
    }

    @discardableResult
    public func record(_ record: DisabledLaunchItemRecord) -> [DisabledLaunchItemRecord] {
        let updated = DisabledLaunchItems.upserting(record, into: load())
        try? save(updated)
        return updated
    }

    @discardableResult
    public func forget(id: String) -> [DisabledLaunchItemRecord] {
        let updated = DisabledLaunchItems.removing(id: id, from: load())
        try? save(updated)
        return updated
    }

    /// Applies `reconciled(_:with:)` to the file and returns what remains.
    @discardableResult
    public func reconcile(with items: [PersistenceItem]) -> [DisabledLaunchItemRecord] {
        let current = load()
        let updated = DisabledLaunchItems.reconciled(current, with: items)
        if updated != current { try? save(updated) }
        return updated
    }
}
