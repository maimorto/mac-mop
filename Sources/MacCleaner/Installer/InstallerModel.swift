import SwiftUI
import AppKit
import Darwin
import MacCleanerKit

/// Drives the first-run installer window: plan, copy in the background with
/// a minimum dwell per step (so the animation reads), relaunch the installed
/// copy and quit. The disk image is ejected by the NEW instance (see
/// `InstallerEject`), once this one has exited and released the volume.
@MainActor
@Observable
final class InstallerModel {
    enum Phase: Equatable {
        case welcome
        case installing(InstallStep)
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .welcome
    var ejectAfterInstall = true
    /// Folder the app will be copied to (shown under the button).
    private(set) var destinationFolder: URL?
    private(set) var replacesExisting = false

    // Progress glide: the ring and the flying icon ease towards `target`.
    private(set) var target: Double = 0
    private var from: Double = 0
    private var changedAt = Date()
    /// When the success burst started (drives the celebration particles).
    private(set) var doneAt: Date?

    let location = InstallLocation.current()
    /// Root of the disk image the app runs from (resolved through App
    /// Translocation when needed); nil when unknown.
    let sourceVolume: String?
    /// The bundle as the user sees it (on the disk image, not the
    /// translocated copy), for "Show in Finder".
    let visibleBundle: URL

    private let env = ProcessInfo.processInfo.environment

    init() {
        var bundle = Bundle.main.bundleURL
        if case .translocated = location, let original = Self.untranslocated(bundle) { bundle = original }
        visibleBundle = bundle
        switch location {
        case .diskImage(let volume): sourceVolume = volume
        case .translocated:
            if case .diskImage(let volume) = InstallLocation.current(bundlePath: bundle.path) { sourceVolume = volume } else { sourceVolume = nil }
        default: sourceVolume = nil
        }
        refreshPlan()
    }

    private var override: String? { env["KMR_INSTALL_DEST"] }

    private func makePlan() -> InstallPlan? {
        InstallPlanner.plan(source: Bundle.main.bundleURL, override: override, home: NSHomeDirectory(),
                            ejectVolume: ejectAfterInstall ? sourceVolume : nil,
                            isWritable: InstallPlanner.isWritableFolder,
                            exists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    func refreshPlan() {
        let plan = makePlan()
        destinationFolder = plan?.destinationDirectory
            ?? InstallPlanner.candidates(override: override, home: NSHomeDirectory()).first
        replacesExisting = plan?.existing != nil
    }

    /// Progress shown at `date` (nil = no clock running: jump to the target).
    func displayedProgress(at date: Date?) -> Double {
        guard let date else { return target }
        let k = min(1, max(0, date.timeIntervalSince(changedAt) / 0.85))
        return from + (target - from) * (k * k * (3 - 2 * k))
    }

    private func setTarget(_ value: Double) {
        from = displayedProgress(at: Date())
        target = value
        changedAt = Date()
    }

    var isBusy: Bool {
        if case .installing = phase { return true }
        return phase == .done
    }

    // MARK: - Install

    func install() {
        guard !isBusy else { return }
        guard let plan = makePlan() else {
            phase = .failed(KMR.t("Non riesco a scrivere nella cartella Applicazioni con questo account.",
                                  "This account can't write to the Applications folder."))
            return
        }
        from = 0; target = 0; changedAt = Date(); doneAt = nil
        phase = .installing(.copying)
        setTarget(InstallStep.copying.fraction)

        let (steps, continuation) = AsyncStream<InstallStep>.makeStream()
        let installer = AppBundleInstaller()
        let work = Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            let result = Result { try installer.install(plan) { continuation.yield($0) } }
            continuation.finish()
            return result
        }
        Task {
            let dwell: Duration = .milliseconds(650)
            try? await Task.sleep(for: dwell)
            for await step in steps where step != .done && step != .copying {
                phase = .installing(step)
                setTarget(step.fraction)
                try? await Task.sleep(for: dwell)
            }
            switch await work.value {
            case .failure(let error):
                phase = .failed(error.localizedDescription)
                setTarget(0)
            case .success(let installed):
                phase = .done
                setTarget(1)
                doneAt = Date()
                try? await Task.sleep(for: .milliseconds(1600))
                relaunch(installed, eject: plan.ejectVolume)
            }
        }
    }

    /// Open the installed copy once this process has exited (Mac Mop allows
    /// one running instance), then quit. With `KMR_INSTALL_DEST` (tests) the
    /// window just stays on the success screen.
    private func relaunch(_ app: URL, eject: String?) {
        guard override == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = InstallerLaunchArgument.relaunchCommand(pid: getpid(), appPath: app.path, ejectVolume: eject)
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(app)   // best effort; the user can still start it from Applications
        }
        NSApp.terminate(nil)
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([visibleBundle])
    }

    func reset() {
        phase = .welcome
        setTarget(0)
        refreshPlan()
    }

    /// Debug/screenshot states (KMR_INSTALLER_DEMO=progress|done|failed|install).
    func demo(_ name: String) {
        switch name {
        case "progress":
            phase = .installing(.replacing)
            from = 0.62; target = 0.62; changedAt = .distantPast
        case "done":
            phase = .done
            from = 1; target = 1; changedAt = .distantPast
            doneAt = Date().addingTimeInterval(-0.35)
        case "install":   // real install; pair with KMR_INSTALL_DEST (no relaunch)
            install()
        case "failed":
            phase = .failed(KMR.t("Non riesco a scrivere nella cartella Applicazioni con questo account.",
                                  "This account can't write to the Applications folder."))
        default: break
        }
    }

    // MARK: - App Translocation

    /// Original location of a translocated bundle (Security's
    /// SecTranslocateCreateOriginalPathForURL, looked up at run time).
    static func untranslocated(_ url: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: Original.self)
        return function(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}

/// Runs in the freshly installed copy: eject the disk image named by the
/// launch argument, retrying while the old instance releases it. Only a
/// volume that still looks like our installer image is ejected.
enum InstallerEject {
    static func handleLaunchArguments() {
        guard let volume = InstallerLaunchArgument.ejectVolume(in: CommandLine.arguments),
              case .diskImage = InstallLocation.current(bundlePath: volume + "/\(MCConstants.appName).app")
        else { return }
        Task.detached(priority: .utility) {
            for attempt in 0..<8 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 600 : 1200))
                guard FileManager.default.fileExists(atPath: volume) else { return }
                if (try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume))) != nil { return }
            }
        }
    }
}
