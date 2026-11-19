import Foundation
import Security

/// Reads who signed a program or bundle, for the launch-items inventory:
/// Apple / Mac App Store / Developer ID (with the team's name) / ad-hoc /
/// unsigned / revoked, plus notarization. Results are cached per path.
public enum PersistenceCodeSigning {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: PersistenceSignature] = [:]
    }
    private static let cache = Cache()

    public static func signature(of url: URL) -> PersistenceSignature {
        let path = url.path(percentEncoded: false)
        if let cached = cache.lock.withLock({ cache.values[path] }) { return cached }
        let result = compute(url)
        cache.lock.withLock { cache.values[path] = result }
        return result
    }

    /// errSecCertificateRevoked and CSSMERR_TP_CERT_REVOKED.
    static let revokedStatuses: Set<OSStatus> = [errSecCertificateRevoked, -2147409652]

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String, flags: SecCSFlags = []) -> Bool {
        guard let req = requirement(text) else { return false }
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    private static func compute(_ url: URL) -> PersistenceSignature {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return PersistenceSignature(kind: .missing) }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return PersistenceSignature(kind: .unsigned)
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] != nil else {
            return PersistenceSignature(kind: .unsigned)
        }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return PersistenceSignature(kind: .adHoc) }

        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        var teamName: String?
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            teamName = PersistenceSignature.teamName(fromCertificateSummary: summary)
        }

        // Structural validity first (no network); then the revocation check
        // tells a revoked Developer ID apart from a merely invalid file.
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            // Signed, but the files changed afterwards (cracked, patched or
            // damaged).
            return PersistenceSignature(kind: .modified, teamID: team, teamName: teamName)
        }
        if satisfies(code, "anchor apple") {
            return PersistenceSignature(kind: .apple, teamName: "Apple", notarized: nil)
        }
        let appStore = satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
        let developerID = satisfies(code, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                                    + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
        guard appStore || developerID else {
            // An Apple-issued development certificate, or a self-made one.
            let development = satisfies(code, "anchor apple generic")
            return PersistenceSignature(kind: development ? .development : .unsigned, teamID: team, teamName: teamName)
        }
        // Only a definite "revoked" answer counts: offline, the check fails
        // with other codes and must not turn a good app into a suspect.
        if developerID {
            let status = SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures).union(.enforceRevocationChecks), nil)
            if revokedStatuses.contains(status) {
                return PersistenceSignature(kind: .revoked, teamID: team, teamName: teamName)
            }
        }
        let notarized = appStore ? nil : satisfies(code, "notarized")
        return PersistenceSignature(kind: appStore ? .appStore : .developerID, teamID: team,
                                    teamName: appStore ? nil : teamName, notarized: notarized)
    }
}
