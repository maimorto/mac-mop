import Foundation

/// Gathers `SecurityProbe` inputs from the running Mac. Read-only and
/// without administrator rights: no `sudo`, `systemsetup`, `profiles` or
/// `sfltool`, nothing that can show a password or permission prompt.
/// Safari's settings (inside its container) are read only when the app
/// already has Full Disk Access.
public enum SecurityChecklistProbe {
    public static func gather(home: URL = MCConstants.home,
                              hasFullDiskAccess: Bool = PersistenceCollector.detectFullDiskAccess()) async -> SecurityProbe {
        let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        async let fdesetup = run("/usr/bin/fdesetup", ["status"])
        async let firewall = run(firewallTool, ["--getglobalstate"])
        async let stealth = run(firewallTool, ["--getstealthmode"])
        async let blockAll = run(firewallTool, ["--getblockall"])
        async let spctl = run("/usr/sbin/spctl", ["--status"], mergeStderr: true)
        async let csrutil = run("/usr/bin/csrutil", ["status"])
        async let xprotect = run("/usr/bin/xprotect", ["version"])
        async let screenLock = run("/usr/sbin/sysadminctl", ["-screenLock", "status"], mergeStderr: true)
        async let services = run("/bin/launchctl", ["print", "system"])
        async let netstat = run("/usr/sbin/netstat", ["-anv", "-p", "tcp"])
        async let ard = run("/usr/bin/pgrep", ["-x", "ARDAgent"])
        async let tmDestinations = run("/usr/bin/tmutil", ["destinationinfo"], mergeStderr: true)

        var probe = SecurityProbe()
        probe.fdesetup = await fdesetup
        probe.firewallGlobal = await firewall
        probe.firewallStealth = await stealth
        probe.firewallBlockAll = await blockAll
        probe.spctl = await spctl
        probe.csrutil = await csrutil
        probe.xprotectVersion = await xprotect
        if probe.xprotectVersion?.contains("Version:") != true {
            let bundle = URL(filePath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
            probe.xprotectBundleDate = (try? bundle.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        probe.screenLock = await screenLock
        probe.systemServices = Set(LaunchctlParser.services(await services ?? "").keys)
        probe.listeningPorts = SecurityChecklist.parseListeningPorts(await netstat ?? "")
        probe.ardAgentRunning = !(await ard ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        probe.timeMachineDestinations = await tmDestinations

        let library = home.appending(path: "Library/Preferences")
        probe.softwareUpdate = plist("/Library/Preferences/com.apple.SoftwareUpdate.plist")
        probe.commerce = plist("/Library/Preferences/com.apple.commerce.plist")
            ?? plist(library.appending(path: "com.apple.commerce.plist").path(percentEncoded: false))
        probe.loginWindow = plist("/Library/Preferences/com.apple.loginwindow.plist")
        probe.kcpasswordExists = FileManager.default.fileExists(atPath: "/etc/kcpassword")
        probe.airDropMode = plist(library.appending(path: "com.apple.sharingd.plist").path(percentEncoded: false))?["DiscoverableMode"]?.string
        probe.findMy = plist("/Library/Preferences/com.apple.FindMyMac.plist")
        probe.timeMachine = plist("/Library/Preferences/com.apple.TimeMachine.plist")
        probe.lockdownEnabled = plist(library.appending(path: ".GlobalPreferences.plist").path(percentEncoded: false))?["LDMGlobalEnabled"]?.bool

        let byHost = library.appending(path: "ByHost")
        let bluetoothFiles = ((try? FileManager.default.contentsOfDirectory(atPath: byHost.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix("com.apple.Bluetooth.") && $0.hasSuffix(".plist") }
        probe.bluetoothServicesEnabled = bluetoothFiles.compactMap {
            plist(byHost.appending(path: $0).path(percentEncoded: false))?["PrefKeyServicesEnabled"]?.bool
        }.first

        if hasFullDiskAccess {
            probe.safari = plist(home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist")
                .path(percentEncoded: false))
        }
        return probe
    }

    public static func evaluate() async -> [SecurityCheckResult] {
        SecurityChecklist.evaluate(await gather())
    }

    static func plist(_ path: String) -> [String: SendablePlistValue]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return SendablePlistValue.dictionary(from: object)
    }

    static func run(_ path: String, _ args: [String], mergeStderr: Bool = false) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let outcome = await BoundedProcess.run(path, args, timeout: .seconds(10))
        guard case .exited(_, let out, let err) = outcome else { return nil }
        let text = String(decoding: out, as: UTF8.self) + (mergeStderr ? String(decoding: err, as: UTF8.self) : "")
        return text.isEmpty ? nil : text
    }
}
