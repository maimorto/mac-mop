import Foundation

/// One command from a shell history file.
public struct ShellHistoryEntry: Sendable, Equatable {
    public let date: Date?
    public let command: String

    public init(date: Date?, command: String) {
        self.date = date
        self.command = command
    }
}

/// A past command that matches a ClickFix / stealer rule. Informational:
/// the command already ran, so there is nothing to remove; the UI explains
/// what to do (change passwords, move crypto funds, log out sessions).
public struct ShellHistoryHit: Sendable, Hashable, Codable {
    public let file: URL
    public let date: Date?
    /// Truncated, secrets masked.
    public let command: String
    public let findings: [ThreatFinding]

    public var severity: ThreatSeverity { findings.map(\.severity).max() ?? .medium }
}

/// Reads zsh / bash history (zsh extended `: <epoch>:<secs>;cmd`, bash
/// `#<epoch>` timestamp lines, plain lines) and runs every command through
/// `ThreatCommandAnalyzer`. Pure over text; the caller reads only the tail
/// of each file.
public enum ShellHistoryAudit {
    public static let defaultMaxBytes = 2 * 1024 * 1024
    public static let defaultMaxEntries = 20_000
    static let commandLimit = 200

    /// The last `maxBytes` of a history file, starting at a line boundary.
    public static func tail(_ data: Data, maxBytes: Int = defaultMaxBytes) -> Data {
        guard data.count > maxBytes else { return data }
        let slice = data.suffix(maxBytes)
        guard let newline = slice.firstIndex(of: 0x0A) else { return Data(slice) }
        return Data(slice[slice.index(after: newline)...])
    }

    /// zsh "metafies" non-ASCII bytes (0x83 followed by byte ^ 0x20); undo
    /// that, then decode UTF-8 leniently.
    public static func decode(_ data: Data) -> String {
        guard data.contains(0x83) else { return String(decoding: data, as: UTF8.self) }
        var out = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta {
                out.append(byte ^ 0x20)
                meta = false
            } else if byte == 0x83 {
                meta = true
            } else {
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func parse(_ text: String) -> [ShellHistoryEntry] {
        var entries: [ShellHistoryEntry] = []
        var pendingDate: Date?
        var current: (date: Date?, lines: [String])?

        func flush() {
            if let entry = current {
                let command = entry.lines.joined(separator: "\n")
                if !command.trimmingCharacters(in: .whitespaces).isEmpty {
                    entries.append(ShellHistoryEntry(date: entry.date, command: command))
                }
            }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine)
            // Inside a multi-line command: zsh writes embedded newlines as
            // a trailing backslash.
            if var entry = current, let last = entry.lines.last, endsWithContinuation(last) {
                entry.lines.append(line)
                current = entry
                continue
            }
            flush()
            if let (date, command) = extendedEntry(line) {
                current = (date, [command])
                pendingDate = nil
            } else if line.hasPrefix("#"), let epoch = TimeInterval(line.dropFirst()), epoch > 0 {
                pendingDate = Date(timeIntervalSince1970: epoch) // bash HISTTIMEFORMAT
            } else if !line.isEmpty {
                current = (pendingDate, [line])
                pendingDate = nil
            }
        }
        flush()
        return entries
    }

    /// `: 1731974400:0;curl … | bash`
    static func extendedEntry(_ line: String) -> (Date?, String)? {
        guard line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") else { return nil }
        let header = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
        let parts = header.split(separator: ":")
        guard parts.count == 2, let epoch = TimeInterval(parts[0]), Int(parts[1]) != nil else { return nil }
        return (Date(timeIntervalSince1970: epoch), String(line[line.index(after: semicolon)...]))
    }

    static func endsWithContinuation(_ line: String) -> Bool {
        var count = 0
        for c in line.reversed() {
            guard c == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    public static func audit(text: String, file: URL, maxEntries: Int = defaultMaxEntries) -> [ShellHistoryHit] {
        audit(entries: parse(text).suffix(maxEntries).map { (file, $0) })
    }

    public static func audit(
        data: Data, file: URL, maxBytes: Int = defaultMaxBytes, maxEntries: Int = defaultMaxEntries
    ) -> [ShellHistoryHit] {
        audit(text: decode(tail(data, maxBytes: maxBytes)), file: file, maxEntries: maxEntries)
    }

    /// Several history files at once (`~/.zsh_history` plus Terminal's
    /// per-session files repeat the same commands): each distinct command
    /// is analysed once and reported with its most recent run.
    public static func audit(files: [(url: URL, data: Data)], maxBytes: Int = defaultMaxBytes,
                             maxEntries: Int = defaultMaxEntries) -> [ShellHistoryHit] {
        audit(entries: files.flatMap { file in
            parse(decode(tail(file.data, maxBytes: maxBytes))).suffix(maxEntries).map { (file.url, $0) }
        })
    }

    static func audit(entries: [(URL, ShellHistoryEntry)]) -> [ShellHistoryHit] {
        var latest: [String: (URL, ShellHistoryEntry)] = [:]
        var order: [String] = []
        for (file, entry) in entries {
            if let existing = latest[entry.command] {
                if (entry.date ?? .distantPast) >= (existing.1.date ?? .distantPast) { latest[entry.command] = (file, entry) }
            } else {
                order.append(entry.command)
                latest[entry.command] = (file, entry)
            }
        }
        return order.compactMap { command -> ShellHistoryHit? in
            guard let (file, entry) = latest[command] else { return nil }
            let findings = ThreatCommandAnalyzer.analyze(command)
            guard !findings.isEmpty else { return nil }
            let shown = ThreatCommandAnalyzer.truncate(SecretMasker.mask(command), limit: commandLimit)
            return ShellHistoryHit(file: file, date: entry.date, command: shown, findings: findings)
        }
    }
}
