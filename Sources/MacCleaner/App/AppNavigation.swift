import SwiftUI
import AppKit
import Quartz
import MacCleanerKit

// App-wide navigation like System Settings and Finder:
//  • toolbar Back/Forward (⌘[ / ⌘], mouse buttons 4/5, three-finger swipe)
//    that walk the page's own drill-downs first, then the pages visited;
//  • Esc steps back out of a drill-down (done screen → results…);
//  • ⌘F focuses the visible page's search field, or the sidebar search;
//  • Edit › Undo (⌘Z) puts the last clean back from Cleanup History.

// MARK: - Model

/// A drill-down a visible page registered with `.pageNavigation(…)`.
struct PageNavigationEntry {
    let id: String
    let back: (() -> Void)?
    let forward: (() -> Void)?
    /// Esc runs `back` too (off for pages that handle Esc themselves).
    let handlesEscape: Bool
}

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var symbol: String = "checkmark.circle.fill"
    /// Offers "Annulla" (Undo) for the last clean.
    var offersUndo = false

    static func == (a: AppToast, b: AppToast) -> Bool { a.id == b.id }
}

@MainActor
extension AppState {
    private var currentEntries: [PageNavigationEntry] {
        selectedSidebarItem.flatMap { pageNavigation[$0] } ?? []
    }

    var canGoBack: Bool {
        NavigationRouting.back(pageCanGoBack: currentEntries.contains { $0.back != nil },
                               historyCanGoBack: pageHistory.canGoBack) != .none
    }

    var canGoForward: Bool {
        NavigationRouting.forward(pageCanGoForward: currentEntries.contains { $0.forward != nil },
                                  historyCanGoForward: pageHistory.canGoForward) != .none
    }

    /// Title of the place Back leads to (tooltip), when it is another page.
    var backDestinationTitle: String? {
        guard !currentEntries.contains(where: { $0.back != nil }) else { return nil }
        return pageHistory.backStack.last?.displayTitle
    }

    func goBack() {
        let pageBack = currentEntries.last(where: { $0.back != nil })?.back
        switch NavigationRouting.back(pageCanGoBack: pageBack != nil, historyCanGoBack: pageHistory.canGoBack) {
        case .withinPage: pageBack?()
        case .history: traverse { pageHistory.goBack() }
        case .none: NSSound.beep()
        }
    }

    func goForward() {
        let pageForward = currentEntries.last(where: { $0.forward != nil })?.forward
        switch NavigationRouting.forward(pageCanGoForward: pageForward != nil, historyCanGoForward: pageHistory.canGoForward) {
        case .withinPage: pageForward?()
        case .history: traverse { pageHistory.goForward() }
        case .none: NSSound.beep()
        }
    }

    /// Esc: leaves the visible page's drill-down. Returns false when there is
    /// nothing to leave (the key then goes on to the focused control).
    func escapeWithinPage() -> Bool {
        guard let entry = currentEntries.last(where: { $0.back != nil && $0.handlesEscape }) else { return false }
        entry.back?()
        return true
    }

    private func traverse(_ step: () -> SidebarItem?) {
        guard let item = step() else { return }
        isTraversingHistory = true
        selectedSidebarItem = item
        isTraversingHistory = false
    }

    func registerPageNavigation(_ entry: PageNavigationEntry, for item: SidebarItem) {
        var list = pageNavigation[item] ?? []
        if let i = list.firstIndex(where: { $0.id == entry.id }) { list[i] = entry } else { list.append(entry) }
        pageNavigation[item] = list
    }

    func unregisterPageNavigation(id: String, for item: SidebarItem) {
        guard var list = pageNavigation[item], list.contains(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        pageNavigation[item] = list.isEmpty ? nil : list
    }

    func showToast(_ toast: AppToast) {
        withAnimation(.smooth(duration: 0.25)) { self.toast = toast }
        let id = toast.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(toast.offersUndo ? 8 : 4))
            if self.toast?.id == id { withAnimation(.smooth(duration: 0.25)) { self.toast = nil } }
        }
    }

    /// Opens Settings on a given pane (search results).
    func openSettings(_ pane: SettingsPane) {
        selectedSidebarItem = .settings
        requestedSettingsPane = pane
    }

    /// Puts the last clean back where it was (Edit › Undo, toast "Annulla").
    /// Restore never overwrites anything; items already emptied are skipped.
    func undoLastClean() {
        guard let recorded = lastUndoableClean else { NSSound.beep(); return }
        lastUndoableClean = nil
        toast = nil
        Task { @MainActor in
            guard let activity = try? await AppOperationActivity.shared.begin() else { return }
            defer { AppOperationActivity.shared.end(activity) }
            let summary = await Task.detached(priority: .userInitiated) { () -> CleanHistoryRestoreSummary? in
                // Use the stored copy: items restored since then are gone from it.
                guard let session = CleanHistoryRecorder.load().first(where: { $0.id == recorded.id }) else { return nil }
                return CleanHistoryRecorder.restore(session)
            }.value
            NotificationCenter.default.post(name: CleanHistoryRecorder.didRestoreNotification, object: nil)
            guard let summary else {
                showToast(AppToast(message: KMR.t("Questa pulizia non è più nella Cronologia.", "This clean is no longer in Cleanup History."),
                                   symbol: "exclamationmark.triangle.fill"))
                return
            }
            let message = summary.failed + summary.emptied + summary.reappeared == 0
                ? KMR.t("Ripristinati: \(summary.restored)", "Restored: \(summary.restored)")
                : KMR.t("Ripristinati: \(summary.restored) · non ripristinati: \(summary.failed + summary.emptied + summary.reappeared)",
                        "Restored: \(summary.restored) · not restored: \(summary.failed + summary.emptied + summary.reappeared)")
            showToast(AppToast(message: message, symbol: "arrow.uturn.backward.circle.fill"))
        }
    }

    /// ⌘F: the visible page's search field if it has one, else the sidebar's.
    func focusSearch() {
        let claim = SearchFocusClaim()
        NotificationCenter.default.post(name: SearchFocusClaim.notification, object: claim)
        guard !claim.claimed else { return }
        if #available(macOS 15.0, *) {
            sidebarSearchFocusRequest &+= 1
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            SearchFocusClaim.focusSidebarSearch(in: window)
        }
    }
}

extension CleanHistoryRecorder {
    /// Posted after Undo put a clean back (Cleanup History reloads).
    static let didRestoreNotification = Notification.Name("MacMopCleanHistoryDidRestore")
}

// MARK: - Search focus (⌘F)

/// Passed with the ⌘F notification: the first visible filter field takes it.
final class SearchFocusClaim {
    static let notification = Notification.Name("MacMopFocusSearch")
    var claimed = false

    /// True when the view is on screen in the key window (hidden modules have
    /// a zero-size frame, so their fields don't qualify).
    static func isVisible(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, window.attachedSheet == nil,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        let visible = view.visibleRect
        return visible.width > 4 && visible.height > 4
    }

    /// The sidebar's `.searchable` field: the leftmost visible search field.
    static func focusSidebarSearch(in window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var fields: [NSSearchField] = []
        func walk(_ v: NSView) {
            if let f = v as? NSSearchField, isVisible(f) { fields.append(f) }
            v.subviews.forEach(walk)
        }
        walk(root)
        let leftmost = fields.min { a, b in
            a.convert(a.bounds, to: nil).minX < b.convert(b.bounds, to: nil).minX
        }
        if let leftmost { window.makeFirstResponder(leftmost) }
    }
}

// MARK: - Page drill-down registration

private struct PageNavigationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.currentModule) private var module
    let id: String
    let canGoBack: Bool
    let canGoForward: Bool
    let handlesEscape: Bool
    let back: () -> Void
    let forward: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onChange(of: [canGoBack, canGoForward], initial: true) { _, _ in update() }
            .onDisappear {
                if let module { appState.unregisterPageNavigation(id: id, for: module) }
            }
    }

    private func update() {
        guard let module else { return }
        if canGoBack || canGoForward {
            appState.registerPageNavigation(PageNavigationEntry(
                id: id,
                back: canGoBack ? back : nil,
                forward: canGoForward ? forward : nil,
                handlesEscape: handlesEscape), for: module)
        } else {
            appState.unregisterPageNavigation(id: id, for: module)
        }
    }
}

extension View {
    /// Lets the window's Back button (and Esc, ⌘[, mouse back) step out of a
    /// drill-down on this page while `canGoBack` is true.
    func pageNavigation(id: String, canGoBack: Bool, handlesEscape: Bool = true,
                        back: @escaping () -> Void,
                        canGoForward: Bool = false, forward: (() -> Void)? = nil) -> some View {
        modifier(PageNavigationModifier(id: id, canGoBack: canGoBack, canGoForward: canGoForward,
                                        handlesEscape: handlesEscape, back: back, forward: forward))
    }
}

// MARK: - Toolbar Back / Forward

struct NavigationButtons: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ControlGroup {
            Button { appState.goBack() } label: {
                Label(KMR.t("Indietro", "Back"), systemImage: "chevron.left")
            }
            .disabled(!appState.canGoBack)
            .help(appState.backDestinationTitle.map { KMR.t("Torna a \($0) (⌘[)", "Back to \($0) (⌘[)") }
                  ?? KMR.t("Indietro (⌘[)", "Back (⌘[)"))
            Button { appState.goForward() } label: {
                Label(KMR.t("Avanti", "Forward"), systemImage: "chevron.right")
            }
            .disabled(!appState.canGoForward)
            .help(KMR.t("Avanti (⌘])", "Forward (⌘])"))
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.iconOnly)
    }
}

// MARK: - Toast

struct AppToastView: View {
    @Environment(AppState.self) private var appState
    let toast: AppToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.symbol.contains("exclamation") ? Color.orange : Color.green)
            Text(toast.message)
                .lineLimit(2)
            if toast.offersUndo {
                Button(KMR.t("Annulla", "Undo")) { appState.undoLastClean() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .help(KMR.t("Rimetti a posto gli elementi appena spostati nel Cestino (⌘Z)",
                                "Put back the items just moved to the Trash (⌘Z)"))
            }
            Button {
                withAnimation(.smooth(duration: 0.2)) { appState.toast = nil }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(KMR.t("Chiudi", "Close"))
            .accessibilityLabel(KMR.t("Chiudi", "Close"))
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Event handling (mouse back/forward, swipe, Esc)

@MainActor
private final class NavigationEventMonitor {
    nonisolated(unsafe) private var token: Any?

    func install(appState: AppState) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe, .keyDown]) { [weak appState] event in
            guard let appState, let window = event.window, window.isKeyWindow,
                  window.attachedSheet == nil, window.frame.width > 500 else { return event }
            switch event.type {
            case .otherMouseDown where event.buttonNumber == 3:
                appState.goBack(); return nil
            case .otherMouseDown where event.buttonNumber == 4:
                appState.goForward(); return nil
            case .swipe where event.deltaX > 0:
                appState.goBack(); return nil
            case .swipe where event.deltaX < 0:
                appState.goForward(); return nil
            case .keyDown where event.keyCode == 53
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty:
                // Text fields keep Esc (clear / cancel editing).
                if window.firstResponder is NSText { return event }
                return appState.escapeWithinPage() ? nil : event
            default:
                return event
            }
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}

// MARK: - ContentView glue

private struct AppNavigationSupport: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.undoManager) private var undoManager
    @State private var monitor = NavigationEventMonitor()

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigation) { NavigationButtons() }
            }
            .overlay(alignment: .bottom) {
                if let toast = appState.toast {
                    AppToastView(toast: toast)
                        .padding(.bottom, 18)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(StandardWindowBehaviour())
            .onAppear { monitor.install(appState: appState) }
            .onReceive(NotificationCenter.default.publisher(for: CleanHistoryRecorder.didRecordNotification)) { note in
                guard let session = note.userInfo?["session"] as? CleanHistorySession else { return }
                appState.lastUndoableClean = session
                if let undoManager {
                    undoManager.removeAllActions(withTarget: appState)
                    undoManager.registerUndo(withTarget: appState) { $0.undoLastClean() }
                    undoManager.setActionName(KMR.t("pulizia", "Cleanup"))
                }
                let count = session.items.count + (session.omittedCount ?? 0)
                appState.showToast(AppToast(
                    message: KMR.t("Nel Cestino: \(count) · \(FileSizeFormatter.format(session.totalBytes))",
                                   "Moved to the Trash: \(count) · \(FileSizeFormatter.format(session.totalBytes))"),
                    symbol: "trash.circle.fill",
                    offersUndo: true))
            }
            .onAppear { Task { @MainActor in await WindowBehaviourProbe.runIfRequested(appState: appState) } }
    }
}

extension View {
    /// Toolbar Back/Forward, Esc/mouse/swipe handling, the toast and Undo.
    func appNavigationSupport() -> some View { modifier(AppNavigationSupport()) }
}

// MARK: - Menu commands

/// Files selected on the visible page (Space Lens tile, Uninstaller apps),
/// for File › Show in Finder / Quick Look / Copy Path.
private struct SelectedFileURLsKey: FocusedValueKey { typealias Value = [URL] }

extension FocusedValues {
    var selectedFileURLs: [URL]? {
        get { self[SelectedFileURLsKey.self] }
        set { self[SelectedFileURLsKey.self] = newValue }
    }
}

extension View {
    /// Publishes the page's selected files to the File menu while the page is visible.
    func selectedFilesForMenu(_ urls: [URL], isVisible: Bool) -> some View {
        focusedSceneValue(\.selectedFileURLs, isVisible && !urls.isEmpty ? urls : nil)
    }
}

struct AppNavigationCommands: Commands {
    let appState: AppState
    @FocusedValue(\.selectedFileURLs) private var selectedFiles

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button(KMR.t("Nuova scansione", "New Scan")) { appState.requestScanShortcut() }
                .keyboardShortcut("r", modifiers: .command)
            Button(KMR.t("Pulisci selezionati", "Clean Selected")) { appState.requestCleanShortcut() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button(KMR.t("Mostra nel Finder", "Show in Finder")) { FileActions.reveal(selectedFiles ?? []) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled((selectedFiles ?? []).isEmpty)
            Button(KMR.t("Anteprima", "Quick Look")) { QuickLookPanelController.shared.show(selectedFiles ?? []) }
                .keyboardShortcut("y", modifiers: .command)
                .disabled((selectedFiles ?? []).isEmpty)
            Button(KMR.t("Copia percorso", "Copy Path")) { FileActions.copyPaths(selectedFiles ?? []) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled((selectedFiles ?? []).isEmpty)
        }
        // Edit › Find
        CommandGroup(after: .textEditing) {
            Button(KMR.t("Cerca", "Find")) { appState.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        // View: Back / Forward and the modules, like System Settings.
        CommandGroup(before: .toolbar) {
            Button(KMR.t("Indietro", "Back")) { appState.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!appState.canGoBack)
            Button(KMR.t("Avanti", "Forward")) { appState.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!appState.canGoForward)
            Divider()
            ForEach(1...9, id: \.self) { digit in
                if let item = SidebarItem.item(forShortcutDigit: digit) {
                    Button(item.title) { appState.selectedSidebarItem = item }
                        .keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command)
                }
            }
            Divider()
        }
        // Help
        CommandGroup(replacing: .help) {
            Button(KMR.t("Aiuto di \(MCConstants.appName)", "\(MCConstants.appName) Help")) {
                NSWorkspace.shared.open(MCConstants.repoURL.appending(path: "blob/main/README.md"))
            }
            .keyboardShortcut("?", modifiers: .command)
            Button(KMR.t("Segnala un problema…", "Report an Issue…")) {
                NSWorkspace.shared.open(MCConstants.issuesURL)
            }
            Button(KMR.t("Cronologia pulizia", "Cleanup History")) { appState.selectedSidebarItem = .cleanHistory }
        }
    }
}

// MARK: - Quick Look (in-process panel, Space to close)

@MainActor
final class QuickLookPanelController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPanelController()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

// MARK: - File row actions shared by lists

enum FileActions {
    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Standard file context-menu items: Show in Finder, Quick Look, Copy Path.
struct FileContextMenuItems: View {
    let url: URL

    var body: some View {
        Button(KMR.t("Mostra nel Finder", "Show in Finder")) { FileActions.reveal([url]) }
        Button(KMR.t("Anteprima", "Quick Look")) { QuickLookPanelController.shared.show([url]) }
        Button(KMR.t("Copia percorso", "Copy Path")) { FileActions.copyPaths([url]) }
    }
}

// MARK: - Standard window behaviour

/// Makes sure the main window behaves like every Mac window: it can go full
/// screen (green button, ⌃⌘F, View › Enter Full Screen), it is listed in the
/// Window menu, and its size and position are remembered. SwiftUI leaves
/// `fullScreenNone` set and the window out of the Window menu in some launch
/// paths (seen with the unbundled build).
private struct StandardWindowBehaviour: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                window.collectionBehavior.remove(.fullScreenNone)
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.isExcludedFromWindowsMenu = false
                window.styleMask.formUnion([.miniaturizable, .resizable, .closable])
                if window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("MacMopMainWindow") }
            }
        }
    }
}

private func isInSearchField(_ window: NSWindow) -> Bool {
    guard let text = window.firstResponder as? NSTextView, text.isFieldEditor else { return false }
    return text.delegate is NSSearchField
}

// MARK: - Window behaviour probe (debug)

/// Debug aid: KMR_WINDOWTEST=/path/report.txt exercises minimize, zoom,
/// close + Dock reopen and the menus in-process, writes what happened, then
/// quits. No accessibility permission needed.
@MainActor
enum WindowBehaviourProbe {
    private static var started = false

    static func runIfRequested(appState: AppState) async {
        guard let path = ProcessInfo.processInfo.environment["KMR_WINDOWTEST"], !started else { return }
        started = true
        var log: [String] = []
        nonisolated(unsafe) var log2: [String] = []
        func mainWindow() -> NSWindow? {
            NSApp.windows.filter { $0.frame.width > 500 && $0.canBecomeMain }.max { $0.frame.width < $1.frame.width }
        }
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else {
            try? "no main window".write(toFile: path, atomically: true, encoding: .utf8); NSApp.terminate(nil); return
        }
        let mask = window.styleMask
        log.append("at launch: isMiniaturized=\(window.isMiniaturized) visible=\(window.isVisible) onScreen=\(window.isOnActiveSpace) frame=\(window.frame) alpha=\(window.alphaValue)")
        // Navigation history
        appState.selectedSidebarItem = .spaceLens
        appState.selectedSidebarItem = .uninstaller
        appState.selectedSidebarItem = .duplicates
        appState.goBack()
        log.append("history: back from duplicates -> \(String(describing: appState.selectedSidebarItem)) canBack=\(appState.canGoBack) canFwd=\(appState.canGoForward)")
        appState.goBack()
        appState.goForward()
        log.append("history: back, forward -> \(String(describing: appState.selectedSidebarItem))")
        appState.selectedSidebarItem = .ports
        try? await Task.sleep(for: .seconds(4))
        var fields: [String] = []
        func walk(_ v: NSView) {
            if let f = v as? NSSearchField { fields.append("\(type(of: f)) vis=\(f.visibleRect.size) claimable=\(SearchFocusClaim.isVisible(f))") }
            v.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
        log.append("search fields: \(fields)")
        appState.focusSearch()
        try? await Task.sleep(for: .seconds(0.5))
        log.append("⌘F on Ports: firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) })) in search field=\(isInSearchField(window))")
        appState.selectedSidebarItem = .smartScan
        try? await Task.sleep(for: .seconds(1))
        window.makeFirstResponder(nil)
        appState.focusSearch()
        try? await Task.sleep(for: .seconds(0.5))
        log.append("⌘F on Overview: in search field=\(isInSearchField(window)) sidebar=\((window.firstResponder as? NSView).map { $0.convert($0.bounds, to: nil).minX < 400 } ?? false)")
        window.makeFirstResponder(nil)
        log.append("styleMask miniaturizable=\(mask.contains(.miniaturizable)) resizable=\(mask.contains(.resizable)) closable=\(mask.contains(.closable)) titled=\(mask.contains(.titled))")
        log.append("collectionBehavior fullScreenPrimary=\(window.collectionBehavior.contains(.fullScreenPrimary)) fullScreenNone=\(window.collectionBehavior.contains(.fullScreenNone))")
        log.append("buttons: min enabled=\(window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false) zoom enabled=\(window.standardWindowButton(.zoomButton)?.isEnabled ?? false)")
        log.append("frameAutosaveName='\(window.frameAutosaveName)' isRestorable=\(window.isRestorable) minSize=\(window.minSize) contentMinSize=\(window.contentMinSize)")
        log.append("activationPolicy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) key=\(window.isKeyWindow) collection=\(window.collectionBehavior.rawValue) maxSize=\(window.maxSize) contentMax=\(window.contentMaxSize) title='\(window.title)' excludedFromWindowsMenu=\(window.isExcludedFromWindowsMenu) delegate=\(String(describing: window.delegate.map { type(of: $0) })) class=\(type(of: window))")
        for menu in NSApp.mainMenu?.items ?? [] {
            let items = (menu.submenu?.items ?? []).map { item in
                item.isSeparatorItem ? "—" : "\(item.title)[\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(item.keyEquivalent)]"
            }
            log.append("MENU \(menu.title): \(items.joined(separator: ", "))")
        }
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2.5))
        log.append("after toggleFullScreen: fullScreen=\(window.styleMask.contains(.fullScreen))")
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); try? await Task.sleep(for: .seconds(2.5)) }
        let deminiObserver = NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { _ in
            log2.append("didDeminiaturize at \(Date().timeIntervalSince1970)")
        }
        defer { NotificationCenter.default.removeObserver(deminiObserver) }
        window.performMiniaturize(nil)
        var trace0: [String] = []
        for i in 0..<16 {
            try? await Task.sleep(for: .seconds(0.25))
            trace0.append("\(i):\(window.isMiniaturized ? "M" : "-")")
        }
        log.append("performMiniaturize trace: \(trace0.joined(separator: " ")) events=\(log2)")
        log.append("after performMiniaturize: isMiniaturized=\(window.isMiniaturized)")
        window.deminiaturize(nil)
        try? await Task.sleep(for: .seconds(1.5))
        log.append("after deminiaturize: isMiniaturized=\(window.isMiniaturized) visible=\(window.isVisible)")
        window.miniaturize(nil)
        var trace: [String] = []
        for i in 0..<16 {
            try? await Task.sleep(for: .seconds(0.25))
            trace.append("\(i):\(window.isMiniaturized ? "M" : "-")")
        }
        log.append("miniaturize trace: \(trace.joined(separator: " "))")
        log.append("after miniaturize: isMiniaturized=\(window.isMiniaturized) shouldMin=\(String(describing: window.delegate?.windowShouldZoom))")
        window.deminiaturize(nil)
        try? await Task.sleep(for: .seconds(1))
        let before = window.frame
        window.performZoom(nil)
        try? await Task.sleep(for: .seconds(1))
        log.append("zoom: \(before) -> \(window.frame)")
        window.performZoom(nil)
        try? await Task.sleep(for: .seconds(1))
        try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        window.performClose(nil)
        try? await Task.sleep(for: .seconds(1))
        log.append("after performClose: main window visible=\(mainWindow()?.isVisible ?? false)")
        // Simulate a Dock click: send ourselves the "reopen" Apple Event.
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: [.noReply], timeout: 2)
        try? await Task.sleep(for: .seconds(2))
        log.append("after reopen event: main window visible=\(mainWindow()?.isVisible ?? false)")
        try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

// MARK: - Done screen footer

/// Under every "cleaned" screen: Undo the clean just done, or open Cleanup
/// History to restore an older one.
struct DoneScreenFooter: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 16) {
            if appState.lastUndoableClean != nil {
                Button {
                    appState.undoLastClean()
                } label: {
                    Label(KMR.t("Annulla pulizia", "Undo Cleanup"), systemImage: "arrow.uturn.backward")
                }
                .help(KMR.t("Rimetti tutto dov'era (⌘Z)", "Put everything back where it was (⌘Z)"))
            }
            Button {
                appState.selectedSidebarItem = .cleanHistory
            } label: {
                Label(KMR.t("Cronologia pulizia", "Cleanup History"), systemImage: "clock.arrow.circlepath")
            }
            .help(KMR.t("Ripristina una pulizia precedente", "Restore an earlier cleanup"))
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}

extension Array where Element == ScanResult {
    /// Remaining results and selection after a clean removed `removed`.
    func afterClean(removed: Set<URL>, selection: Set<URL>) -> (results: [ScanResult], selection: Set<URL>) {
        let left = removing(removed)
        let remaining = Set(left.lazy.flatMap(\.items).map(\.url))
        return (left, selection.intersection(remaining))
    }
}

// MARK: - Esc closes sheets

extension View {
    /// Esc (Cancel) runs `action`: for sheets whose only button is "Done"
    /// (the default button keeps Return).
    func escapeKeyAction(_ action: @escaping () -> Void) -> some View {
        background {
            Button(KMR.t("Chiudi", "Close"), action: action)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
