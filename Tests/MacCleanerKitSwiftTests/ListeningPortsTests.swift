import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Listening ports")
struct ListeningPortsTests {
    // Trimmed real output of `lsof -nP -iTCP -sTCP:LISTEN -FpcLuPnt` on macOS 27.
    let tcp = """
    p917
    crapportd
    u501
    La
    f11
    tIPv4
    PTCP
    n*:63618
    f14
    tIPv6
    PTCP
    n*:63618
    p1276
    cControlCenter
    u501
    La
    f9
    tIPv4
    PTCP
    n*:7000
    f11
    tIPv4
    PTCP
    n*:5000
    p2185
    cDiscord
    u501
    La
    f36
    tIPv4
    PTCP
    n127.0.0.1:6463
    p25836
    cCode\\x20Helper
    u501
    La
    f35
    tIPv6
    PTCP
    n[::1]:64171
    """

    let udp = """
    p950
    cidentityservicesd
    u501
    La
    f7
    tIPv4
    PUDP
    n*:*
    p953
    csharingd
    u501
    La
    f4
    tIPv4
    PUDP
    n*:5353
    f5
    tIPv4
    PUDP
    n192.168.1.20:123->17.253.14.125:123
    """

    @Test func parsesAndMergesIPv4AndIPv6() {
        let ports = ListeningPorts.parse(tcp)
        #expect(ports.count == 5)
        let rapport = ports.first { $0.port == 63618 }
        #expect(rapport?.command == "rapportd")
        #expect(rapport?.pid == 917)
        #expect(rapport?.uid == 501)
        #expect(rapport?.user == "a")
        #expect(rapport?.addresses == ["*"])
        #expect(rapport?.proto == .tcp)
    }

    @Test func sortedByPort() {
        #expect(ListeningPorts.parse(tcp).map(\.port) == [5000, 6463, 7000, 63618, 64171])
    }

    @Test func exposure() {
        let ports = Dictionary(uniqueKeysWithValues: ListeningPorts.parse(tcp).map { ($0.port, $0) })
        #expect(ports[5000]?.isExposed == true)
        #expect(ports[6463]?.isExposed == false)
        #expect(ports[64171]?.isExposed == false)
        #expect(ListeningPorts.Listener(pid: 1, command: "x", uid: 501, user: nil, proto: .tcp, port: 1,
                                        addresses: ["127.0.0.1", "192.168.1.4"]).isExposed)
    }

    @Test func decodesEscapedCommandNames() {
        #expect(ListeningPorts.parse(tcp).first { $0.port == 64171 }?.command == "Code Helper")
    }

    @Test func udpSkipsUnboundAndConnectedSockets() {
        let ports = ListeningPorts.parse(udp)
        #expect(ports.count == 1)
        #expect(ports.first?.port == 5353)
        #expect(ports.first?.proto == .udp)
        #expect(ports.first?.command == "sharingd")
    }

    @Test func emptyAndGarbageInput() {
        #expect(ListeningPorts.parse("").isEmpty)
        #expect(ListeningPorts.parse("n*:80\nfoo\n").isEmpty) // no process line
    }

    @Test func knownPortExplanations() {
        #expect(ListeningPorts.explanation(port: 5000, command: "ControlCenter")?.contains("AirPlay") == true)
        #expect(ListeningPorts.explanation(port: 5000, command: "python3") != nil)
        #expect(ListeningPorts.explanation(port: 5000, command: "python3")?.contains("AirPlay") == false)
        #expect(ListeningPorts.explanation(port: 22) != nil)
        #expect(ListeningPorts.explanation(port: 5432) != nil)
        #expect(ListeningPorts.explanation(port: 3000) != nil)
        #expect(ListeningPorts.explanation(port: 41234) == nil)
    }

    @Test func systemProcessesAreNotTerminable() {
        #expect(ListeningPorts.isSystemProcess(command: "rapportd", uid: 501))
        #expect(ListeningPorts.isSystemProcess(command: "ControlCenter", uid: 501))
        #expect(ListeningPorts.isSystemProcess(command: "node", uid: 0))
        #expect(ListeningPorts.isSystemProcess(command: "node", uid: 88))
        #expect(!ListeningPorts.isSystemProcess(command: "node", uid: 501))
    }
}
