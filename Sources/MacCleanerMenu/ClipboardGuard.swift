import AppKit
import SwiftUI
import UserNotifications
import MacCleanerKit

/// ClickFix clipboard guard (idea: ClickGrab's ClickFix page collection).
/// The menu bar helper is always running, so it watches the general
/// pasteboard: every `ClipboardThreatPolicy.pollInterval` it reads only the
/// integer `changeCount`; the text is read only after a change, never for
/// concealed / transient items or password managers, and never logged or
/// stored. When the copied text is an infostealer command (`.high`
/// `ThreatCommandAnalyzer` finding) a small warning panel appears under the
/// menu bar, plus a notification, offering to clear the clipboard.
@MainActor
final class ClipboardGuard {
    static let shared = ClipboardGuard()

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var panel: NSPanel?
    private var notificationsRequested = false

    func start() {
        guard timer == nil else { return }
        // Debug / snapshot runs of the helper never look at the clipboard.
        let env = ProcessInfo.processInfo.environment
        guard !env.keys.contains(where: { $0.hasPrefix("KMR_MENU_") }) else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: ClipboardThreatPolicy.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardGuard.shared.poll() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard ClipboardThreatPolicy.isEnabled(SharedAppState.defaults) else { return }
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let source = pasteboard.string(forType: NSPasteboard.PasteboardType(ClipboardThreatPolicy.sourceType))
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let verdict = ClipboardThreatPolicy.verdict(types: types, source: source) {
            pasteboard.string(forType: .string)
        }
        guard let verdict else { return }
        warn(verdict, changeCount: count)
    }

    private func warn(_ verdict: ClipboardThreatVerdict, changeCount: Int) {
        showPanel(verdict, changeCount: changeCount)
        notify(verdict)
    }

    /// Clears the clipboard only if it still holds the flagged copy.
    private func clear(changeCount: Int) {
        if NSPasteboard.general.changeCount == changeCount {
            NSPasteboard.general.clearContents()
            lastChangeCount = NSPasteboard.general.changeCount
        }
        closePanel()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Panel

    private func showPanel(_ verdict: ClipboardThreatVerdict, changeCount: Int) {
        closePanel()
        let view = ClipboardWarningView(
            reason: verdict.rule.title,
            onClear: { [weak self] in self?.clear(changeCount: changeCount) },
            onIgnore: { [weak self] in self?.closePanel() }
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        // Don't leave it on screen forever if the user walks away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak panel] in
            if let panel, self?.panel === panel { self?.closePanel() }
        }
    }

    // MARK: Notification

    private func notify(_ verdict: ClipboardThreatVerdict) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !notificationsRequested {
            notificationsRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = ClipboardThreatPolicy.warningTitle
        content.body = ClipboardThreatPolicy.warningBody
        content.subtitle = verdict.rule.title
        content.sound = .defaultCritical
        content.threadIdentifier = "clipboard-guard"
        center.add(UNNotificationRequest(identifier: "clipboard-guard", content: content, trigger: nil))
    }
}

private struct ClipboardWarningView: View {
    let reason: String
    let onClear: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, .red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ClipboardThreatPolicy.warningTitle)
                        .font(.headline)
                    Text(ClipboardThreatPolicy.warningBody)
                        .font(.callout)
                    Text(reason)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(ClipboardThreatPolicy.warningDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(ClipboardThreatPolicy.ignoreAction, action: onIgnore)
                Button(ClipboardThreatPolicy.clearAction, action: onClear)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
