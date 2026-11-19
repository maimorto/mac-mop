import SwiftUI
import AppKit
import ServiceManagement
import MacCleanerKit

/// In-app Settings page rendered in the detail pane. Opened from the
/// pinned sidebar footer, the Cmd-comma "Settings…" menu item, or
/// maccleaner://module/settings.
///
/// Laid out like System Settings: a tab bar picks a pane, every pane is a
/// grouped Form that opens with a hero row, and each row carries a coloured
/// icon tile, a title and at most a short caption.
struct SettingsPageView: View {
    enum UpdateUIState: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(message: String)
    }

    @AppStorage("showMenuBarWidget") private var showMenuBarWidget = true
    @AppStorage(MenuBarMetric.defaultsKey, store: SharedAppState.defaults) private var menuBarMetricRaw = MenuBarMetric.diskFree.rawValue
    @AppStorage("menuItemRAM", store: SharedAppState.defaults) private var menuItemRAM = true
    @AppStorage("menuItemBattery", store: SharedAppState.defaults) private var menuItemBattery = true
    @AppStorage("menuItemNetwork", store: SharedAppState.defaults) private var menuItemNetwork = true
    @AppStorage("menuItemCPU", store: SharedAppState.defaults) private var menuItemCPU = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage(SoundFX.settingsKey) private var uiSoundsEnabled = true
    @AppStorage(AutoCleaner.intervalKey) private var autoCleanDays = 0
    @AppStorage(CleanSafety.dryRunDefaultsKey) private var dryRunEveryClean = false
    @AppStorage(RealtimeProtection.enabledKey) private var realtimeProtectionEnabled = true
    @AppStorage(ClipboardThreatPolicy.enabledKey, store: SharedAppState.defaults) private var clipboardGuardEnabled = true
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true
    @AppStorage("lastUpdateCheckDate") private var lastUpdateCheckTimestamp: Double = 0
    @AppStorage(AppearanceManager.defaultsKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(AppLanguage.defaultsKey, store: SharedAppState.defaults) private var appLanguageRaw = AppLanguage.system.rawValue
    @AppStorage(HealthAlertSettings.memoryPressureAlertKey, store: SharedAppState.defaults) private var memoryPressureAlert = true
    @AppStorage(HealthAlertSettings.swapAlertThresholdKey, store: SharedAppState.defaults) private var swapAlertThresholdGB = 0
    @State private var selfUpdater = SelfUpdateController.shared
    @State private var launcher = MenuBarLauncher.shared
    @State private var loginLauncher = LaunchAtLoginManager.shared
    @State private var pane: SettingsPane = .general
    @Environment(AppState.self) private var appState
    @State private var updateState: UpdateUIState = .idle
    @State private var keptLanguages: Set<String> = []
    @State private var selectable: [(name: String, lprojs: [String])] = []
    @State private var languageSearch: String = ""
    @State private var excludedFolders: [String] = FolderExclusionPreferences.paths
    @State private var exclusionError: String?
    @State private var malwareSignatures: MalwareSignatureSummary?
    @State private var bazaarKeyDraft = ""
    @State private var bazaarHasKey = false
    @State private var bazaarUpdating = false
    @State private var bazaarMessage: String?
    @State private var licenseText: String?
    @State private var confirmRemoveBazaarKey = false

    /// Selectable languages filtered by the search field (case-insensitive).
    private var filteredLanguages: [(name: String, lprojs: [String])] {
        guard !languageSearch.isEmpty else { return selectable }
        return selectable.filter { $0.name.localizedCaseInsensitiveContains(languageSearch) }
    }

    /// The menu-bar helper is another process: tell it right away (it also
    /// watches these keys with KVO, this just makes the change instant).
    static func notifyMenuHelper() {
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.maccleaner.menuItemsChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $pane)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Group {
                switch pane {
                case .general: generalPane
                case .menuBar: menuBarPane
                case .alerts: alertsPane
                case .cleanup: cleanupPane
                case .security: securityPane
                case .about: aboutPane
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(get: { licenseText != nil }, set: { if !$0 { licenseText = nil } })) {
            LicenseSheet(text: licenseText ?? "")
        }
        .onAppear {
            launchAtLogin = loginLauncher.refreshStatus()
            keptLanguages = LanguagePreferences.userKept
            selectable = LanguagePreferences.selectableLanguages()
            excludedFolders = FolderExclusionPreferences.paths
            refreshMalwareSignatures()
            Task.detached(priority: .userInitiated) {
                let found = LanguageScanner().discoverLproj(in: LanguageScanner.defaultRoots)
                await MainActor.run {
                    LanguagePreferences.discoveredLproj = found
                    selectable = LanguagePreferences.selectableLanguages()
                }
            }
        }
        // Sidebar search → "Settings › <pane>" opens that pane.
        .onChange(of: appState.requestedSettingsPane, initial: true) { _, requested in
            guard let requested else { return }
            pane = requested
            appState.requestedSettingsPane = nil
        }
        .onChange(of: showMenuBarWidget) { _, newValue in
            Task { await launcher.setEnabled(newValue) }
        }
        .onChange(of: appLanguageRaw) { _, _ in Self.notifyMenuHelper() }
        .onChange(of: appLanguageRaw) { _, newValue in
            AppLanguage.current = AppLanguage(rawValue: newValue) ?? .fallback
            selectable = LanguagePreferences.selectableLanguages()
        }
        .onChange(of: appearanceRaw) { _, newValue in
            AppearanceManager.apply(AppearanceMode(rawValue: newValue) ?? .system)
        }
        .onChange(of: autoCleanDays) { _, v in
            if v > 0 { AutoCleaner.requestNotificationPermission() }
        }
        .onChange(of: menuItemRAM) { _, _ in Self.notifyMenuHelper() }
        .onChange(of: menuItemBattery) { _, _ in Self.notifyMenuHelper() }
        .onChange(of: menuItemNetwork) { _, _ in Self.notifyMenuHelper() }
        .onChange(of: menuItemCPU) { _, _ in Self.notifyMenuHelper() }
        .onChange(of: menuBarMetricRaw) { _, _ in Self.notifyMenuHelper() }
        .onChange(of: realtimeProtectionEnabled) { _, v in
            RealtimeProtection.shared.setEnabled(v)
        }
    }

    private func hero(_ pane: SettingsPane) -> some View {
        Section { SettingsHero(pane: pane) }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.caption)
    }

    // MARK: - Generali

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { requestedValue in
                launchAtLogin = requestedValue
                Task {
                    launchAtLogin = await loginLauncher.setEnabled(requestedValue)
                }
            }
        )
    }

    private var generalPane: some View {
        Form {
            hero(.general)

            Section {
                // Toggle flips instantly; the SMAppService round-trip runs in the
                // background with a spinner (no main-thread block, no lag).
                LabeledContent {
                    HStack(spacing: 8) {
                        if loginLauncher.isBusy { ProgressView().controlSize(.small) }
                        Toggle("", isOn: launchAtLoginBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(loginLauncher.isBusy)
                    }
                } label: {
                    SettingsRowLabel(symbol: "power", color: Color(nsColor: .systemGreen),
                                     title: KMR.t("Apri al login", "Open at login"))
                }
                .help(KMR.t("Gestibile anche in Impostazioni di Sistema › Generali › Elementi login.",
                            "Also managed in System Settings › General › Login Items."))
                if loginLauncher.status == .requiresApproval {
                    warning(KMR.t("Da approvare in Impostazioni di Sistema › Elementi login",
                                  "Needs approval in System Settings › Login Items"))
                }
                if let err = loginLauncher.lastError {
                    warning(err.localizedDescription)
                }

                Toggle(isOn: $uiSoundsEnabled) {
                    SettingsRowLabel(symbol: "speaker.wave.2.fill", color: Color(nsColor: .systemPink),
                                     title: KMR.t("Effetti sonori", "Sound effects"),
                                     caption: KMR.t("Al termine di scansioni e pulizie", "When scans and cleanups finish"))
                }
                .toggleStyle(.switch)
            }

            Section(KMR.t("Aspetto e lingua", "Appearance and language")) {
                Picker(selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(modeLabel(mode)).tag(mode.rawValue)
                    }
                } label: {
                    SettingsRowLabel(symbol: "circle.lefthalf.filled", color: Color(nsColor: .systemIndigo),
                                     title: KMR.t("Aspetto", "Appearance"))
                }
                .pickerStyle(.menu)

                Picker(selection: $appLanguageRaw) {
                    ForEach([AppLanguage.system], id: \.self) { language in
                        Text(language.pickerLabel).tag(language.rawValue)
                    }
                    Divider()
                    ForEach([AppLanguage.en, .de, .es, .fr, .it, .ptBR, .tr, .ru, .fa, .ja, .ko, .zhHans, .zhHant], id: \.self) { language in
                        Text(language.pickerLabel).tag(language.rawValue)
                    }
                } label: {
                    SettingsRowLabel(symbol: "globe", color: Color(nsColor: .systemBlue),
                                     title: KMR.t("Lingua", "Language"))
                }
                .pickerStyle(.menu)
                .help(KMR.t("Si applica subito alla finestra e alla barra dei menu.",
                            "Applies immediately to the window and the menu bar."))
            }

            if MCConstants.selfUpdatesEnabled { softwareUpdateSection }
        }
    }

    private func modeLabel(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: KMR.t("Automatico", "Automatic")
        case .light: KMR.t("Chiaro", "Light")
        case .dark: KMR.t("Scuro", "Dark")
        }
    }

    // MARK: - Software update

    private var lastCheckedCaption: String? {
        let prefix = KMR.t("Ultimo controllo: ", "Last checked: ")
        if selfUpdater.usesInAppUpdates, let checked = selfUpdater.lastCheckDate {
            return prefix + checked.formatted(date: .abbreviated, time: .shortened)
        }
        guard lastUpdateCheckTimestamp > 0 else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: lastUpdateCheckTimestamp)
        return prefix + date.formatted(date: .abbreviated, time: .shortened)
    }

    private var softwareUpdateSection: some View {
        Section {
            LabeledContent {
                updateControl
            } label: {
                SettingsRowLabel(symbol: "arrow.down.circle.fill", color: Color(nsColor: .systemBlue),
                                 title: KMR.t("Versione \(selfUpdater.installedVersion)", "Version \(selfUpdater.installedVersion)"),
                                 caption: lastCheckedCaption)
            }
            if !selfUpdater.usesInAppUpdates, case .available(let version, let url) = updateState {
                updateAvailableRow(version: version, url: url)
            }
            if selfUpdater.usesInAppUpdates {
                Toggle(isOn: Binding(get: { selfUpdater.automaticChecks }, set: { selfUpdater.setAutomaticChecks($0) })) {
                    SettingsRowLabel(symbol: "arrow.triangle.2.circlepath", color: Color(nsColor: .systemGreen),
                                     title: KMR.t("Controlla automaticamente", "Check automatically"))
                }
                .toggleStyle(.switch)
                Toggle(isOn: Binding(get: { selfUpdater.automaticDownloads }, set: { selfUpdater.setAutomaticDownloads($0) })) {
                    SettingsRowLabel(symbol: "square.and.arrow.down.fill", color: Color(nsColor: .systemTeal),
                                     title: KMR.t("Scarica e installa automaticamente", "Download and install automatically"),
                                     caption: KMR.t("Installati all'uscita dall'app", "Installed when you quit"))
                }
                .toggleStyle(.switch)
                .disabled(!selfUpdater.automaticChecks)
                .help(KMR.t("Gli aggiornamenti si installano quando esci, oppure puoi riavviare subito l'app.",
                            "Updates install when you quit, or you can restart the app right away."))
                if selfUpdater.canRetryInstallation {
                    Button(KMR.t("Riprova installazione", "Retry Installation")) {
                        selfUpdater.retryInstallation()
                    }
                }
            } else {
                Toggle(isOn: $automaticUpdateChecks) {
                    SettingsRowLabel(symbol: "arrow.triangle.2.circlepath", color: Color(nsColor: .systemGreen),
                                     title: KMR.t("Controlla automaticamente", "Check automatically"))
                }
                .toggleStyle(.switch)
            }
        } header: {
            Text(KMR.t("Aggiornamento software", "Software Update"))
        } footer: {
            updateFooter
        }
    }

    private var updateFooterLines: [String] {
        var out: [String] = []
        if selfUpdater.usesInAppUpdates {
            if let message = selfUpdater.lastError { out.append(message) }
            if let channel = Bundle.main.object(forInfoDictionaryKey: "MacCleanerUpdateChannelName") as? String {
                out.append(KMR.t("Canale: ", "Channel: ") + channel)
            }
        } else if !selfUpdater.isHomebrew {
            out.append(KMR.t("Installazione dall'app non configurata in questa build.",
                             "In-app installation isn't configured in this build."))
        }
        return out
    }

    @ViewBuilder
    private var updateFooter: some View {
        let lines = updateFooterLines
        if !lines.isEmpty {
            Text(lines.joined(separator: "\n"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        if selfUpdater.usesInAppUpdates {
            Button(KMR.t("Verifica aggiornamenti", "Check for Updates")) {
                selfUpdater.checkForUpdates()
            }
            .disabled(!selfUpdater.canCheckForUpdates || selfUpdater.isPreparingInstallation)
        } else {
            switch updateState {
            case .idle:
                Button(KMR.t("Verifica aggiornamenti", "Check for Updates")) { startUpdateCheck() }
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(KMR.t("Verifica…", "Checking…")).foregroundStyle(.secondary)
                }
            case .upToDate:
                Label(KMR.t("Aggiornato", "Up to date"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .available:
                EmptyView()   // detail rendered by updateAvailableRow
            case .failed(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(message)
                    Button(KMR.t("Riprova", "Retry")) { startUpdateCheck() }
                }
            }
        }
    }

    @ViewBuilder
    private func updateAvailableRow(version: String, url: URL) -> some View {
        if UpdateChecker.isHomebrewInstall() {
            LabeledContent {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.brewUpgradeCommand, forType: .string)
                } label: {
                    Label(KMR.t("Copia", "Copy"), systemImage: "doc.on.doc")
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(KMR.t("Disponibile la versione \(version)", "Version \(version) is available"))
                    Text(Self.brewUpgradeCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } else {
            LabeledContent(KMR.t("Disponibile la versione \(version)", "Version \(version) is available")) {
                Button(KMR.t("Vedi novità", "View Release")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    static let brewUpgradeCommand = "brew upgrade --cask maccleaner"

    @MainActor
    private func startUpdateCheck() {
        updateState = .checking
        Task {
            let result = await UpdateChecker.check()
            switch result {
            case .upToDate:
                updateState = .upToDate
            case .updateAvailable(let version, let url):
                updateState = .available(version: version, url: url)
            case .failed(let message):
                updateState = .failed(message: message)
            }
        }
    }

    // MARK: - Barra dei menu

    private var menuBarPane: some View {
        Form {
            hero(.menuBar)

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if launcher.isBusy { ProgressView().controlSize(.small) }
                        Toggle("", isOn: $showMenuBarWidget)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(launcher.isBusy)
                    }
                } label: {
                    SettingsRowLabel(symbol: "menubar.rectangle", color: Color(nsColor: .systemBlue),
                                     title: KMR.t("Mostra nella barra dei menu", "Show in menu bar"),
                                     caption: statusCaption)
                }
                .help(KMR.t("Fai clic sull'icona nella barra dei menu per aprire il pannello.",
                            "Click the menu bar icon to open the panel."))
                if let err = launcher.lastError {
                    warning(err.localizedDescription)
                }

                Picker(selection: $menuBarMetricRaw) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.localizedName).tag(metric.rawValue)
                    }
                } label: {
                    SettingsRowLabel(symbol: "textformat.123", color: Color(nsColor: .systemOrange),
                                     title: KMR.t("Valore accanto all'icona", "Value next to the icon"))
                }
                .pickerStyle(.menu)
                .disabled(!showMenuBarWidget)
                .help(KMR.t("Se il sensore non è disponibile viene mostrato --.",
                            "Shows -- when the sensor isn't available."))
            }

            Section {
                Toggle(isOn: $menuItemCPU) {
                    SettingsRowLabel(symbol: "cpu.fill", color: Color(nsColor: .systemOrange), title: "CPU")
                }
                Toggle(isOn: $menuItemRAM) {
                    SettingsRowLabel(symbol: "memorychip.fill", color: Color(nsColor: .systemGreen),
                                     title: KMR.t("Memoria (RAM)", "Memory (RAM)"))
                }
                Toggle(isOn: $menuItemBattery) {
                    SettingsRowLabel(symbol: "battery.100percent", color: Color(nsColor: .systemYellow),
                                     title: KMR.t("Batteria", "Battery"))
                }
                Toggle(isOn: $menuItemNetwork) {
                    SettingsRowLabel(symbol: "arrow.up.arrow.down", color: Color(nsColor: .systemBlue),
                                     title: KMR.t("Rete", "Network"))
                }
            } header: {
                Text(KMR.t("Elementi in tempo reale", "Live items"))
            } footer: {
                Text(KMR.t("Ogni elemento compare come icona separata nella barra dei menu.",
                           "Each item appears as its own icon in the menu bar."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .disabled(!showMenuBarWidget)
        }
    }

    // MARK: - Avvisi

    private var alertsPane: some View {
        Form {
            hero(.alerts)

            Section {
                Toggle(isOn: $memoryPressureAlert) {
                    SettingsRowLabel(symbol: "memorychip.fill", color: Color(nsColor: .systemPurple),
                                     title: KMR.t("Memoria sotto pressione", "Memory pressure"),
                                     caption: KMR.t("Quando resta alta a lungo", "When it stays high"))
                }
                .toggleStyle(.switch)

                Picker(selection: $swapAlertThresholdGB) {
                    ForEach(HealthAlertSettings.swapThresholdChoices, id: \.self) { gigabytes in
                        Text(gigabytes == 0 ? KMR.t("Disattivato", "Off") : FileSizeFormatter.format(HealthAlertSettings.bytes(forGB: gigabytes)))
                            .tag(gigabytes)
                    }
                } label: {
                    SettingsRowLabel(symbol: "arrow.left.arrow.right", color: Color(nsColor: .systemOrange),
                                     title: KMR.t("Uso dello swap", "Swap usage"),
                                     caption: KMR.t("Oltre la soglia scelta", "Above the chosen size"))
                }
                .pickerStyle(.menu)
                .help(KMR.t("Avvisa una volta quando lo swap supera la soglia, e di nuovo solo dopo che è sceso parecchio sotto.",
                            "Notifies once when swap goes above the size, and again only after it has dropped well below it."))
            } footer: {
                if !showMenuBarWidget {
                    Label(KMR.t("Richiede l'icona nella barra dei menu attiva.", "Requires the menu bar icon to be on."),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!showMenuBarWidget)
        }
    }

    // MARK: - Pulizia

    private var autoCleanCaption: String? {
        AutoCleaner.lastRun.map { KMR.t("Ultima: ", "Last: ") + $0.formatted(.relative(presentation: .named)) }
    }

    private var cleanupPane: some View {
        Form {
            hero(.cleanup)

            Section {
                Picker(selection: $autoCleanDays) {
                    Text(KMR.t("Disattivata", "Off")).tag(0)
                    Text(KMR.t("Ogni giorno", "Every day")).tag(1)
                    Text(KMR.t("Ogni settimana", "Every week")).tag(7)
                } label: {
                    SettingsRowLabel(symbol: "clock.arrow.circlepath", color: Color(nsColor: .systemGreen),
                                     title: KMR.t("Pulizia automatica", "Automatic cleanup"),
                                     caption: autoCleanCaption)
                }
                .pickerStyle(.menu)
                .help(KMR.t("Solo cache che si ricreano da sole, non toccate da 3 giorni e non di app aperte. Tutto va nel Cestino.",
                            "Only caches that rebuild themselves, untouched for 3 days and not from open apps. Everything goes to the Trash."))
                Toggle(isOn: $dryRunEveryClean) {
                    SettingsRowLabel(symbol: "eye", color: Color(nsColor: .systemBlue),
                                     title: KMR.t("Mostra un'anteprima prima di ogni pulizia", "Preview before every cleanup"),
                                     caption: KMR.t("La prima pulizia mostra sempre l'anteprima", "The first cleanup always shows it"))
                }
            } footer: {
                Text(KMR.t("Solo cache sicure. Tutto finisce nel Cestino.", "Safe caches only. Everything goes to the Trash."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            languageSection
            excludedFoldersSection
        }
    }

    private var languageSection: some View {
        Section {
            if selectable.isEmpty {
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    SettingsRowLabel(symbol: "character.bubble.fill", color: Color(nsColor: .systemTeal),
                                     title: KMR.t("Ricerca lingue installate…", "Detecting installed languages…"))
                }
            } else {
                TextField(KMR.t("Cerca lingua", "Search languages"), text: $languageSearch)
                    .textFieldStyle(.roundedBorder)

                if filteredLanguages.isEmpty {
                    Text(KMR.t("Nessuna lingua per “\(languageSearch)”.", "No languages match “\(languageSearch)”."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Fixed-height scroll box: ~100 languages would otherwise
                // stretch the pane.
                DirectionalScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredLanguages, id: \.name) { lang in
                            // One toggle covers every folder variant of the
                            // language (e.g. "fr.lproj" + legacy "French.lproj").
                            HStack {
                                Text(lang.name)
                                Spacer()
                                Toggle(lang.name, isOn: Binding(
                                    get: { lang.lprojs.allSatisfy { keptLanguages.contains($0) } },
                                    set: { on in
                                        if on { keptLanguages.formUnion(lang.lprojs) }
                                        else { lang.lprojs.forEach { keptLanguages.remove($0) } }
                                        LanguagePreferences.userKept = keptLanguages
                                    }
                                ))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                            }
                            .padding(.vertical, 5)
                            .padding(.trailing, 6)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(height: 250)
            }
        } header: {
            Text(KMR.t("Lingue da conservare", "Languages to keep"))
        } footer: {
            Text(KMR.t("Le lingue non attivate possono essere rimosse da Sistema. Quelle del Mac e dell'app restano sempre.",
                       "Unchecked languages can be removed by System Junk. Your Mac's and the app's languages are always kept."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var excludedFoldersSection: some View {
        Section {
            ForEach(excludedFolders, id: \.self) { path in
                LabeledContent {
                    Button(KMR.t("Rimuovi", "Remove"), role: .destructive) {
                        FolderExclusionPreferences.remove(path)
                        excludedFolders = FolderExclusionPreferences.paths
                        exclusionError = nil
                    }
                    .buttonStyle(.borderless)
                } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: "folder.fill", color: Color(nsColor: .systemBlue), size: 24)
                        Text(path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path)
                    }
                }
            }

            SettingsActionRow(symbol: "plus", color: Color(nsColor: .systemGray),
                              title: KMR.t("Aggiungi cartella…", "Add Folder…"), trailingSymbol: "folder.badge.plus") {
                addExcludedFolder()
            }

            if let exclusionError {
                warning(exclusionError)
            }
        } header: {
            Text(KMR.t("Cartelle escluse", "Excluded folders"))
        } footer: {
            Text(KMR.t("Mai mostrate né eliminate, nemmeno da Distruggi. Solo nella Home o in /Volumes.",
                       "Never shown or deleted, not even by Shredder. Home or /Volumes only."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = KMR.t("Escludi", "Exclude")
        panel.message = KMR.t("Scegli una cartella da escludere dalla pulizia.", "Choose a folder to exclude from cleanup.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        if FolderExclusionPreferences.add(path) {
            excludedFolders = FolderExclusionPreferences.paths
            exclusionError = nil
        } else {
            exclusionError = rejectionMessage(for: path)
        }
    }

    private func rejectionMessage(for path: String) -> String {
        switch PathExclusion.candidateDecision(
            for: path,
            home: NSHomeDirectory(),
            maxCount: FolderExclusionPreferences.defaultMaxCount,
            existing: FolderExclusionPreferences.paths
        ) {
        case .allow:
            return KMR.t("Impossibile aggiungere la cartella.", "Couldn't add that folder.")
        case .reject(.notAbsolute):
            return KMR.t("Scegli un percorso assoluto.", "Choose an absolute path.")
        case .reject(.entireHome):
            return KMR.t("Non puoi escludere l'intera Home.", "You can't exclude your entire home folder.")
        case .reject(.entireVolumesRoot):
            return KMR.t("Non puoi escludere tutto /Volumes.", "You can't exclude all of /Volumes.")
        case .reject(.outsideAllowedRoots):
            return KMR.t("Solo cartelle nella Home o in /Volumes.", "Only folders under your home folder or /Volumes.")
        case .reject(.atCapacity):
            return KMR.t("Massimo \(FolderExclusionPreferences.defaultMaxCount) cartelle.",
                         "At most \(FolderExclusionPreferences.defaultMaxCount) folders.")
        case .reject(.alreadyCovered):
            return KMR.t("Già coperta da un'esclusione esistente.", "Already covered by an existing exclusion.")
        }
    }

    // MARK: - Sicurezza

    private var securityPane: some View {
        Form {
            hero(.security)

            Section(KMR.t("Protezione", "Protection")) {
                Toggle(isOn: $realtimeProtectionEnabled) {
                    SettingsRowLabel(symbol: "shield.checkered", color: Color(nsColor: .systemGreen),
                                     title: KMR.t("Protezione in tempo reale", "Real-time protection"),
                                     caption: KMR.t("Avvisa se compaiono elementi sospetti in Download, cartelle temporanee e agenti di avvio",
                                                    "Alerts you when suspicious items appear in Downloads, temporary folders and launch agents"))
                }
                .toggleStyle(.switch)
                Toggle(isOn: $clipboardGuardEnabled) {
                    SettingsRowLabel(symbol: "doc.on.clipboard.fill", color: Color(nsColor: .systemOrange),
                                     title: KMR.t("Controllo degli appunti", "Clipboard guard"),
                                     caption: KMR.t("Avvisa se copi un comando usato dagli infostealer (attacchi ClickFix) prima che tu lo incolli nel Terminale. Il testo copiato non viene mai salvato.",
                                                    "Warns you if you copy a command used by infostealers (ClickFix attacks) before you paste it into Terminal. Copied text is never stored."))
                }
                .toggleStyle(.switch)
            }

            Section(KMR.t("Database malware", "Malware databases")) {
                LabeledContent {
                    if malwareSignatures == nil { ProgressView().controlSize(.small) }
                } label: {
                    SettingsRowLabel(symbol: "shield.lefthalf.filled", color: Color(nsColor: .systemGray),
                                     title: "Apple XProtect",
                                     caption: malwareSignatures.map(MalwareStrings.xprotectRow) ?? MalwareStrings.updating)
                }

                LabeledContent {
                    if bazaarHasKey {
                        HStack(spacing: 8) {
                            if bazaarUpdating { ProgressView().controlSize(.small) }
                            Button(KMR.t("Aggiorna ora", "Update Now")) { updateMalwareBazaar() }
                                .disabled(bazaarUpdating)
                        }
                    }
                } label: {
                    SettingsRowLabel(symbol: "ladybug.fill", color: Color(nsColor: .systemRed),
                                     title: "MalwareBazaar",
                                     caption: bazaarStatusLine)
                }
                .help(MalwareStrings.bazaarExplanation)

                if bazaarHasKey {
                    Button(KMR.t("Rimuovi chiave e hash…", "Remove Key and Hashes…"), role: .destructive) {
                        confirmRemoveBazaarKey = true
                    }
                    .buttonStyle(.borderless)
                    .disabled(bazaarUpdating)
                    .confirmationDialog(KMR.t("Rimuovere la chiave MalwareBazaar?", "Remove the MalwareBazaar key?"),
                                        isPresented: $confirmRemoveBazaarKey, titleVisibility: .visible) {
                        Button(KMR.t("Rimuovi", "Remove"), role: .destructive) { removeMalwareBazaarKey() }
                        Button(KMR.t("Annulla", "Cancel"), role: .cancel) {}
                    } message: {
                        Text(KMR.t("Gli hash scaricati vengono eliminati: per riaverli servirà di nuovo la chiave.",
                                   "The downloaded hashes are deleted: you'll need the key again to get them back."))
                    }
                } else {
                    HStack {
                        SecureField(KMR.t("Auth-Key di abuse.ch", "abuse.ch Auth-Key"), text: $bazaarKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Button(KMR.t("Salva", "Save")) {
                            if MalwareBazaarKeychain().save(bazaarKeyDraft) {
                                bazaarKeyDraft = ""
                                bazaarHasKey = true
                                bazaarMessage = MalwareStrings.keySaved
                            } else {
                                bazaarMessage = MalwareStrings.keySaveFailed
                            }
                        }
                        .disabled(bazaarKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let signup = MalwareBazaarFeed.authKeySignupURL {
                        SettingsLinkRow(symbol: "key.fill", color: Color(nsColor: .systemYellow),
                                        title: KMR.t("Ottieni una chiave gratuita", "Get a free key"), url: signup)
                    }
                }
            }
        }
    }

    private var bazaarStatusLine: String {
        if let bazaarMessage { return bazaarMessage }
        guard let summary = malwareSignatures, summary.bazaarHashCount > 0,
              let updated = summary.bazaarUpdatedAt else {
            return bazaarHasKey ? MalwareStrings.neverUpdated
                                : KMR.t("Facoltativo, con chiave gratuita abuse.ch", "Optional, with a free abuse.ch key")
        }
        return MalwareStrings.bazaarStatus(count: summary.bazaarHashCount, updatedAt: updated)
    }

    /// Loads the signature summary and the key's presence off the main
    /// thread; neither touches the network or decrypts the key.
    private func refreshMalwareSignatures() {
        Task.detached(priority: .utility) {
            let summary = MalwareDatabase.loadCurrent().summary
            let hasKey = MalwareBazaarKeychain().hasKey
            await MainActor.run {
                malwareSignatures = summary
                bazaarHasKey = hasKey
            }
        }
    }

    private func updateMalwareBazaar() {
        bazaarUpdating = true
        bazaarMessage = MalwareStrings.updating
        Task {
            let outcome = await MalwareBazaarStore.updateNow()
            bazaarUpdating = false
            bazaarMessage = MalwareStrings.outcomeMessage(outcome)
            refreshMalwareSignatures()
        }
    }

    private func removeMalwareBazaarKey() {
        if MalwareBazaarStore.removeKeyAndHashes() {
            bazaarHasKey = false
            bazaarMessage = nil
        } else {
            bazaarMessage = MalwareStrings.keyRemoveFailed
        }
        refreshMalwareSignatures()
    }

    // MARK: - Informazioni

    private var aboutPane: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text(MCConstants.appName)
                        .font(.title.weight(.bold))
                    Text(KMR.t("Versione \(MCConstants.appVersion)", "Version \(MCConstants.appVersion)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if MCConstants.selfUpdatesEnabled {
                        updateControl
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                if !selfUpdater.usesInAppUpdates, case .available(let version, let url) = updateState {
                    updateAvailableRow(version: version, url: url)
                }
            }

            Section {
                SettingsLinkRow(symbol: "chevron.left.forwardslash.chevron.right", color: Color(nsColor: .systemGray),
                                title: KMR.t("Codice sorgente", "Source code"), url: MCConstants.repoURL)
                SettingsLinkRow(symbol: "exclamationmark.bubble.fill", color: Color(nsColor: .systemOrange),
                                title: KMR.t("Segnala un problema", "Report an issue"), url: MCConstants.issuesURL)
                SettingsLinkRow(symbol: "doc.text.fill", color: Color(nsColor: .systemBlue),
                                title: KMR.t("Note di rilascio", "Release notes"), url: MCConstants.releasesURL)
                SettingsActionRow(symbol: "checkmark.seal.fill", color: Color(nsColor: .systemGreen),
                                  title: KMR.t("Licenza open source", "Open source license")) {
                    licenseText = LicenseSheet.loadText()
                }
            }
        }
    }

    // MARK: - Menu bar widget status

    private var statusCaption: String {
        let state: String = switch launcher.statusSnapshot {
        case .enabled: KMR.t("in esecuzione", "running")
        case .notRegistered: KMR.t("non registrato", "not registered")
        case .notFound: KMR.t("componente non trovato nell'app", "helper not found in the app")
        case .requiresApproval: KMR.t("da approvare in Elementi login", "needs approval in Login Items")
        @unknown default: KMR.t("sconosciuto", "unknown")
        }
        return KMR.t("Stato: ", "Status: ") + state
    }
}
