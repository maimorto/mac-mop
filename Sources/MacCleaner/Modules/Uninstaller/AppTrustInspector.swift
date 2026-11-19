import Foundation
import Security
import CoreServices
import MacCleanerKit

/// Collects the raw trust facts for an app bundle (code signature, Gatekeeper
/// assessment, quarantine origin, entitlements) off the main thread and
/// caches them per bundle path + modification date. Mapping to plain
/// language lives in MacCleanerKit's `AppTrust`.
actor AppTrustInspector {
    static let shared = AppTrustInspector()

    private struct Key: Hashable { let path: String; let modified: Date? }
    private var cache: [Key: AppTrustReport] = [:]

    func report(for app: AppInfo) async -> AppTrustReport {
        let url = app.path
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = Key(path: url.path(percentEncoded: false), modified: modified)
        if let cached = cache[key] { return cached }
        let report = await Self.inspect(url, lastOpened: app.lastOpened, size: app.size)
        cache[key] = report
        return report
    }

    // MARK: - Signature

    struct SigningFacts: Sendable {
        var isSigned = false
        var isValid = false
        var isAdHoc = false
        var isRevoked = false
        var hardenedRuntime = false
        var teamID: String?
        var leafCommonName: String?
        var entitlements: [String: any Sendable] = [:]

        var appGroups: [String] {
            (entitlements["com.apple.security.application-groups"] as? [String]) ?? []
        }
        var sandboxed: Bool { (entitlements["com.apple.security.app-sandbox"] as? Bool) == true }
    }

    /// Signature facts via SecStaticCode (no network unless the revocation
    /// check needs it; the OCSP result is cached by the system).
    nonisolated static func signingFacts(_ url: URL, checkRevocation: Bool = true) -> SigningFacts {
        var facts = SigningFacts()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return facts }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              dict[kSecCodeInfoIdentifier as String] != nil else { return facts }
        facts.isSigned = true
        let csFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        facts.isAdHoc = csFlags & SecCodeSignatureFlags.adhoc.rawValue != 0
        facts.hardenedRuntime = csFlags & SecCodeSignatureFlags.runtime.rawValue != 0
        facts.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            facts.leafCommonName = SecCertificateCopySubjectSummary(leaf) as String?
        }
        if let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            for (k, v) in ent {
                switch v {
                case let b as Bool: facts.entitlements[k] = b
                case let s as String: facts.entitlements[k] = s
                case let a as [String]: facts.entitlements[k] = a
                default: facts.entitlements[k] = true
                }
            }
        }
        let basic = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        facts.isValid = basic == errSecSuccess
        if facts.isValid, !facts.isAdHoc, checkRevocation {
            let status = SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures).union(.enforceRevocationChecks), nil)
            // Only a definite revocation counts; offline/OCSP failures don't.
            facts.isRevoked = status == errSecCSRevokedNotarization
                || status == OSStatus(CSSMERR_TP_CERT_REVOKED)
                || status == errSecCertificateRevoked
        }
        return facts
    }

    // MARK: - Report

    nonisolated static func inspect(_ url: URL, lastOpened: Date?, size: UInt64) async -> AppTrustReport {
        let path = url.path(percentEncoded: false)
        let facts = signingFacts(url)
        let signer = AppSigner.classify(isSigned: facts.isSigned, isValid: facts.isValid, isAdHoc: facts.isAdHoc,
                                        leafCommonName: facts.leafCommonName, teamID: facts.teamID)
        var gatekeeper: GatekeeperAssessment?
        if facts.isSigned, !facts.isAdHoc {
            let r = await Shell.run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", path], timeout: 20)
            gatekeeper = GatekeeperAssessment.parse(r.output)
        }
        // A stapled ticket lives in Contents/CodeResources.
        let stapled = FileManager.default.fileExists(atPath: url.appending(path: "Contents/CodeResources").path(percentEncoded: false))

        let quarantine = xattrString(path, "com.apple.quarantine").flatMap {
            QuarantineOrigin.parse(quarantine: $0, whereFroms: whereFroms(path))
        }

        var arm = false, x86 = false
        if let archs = Bundle(url: url)?.executableArchitectures?.map(\.intValue) {
            arm = archs.contains(NSBundleExecutableArchitectureARM64)
            x86 = archs.contains(NSBundleExecutableArchitectureX86_64)
        }

        let plistKeys = (NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any])?.keys
        let caps = AppCapability.requested(entitlementKeys: facts.entitlements.keys,
                                           infoPlistKeys: plistKeys.map(Array.init) ?? [])

        return AppTrustReport(
            signer: signer, gatekeeper: gatekeeper, hasStapledTicket: stapled, isRevoked: facts.isRevoked,
            hardenedRuntime: facts.hardenedRuntime, sandboxed: facts.sandboxed, quarantine: quarantine,
            architecture: .from(hasARM64: arm, hasX86_64: x86), capabilities: caps,
            lastOpened: lastOpened, size: size)
    }

    nonisolated static func xattrData(_ path: String, _ name: String) -> Data? {
        let len = getxattr(path, name, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }

    nonisolated static func xattrString(_ path: String, _ name: String) -> String? {
        xattrData(path, name).map { String(decoding: $0, as: UTF8.self) }
    }

    /// kMDItemWhereFroms: stored as a binary-plist xattr; falls back to Spotlight.
    nonisolated static func whereFroms(_ path: String) -> [String] {
        if let data = xattrData(path, "com.apple.metadata:kMDItemWhereFroms"),
           let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            return list.filter { !$0.isEmpty }
        }
        if let item = MDItemCreate(nil, path as CFString),
           let list = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] {
            return list.filter { !$0.isEmpty }
        }
        return []
    }
}
