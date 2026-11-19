import Foundation
import Testing
@testable import MacCleanerKit

@Suite("XProtect activity log")
struct XProtectLogTests {
    private func line(_ ts: String, _ msg: String, process: String, subsystem: String = "", category: String = "") -> String {
        let object: [String: Any] = [
            "timestamp": ts, "eventMessage": msg, "processImagePath": process,
            "subsystem": subsystem, "category": category,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private let runner = "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect"

    @Test func countsFinishedSystemScansOnly() {
        let text = [
            line("2026-11-18 19:04:07.924402+0100", "Starting system scan, running as 0", process: runner,
                 subsystem: "com.apple.XProtectFramework", category: "Runner"),
            line("2026-11-18 19:04:08.719841+0100", "Finished system scan, ran as 0", process: runner,
                 subsystem: "com.apple.XProtectFramework", category: "Runner"),
            line("2026-11-16 00:46:04.982429+0100", "XPC connection invalidated", process: runner,
                 subsystem: "com.apple.XProtectFramework", category: "Runner"),
        ].joined(separator: "\n")
        let s = XProtectActivity.parse(ndjson: Data(text.utf8))
        #expect(s.systemScans == 1)
        #expect(s.lastSystemScan != nil)
        #expect(s.detections.isEmpty)
        #expect(s.firstEvent! < s.lastEvent!)
    }

    @Test func privateRemediatorReportsAreCountedNotDetections() {
        let text = (0..<3).map { _ in
            line("2026-11-18 23:05:43.733560+0100", "<private>", process: "/usr/libexec/XProtectBridgeService",
                 subsystem: "com.apple.XProtectFramework.PluginAPI", category: "XPEvent")
        }.joined(separator: "\n")
        let s = XProtectActivity.parse(ndjson: Data(text.utf8))
        #expect(s.remediatorReports == 3)
        #expect(s.detections.isEmpty)
    }

    @Test func readableRemediatorReportWithRemediationIsADetection() {
        let json = #"{"plugin":"XProtectRemediatorAdload","status":{"remediated":true},"caller":"timed"}"#
        let text = line("2026-11-10 10:00:00.000000+0100", json, process: "/usr/libexec/XProtectBridgeService",
                        subsystem: "com.apple.XProtectFramework.PluginAPI", category: "XPEvent")
        let s = XProtectActivity.parse(ndjson: Data(text.utf8))
        #expect(s.detections.count == 1)
        #expect(s.detections.first?.remediated == true)
        #expect(s.detections.first?.family == "Adload")
    }

    @Test func readableReportWithoutFindingIsNotADetection() {
        let json = #"{"plugin":"XProtectRemediatorPirrit","status":{"status":"success"}}"#
        let text = line("2026-11-10 10:00:00.000000+0100", json, process: "/usr/libexec/XProtectBridgeService",
                        subsystem: "com.apple.XProtectFramework.PluginAPI", category: "XPEvent")
        #expect(XProtectActivity.parse(ndjson: Data(text.utf8)).detections.isEmpty)
    }

    @Test func clearTextGatekeeperDetectionGetsFamily() {
        let text = [
            line("2026-11-12 09:00:00.000000+0100", "XProtect detected malware: MACOS.SOMA.JAPEENA in /Users/x/Downloads/a.dmg",
                 process: "/usr/libexec/syspolicyd", subsystem: "com.apple.xprotect", category: "xprotect"),
            line("2026-11-18 16:52:15.365256+0100", "Forwarding detection succeeded!",
                 process: "/usr/libexec/syspolicyd", subsystem: "com.apple.xprotect", category: "xprotect"),
        ].joined(separator: "\n")
        let s = XProtectActivity.parse(ndjson: Data(text.utf8))
        #expect(s.detections.count == 1)
        #expect(s.detections.first?.label == "MACOS.SOMA.JAPEENA")
        #expect(s.detections.first?.family == "AMOS (Atomic Stealer)")
    }

    @Test func scriptChecksAndUpdates() {
        let text = [
            line("2026-11-18 10:00:00.000000+0100",
                 "Using XProtect rules location: /var/protected/xprotect/XProtect.bundle/Contents/Resources/XPScripts.yr",
                 process: "/usr/bin/osascript", subsystem: "com.apple.xprotect", category: "xprotect"),
            line("2026-11-18 10:41:23.865581+0100", "SoftwareUpdate: starting download of 142-44702 (XProtectPayloads_10_15-170)",
                 process: "/System/Library/PrivateFrameworks/SoftwareUpdate.framework/Resources/softwareupdated",
                 subsystem: "com.apple.SoftwareUpdate", category: "SoftwareUpdate"),
            line("2026-11-18 10:41:23.946749+0100",
                 "142-53984: Starting download of XProtectPlistConfigData_10_15.pkg (Size:1329869) with URL https://example",
                 process: "/x/softwareupdated", subsystem: "com.apple.SoftwareUpdate", category: "SoftwareUpdate"),
            line("2026-11-18 00:53:53.943431+0100", "6 updates found:\n142-44024\t | XProtectPlistConfigData 5368",
                 process: "/x/softwareupdated", subsystem: "com.apple.SoftwareUpdate", category: "SoftwareUpdate"),
        ].joined(separator: "\n")
        let s = XProtectActivity.parse(ndjson: Data(text.utf8))
        #expect(s.scriptChecks == 1)
        // Updates come from InstallHistory.plist, not from log lines.
        #expect(s.updates.isEmpty)
        #expect(s.detections.isEmpty)
    }

    @Test func garbageLinesAreIgnored() {
        let text = "Filtering the log data using \"subsystem == x\"\nnot json\n{broken\n"
        #expect(XProtectActivity.parse(ndjson: Data(text.utf8)).isEmpty)
    }

    @Test func parsesXprotectVersionAndStatus() {
        let v = XProtectActivity.parseVersion("Version: 5372 Installed: 2026-11-11 07:58:51 +0000\n")
        #expect(v.version == "5372")
        #expect(v.installed == Date(timeIntervalSince1970: 1_794_383_931))
        #expect(XProtectActivity.parseBackgroundScans(#"{"xprotect_launch_scans":false,"xprotect_background_scans":true}"#) == true)
        #expect(XProtectActivity.parseBackgroundScans("nope") == nil)
    }

    @Test func predicateIsBoundedAndArgumentsWellFormed() {
        let args = XProtectActivity.logArguments(days: 30)
        #expect(args.prefix(3) == ["show", "--last", "30d"])
        #expect(args.last == XProtectActivity.predicate)
        #expect(XProtectActivity.predicate.contains(#"subsystem BEGINSWITH "com.apple.XProtectFramework""#))
        #expect(args.contains("--info"))
    }

    @Test func installHistoryUpdates() throws {
        let entries: [[String: Any]] = [
            ["displayName": "Safari", "displayVersion": "26.1", "date": Date(timeIntervalSince1970: 1)],
            ["displayName": "XProtectPlistConfigData", "displayVersion": "5371", "date": Date(timeIntervalSince1970: 100)],
            ["displayName": "XProtectPlistConfigData", "displayVersion": "5372", "date": Date(timeIntervalSince1970: 200)],
            ["displayName": "XProtectPlistConfigData", "displayVersion": "5372", "date": Date(timeIntervalSince1970: 300)],
            ["displayName": "XProtectPayloads", "displayVersion": "170", "date": Date(timeIntervalSince1970: 250)],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        let updates = XProtectActivity.updates(installHistory: data)
        #expect(updates.map(\.version) == ["170", "5372", "5371"])
        #expect(updates.first?.component == "XProtectPayloads")
        #expect(XProtectActivity.updates(installHistory: Data("x".utf8)).isEmpty)
    }
}
