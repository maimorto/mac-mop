import SwiftUI
import AppKit
import MacCleanerKit

// MARK: - Design language
//
// Follow the system, do not imitate it: grouped Forms, standard controls,
// semantic colours and text styles, the user's accent colour, SF Symbols.
// Custom drawing is limited to what AppKit/SwiftUI do not provide (icon
// tiles like System Settings, the storage bar, a progress ring).

enum KMR {
    /// The user's accent colour (System Settings › Appearance).
    static let accent = Color.accentColor
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let purple = Color(nsColor: .systemPurple)
    static let gray = Color(nsColor: .systemGray)
    static let cornerRadius: CGFloat = 12

    /// Italian / English pair for the strings added by this fork.
    /// UI string in the current language (13 languages; see UIText).
    static func t(_ italian: String, _ english: String) -> String { UIText.t(italian, english) }
}

extension SidebarItem: @unchecked Sendable {}

private struct CurrentModuleKey: EnvironmentKey {
    static let defaultValue: SidebarItem? = nil
}

extension EnvironmentValues {
    var currentModule: SidebarItem? {
        get { self[CurrentModuleKey.self] }
        set { self[CurrentModuleKey.self] = newValue }
    }
}

// MARK: - Icon tiles (System Settings style)

extension SidebarItem {
    /// Filled glyph shown on the tile.
    var tileSymbol: String {
        switch self {
        case .smartScan: "house.fill"
        case .systemJunk: "sparkles"
        case .mailAttachments: "paperclip"
        case .trashBins: "trash.fill"
        case .diskHogs: "hammer.fill"
        case .projectJunk: "shippingbox.fill"
        case .cleanHistory: "clock.arrow.circlepath"
        case .malwareRemoval: "ladybug.fill"
        case .privacy: "hand.raised.fill"
        case .wifiNetworks: "wifi"
        case .appPermissions: "lock.fill"
        case .browserExtensions: "puzzlepiece.extension.fill"
        case .optimization: "gauge.with.dots.needle.67percent"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .uninstaller: "xmark.app.fill"
        case .unusedApps: "moon.zzz.fill"
        case .extensions: "puzzlepiece.fill"
        case .updater: "arrow.triangle.2.circlepath"
        case .spaceLens: "chart.pie.fill"
        case .largeOldFiles: "doc.fill"
        case .duplicates: "doc.on.doc.fill"
        case .shredder: "scissors"
        case .storageExtras: "externaldrive.fill.badge.plus"
        case .ports: "network"
        case .packages: "shippingbox.fill"
        case .applePrivacy: "eye.slash.fill"
        case .securityCheck: "checkmark.shield.fill"
        case .persistence: "bolt.badge.clock.fill"
        case .systemData: "internaldrive.fill"
        case .settings: "gearshape.fill"
        }
    }

    var tileColor: Color {
        let c: NSColor = switch self {
        case .smartScan: .systemBlue
        case .systemJunk: .systemOrange
        case .mailAttachments: .systemBlue
        case .trashBins: .systemGray
        case .diskHogs: .systemIndigo
        case .projectJunk: .systemBrown
        case .cleanHistory: .systemGreen
        case .malwareRemoval: .systemRed
        case .privacy: .systemBlue
        case .wifiNetworks: .systemBlue
        case .appPermissions: .systemGray
        case .browserExtensions: .systemPurple
        case .optimization: .systemOrange
        case .maintenance: .systemGray
        case .uninstaller: .systemRed
        case .unusedApps: .systemIndigo
        case .extensions: .systemTeal
        case .updater: .systemGreen
        case .spaceLens: .systemPurple
        case .largeOldFiles: .systemOrange
        case .duplicates: .systemTeal
        case .shredder: .systemPink
        case .storageExtras: .systemIndigo
        case .ports: .systemTeal
        case .packages: .systemBrown
        case .applePrivacy: .systemBlue
        case .securityCheck: .systemGreen
        case .persistence: .systemOrange
        case .systemData: .systemGray
        case .settings: .systemGray
        }
        return Color(nsColor: c)
    }

    var displayTitle: String {
        switch self {
        case .smartScan: KMR.t("Panoramica", "Overview")
        case .storageExtras: KMR.t("Spazio extra", "Extra space")
        case .ports: KMR.t("Porte di rete", "Network ports")
        case .packages: KMR.t("Pacchetti installati", "Installed packages")
        case .applePrivacy: KMR.t("Privacy Apple", "Apple privacy")
        case .securityCheck: KMR.t("Controllo sicurezza", "Security check")
        case .persistence: KMR.t("Avvio automatico", "Launch items")
        case .systemData: KMR.t("Dati di sistema", "System Data")
        default: title
        }
    }
}

/// White glyph on a coloured rounded square, like System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.56, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Surfaces and buttons

extension View {
    /// Tinted capsule for the module action pills: system glass on Tahoe.
    @ViewBuilder
    func kmrGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .capsule)
        } else {
            self.background(tint ?? Color(nsColor: .controlColor), in: Capsule())
        }
    }

    /// Grouped container for inner-page lists: hides the list's own opaque
    /// background so the system grouped fill shows, like a Settings section.
    func kmrGroupedBox() -> some View {
        self.scrollContentBackground(.hidden)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Grouped-box surface, same fill the system uses for grouped content.
    func kmrCard(padding: CGFloat = 16, radius: CGFloat = KMR.cornerRadius) -> some View {
        self.padding(padding)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func glassPanel(cornerRadius: CGFloat = KMR.cornerRadius) -> some View {
        kmrCard(padding: 0, radius: cornerRadius)
    }
}

struct OptionalGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.kmrCard(padding: 0) }
        else { content.clipShape(RoundedRectangle(cornerRadius: KMR.cornerRadius)) }
    }
}

// MARK: - Module symbol (empty-state style)

/// Empty-state icon: the module's macOS system icon (64 pt, like the panes of
/// System Settings), or a large hierarchical symbol when one is forced.
struct ModuleHero: View {
    let theme: ModuleTheme
    var symbol: String? = nil
    var size: CGFloat = 120
    var energized: Bool = false

    @Environment(\.currentModule) private var module

    var body: some View {
        if symbol == nil, let module {
            ModuleIcon(item: module, size: 64)
        } else {
            Image(systemName: symbol ?? module?.tileSymbol ?? "sparkles")
                .font(.system(size: 48, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - System hero (System Settings pane header)

/// Header card like the top of a System Settings pane ("General"): big system
/// icon, bold title, one centred line of description. `item` defaults to the
/// module in the environment. Pass `card: false` inside a grouped `Form`
/// section, which already draws the rounded background.
struct SystemHero<Accessory: View>: View {
    var item: SidebarItem? = nil
    var title: String? = nil
    var subtitle: String? = nil
    var card = true
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.currentModule) private var envModule

    var body: some View {
        let module = item ?? envModule
        let line = subtitle ?? module?.heroSubtitle ?? ""
        VStack(spacing: 6) {
            Group {
                if let module { ModuleIcon(item: module, size: 64) }
                else { SystemIconView(sources: [.named(NSImage.applicationIconName)], symbol: "sparkles", color: KMR.accent, size: 64) }
            }
            .padding(.bottom, 4)
            Text(title ?? module?.displayTitle ?? "")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if !line.isEmpty {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            accessory()
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, card ? 22 : 8)
        .padding(.horizontal, card ? 20 : 0)
        .background {
            if card {
                RoundedRectangle(cornerRadius: KMR.cornerRadius, style: .continuous).fill(.fill.quaternary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension SystemHero where Accessory == EmptyView {
    init(item: SidebarItem? = nil, title: String? = nil, subtitle: String? = nil, card: Bool = true) {
        self.init(item: item, title: title, subtitle: subtitle, card: card) { EmptyView() }
    }
}

// MARK: - System icons
//
// Real macOS icons, looked up at runtime from the system (never copied into
// the app): apps, System Settings extensions and named AppKit images. Every
// path is checked; when one is missing (older or newer macOS) the next source
// is tried and finally the coloured IconTile is drawn instead.

enum SystemIconSource: Hashable, Sendable {
    case file(String)
    case named(String)

    static let systemInformation = file(SystemIconPaths.systemInformation)
    static let diskUtility = file(SystemIconPaths.diskUtility)
    static let activityMonitor = file(SystemIconPaths.activityMonitor)
    static let terminal = file(SystemIconPaths.terminal)
    static let appsApp = file(SystemIconPaths.appsApp)
    static let appStore = file(SystemIconPaths.appStore)
    static let systemSettings = file(SystemIconPaths.systemSettings)
    static let timeMachine = file(SystemIconPaths.timeMachine)
    static let mail = file(SystemIconPaths.mail)
    static let passwords = file(SystemIconPaths.passwords)
    static let siri = file(SystemIconPaths.siri)
    static let finder = file(SystemIconPaths.finder)
    static let installer = file(SystemIconPaths.installer)
    static let keychain = file(SystemIconPaths.keychain)
    static let feedback = file(SystemIconPaths.feedback)
    static let privacySecurity = file(SystemIconPaths.privacySecurity)
    static let securityShield = file(SystemIconPaths.securityShield)
    static let wifi = file(SystemIconPaths.wifi)
    static let network = file(SystemIconPaths.network)
    static let loginItems = file(SystemIconPaths.loginItems)
    static let storage = file(SystemIconPaths.storage)
    static let general = file(SystemIconPaths.general)
    static let softwareUpdate = file(SystemIconPaths.softwareUpdate)
    static let controlCenter = file(SystemIconPaths.controlCenter)
    static let notifications = file(SystemIconPaths.notifications)
    static let appearance = file(SystemIconPaths.appearance)
    static let sound = file(SystemIconPaths.sound)
    static let language = file(SystemIconPaths.language)
    static let profiles = file(SystemIconPaths.profiles)
    static let trashFull = named(NSImage.trashFullName)
    static let computer = named(NSImage.computerName)
    static let appIcon = named(NSImage.applicationIconName)
}

@MainActor
enum SystemIcons {
    private static var cache: [SystemIconSource: NSImage] = [:]
    private static var missing: Set<SystemIconSource> = []

    /// First source that resolves on this Mac, cached.
    static func image(_ sources: [SystemIconSource]) -> NSImage? {
        for source in sources {
            if let hit = cache[source] { return hit }
            if missing.contains(source) { continue }
            var image: NSImage?
            switch source {
            case .file(let path):
                if FileManager.default.fileExists(atPath: path) { image = NSWorkspace.shared.icon(forFile: path) }
            case .named(let name):
                image = NSImage(named: name)
            }
            if let image {
                cache[source] = image
                return image
            }
            missing.insert(source)
            NSLog("Mac Mop: system icon not found, using fallback: %@", String(describing: source))
        }
        return nil
    }
}

/// A system icon at `size` pt, or the coloured tile when none resolves. App
/// icons keep a transparent margin around their squircle (about 10 % per
/// side), so they are drawn larger than the frame to line up with tiles.
struct SystemIconView: View {
    let sources: [SystemIconSource]
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        if let image = SystemIcons.image(sources) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: size * 1.22, height: size * 1.22)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: symbol, color: color, size: size)
        }
    }
}

/// The module's system icon (falls back to its tile).
struct ModuleIcon: View {
    let item: SidebarItem
    var size: CGFloat = 20
    var body: some View {
        SystemIconView(sources: item.systemIcon, symbol: item.tileSymbol, color: item.tileColor, size: size)
    }
}

extension SidebarItem {
    /// Closest macOS icon for the module, in order of preference. Empty when
    /// no system icon fits; the coloured tile is used then.
    var systemIcon: [SystemIconSource] {
        typealias S = SystemIconSource
        return switch self {
        case .smartScan: [S.systemInformation, S.computer]
        case .systemJunk: [S.storage]
        case .mailAttachments: [S.mail]
        case .trashBins: [S.trashFull]
        case .diskHogs: [S.terminal]
        case .projectJunk: []
        case .cleanHistory: [S.timeMachine]
        case .malwareRemoval: [S.securityShield, S.privacySecurity]
        case .securityCheck: [S.profiles, S.privacySecurity]
        case .persistence: [S.loginItems]
        case .privacy: [S.privacySecurity]
        case .applePrivacy: [S.siri, S.privacySecurity]
        case .browserExtensions: []
        case .wifiNetworks: [S.wifi]
        case .appPermissions: [S.keychain]
        case .optimization: [S.activityMonitor]
        case .maintenance: [S.diskUtility]
        case .ports: [S.network]
        case .uninstaller: [S.appsApp, S.appStore]
        case .unusedApps: []
        case .extensions: []
        case .packages: [S.installer]
        case .updater: [S.softwareUpdate, S.appStore]
        case .spaceLens: [S.diskUtility]
        case .systemData: [S.storage]
        case .storageExtras: []
        case .duplicates: [S.finder]
        case .largeOldFiles: []
        case .shredder: []
        case .settings: [S.systemSettings]
        }
    }

    /// One line under the module name in its hero card.
    var heroSubtitle: String {
        switch self {
        case .smartScan: KMR.t("Lo stato del Mac a colpo d'occhio e una scansione completa.", "Your Mac at a glance, and one scan for everything.")
        case .systemJunk: KMR.t("Cache, log e file temporanei che macOS e le app lasciano indietro.", "Caches, logs and temporary files macOS and apps leave behind.")
        case .mailAttachments: KMR.t("Allegati di Mail già scaricati che occupano spazio.", "Downloaded Mail attachments taking up space.")
        case .trashBins: KMR.t("Il Cestino del Mac e quelli dei dischi esterni.", "The Mac's Trash and the trash on external drives.")
        case .diskHogs: KMR.t("Cache di Xcode, simulatori e strumenti per sviluppatori.", "Xcode caches, simulators and developer tools.")
        case .projectJunk: KMR.t("Cartelle di build e dipendenze di progetti vecchi.", "Build folders and dependencies of old projects.")
        case .cleanHistory: KMR.t("Tutto ciò che è stato pulito, con la possibilità di ripristinarlo.", "Everything that was cleaned, with a way to put it back.")
        case .malwareRemoval: KMR.t("Cerca malware, adware e programmi indesiderati.", "Looks for malware, adware and unwanted software.")
        case .securityCheck: KMR.t("Verifica FileVault, firewall, Gatekeeper e le altre protezioni.", "Checks FileVault, the firewall, Gatekeeper and other protections.")
        case .persistence: KMR.t("Cosa si avvia da solo all'accensione e al login.", "What starts by itself at power-on and login.")
        case .privacy: KMR.t("Cronologia, cookie e tracce dei browser e delle app.", "History, cookies and traces left by browsers and apps.")
        case .applePrivacy: KMR.t("Analisi, pubblicità e suggerimenti che macOS condivide.", "Analytics, ads and suggestions macOS shares.")
        case .browserExtensions: KMR.t("Estensioni installate nei browser e cosa possono fare.", "Extensions installed in your browsers and what they can do.")
        case .wifiNetworks: KMR.t("Reti Wi‑Fi salvate a cui il Mac si collega da solo.", "Saved Wi‑Fi networks your Mac joins by itself.")
        case .appPermissions: KMR.t("Quali app possono usare fotocamera, microfono, file e altro.", "Which apps can use the camera, microphone, files and more.")
        case .optimization: KMR.t("Processi, memoria ed elementi che rallentano il Mac.", "Processes, memory and items that slow your Mac down.")
        case .maintenance: KMR.t("Operazioni di manutenzione che macOS fa di rado.", "Maintenance tasks macOS rarely runs on its own.")
        case .ports: KMR.t("Programmi in ascolto sulla rete e chi può raggiungerli.", "Programs listening on the network and who can reach them.")
        case .uninstaller: KMR.t("Rimuove le app insieme a tutti i file che lasciano.", "Removes apps together with every file they leave behind.")
        case .unusedApps: KMR.t("App che non apri da molto tempo.", "Apps you haven't opened in a long time.")
        case .extensions: KMR.t("Plug-in, widget ed estensioni di sistema installate.", "Installed plug-ins, widgets and system extensions.")
        case .packages: KMR.t("Pacchetti .pkg installati e i file che hanno aggiunto.", "Installed .pkg packages and the files they added.")
        case .updater: KMR.t("Aggiornamenti disponibili per le app installate.", "Available updates for your installed apps.")
        case .spaceLens: KMR.t("Una mappa del disco per vedere cosa occupa spazio.", "A map of your disk to see what takes up space.")
        case .systemData: KMR.t("Cosa c'è davvero dentro \"Dati di sistema\".", "What is really inside \"System Data\".")
        case .storageExtras: KMR.t("Istantanee, immagini Docker e altro spazio nascosto.", "Snapshots, Docker images and other hidden space.")
        case .duplicates: KMR.t("Copie identiche dello stesso file in cartelle diverse.", "Identical copies of the same file in different folders.")
        case .largeOldFiles: KMR.t("File grandi o che non apri da tempo.", "Large files and files you haven't opened in a while.")
        case .shredder: KMR.t("Elimina file in modo che non si possano recuperare.", "Deletes files so they can't be recovered.")
        case .settings: KMR.t("Preferenze di Mac Mop.", "Mac Mop preferences.")
        }
    }
}

extension NavGroup {
    var systemIcon: [SystemIconSource] {
        typealias S = SystemIconSource
        return switch self {
        case .overview: [S.systemInformation, S.computer]
        case .cleanup: [S.trashFull]
        case .spaceLens: [S.diskUtility]
        case .applications: [S.appsApp, S.appStore]
        case .protection: [S.privacySecurity]
        case .performance: [S.activityMonitor]
        case .files: [S.finder]
        case .settings: [S.systemSettings]
        }
    }
}

/// Sidebar / tab icon of a group.
struct GroupIcon: View {
    let group: NavGroup
    var size: CGFloat = 20
    var body: some View {
        SystemIconView(sources: group.systemIcon, symbol: group.symbol, color: group.tint, size: size)
    }
}

// MARK: - Progress ring

struct RadarProgress: View {
    let progress: Double
    let theme: ModuleTheme
    var size: CGFloat = 150

    var body: some View {
        let line = max(5, size * 0.055)
        ZStack {
            Circle().stroke(.fill.tertiary, lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.004, min(progress, 1)))
                .stroke(KMR.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: progress))
        }
        .frame(width: size, height: size)
        .padding(line)
        .animation(.smooth(duration: 0.35), value: progress)
    }
}

// MARK: - Motion
//
// Only state-driven, system-style motion: a blur cross-fade between the
// screens of a module and a single symbol bounce on success.

extension AnyTransition {
    static var immersive: AnyTransition { AnyTransition(.blurReplace) }
}

extension Animation {
    static let immersiveScreen = Animation.smooth(duration: 0.35)
}

struct KMRCelebrate: ViewModifier {
    @State private var fired = false

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .nonRepeating, value: fired)
            .onAppear {
                fired = true
                // One light tap for a finished job; no other haptics anywhere.
                if SoundFX.enabled {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
            }
    }
}

extension View {
    func kmrCelebrate() -> some View { modifier(KMRCelebrate()) }
}

// MARK: - Sounds
//
// The macOS sounds everyone knows, at the system alert volume: Glass when a
// scan finishes, the Finder "empty Trash" sound after a cleanup.

@MainActor
enum SoundFX {
    enum Cue {
        case hover, scanStart, scanDone, cleanDone, nothingFound
    }

    static let settingsKey = "uiSoundsEnabled"
    private static var cache: [String: NSSound] = [:]
    private static var lastPlay: [String: Date] = [:]
    private static let finderSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    private static func sound(for cue: Cue) -> (key: String, make: () -> NSSound?)? {
        switch cue {
        case .hover, .scanStart: nil
        case .scanDone: ("Glass", { NSSound(named: "Glass") })
        case .nothingFound: ("Pop", { NSSound(named: "Pop") })
        case .cleanDone:
            ("empty trash", {
                NSSound(contentsOfFile: finderSounds + "empty trash.aif", byReference: true) ?? NSSound(named: "Hero")
            })
        }
    }

    static func play(_ cue: Cue) {
        guard enabled, let (key, make) = sound(for: cue) else { return }
        let now = Date()
        if let last = lastPlay[key], now.timeIntervalSince(last) < 1.0 { return }
        lastPlay[key] = now
        guard let sound = cache[key] ?? make() else { return }
        cache[key] = sound
        sound.stop()
        sound.play()
    }
}


// MARK: - Success mark

/// Circle and checkmark drawn in sequence, then a single bounce.
struct SuccessMark: View {
    var size: CGFloat = 84
    var color: Color = KMR.green
    @State private var ring: CGFloat = 0
    @State private var tick: CGFloat = 0
    @State private var pop = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
                .scaleEffect(pop ? 1 : 0.6)
            Circle()
                .trim(from: 0, to: ring)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: tick)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.42, height: size * 0.32)
        }
        .frame(width: size, height: size)
        .scaleEffect(pop ? 1 : 0.92)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.35)) { tick = 1 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.55)) { pop = true }
            if SoundFX.enabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
            }
        }
        .accessibilityLabel(KMR.t("Completato", "Done"))
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}


// MARK: - Motion budget

/// Ambient animations stop when the app is in the background, in Low Power
/// Mode or with Reduce Motion.
@MainActor
@Observable
final class MotionBudget {
    static let shared = MotionBudget()
    private(set) var appActive = NSApp?.isActive ?? true
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MotionBudget.shared.appActive = true }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MotionBudget.shared.appActive = false }
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MotionBudget.shared.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    /// Debug aid: KMR_FORCE_MOTION=1 animates even when the app is not
    /// frontmost (snapshots and CPU measurements launched from a terminal).
    private let forced = ProcessInfo.processInfo.environment["KMR_FORCE_MOTION"] == "1"

    func ambientAllowed(reduceMotion: Bool) -> Bool { (appActive || forced) && !lowPower && !reduceMotion }
}


// MARK: - App icon cache

/// Launch Services lookups are slow enough to stutter a list redrawn every
/// second; resolve each bundle id once.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]
    private static var fileCache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let hit = fileCache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        if fileCache.count > 3000 { fileCache.removeAll() }
        fileCache[path] = image
        return image
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
        cache[bundleID] = image
        return image
    }
}
