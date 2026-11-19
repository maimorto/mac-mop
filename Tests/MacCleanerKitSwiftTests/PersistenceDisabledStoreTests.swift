import Foundation
import Testing
@testable import MacCleanerKit

/// Uses fake items and a temp file only: nothing on the real Mac is
/// disabled, enabled or moved.
@Suite("Disabled launch items store")
struct PersistenceDisabledStoreTests {
    func agent(_ name: String, enabled: Bool? = true, mechanism: PersistenceMechanism = .userLaunchAgents) -> PersistenceItem {
        let path = "/Users/test/Library/LaunchAgents/com.example.\(name).plist"
        return PersistenceItem(id: "\(mechanism.rawValue):\(path)", mechanism: mechanism, name: name, path: path,
                               label: "com.example.\(name)", enabled: enabled, running: enabled == true)
    }

    func tempStore() -> DisabledLaunchItemStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mm-disabled-\(UUID().uuidString)")
        return DisabledLaunchItemStore(fileURL: dir.appending(path: "disabled-launch-items.json"))
    }

    @Test func recordSnapshotsTheItemAsOff() {
        let record = DisabledLaunchItemRecord(item: agent("a"), method: .launchctl)
        #expect(record.item.enabled == false)
        #expect(record.item.running == false)
        #expect(record.originalPath == "/Users/test/Library/LaunchAgents/com.example.a.plist")
        #expect(record.undoAction == .reenable)
        #expect(!record.undoHint.isEmpty)
        #expect(DisabledLaunchItemRecord(item: agent("d", mechanism: .launchDaemons), method: .launchctlAdmin).undoAction == .reenableWithPassword)
        #expect(DisabledLaunchItemRecord(item: agent("t"), method: .movedToTrash).undoAction == .restoreFromTrash)
    }

    @Test func persistsAcrossInstancesNewestFirstWithoutDuplicates() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        #expect(store.load().isEmpty)
        store.record(DisabledLaunchItemRecord(item: agent("a"), method: .launchctl, date: Date(timeIntervalSince1970: 1)))
        store.record(DisabledLaunchItemRecord(item: agent("b"), method: .movedToTrash, date: Date(timeIntervalSince1970: 2),
                                              trashPath: "/Users/test/.Trash/com.example.b.plist"))
        store.record(DisabledLaunchItemRecord(item: agent("a"), method: .launchctl, date: Date(timeIntervalSince1970: 3)))

        let reopened = DisabledLaunchItemStore(fileURL: store.fileURL).load()
        #expect(reopened.map(\.item.name) == ["a", "b"])
        #expect(reopened[1].trashPath == "/Users/test/.Trash/com.example.b.plist")
        #expect(reopened[1].method == .movedToTrash)
        #expect(reopened[0].date == Date(timeIntervalSince1970: 3))

        store.forget(id: reopened[0].id)
        #expect(store.load().map(\.item.name) == ["b"])
    }

    @Test func reconcileDropsItemsThatAreBackOn() {
        let records = [
            DisabledLaunchItemRecord(item: agent("stillOff"), method: .launchctl),
            DisabledLaunchItemRecord(item: agent("reenabledElsewhere"), method: .launchctl),
            DisabledLaunchItemRecord(item: agent("trashed"), method: .movedToTrash),
            DisabledLaunchItemRecord(item: agent("restoredByHand"), method: .movedToTrash),
        ]
        let scan = [agent("stillOff", enabled: false), agent("reenabledElsewhere", enabled: true), agent("restoredByHand", enabled: true)]
        let kept = DisabledLaunchItems.reconciled(records, with: scan)
        #expect(kept.map(\.item.name) == ["stillOff", "trashed"])
    }

    @Test func reconcileOnDisk() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        store.record(DisabledLaunchItemRecord(item: agent("x"), method: .launchctl))
        #expect(store.reconcile(with: [agent("x", enabled: false)]).count == 1)
        #expect(store.reconcile(with: [agent("x", enabled: true)]).isEmpty)
        #expect(store.load().isEmpty)
    }

    @Test func statesAndPlaceholders() {
        let off = DisabledLaunchItemRecord(item: agent("off"), method: .launchctl)
        let trashed = DisabledLaunchItemRecord(item: agent("trashed"), method: .movedToTrash, trashPath: "/T/trashed.plist")
        let emptied = DisabledLaunchItemRecord(item: agent("emptied"), method: .movedToTrash, trashPath: "/T/emptied.plist")
        let uninstalled = DisabledLaunchItemRecord(item: agent("uninstalled"), method: .launchctl)
        let ids: Set<String> = [off.id]
        let exists: (String) -> Bool = { $0 == "/T/trashed.plist" }

        #expect(DisabledLaunchItems.state(of: off, inScan: ids, fileExists: exists) == .disabled)
        #expect(DisabledLaunchItems.state(of: trashed, inScan: ids, fileExists: exists) == .inTrash)
        #expect(DisabledLaunchItems.state(of: emptied, inScan: ids, fileExists: exists) == .gone)
        #expect(DisabledLaunchItems.state(of: uninstalled, inScan: ids, fileExists: exists) == .gone)

        let ghosts = DisabledLaunchItems.placeholders(for: [off, trashed, uninstalled], inScan: ids)
        #expect(ghosts.map(\.name) == ["trashed", "uninstalled"])
        #expect(ghosts.allSatisfy { $0.enabled == false })
    }

    @Test func undoRoutesForItemsWithoutARecord() {
        var settingsOff = agent("btm", enabled: false)
        settingsOff.disabledInSettings = true
        #expect(DisabledLaunchItems.undoAction(for: settingsOff, record: nil) == .openLoginItemsSettings)
        #expect(DisabledLaunchItems.undoAction(for: agent("bg", enabled: false, mechanism: .backgroundItems), record: nil) == .openLoginItemsSettings)
        #expect(DisabledLaunchItems.undoAction(for: agent("u", enabled: false), record: nil) == .reenable)
        #expect(DisabledLaunchItems.undoAction(for: agent("d", enabled: false, mechanism: .launchDaemons), record: nil) == .reenableWithPassword)
        #expect(DisabledLaunchItems.undoAction(for: agent("on"), record: nil) == .none)
        #expect(DisabledLaunchItems.undoAction(for: agent("cron", enabled: false, mechanism: .cron), record: nil) == .none)

        let list = DisabledLaunchItems.disabledInSettings([settingsOff, agent("u", enabled: false), agent("bg", enabled: false, mechanism: .backgroundItems)])
        #expect(list.map(\.name) == ["btm", "bg"])
    }

    @Test func removedLoginItems() {
        let record = DisabledLaunchItemRecord.removedLoginItem(name: "Foo", appPath: "/Applications/Foo.app")
        #expect(record.id == "legacyLoginItems:/Applications/Foo.app")
        #expect(record.undoAction == .readdLoginItem)
        #expect(DisabledLaunchItems.state(of: record, inScan: [], fileExists: { $0 == "/Applications/Foo.app" }) == .removed)
        #expect(DisabledLaunchItems.state(of: record, inScan: [], fileExists: { _ in false }) == .gone)
        // Listed again by a scan (legacy login items have no on/off flag): cleared.
        let back = PersistenceItem(id: record.id, mechanism: .legacyLoginItems, name: "Foo", program: "/Applications/Foo.app")
        #expect(DisabledLaunchItems.reconciled([record], with: [back]).isEmpty)
    }

    @Test func oldItemsWithoutTheNewFieldStillDecode() throws {
        let json = #"{"id":"cron:x","mechanism":"cron","name":"x","arguments":[],"signature":{"kind":"notCode"},"running":false,"risk":"safe","reasons":[],"facts":[]}"#
        let item = try JSONDecoder().decode(PersistenceItem.self, from: Data(json.utf8))
        #expect(item.disabledInSettings == nil)
    }
}
