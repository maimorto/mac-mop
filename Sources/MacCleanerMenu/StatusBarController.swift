import AppKit
import SwiftUI
import OSLog
import MacCleanerKit

// Stats-style menu bar: one NSStatusItem per module (main + CPU, network,
// battery, RAM), each showing a live rendered image, and a borderless popup
// window anchored right under the clicked button (like Stats' Popup window,
// no NSPopover arrow). The popup shows instantly: data is already polled
// continuously by MenuStatsModel, nothing is collected before showing.

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    /// Creation order is right-to-left in the menu bar, so this gives
    /// (left to right) RAM · battery · network · CPU · Mac Mop.
    enum Module: String, CaseIterable {
        case main, cpu, network, battery, ram

        var defaultsKey: String? {
            switch self {
            case .main: nil
            case .cpu: MenuItemKey.cpu
            case .network: MenuItemKey.network
            case .battery: MenuItemKey.battery
            case .ram: MenuItemKey.ram
            }
        }

        var tab: MenuTab {
            switch self {
            case .main: .home
            case .cpu: .cpu
            case .network: .network
            case .battery: .battery
            case .ram: .memory
            }
        }
    }

    private let model = MenuStatsModel.shared
    private var items: [Module: NSStatusItem] = [:]
    private var visibilityObservers: [Module: NSKeyValueObservation] = [:]
    private var defaultsObserver: NSObjectProtocol?

    private let panel = DashboardPanel()
    private var host: NSHostingController<AnyView>?
    private var sizeObserver: NSKeyValueObservation?
    private var openModule: Module?
    private var anchor: (midX: CGFloat, top: CGFloat, screen: NSRect)?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    /// Posted (distributed) by the main app after it changes one of the
    /// shared settings below; the helper re-reads them at once.
    static let settingsChangedNotification = Notification.Name("com.maccleaner.menuItemsChanged")

    /// Shared-defaults keys the helper reacts to, whichever process writes them.
    private static let observedKeys = [MenuItemKey.ram, MenuItemKey.battery, MenuItemKey.network, MenuItemKey.cpu,
                                       MenuBarMetric.defaultsKey, AppLanguage.defaultsKey]
    /// One long-lived instance: KVO on it also reports writes made by other
    /// processes (the main app's Settings, `defaults write`), through cfprefsd.
    private let shared = SharedAppState.defaults
    private var distributedObserver: NSObjectProtocol?

    func start() {
        syncItems()
        model.onUpdate = { [weak self] in self?.refreshLabels() }
        // Same-process writes (the popup's own toggles).
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged(source: "local") }
        }
        // Writes from the main app or the shell.
        for key in Self.observedKeys {
            shared.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.settingsChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged(source: "distributed") }
        }
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let key = keyPath ?? "?"
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.settingsChanged(source: "kvo \(key)") }
        }
    }

    private static let log = Logger(subsystem: MCConstants.menuBundleIdentifier, category: "StatusBar")

    private func settingsChanged(source: String) {
        let before = Set(items.keys)
        syncItems()
        let after = Set(items.keys)
        if before != after {
            let added = after.subtracting(before).map(\.rawValue).sorted(), removed = before.subtracting(after).map(\.rawValue).sorted()
            Self.log.info("menu items changed (\(source, privacy: .public)): +\(added, privacy: .public) -\(removed, privacy: .public)")
            if ProcessInfo.processInfo.environment["KMR_MENU_LOG_ITEMS"] != nil {
                print("menu items changed (\(source)): added \(added) removed \(removed)")
                fflush(stdout)
            }
        }
    }

    // MARK: Items

    private func isEnabled(_ m: Module) -> Bool {
        if m == .battery && !BatteryInfo.hasBattery { return false }
        guard let key = m.defaultsKey else { return true }
        return shared.object(forKey: key) as? Bool ?? true
    }

    private func syncItems() {
        for m in Module.allCases {
            let enabled = isEnabled(m)
            if enabled, items[m] == nil {
                items[m] = makeItem(m)
            } else if !enabled, let item = items[m] {
                if openModule == m { closePopup() }
                visibilityObservers[m] = nil
                NSStatusBar.system.removeStatusItem(item)
                items[m] = nil
            }
        }
        refreshLabels()
    }

    private func makeItem(_ m: Module) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MacCleaner.\(m.rawValue)"
        item.isVisible = true
        if let button = item.button {
            button.identifier = NSUserInterfaceItemIdentifier(m.rawValue)
            button.target = self
            button.action = #selector(itemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
        if let key = m.defaultsKey {
            // ⌘-dragging an extra item out of the menu bar switches it off.
            item.behavior = .removalAllowed
            visibilityObservers[m] = item.observe(\.isVisible, options: [.new]) { _, change in
                if change.newValue == false { SharedAppState.defaults.set(false, forKey: key) }
            }
        }
        return item
    }

    /// Called after every poll. Images are cached per displayed string, so
    /// the button is only touched when the text actually changes.
    func refreshLabels() {
        for (m, item) in items {
            guard let button = item.button else { continue }
            switch m {
            case .main:
                let (caption, value, widest) = mainLabel()
                set(item, MenuBarLabelImages.main(caption: caption, value: value, widest: widest))
            case .ram:
                let p = Int((model.memory.usedFraction * 100).rounded())
                set(item, MenuBarLabelImages.stacked(slot: "ram", caption: "RAM", value: "\(p)%"))
            case .cpu:
                let p = Int((model.cpu.total * 100).rounded())
                set(item, MenuBarLabelImages.stacked(slot: "cpu", caption: "CPU", value: "\(p)%"))
            case .network:
                let s = model.networkSpeed
                set(item, MenuBarLabelImages.network(up: MenuBarLabelImages.compactRate(s?.bytesOutPerSecond ?? 0),
                                                       down: MenuBarLabelImages.compactRate(s?.bytesInPerSecond ?? 0)))
            case .battery:
                let b = model.battery
                set(item, MenuBarLabelImages.battery(level: b.level, charging: b.isCharging, onAC: b.onAC))
            }
        }
    }

    /// Sets the label and sizes the item to exactly the image width: the
    /// images carry no padding of their own (macOS adds its own item spacing).
    private func set(_ item: NSStatusItem, _ image: NSImage) {
        guard let button = item.button, button.image !== image else { return }
        button.image = image
        let length = ceil(image.size.width)
        if item.length != length { item.length = length }
    }

    /// Caption, value and widest expected value of the Mac Mop item for
    /// the metric picked in the app's settings (nil caption = icon only).
    private func mainLabel() -> (String?, String, String) {
        let s = model.stats
        func percent(_ v: Double?) -> String {
            guard let v, v.isFinite else { return "--" }
            return "\(Int((min(max(v, 0), 1) * 100).rounded()))%"
        }
        // KMR_MENU_METRIC (debug) previews another metric without touching the user's setting.
        let raw = ProcessInfo.processInfo.environment["KMR_MENU_METRIC"] ?? shared.string(forKey: MenuBarMetric.defaultsKey)
        switch MenuBarMetric.resolve(raw) {
        case .diskFree:
            // Free space moves slowly: size for the current digit count only
            // (digits are monospaced), so "80 GB" doesn't reserve room for "999 GB".
            let value = s.map { MenuBarLabelImages.compactDisk($0.diskFree) } ?? "--"
            return ("SSD", value, String(value.map { $0.isNumber ? "0" : $0 }))
        case .gpuUsage:
            return ("GPU", percent(s?.gpuUsage), "100%")
        case .memoryUsage:
            return ("RAM", percent(s.map { $0.memoryTotal > 0 ? Double($0.memoryUsed) / Double($0.memoryTotal) : 0 }), "100%")
        case .batteryTemperature:
            let temp = s?.batteryTemperature.flatMap { $0 > 0 && $0 <= 120 ? "\(Int($0.rounded()))°C" : nil }
            return (UIText.t("TEMP", "TEMP"), temp ?? "--", "99°C")
        case .iconOnly:
            return (nil, "", "")
        }
    }

    // MARK: Popup

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let m = sender.identifier.flatMap({ Module(rawValue: $0.rawValue) }) else { return }
        if openModule == m {
            closePopup()
        } else {
            showPopup(m, under: sender)
        }
    }

    private static var language: AppLanguage {
        AppLanguage(rawValue: SharedAppState.defaults.string(forKey: AppLanguage.defaultsKey) ?? AppLanguage.system.rawValue) ?? .fallback
    }

    static func makeHost(tab: MenuTab) -> NSHostingController<AnyView> {
        let lang = language
        let root = MenuDashboardView(initialTab: tab)
            .environment(\.locale, Locale(identifier: lang.localeIdentifier))
            .environment(\.layoutDirection, lang.isRightToLeft ? .rightToLeft : .leftToRight)
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    private func showPopup(_ m: Module, under button: NSStatusBarButton) {
        closePopup()
        guard let buttonWindow = button.window else { return }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        anchor = (rect.midX, rect.minY - 5, screen)

        let host = Self.makeHost(tab: m.tab)
        self.host = host
        panel.setContent(host.view)
        host.view.layoutSubtreeIfNeeded()   // resolves the measured panel height before showing
        place()
        sizeObserver = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.place() }
        }

        openModule = m
        model.panelAppeared(tab: m.tab)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        // The status button un-highlights at the end of its own tracking: re-assert after it.
        // The shadow is re-derived once the rounded content has been drawn.
        DispatchQueue.main.async { [panel] in
            button.highlight(true)
            panel.invalidateShadow()
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopup() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            Task { @MainActor in self?.closePopup() }
            return nil
        }
    }

    /// Size from the SwiftUI content, top edge pinned under the button,
    /// centred on it and kept inside the screen.
    private func place() {
        guard let host, let anchor else { return }
        var size = host.preferredContentSize
        if size.width < 1 || size.height < 1 { size = host.view.fittingSize }
        let h = min(size.height, anchor.top - anchor.screen.minY - 6)
        let x = min(max(anchor.midX - size.width / 2, anchor.screen.minX + 6), anchor.screen.maxX - size.width - 6)
        panel.setFrame(NSRect(x: x, y: anchor.top - h, width: size.width, height: h), display: true)
        panel.invalidateShadow()
    }

    /// Debug: KMR_MENU_SELFTEST=/dir — logs where each status item sits,
    /// clicks the RAM item like a user would, then records where the popup
    /// opened (and its pixels) and quits. Nothing else changes.
    func selfTest(to dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var log = ""
            for (m, item) in self.items {
                guard let b = item.button, let w = b.window else { log += "\(m): no button\n"; continue }
                let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                log += "\(m): button \(r) visible=\(item.isVisible) image=\(b.image?.size ?? .zero)\n"
            }
            let target = self.items[.ram] ?? self.items[.main]
            let t0 = Date()
            target?.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                log += "popup open=\(self.openModule.map { "\($0)" } ?? "nil") frame=\(self.panel.frame) visible=\(self.panel.isVisible) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n"
                typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                   let img = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(self.panel.windowNumber), 0)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir + "/selftest-popup.png"))
                }
                try? log.write(toFile: dir + "/selftest.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    func closePopup() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        sizeObserver = nil
        guard let m = openModule else { return }
        openModule = nil
        panel.orderOut(nil)
        host = nil
        items[m]?.button?.highlight(false)
        model.panelDisappeared()
    }
}

/// Borderless, non-activating popup window with the system glass (Liquid
/// Glass on macOS 26+, popover material before), like a menu-bar extra.
///
/// One rounded shape only: the content view is a clear, layer-backed view
/// clipped to the same continuous corner radius as the glass inside it, so
/// nothing square is ever drawn, and the window shadow (re-derived from the
/// alpha after every resize, see `invalidateShadow`) follows the rounded
/// outline instead of a rectangle.
final class DashboardPanel: NSPanel {
    static let cornerRadius: CGFloat = 18   // measured: matches a system NSPopover on Tahoe
    private let clip = NSView()
    private let surface: NSView

    init() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            surface = glass
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.state = .active
            v.blendingMode = .behindWindow
            surface = v
        }
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        clip.wantsLayer = true
        clip.layer?.backgroundColor = NSColor.clear.cgColor
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        surface.frame = clip.bounds
        surface.autoresizingMask = [.width, .height]
        clip.addSubview(surface)
        contentView = clip
    }

    override var canBecomeKey: Bool { true }

    func setContent(_ view: NSView) {
        view.frame = surface.bounds
        view.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = view
        } else {
            surface.subviews.forEach { $0.removeFromSuperview() }
            surface.addSubview(view)
        }
    }
}
