import Foundation
import Security
import CoreServices
import MacCleanerKit

/// Cheap per-app facts for sorting and filtering the app lists: who made it,
/// where it came from, Intel-only, when it was installed and last opened.
/// Read off the main thread, in parallel, and cached per bundle path +
/// modification date, so switching tabs or re-sorting never re-reads them.
struct AppListFacts: Sendable, Hashable {
    var developer: String?
    var source: AppSource
    var isIntelOnly: Bool
    var installed: Date?
    var lastUsed: Date?
}

actor AppListFactsStore {
    static let shared = AppListFactsStore()

    private struct Entry { let modified: Date?; let facts: AppListFacts }
    private var cache: [String: Entry] = [:]

    /// Facts for every path (bundle paths), computed concurrently.
    func facts(for paths: [String]) async -> [String: AppListFacts] {
        var result: [String: AppListFacts] = [:]
        var missing: [(String, Date?)] = []
        for path in paths {
            let modified = Self.modificationDate(path)
            if let hit = cache[path], hit.modified == modified {
                result[path] = hit.facts
            } else {
                missing.append((path, modified))
            }
        }
        guard !missing.isEmpty else { return result }

        let computed = await withTaskGroup(of: (String, Date?, AppListFacts).self) { group in
            var out: [(String, Date?, AppListFacts)] = []
            var iterator = missing.makeIterator()
            // Bounded parallelism: signature + Spotlight reads are I/O-ish.
            for _ in 0..<min(6, missing.count) {
                if let (path, modified) = iterator.next() {
                    group.addTask(priority: .utility) { (path, modified, Self.read(path)) }
                }
            }
            while let value = await group.next() {
                out.append(value)
                if let (path, modified) = iterator.next() {
                    group.addTask(priority: .utility) { (path, modified, Self.read(path)) }
                }
            }
            return out
        }
        for (path, modified, facts) in computed {
            cache[path] = Entry(modified: modified, facts: facts)
            result[path] = facts
        }
        return result
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? URL(filePath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Reading

    nonisolated static func read(_ path: String) -> AppListFacts {
        let url = URL(filePath: path)
        let plist = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let hasReceipt = FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path(percentEncoded: false))

        let signing = signer(url)
        let source = AppSource.from(signer: signing.signer, hasAppStoreReceipt: hasReceipt, bundleIdentifier: bundleID)
        var developer: String?
        switch signing.signer {
        case .developerID(let name, _)?: developer = name
        case .apple?: developer = bundleID.hasPrefix("com.apple.") ? "Apple" : nil
        default: break
        }
        if developer == nil {
            developer = AppDeveloperName.fromCopyright(plist["NSHumanReadableCopyright"] as? String)
        }

        var intelOnly = false
        if let archs = Bundle(url: url)?.executableArchitectures?.map(\.intValue), !archs.isEmpty {
            intelOnly = archs.contains(NSBundleExecutableArchitectureX86_64) && !archs.contains(NSBundleExecutableArchitectureARM64)
        }

        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        var lastUsed: Date?
        var added: Date?
        if let item = MDItemCreate(nil, path as CFString) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        }
        return AppListFacts(developer: developer, source: source, isIntelOnly: intelOnly,
                            installed: added ?? values?.addedToDirectoryDate ?? values?.creationDate,
                            lastUsed: lastUsed)
    }

    /// Reads the signature blob only (no hashing of the bundle, so it stays
    /// fast for multi-GB apps); validity is the Trust tab's job.
    nonisolated static func signer(_ url: URL) -> (signer: AppSigner?, teamID: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, nil) }
        guard dict[kSecCodeInfoIdentifier as String] != nil else {
            return (.unsigned, nil)
        }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        var leaf: String?
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first {
            leaf = SecCertificateCopySubjectSummary(first) as String?
        }
        let signer = AppSigner.classify(isSigned: true, isValid: true, isAdHoc: isAdHoc, leafCommonName: leaf, teamID: team)
        return (signer, team)
    }
}

extension AppListEntry {
    /// Entry for an Uninstaller row.
    init(app: AppInfo, facts: AppListFacts?) {
        self.init(id: app.path.path(percentEncoded: false), name: app.name, bundleIdentifier: app.bundleIdentifier,
                  developer: facts?.developer, bytes: app.size, lastUsed: facts?.lastUsed, installed: facts?.installed,
                  source: facts?.source ?? (app.isAppleApp ? .apple : .unknown),
                  isIntelOnly: facts?.isIntelOnly ?? false, isApple: app.isAppleApp)
    }

    /// Entry for an Unused Apps row (size = app + support files).
    init(record: UnusedAppRecord, facts: AppListFacts?) {
        self.init(id: record.path, name: record.name, bundleIdentifier: record.bundleIdentifier,
                  developer: facts?.developer, bytes: record.totalBytes, lastUsed: record.lastUsed ?? facts?.lastUsed,
                  installed: facts?.installed, source: facts?.source ?? (record.isApple ? .apple : .unknown),
                  isIntelOnly: facts?.isIntelOnly ?? false, isApple: record.isApple)
    }
}
