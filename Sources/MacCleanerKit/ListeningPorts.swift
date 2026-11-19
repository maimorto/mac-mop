import Foundation

/// Network ports that processes are listening on, parsed from `lsof -F`
/// output (machine-readable field mode), plus plain-language explanations of
/// the ports people most often find open on a Mac.
///
/// `lsof -nP -iTCP -sTCP:LISTEN -FpcLuPnt` and `lsof -nP -iUDP -FpcLuPnt`
/// print one field per line: `p<pid>` starts a process, `c<command>`,
/// `u<uid>`, `L<login>`; then per open file `f<fd>`, `t<IPv4|IPv6>`,
/// `P<TCP|UDP>`, `n<address:port>`. Without administrator rights lsof only
/// sees the current user's processes, which is what the Ports page shows.
public enum ListeningPorts {
    public enum Proto: String, Sendable, Hashable, Comparable {
        case tcp = "TCP", udp = "UDP"
        public static func < (a: Proto, b: Proto) -> Bool { a.rawValue < b.rawValue }
    }

    /// One listening socket, merged across IPv4/IPv6 and duplicate file
    /// descriptors of the same process.
    public struct Listener: Sendable, Hashable, Identifiable {
        public let pid: Int32
        public let command: String
        public let uid: UInt32?
        public let user: String?
        public let proto: Proto
        public let port: Int
        /// Every local address the port is bound to (`*`, `127.0.0.1`, `[::1]`, `192.168.1.5`…).
        public let addresses: [String]

        public var id: String { "\(pid)-\(proto.rawValue)-\(port)" }

        /// True when another device on the network can reach the port: bound
        /// to all interfaces or to a non-loopback address.
        public var isExposed: Bool { addresses.contains { !ListeningPorts.isLoopback($0) } }

        public init(pid: Int32, command: String, uid: UInt32?, user: String?, proto: Proto, port: Int, addresses: [String]) {
            self.pid = pid
            self.command = command
            self.uid = uid
            self.user = user
            self.proto = proto
            self.port = port
            self.addresses = addresses
        }
    }

    /// Parses `lsof -F` output. Connected sockets (`a->b`), unbound UDP
    /// sockets (`*:*`) and lines without a numeric port are ignored.
    public static func parse(_ output: String) -> [Listener] {
        struct Key: Hashable { let pid: Int32; let proto: Proto; let port: Int }
        var order: [Key] = []
        var merged: [Key: (command: String, uid: UInt32?, user: String?, addresses: [String])] = [:]

        var pid: Int32?
        var command = ""
        var uid: UInt32?
        var user: String?
        var proto: Proto?

        for raw in output.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value); command = ""; uid = nil; user = nil; proto = nil
            case "c": command = decodeEscapes(value)
            case "u": uid = UInt32(value)
            case "L": user = value
            case "f": proto = nil
            case "P": proto = Proto(rawValue: value.uppercased())
            case "n":
                guard let pid, let proto, let (address, port) = splitAddress(value) else { continue }
                let key = Key(pid: pid, proto: proto, port: port)
                if var entry = merged[key] {
                    if !entry.addresses.contains(address) { entry.addresses.append(address) }
                    merged[key] = entry
                } else {
                    order.append(key)
                    merged[key] = (command, uid, user, [address])
                }
            default: continue
            }
        }
        return order.compactMap { key in
            guard let e = merged[key] else { return nil }
            return Listener(pid: key.pid, command: e.command, uid: e.uid, user: e.user,
                            proto: key.proto, port: key.port, addresses: e.addresses)
        }
        .sorted { ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid) }
    }

    /// `*:5000` → (`*`, 5000); `[::1]:631` → (`[::1]`, 631). Nil for
    /// connections (`a->b`) and wildcard ports.
    static func splitAddress(_ name: String) -> (String, Int)? {
        guard !name.contains("->"), let colon = name.lastIndex(of: ":") else { return nil }
        let host = String(name[..<colon])
        guard let port = Int(name[name.index(after: colon)...]), port > 0, !host.isEmpty else { return nil }
        return (host, port)
    }

    public static func isLoopback(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return a.hasPrefix("127.") || a == "::1" || a == "localhost" || a.hasPrefix("::ffff:127.")
    }

    /// lsof escapes non-printable characters in command names (`Code\x20Helper`).
    static func decodeEscapes(_ s: String) -> String {
        guard s.contains("\\x") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s.index(i, offsetBy: 4, limitedBy: s.endIndex) != nil,
               s[s.index(after: i)] == "x",
               let byte = UInt8(s[s.index(i, offsetBy: 2)..<s.index(i, offsetBy: 4)], radix: 16) {
                out.append(Character(UnicodeScalar(byte)))
                i = s.index(i, offsetBy: 4)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    // MARK: Known ports

    /// What a well-known port usually is, in plain language. Nil when the
    /// port has no common meaning (most high ports are picked at random).
    public static func explanation(port: Int, proto: Proto = .tcp, command: String = "") -> String? {
        let c = command.lowercased()
        switch port {
        case 5000 where c.contains("controlce"), 7000 where c.contains("controlce"):
            return UIText.t("Ricevitore AirPlay di macOS: permette ad altri dispositivi Apple di trasmettere su questo Mac. Si disattiva in Impostazioni › Generali › AirDrop e Handoff.",
                            "macOS AirPlay Receiver: lets other Apple devices stream to this Mac. Turn it off in Settings › General › AirDrop & Handoff.")
        case 22: return UIText.t("SSH (Login remoto): permette di collegarsi a questo Mac dal terminale di un altro computer.",
                                 "SSH (Remote Login): lets another computer log in to this Mac from a terminal.")
        case 53: return UIText.t("DNS: un server di nomi locale (per esempio un blocco pubblicità o una VPN).",
                                 "DNS: a local name server (for example an ad blocker or a VPN).")
        case 80, 8080, 8000, 8888: return UIText.t("Server web (HTTP), spesso uno strumento di sviluppo o un'app che offre un'interfaccia nel browser.",
                                                   "Web server (HTTP), often a developer tool or an app with a browser interface.")
        case 443, 8443: return UIText.t("Server web sicuro (HTTPS).", "Secure web server (HTTPS).")
        case 88: return UIText.t("Kerberos: autenticazione di macOS per la condivisione.", "Kerberos: macOS sign-in for sharing.")
        case 137, 138, 139, 445: return UIText.t("Condivisione file di Windows (SMB): altri computer possono aprire le cartelle condivise.",
                                                 "Windows file sharing (SMB): other computers can open shared folders.")
        case 548: return UIText.t("Condivisione file Apple (AFP).", "Apple file sharing (AFP).")
        case 631: return UIText.t("Stampa (CUPS): condivisione delle stampanti.", "Printing (CUPS): printer sharing.")
        case 3000, 3001, 4200, 5000, 5173, 8081, 19000:
            return UIText.t("Server di sviluppo (Node, React, Vite…): di solito avviato da te o da un editor.",
                            "Development server (Node, React, Vite…): usually started by you or an editor.")
        case 3283, 5900: return UIText.t("Condivisione schermo / Gestione remota: qualcuno può vedere e controllare questo Mac.",
                                         "Screen Sharing / Remote Management: someone can see and control this Mac.")
        case 3306: return UIText.t("Database MySQL / MariaDB.", "MySQL / MariaDB database.")
        case 5353: return UIText.t("Bonjour (mDNS): serve a trovare stampanti, AirPlay e altri Mac nella rete. Normale.",
                                   "Bonjour (mDNS): finds printers, AirPlay and other Macs on the network. Normal.")
        case 5432: return UIText.t("Database PostgreSQL.", "PostgreSQL database.")
        case 6379: return UIText.t("Database Redis.", "Redis database.")
        case 6463...6472 where c.contains("discord"):
            return UIText.t("Discord: integrazione locale con giochi e browser, solo da questo Mac.", "Discord: local integration with games and browsers, this Mac only.")
        case 7000: return UIText.t("Ricevitore AirPlay o un server di sviluppo.", "AirPlay Receiver or a development server.")
        case 8008, 8009: return UIText.t("Chromecast / trasmissione multimediale.", "Chromecast / media casting.")
        case 9000, 9090: return UIText.t("Pannello web di uno strumento (PHP-FPM, Prometheus, Portainer…).", "Web panel of a tool (PHP-FPM, Prometheus, Portainer…).")
        case 11434: return UIText.t("Ollama: modelli di intelligenza artificiale in locale.", "Ollama: local AI models.")
        case 27017: return UIText.t("Database MongoDB.", "MongoDB database.")
        case 49152...65535 where c.contains("rapportd"):
            return UIText.t("Continuità di Apple (Handoff, Appunti universali, AirDrop): normale.", "Apple Continuity (Handoff, Universal Clipboard, AirDrop): normal.")
        default: return nil
        }
    }

    /// Processes that belong to macOS itself: never offer to terminate them.
    public static func isSystemProcess(command: String, uid: UInt32?) -> Bool {
        if uid == 0 || (uid ?? 501) < 500 { return true }
        let system: Set<String> = ["rapportd", "controlcenter", "controlce", "sharingd", "identityservicesd", "mdnsresponder",
                                   "launchd", "airplayxpchelper", "screensharingd", "remotemanagementd", "cupsd",
                                   "netbiosd", "smbd", "apsd", "symptomsd", "configd", "bluetoothd", "replicatord",
                                   "universalcontrol", "continuitycaptureagent", "wifiagent", "nearbyd", "remoted"]
        return system.contains(command.lowercased())
    }
}
