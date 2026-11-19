import Foundation

/// Where macOS keeps the icons the app borrows at runtime (apps, System
/// Settings extensions). Only paths: the images are read from the system when
/// drawn and never copied into the app. Any of them can be missing on another
/// macOS version, so callers always provide fallbacks.
public enum SystemIconPaths {
    public static let extensions = "/System/Library/ExtensionKit/Extensions/"
    public static let utilities = "/System/Applications/Utilities/"
    public static let apps = "/System/Applications/"
    public static let coreServices = "/System/Library/CoreServices/"

    public static let systemInformation = utilities + "System Information.app"
    public static let diskUtility = utilities + "Disk Utility.app"
    public static let activityMonitor = utilities + "Activity Monitor.app"
    public static let terminal = utilities + "Terminal.app"
    public static let appsApp = apps + "Apps.app"
    public static let appStore = apps + "App Store.app"
    public static let systemSettings = apps + "System Settings.app"
    public static let timeMachine = apps + "Time Machine.app"
    public static let mail = apps + "Mail.app"
    public static let passwords = apps + "Passwords.app"
    public static let siri = apps + "Siri.app"
    public static let finder = coreServices + "Finder.app"
    public static let installer = coreServices + "Installer.app"
    public static let keychain = coreServices + "Applications/Keychain Access.app"
    public static let feedback = coreServices + "Applications/Feedback Assistant.app"
    public static let privacySecurity = extensions + "SecurityPrivacyExtension.appex"
    public static let securityShield = extensions + "SecurityImprovementsExtension.appex"
    public static let wifi = extensions + "Wi-Fi.appex"
    public static let network = extensions + "Network.appex"
    public static let loginItems = extensions + "LoginItems.appex"
    public static let storage = extensions + "Storage.appex"
    public static let general = extensions + "GeneralSettings.appex"
    public static let softwareUpdate = extensions + "SoftwareUpdateSettingsExtension.appex"
    public static let controlCenter = extensions + "ControlCenterSettings.appex"
    public static let notifications = extensions + "NotificationsSettings.appex"
    public static let appearance = extensions + "Appearance.appex"
    public static let sound = extensions + "Sound.appex"
    public static let language = extensions + "Localization.appex"
    public static let profiles = extensions + "ProfilesSettingsExt.appex"

    /// Every path above, for checks.
    public static let all: [String] = [
        systemInformation, diskUtility, activityMonitor, terminal, appsApp, appStore, systemSettings,
        timeMachine, mail, passwords, siri, finder, installer, keychain, feedback, privacySecurity,
        securityShield, wifi, network, loginItems, storage, general, softwareUpdate, controlCenter,
        notifications, appearance, sound, language, profiles,
    ]

    /// First candidate that exists, in order of preference; nil = use the
    /// drawn fallback.
    public static func firstExisting(_ candidates: [String],
                                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        candidates.first(where: exists)
    }
}
