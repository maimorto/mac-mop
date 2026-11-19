import AppKit
import UniformTypeIdentifiers
import MacCleanerKit

/// "Export app list": a plain-text, Brewfile-style list of installed apps
/// (plus `brew bundle dump` when Homebrew is installed) to reinstall them on
/// another Mac. Writes only where the user picks in the save panel.
@MainActor
enum AppListExporter {
    static func export(apps: [AppInfo]) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = KMR.t("Elenco delle app installate. Le righe brew/cask/mas si possono usare con `brew bundle`.",
                              "List of installed apps. The brew/cask/mas lines work with `brew bundle`.")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        var dump = ""
        if let brew {
            let r = await Shell.run(brew, ["bundle", "dump", "--file=-"], timeout: 90)
            if r.status == 0 { dump = r.output }
        }
        let text = render(apps: apps, brewDump: dump, date: Date())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    nonisolated static func render(apps: [AppInfo], brewDump: String, date: Date) -> String {
        var lines = ["# \(MCConstants.appName) — \(date.formatted(date: .abbreviated, time: .shortened))", ""]
        if !brewDump.isEmpty {
            lines.append("# Homebrew (brew bundle dump)")
            lines.append(brewDump.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        lines.append("# Apps in /Applications and ~/Applications")
        for app in apps where !app.isAppleApp {
            let version = app.version.map { " \($0)" } ?? ""
            lines.append("# \(app.name)\(version) — \(app.bundleIdentifier) — \(app.path.path(percentEncoded: false))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
