import Foundation

/// Plain-language trust information for an installed app ("who made this,
/// did Apple check it, what can it access"). The app target collects the raw
/// facts (code signature, spctl, xattrs); everything here is pure mapping so
/// it is testable.
public enum AppSigner: Hashable, Sendable {
    case apple
    case appStore
    case developerID(teamName: String?, teamID: String?)
    case adHoc
    case unsigned
    /// Signed, but the signature is broken (modified after signing).
    case invalid

    public var title: String {
        switch self {
        case .apple: UIText.t("Apple", "Apple")
        case .appStore: UIText.t("Mac App Store", "Mac App Store")
        case .developerID(let name, let team):
            switch (name, team) {
            case let (n?, t?): "\(n) (\(t))"
            case let (n?, nil): n
            case let (nil, t?): UIText.t("Sviluppatore \(t)", "Developer \(t)")
            default: UIText.t("Sviluppatore identificato", "Identified developer")
            }
        case .adHoc: UIText.t("Firma locale (ad-hoc)", "Local signature (ad-hoc)")
        case .unsigned: UIText.t("Non firmata", "Unsigned")
        case .invalid: UIText.t("Firma non valida", "Invalid signature")
        }
    }

    public var explanation: String {
        switch self {
        case .apple: UIText.t("Fa parte di macOS o è un'app di Apple.", "Part of macOS or an Apple app.")
        case .appStore: UIText.t("Scaricata dal Mac App Store: controllata da Apple e in sandbox.",
                                 "Downloaded from the Mac App Store: reviewed by Apple and sandboxed.")
        case .developerID: UIText.t("Firmata con un certificato Developer ID rilasciato da Apple allo sviluppatore.",
                                    "Signed with a Developer ID certificate Apple issued to the developer.")
        case .adHoc: UIText.t("Firmata solo localmente: nessun certificato identifica chi l'ha creata. Normale per app compilate in proprio.",
                              "Signed locally only: no certificate identifies who made it. Normal for self-built apps.")
        case .unsigned: UIText.t("Nessuna firma: non si può sapere chi l'ha creata né se è stata modificata.",
                                 "No signature: there is no way to know who made it or whether it was modified.")
        case .invalid: UIText.t("La firma non corrisponde più al contenuto: l'app è stata modificata dopo la firma.",
                                "The signature no longer matches the contents: the app was modified after signing.")
        }
    }

    /// Classify from the leaf certificate's subject (e.g. "Developer ID
    /// Application: Google LLC (EQHXZ8M8AV)") and signature flags.
    public static func classify(
        isSigned: Bool,
        isValid: Bool,
        isAdHoc: Bool,
        leafCommonName: String?,
        teamID: String?
    ) -> AppSigner {
        guard isSigned else { return .unsigned }
        if isAdHoc { return .adHoc }
        guard isValid else { return .invalid }
        let leaf = leafCommonName ?? ""
        if leaf == "Apple Mac OS Application Signing" || leaf.hasPrefix("Apple Mac OS Application Signing") {
            return .appStore
        }
        if leaf == "Software Signing" || leaf.hasPrefix("macOS Software Signing") || leaf.hasPrefix("Apple Code Signing") {
            return .apple
        }
        if let range = leaf.range(of: "Developer ID Application: ") {
            var name = String(leaf[range.upperBound...])
            var team = teamID
            if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
                let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
                if team == nil { team = String(inner) }
                name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
            }
            return .developerID(teamName: name.isEmpty ? nil : name, teamID: team)
        }
        return .developerID(teamName: leaf.isEmpty ? nil : leaf, teamID: teamID)
    }
}

/// Outcome of a Gatekeeper assessment (`spctl -a -vv -t exec`).
public struct GatekeeperAssessment: Hashable, Sendable {
    public var accepted: Bool
    /// "Notarized Developer ID", "Mac App Store", "Apple System", "Unnotarized Developer ID", "no usable signature"…
    public var source: String?
    public var origin: String?

    public init(accepted: Bool, source: String?, origin: String?) {
        self.accepted = accepted
        self.source = source
        self.origin = origin
    }

    public var isNotarized: Bool {
        guard let source else { return false }
        return source == "Notarized Developer ID" || source == "Mac App Store" || source == "Apple System"
            || source.hasPrefix("Notarized")
    }

    /// Parse the combined stdout/stderr of `spctl -a -vv -t exec <path>`.
    public static func parse(_ output: String) -> GatekeeperAssessment? {
        var accepted: Bool?
        var source: String?
        var origin: String?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(": accepted") { accepted = true }
            else if line.hasSuffix(": rejected") || line.contains(": rejected (") { accepted = false }
            else if line.hasPrefix("source=") { source = String(line.dropFirst("source=".count)) }
            else if line.hasPrefix("origin=") { origin = String(line.dropFirst("origin=".count)) }
        }
        guard let accepted else { return nil }
        return GatekeeperAssessment(accepted: accepted, source: source, origin: origin)
    }
}

/// Where a downloaded app came from (com.apple.quarantine + kMDItemWhereFroms).
public struct QuarantineOrigin: Hashable, Sendable {
    public var agent: String?
    public var date: Date?
    public var whereFroms: [String]
    /// Whether the user already approved the first launch (flag 0x0040).
    public var userApproved: Bool

    public init(agent: String?, date: Date?, whereFroms: [String], userApproved: Bool) {
        self.agent = agent
        self.date = date
        self.whereFroms = whereFroms
        self.userApproved = userApproved
    }

    /// Parse the xattr value "0083;5f3c1a2b;Safari;UUID".
    public static func parse(quarantine: String, whereFroms: [String] = []) -> QuarantineOrigin? {
        let parts = quarantine.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let flags = UInt32(parts[0], radix: 16) else { return nil }
        let date = UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let agent = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
        return QuarantineOrigin(agent: agent, date: date, whereFroms: whereFroms, userApproved: flags & 0x40 != 0)
    }

    /// The download page host, the most useful single line ("github.com").
    public var sourceHost: String? {
        for s in whereFroms {
            if let host = URL(string: s)?.host, !host.isEmpty { return host }
        }
        return nil
    }
}

public enum AppArchitecture: String, Sendable {
    case appleSilicon, intel, universal, unknown

    public var title: String {
        switch self {
        case .appleSilicon: UIText.t("Apple Silicon", "Apple Silicon")
        case .intel: UIText.t("Intel (usa Rosetta)", "Intel (uses Rosetta)")
        case .universal: UIText.t("Universale (Apple Silicon + Intel)", "Universal (Apple Silicon + Intel)")
        case .unknown: UIText.t("Sconosciuta", "Unknown")
        }
    }

    public static func from(hasARM64: Bool, hasX86_64: Bool) -> AppArchitecture {
        switch (hasARM64, hasX86_64) {
        case (true, true): .universal
        case (true, false): .appleSilicon
        case (false, true): .intel
        default: .unknown
        }
    }
}

/// Privacy-sensitive capabilities an app asks for, from its entitlements and
/// Info.plist usage descriptions. "Asks for" — macOS still asks the user.
public enum AppCapability: String, CaseIterable, Sendable, Identifiable {
    case camera, microphone, location, contacts, calendars, reminders, photos
    case bluetooth, localNetwork, appleEvents, screenCapture, accessibility
    case fullDiskAccess, desktopFolder, documentsFolder, downloadsFolder, removableVolumes
    case speechRecognition, homeKit, motion
    case network, userSelectedFiles

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .camera: UIText.t("Fotocamera", "Camera")
        case .microphone: UIText.t("Microfono", "Microphone")
        case .location: UIText.t("Posizione", "Location")
        case .contacts: UIText.t("Contatti", "Contacts")
        case .calendars: UIText.t("Calendari", "Calendars")
        case .reminders: UIText.t("Promemoria", "Reminders")
        case .photos: UIText.t("Foto", "Photos")
        case .bluetooth: UIText.t("Bluetooth", "Bluetooth")
        case .localNetwork: UIText.t("Rete locale", "Local network")
        case .appleEvents: UIText.t("Controllo di altre app (Apple Events)", "Control other apps (Apple Events)")
        case .screenCapture: UIText.t("Registrazione schermo", "Screen recording")
        case .accessibility: UIText.t("Accessibilità (controllo del Mac)", "Accessibility (control the Mac)")
        case .fullDiskAccess: UIText.t("Accesso completo al disco", "Full Disk Access")
        case .desktopFolder: UIText.t("Cartella Scrivania", "Desktop folder")
        case .documentsFolder: UIText.t("Cartella Documenti", "Documents folder")
        case .downloadsFolder: UIText.t("Cartella Download", "Downloads folder")
        case .removableVolumes: UIText.t("Dischi esterni", "External disks")
        case .speechRecognition: UIText.t("Riconoscimento vocale", "Speech recognition")
        case .homeKit: UIText.t("Casa (HomeKit)", "Home (HomeKit)")
        case .motion: UIText.t("Movimento", "Motion")
        case .network: UIText.t("Connessioni a Internet", "Internet connections")
        case .userSelectedFiles: UIText.t("File che scegli tu", "Files you choose")
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .contacts: "person.crop.circle.fill"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .photos: "photo.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .localNetwork: "network"
        case .appleEvents: "applescript.fill"
        case .screenCapture: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .fullDiskAccess: "internaldrive.fill"
        case .desktopFolder: "menubar.dock.rectangle"
        case .documentsFolder: "doc.fill"
        case .downloadsFolder: "arrow.down.circle.fill"
        case .removableVolumes: "externaldrive.fill"
        case .speechRecognition: "waveform"
        case .homeKit: "house.fill"
        case .motion: "figure.walk"
        case .network: "globe"
        case .userSelectedFiles: "folder.fill"
        }
    }

    /// Sensitive ones are shown first and highlighted.
    public var isSensitive: Bool {
        switch self {
        case .network, .userSelectedFiles: false
        default: true
        }
    }

    static let entitlementMap: [String: AppCapability] = [
        "com.apple.security.device.camera": .camera,
        "com.apple.security.device.audio-input": .microphone,
        "com.apple.security.device.microphone": .microphone,
        "com.apple.security.personal-information.location": .location,
        "com.apple.security.personal-information.addressbook": .contacts,
        "com.apple.security.personal-information.calendars": .calendars,
        "com.apple.security.personal-information.photos-library": .photos,
        "com.apple.security.device.bluetooth": .bluetooth,
        "com.apple.security.automation.apple-events": .appleEvents,
        "com.apple.security.files.downloads.read-only": .downloadsFolder,
        "com.apple.security.files.downloads.read-write": .downloadsFolder,
        "com.apple.security.files.user-selected.read-only": .userSelectedFiles,
        "com.apple.security.files.user-selected.read-write": .userSelectedFiles,
        "com.apple.security.network.client": .network,
        "com.apple.security.network.server": .network,
        "com.apple.developer.homekit": .homeKit,
    ]

    static let usageKeyMap: [String: AppCapability] = [
        "NSCameraUsageDescription": .camera,
        "NSMicrophoneUsageDescription": .microphone,
        "NSLocationUsageDescription": .location,
        "NSLocationWhenInUseUsageDescription": .location,
        "NSLocationAlwaysUsageDescription": .location,
        "NSLocationAlwaysAndWhenInUseUsageDescription": .location,
        "NSContactsUsageDescription": .contacts,
        "NSCalendarsUsageDescription": .calendars,
        "NSCalendarsFullAccessUsageDescription": .calendars,
        "NSCalendarsWriteOnlyAccessUsageDescription": .calendars,
        "NSRemindersUsageDescription": .reminders,
        "NSRemindersFullAccessUsageDescription": .reminders,
        "NSPhotoLibraryUsageDescription": .photos,
        "NSPhotoLibraryAddUsageDescription": .photos,
        "NSBluetoothAlwaysUsageDescription": .bluetooth,
        "NSBluetoothPeripheralUsageDescription": .bluetooth,
        "NSLocalNetworkUsageDescription": .localNetwork,
        "NSAppleEventsUsageDescription": .appleEvents,
        "NSScreenCaptureUsageDescription": .screenCapture,
        "NSDesktopFolderUsageDescription": .desktopFolder,
        "NSDocumentsFolderUsageDescription": .documentsFolder,
        "NSDownloadsFolderUsageDescription": .downloadsFolder,
        "NSRemovableVolumesUsageDescription": .removableVolumes,
        "NSSpeechRecognitionUsageDescription": .speechRecognition,
        "NSHomeKitUsageDescription": .homeKit,
        "NSMotionUsageDescription": .motion,
    ]

    /// Capabilities requested, sensitive first, in declaration order.
    public static func requested(entitlementKeys: some Sequence<String>, infoPlistKeys: some Sequence<String>) -> [AppCapability] {
        var found = Set<AppCapability>()
        for key in entitlementKeys { if let c = entitlementMap[key] { found.insert(c) } }
        for key in infoPlistKeys { if let c = usageKeyMap[key] { found.insert(c) } }
        return allCases.filter(found.contains).sorted { $0.isSensitive && !$1.isSensitive }
    }
}

/// Overall verdict shown as a badge at the top of the trust panel.
public enum AppTrustVerdict: Sendable, Equatable {
    case trusted, review, warning

    public var title: String {
        switch self {
        case .trusted: UIText.t("Affidabile", "Trusted")
        case .review: UIText.t("Da verificare", "Review")
        case .warning: UIText.t("Attenzione", "Warning")
        }
    }
}

public struct AppTrustReport: Sendable, Equatable {
    public var signer: AppSigner
    public var gatekeeper: GatekeeperAssessment?
    public var hasStapledTicket: Bool
    public var isRevoked: Bool
    public var hardenedRuntime: Bool
    public var sandboxed: Bool
    public var quarantine: QuarantineOrigin?
    public var architecture: AppArchitecture
    public var capabilities: [AppCapability]
    public var lastOpened: Date?
    public var size: UInt64

    public init(signer: AppSigner, gatekeeper: GatekeeperAssessment?, hasStapledTicket: Bool, isRevoked: Bool,
                hardenedRuntime: Bool, sandboxed: Bool, quarantine: QuarantineOrigin?, architecture: AppArchitecture,
                capabilities: [AppCapability], lastOpened: Date?, size: UInt64) {
        self.signer = signer
        self.gatekeeper = gatekeeper
        self.hasStapledTicket = hasStapledTicket
        self.isRevoked = isRevoked
        self.hardenedRuntime = hardenedRuntime
        self.sandboxed = sandboxed
        self.quarantine = quarantine
        self.architecture = architecture
        self.capabilities = capabilities
        self.lastOpened = lastOpened
        self.size = size
    }

    /// Notarized by Apple: Gatekeeper said so, or a ticket is stapled.
    public var isNotarized: Bool {
        if gatekeeper?.isNotarized == true { return true }
        if case .developerID = signer, hasStapledTicket { return true }
        return false
    }

    public var notarizationText: String {
        switch signer {
        case .apple: return UIText.t("Non serve: software Apple", "Not needed: Apple software")
        case .appStore: return UIText.t("Controllata dall'App Store", "Reviewed by the App Store")
        default: break
        }
        if isNotarized {
            return hasStapledTicket ? UIText.t("Sì, con ticket allegato", "Yes, with stapled ticket")
                                    : UIText.t("Sì", "Yes")
        }
        if gatekeeper == nil { return UIText.t("Non verificabile", "Could not check") }
        return UIText.t("No", "No")
    }

    public var verdict: AppTrustVerdict {
        if isRevoked { return .warning }
        switch signer {
        case .invalid, .unsigned: return .warning
        case .adHoc: return .review
        case .apple, .appStore: return .trusted
        case .developerID: return isNotarized ? .trusted : .review
        }
    }

    public var verdictExplanation: String {
        if isRevoked {
            return UIText.t("Apple ha revocato il certificato di questo sviluppatore: di solito succede con software dannoso. Valuta di disinstallarla.",
                            "Apple revoked this developer's certificate: this usually happens with harmful software. Consider uninstalling it.")
        }
        switch verdict {
        case .trusted:
            return UIText.t("Firmata da uno sviluppatore identificato e controllata da Apple.",
                            "Signed by an identified developer and checked by Apple.")
        case .review:
            return UIText.t("Non è stata controllata da Apple. Non significa che sia dannosa: tienila solo se sai da dove viene.",
                            "Apple has not checked it. That does not mean it is harmful: keep it only if you know where it came from.")
        case .warning:
            return UIText.t("La firma manca o è stata alterata: non si può sapere chi l'ha creata.",
                            "The signature is missing or altered: there is no way to know who made it.")
        }
    }
}
