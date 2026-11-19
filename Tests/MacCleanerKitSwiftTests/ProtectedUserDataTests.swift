import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Protected user data")
struct ProtectedUserDataTests {
    let home = "/Users/alice"

    private func protected(_ relative: String) -> Bool {
        ProtectedUserData.isProtected(path: home + "/" + relative, home: home)
    }

    @Test(arguments: [
        "Library/Application Support/atomic/Local Storage/leveldb/000003.log",
        "Library/Application Support/MyMonero",
        "Library/Application Support/Trezor Suite/IndexedDB",
        "Library/Application Support/Exodus/exodus.wallet",
        "Library/Application Support/Google/Chrome/Default/Local Extension Settings/bfnaelmomeimhlpmgjnjophhpkkoljpa",
        "Library/Application Support/Google/Chrome/Profile 1/Login Data",
        "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
        "Library/Application Support/Firefox/Profiles/abc.default/key4.db",
        "Library/Keychains/login.keychain-db",
        "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
        "Library/Application Support/Telegram Desktop/tdata",
        "Library/Safari/History.db",
        // Ancestors: removing these would take the data with them.
        "Library/Application Support",
        "Library",
        "",
        // Wallet extension code is protected too, wherever it is.
        "Library/Application Support/Arc/User Data/Default/Extensions/bhhhlbepdkbapadjdnnojkbgioiodbic/1.0",
    ])
    func protectedPaths(_ relative: String) {
        #expect(protected(relative), "should be protected: \(relative)")
    }

    @Test(arguments: [
        "Library/LaunchAgents/com.evil.agent.plist",
        "Library/Application Support/x7k2m9qp/helper",
        "Downloads/Installer.dmg",
        // A (non-wallet) extension's code can still be removed.
        "Library/Application Support/Google/Chrome/Default/Extensions/abcdefghijklmnopabcdefghijklmnop/1.0/bg.js",
        ".helper",
    ])
    func unprotectedPaths(_ relative: String) {
        #expect(!protected(relative), "should not be protected: \(relative)")
    }

    @Test func systemKeychainsAndCaseInsensitivity() {
        #expect(ProtectedUserData.isProtected(path: "/Library/Keychains/System.keychain", home: home))
        #expect(protected("library/application support/ATOMIC"))
        #expect(!ProtectedUserData.isProtected(path: "/tmp/out.zip", home: home))
    }
}
