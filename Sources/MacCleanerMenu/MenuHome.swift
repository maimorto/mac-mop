import SwiftUI
import AppKit
import MacCleanerKit

// Home tab of the Mac Mop (SSD/mop) item, modelled on CleanMyMac's menu
// but in the system Tahoe style: a row of recommendation cards built from
// real data, an overview of the Mac with one action per tile, and a footer
// action. Every button deep-links into the main app through its
// `maccleaner://module/<id>` URL scheme (see TipAction).

// MARK: - Data

struct HomeSnapshot: Sendable, Equatable {
    struct Security: Sendable, Equatable {
        var gatekeeper: Bool?
        var fileVault: Bool?
        var firewall: Bool?
        var off: [String] {
            [("Gatekeeper", gatekeeper), ("FileVault", fileVault), ("Firewall", firewall)].compactMap { $0.1 == false ? $0.0 : nil }
        }
        var known: Bool { gatekeeper != nil || fileVault != nil || firewall != nil }
    }

    struct Volume: Sendable, Equatable, Identifiable {
        let id: String          // mount path
        let name: String
        let total: UInt64
        let free: UInt64
        let ejectable: Bool
    }

    var startupName = "Macintosh HD"
    /// Size of the Trash: measured when readable, else the main app's last measurement.
    var trashBytes: UInt64?
    var security: Security?
    /// The main app's last Smart Scan estimate of reclaimable space.
    var reclaimableBytes: UInt64?
    var reclaimableDate: Date?
    var volumes: [Volume] = []
}

/// Cheap, popup-only collection. The slow parts (Trash walk, the three
/// security tools) run detached and refresh at most every few minutes; each
/// `collect` returns at once with whatever is cached.
actor HomeCollector {
    private var security: HomeSnapshot.Security?
    private var securityAt: Date?
    private var securityRunning = false
    private var trash: UInt64?
    private var trashAt: Date?
    private var trashRunning = false
    private let startupName: String = {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }()

    func collect(previous: HomeSnapshot) -> HomeSnapshot {
        if !securityRunning, securityAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            securityRunning = true
            Task.detached(priority: .utility) { [self] in
                let s = await Self.runSecurityChecks()
                await self.storeSecurity(s)
            }
        }
        if !trashRunning, trashAt.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
            trashRunning = true
            Task.detached(priority: .utility) { [self] in
                let t = Self.measureTrash()
                await self.storeTrash(t)
            }
        }
        var snap = previous
        snap.startupName = startupName
        snap.security = security
        // The main app's own domain (it writes these with UserDefaults.standard).
        let app = UserDefaults(suiteName: MCConstants.bundleIdentifier)
        if let r = app?.object(forKey: "kmr.reclaimableBytes") as? Double, r > 0 {
            snap.reclaimableBytes = UInt64(r)
            snap.reclaimableDate = app?.object(forKey: "kmr.reclaimableDate") as? Date
        } else {
            snap.reclaimableBytes = nil
            snap.reclaimableDate = nil
        }
        snap.trashBytes = trash ?? (app?.object(forKey: "kmr.reclaim.trash") as? Double).map { UInt64($0) }
        snap.volumes = Self.externalVolumes()
        return snap
    }

    private func storeSecurity(_ s: HomeSnapshot.Security) {
        security = s
        securityAt = Date()
        securityRunning = false
    }

    private func storeTrash(_ t: UInt64?) {
        trash = t
        trashAt = Date()
        trashRunning = false
    }

    private static func runSecurityChecks() async -> HomeSnapshot.Security {
        func text(_ o: BoundedProcess.Outcome) -> String? {
            guard case .exited(_, let out, let err) = o else { return nil }
            let s = String(decoding: out + err, as: UTF8.self)
            return s.isEmpty ? nil : s
        }
        async let gk = BoundedProcess.run("/usr/sbin/spctl", ["--status"], timeout: .seconds(4))
        async let fv = BoundedProcess.run("/usr/bin/fdesetup", ["status"], timeout: .seconds(4))
        async let fw = BoundedProcess.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: .seconds(4))
        let g = text(await gk), f = text(await fv), w = text(await fw)
        return HomeSnapshot.Security(
            gatekeeper: g.map { $0.contains("enabled") },
            fileVault: f.map { $0.contains("FileVault is On") },
            firewall: w.map { $0.contains("enabled") || $0.contains("State = 1") || $0.contains("State = 2") }
        )
    }

    /// nil when the Trash isn't readable (no Full Disk Access).
    private static func measureTrash() -> UInt64? {
        let url = MCConstants.userTrash
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return nil }
        var total: UInt64 = 0, n = 0
        while let next = e.nextObject() as? URL, n < 100_000 {
            n += 1
            if let v = try? next.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += UInt64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Disks the user plugged in (USB, Thunderbolt, SD, disk images); network
    /// shares and the startup disk are left out. Phones don't mount volumes.
    private static func externalVolumes() -> [HomeSnapshot.Volume] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
                                      .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path != "/", let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal ?? true else { return nil }
            let removable = v.volumeIsRemovable ?? false, ejectable = v.volumeIsEjectable ?? false
            guard removable || ejectable || !(v.volumeIsInternal ?? true) else { return nil }
            return HomeSnapshot.Volume(id: url.path, name: v.volumeLocalizedName ?? url.lastPathComponent,
                                       total: UInt64(v.volumeTotalCapacity ?? 0), free: UInt64(v.volumeAvailableCapacity ?? 0),
                                       ejectable: removable || ejectable)
        }
    }
}

// MARK: - Actions

@MainActor
enum HomeAction {
    /// Opens the main app at a module (slugs from SidebarItem.deepLinkID) and closes the popup.
    static func open(_ module: String) {
        TipAction.open(moduleID: module)
        StatusBarController.shared.closePopup()
    }
}


// MARK: - View

/// Capsule button that keeps the accent colour even though the popup never
/// belongs to the active app (system prominent buttons turn grey there).
struct PillButtonStyle: ButtonStyle {
    enum Size { case small, regular, large }
    var accent = true
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = switch size { case .small: 24; case .regular: 28; case .large: 34 }
        configuration.label
            .font(size == .small ? .caption.weight(.semibold) : size == .regular ? .callout.weight(.semibold) : .body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(accent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, size == .small ? 10 : 14)
            .frame(height: height)
            .background {
                if accent {
                    Capsule().fill(Color.accentColor.gradient)
                } else {
                    Capsule().fill(.fill.secondary)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct HomePanel: View {
    let model: MenuStatsModel
    let showTab: (MenuTab) -> Void
    @State private var ejecting: Set<String> = []

    private struct Recommendation: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let text: String
        let action: String
        let module: String
    }

    private var recommendations: [Recommendation] {
        let h = model.home
        var list: [Recommendation] = []
        let stale = h.reclaimableDate.map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true
        if let r = h.reclaimableBytes, r >= 200_000_000 {
            let x = diskBytes(r)
            list.append(.init(id: "junk", symbol: "sparkles", tint: Color(nsColor: .systemPink),
                              text: t("Puoi rimuovere in sicurezza \(x) di file inutili.", "You can safely remove \(x) of junk files."),
                              action: t("Libera \(x)", "Free Up \(x)"), module: "system-junk"))
        }
        if let trash = h.trashBytes, trash >= 50_000_000 {
            let x = diskBytes(trash)
            list.append(.init(id: "trash", symbol: "trash", tint: Color(nsColor: .systemGreen),
                              text: t("Il Cestino occupa \(x): svuotalo per recuperare spazio.", "The Trash is taking \(x): empty it to get the space back."),
                              action: t("Svuota il Cestino (\(x))", "Empty Trash (\(x))"), module: "trash-bins"))
        }
        if let s = model.stats, s.diskTotal > 0, s.diskFree < 20_000_000_000 || Double(s.diskFree) / Double(s.diskTotal) < 0.1 {
            let x = diskBytes(s.diskFree)
            list.append(.init(id: "disk", symbol: "internaldrive", tint: Color(nsColor: .systemOrange),
                              text: t("Restano solo \(x) liberi. Scopri cosa occupa più spazio.", "Only \(x) left. See what takes up the most space."),
                              action: t("Libera spazio", "Free Up Space"), module: "space-lens"))
        }
        let m = model.memory
        if m.pressureLevel >= 2 || m.usedFraction > 0.85 {
            list.append(.init(id: "memory", symbol: "memorychip", tint: Color(nsColor: .systemBlue),
                              text: t("La memoria è quasi piena: libera la RAM occupata dalle app inattive.", "Memory is almost full: free the RAM held by idle apps."),
                              action: t("Libera memoria", "Free Up Memory"), module: "optimization"))
        }
        if let p = model.protection, p.threatsFound > 0 {
            list.append(.init(id: "malware", symbol: "exclamationmark.shield", tint: Color(nsColor: .systemRed),
                              text: t("Minacce trovate nell'ultima scansione: \(p.threatsFound).", "Threats found in the last scan: \(p.threatsFound)."),
                              action: t("Rimuovi minacce", "Remove Threats"), module: "malware"))
        } else if model.protection?.isStale ?? true {
            list.append(.init(id: "malware", symbol: "checkmark.shield", tint: Color(nsColor: .systemTeal),
                              text: model.protection == nil
                                ? t("Non hai ancora cercato malware su questo Mac.", "You haven't scanned this Mac for malware yet.")
                                : t("L'ultima ricerca di malware risale a più di una settimana fa.", "Your last malware scan was more than a week ago."),
                              action: t("Cerca malware", "Scan for Malware"), module: "malware"))
        }
        if let sec = h.security, !sec.off.isEmpty {
            list.append(.init(id: "security", symbol: "lock.shield", tint: Color(nsColor: .systemOrange),
                              text: t("Protezioni di macOS disattivate: \(sec.off.joined(separator: ", ")).", "macOS protections turned off: \(sec.off.joined(separator: ", "))."),
                              action: t("Risolvi", "Fix"), module: "smart-scan"))
        }
        let scan = Recommendation(id: "scan", symbol: "wand.and.stars", tint: .accentColor,
                                  text: t("Controlla file inutili, malware e velocità in un solo clic.", "Check junk, malware and speed in a single click."),
                                  action: t("Esegui scansione intelligente", "Run Smart Scan"), module: "smart-scan")
        if stale { list.insert(scan, at: 0) } else { list.append(scan) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("Consigli", "Recommendations"))
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(recommendations) { card($0) }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)

            sectionTitle(t("Panoramica del Mac", "Mac Overview"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                protectionTile
                diskTile
                memoryTile
                cpuTile
                networkTile
                devicesTile
            }

            cleanButton
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.headline)
    }

    private func card(_ r: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: r.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(r.tint)
                .frame(width: 34, height: 34)
                .background(r.tint.opacity(0.16), in: Circle())
            Text(r.text)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { HomeAction.open(r.module) } label: {
                Text(r.action).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(12)
        .frame(width: 214, height: 150, alignment: .topLeading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Tiles

    private struct TileButton {
        let title: String
        var prominent = false
        let action: () -> Void
    }

    private func tile(_ symbol: String, _ tint: Color, _ title: String, value: String, detail: String,
                      button: TileButton) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint).font(.caption.weight(.semibold))
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Button(button.title, action: button.action)
                .buttonStyle(PillButtonStyle(accent: button.prominent, size: .small))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var protectionTile: some View {
        let sec = model.home.security
        let off = sec?.off ?? []
        let threats = model.protection?.threatsFound ?? 0
        let ok = sec?.known == true && off.isEmpty && threats == 0
        let value = sec == nil ? "…" : ok ? t("Attiva", "On") : t("Da controllare", "Check")
        let detail: String = sec == nil ? t("Verifica in corso…", "Checking…")
            : threats > 0 ? t("Minacce: \(threats)", "Threats: \(threats)")
            : off.isEmpty ? t("Tutti i controlli superati", "All checks passed")
            : t("Disattivati: \(off.joined(separator: ", "))", "Off: \(off.joined(separator: ", "))")
        return tile(ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    ok ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange),
                    t("Protezione", "Protection"), value: value, detail: detail,
                    button: TileButton(title: ok ? t("Apri", "Open") : t("Risolvi", "Fix"), prominent: !ok && sec != nil) {
                        HomeAction.open("smart-scan")
                    })
    }

    private var diskTile: some View {
        let s = model.stats
        return tile("internaldrive.fill", Color(nsColor: .systemGray), model.home.startupName,
                    value: s.map { diskBytes($0.diskFree) } ?? "—",
                    detail: s.map { t("Disponibili su \(diskBytes($0.diskTotal))", "Available of \(diskBytes($0.diskTotal))") } ?? "",
                    button: TileButton(title: t("Libera spazio", "Free Up")) { HomeAction.open("space-lens") })
    }

    private var memoryTile: some View {
        let m = model.memory
        return tile("memorychip.fill", Color(nsColor: .systemBlue), t("Memoria", "Memory"),
                    value: bytes(m.total > m.used ? m.total - m.used : 0),
                    detail: t("Disponibili su \(bytes(m.total))", "Available of \(bytes(m.total))"),
                    button: TileButton(title: t("Libera", "Free Up")) { HomeAction.open("optimization") })
    }

    private var cpuTile: some View {
        let load = model.cpu.loadAverage.first ?? 0
        return tile("cpu.fill", Color(nsColor: .systemIndigo), "CPU",
                    value: pct(model.cpu.total),
                    detail: t("Carico \(load.formatted(.number.precision(.fractionLength(2))))",
                              "Load \(load.formatted(.number.precision(.fractionLength(2))))"),
                    button: TileButton(title: t("Dettagli", "Details")) { showTab(.cpu) })
    }

    private var networkTile: some View {
        let n = model.networkSpeed
        return tile("network", Color(nsColor: .systemTeal), t("Rete", "Network"),
                    value: "↓ " + rate(n?.bytesInPerSecond ?? 0),
                    detail: "↑ " + rate(n?.bytesOutPerSecond ?? 0),
                    button: TileButton(title: t("Dettagli", "Details")) { showTab(.network) })
    }

    @ViewBuilder private var devicesTile: some View {
        let vols = model.home.volumes
        if let v = vols.first {
            tile("externaldrive.fill", Color(nsColor: .systemPurple), t("Dispositivi collegati", "Connected devices"),
                 value: v.name,
                 detail: vols.count > 1 ? t("Altri dispositivi: \(vols.count - 1)", "Other devices: \(vols.count - 1)")
                    : t("Liberi \(diskBytes(v.free)) su \(diskBytes(v.total))", "\(diskBytes(v.free)) free of \(diskBytes(v.total))"),
                 button: TileButton(title: ejecting.contains(v.id) ? t("Espulsione…", "Ejecting…") : t("Espelli", "Eject")) { eject(vols) })
        } else {
            tile("externaldrive", Color.secondary, t("Dispositivi collegati", "Connected devices"),
                 value: t("Nessuno", "None"), detail: t("Nessun disco esterno", "No external disks"),
                 button: TileButton(title: "Finder") {
                     if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                         NSWorkspace.shared.openApplication(at: url, configuration: .init())
                     }
                     StatusBarController.shared.closePopup()
                 })
        }
    }

    /// Ejects every connected external disk (the tile lists them as one group).
    private func eject(_ vols: [HomeSnapshot.Volume]) {
        let paths = vols.filter(\.ejectable).map(\.id)
        guard !paths.isEmpty, ejecting.isEmpty else { return }
        ejecting = Set(paths)
        Task.detached(priority: .userInitiated) {
            for p in paths { try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: p)) }
            await MainActor.run {
                ejecting = []
                MenuStatsModel.shared.refreshHome()
            }
        }
    }

    private var cleanButton: some View {
        let r = model.home.reclaimableBytes
        return VStack(spacing: 4) {
            Button { HomeAction.open("smart-scan") } label: {
                Label(r.map { t("Pulisci fino a \(diskBytes($0))", "Clean Up to \(diskBytes($0))") } ?? t("Esegui scansione intelligente", "Run Smart Scan"),
                      systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(size: .large))
            Text(model.home.reclaimableDate.map {
                t("Stima della scansione intelligente del \($0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(UIText.locale)))",
                  "Smart Scan estimate from \($0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(UIText.locale)))")
            } ?? t("Nessuna scansione recente: trova cosa puoi pulire.", "No recent scan: find out what you can clean."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}
