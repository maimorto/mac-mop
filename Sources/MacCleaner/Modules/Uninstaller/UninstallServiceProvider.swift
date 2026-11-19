import AppKit

/// Finder right-click › Services › "Uninstall with Mac Mop" (NSServices entry
/// in Info.plist, NSMessage `uninstallApp`). Opens the Uninstaller with the
/// chosen app selected, the same path as dropping an .app on the window.
///
/// A service request can arrive before the SwiftUI scene exists (the app was
/// launched by the service), so the path waits until `attach` connects it.
@MainActor
final class UninstallServiceProvider: NSObject {
    static let shared = UninstallServiceProvider()

    private var handler: ((String) -> Void)?
    private var pending: String?

    func attach(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        if let pending {
            self.pending = nil
            handler(pending)
        }
    }

    @objc func uninstallApp(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let app = urls.first(where: { $0.pathExtension == "app" }) else {
            error.pointee = "No application selected" as NSString
            return
        }
        let path = app.path(percentEncoded: false)
        NSApp.activate(ignoringOtherApps: true)
        if let handler { handler(path) } else { pending = path }
    }
}
