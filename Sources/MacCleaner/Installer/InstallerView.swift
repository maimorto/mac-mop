import SwiftUI
import AppKit
import MacCleanerKit

// MARK: - First-run installer window
//
// Shown instead of the main UI when Mac Mop runs from its disk image. A
// full-bleed scene (one Canvas inside one TimelineView, capped at 60 fps,
// still frame with Reduce Motion / in the background / Low Power, like the
// scan animations): Tahoe blue aurora, drifting glass bubbles, light sheens,
// twinkling sparkles and water ripples under the floating app icon. During
// the install the icon flies along an arc into the Applications folder
// while a ring fills; on success the folder bursts with sparkles and the
// installed copy is relaunched.

struct InstallerView: View {
    var onSkip: () -> Void

    @State private var model = InstallerModel()
    @State private var appeared = false
    @State private var window: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var budget = MotionBudget.shared

    static let size = CGSize(width: 760, height: 520)

    init(onSkip: @escaping () -> Void) {
        self.onSkip = onSkip
    }

    var body: some View {
        let running = budget.ambientAllowed(reduceMotion: reduceMotion)
        // The clear frame sizes the window's content area; the scene overlay
        // ignores the safe area so it also fills the (transparent) title bar.
        Color.clear
            .frame(width: Self.size.width, height: Self.size.height - 28)
            .overlay { scene(running: running) }
            .environment(\.colorScheme, .dark)
            .background(InstallerWindowChrome(window: $window))
            .modifier(ImmersiveTitlebar())
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.9, dampingFraction: 0.72)) { appeared = true }
            }
            .onChange(of: model.ejectAfterInstall) { _, _ in model.refreshPlan() }
            .task { await snapshotIfRequested() }
    }

    private func scene(running: Bool) -> some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { context in
                let t = running ? context.date.timeIntervalSinceReferenceDate : InstallerArt.stillTime
                let p = model.displayedProgress(at: running ? context.date : nil)
                let since = model.doneAt.map { running ? context.date.timeIntervalSince($0) : 0.6 }
                InstallerStage(phase: model.phase, t: t, progress: p, doneSince: since, appeared: appeared)
            }
            controls
        }
        .ignoresSafeArea()
    }

    // MARK: Text and buttons

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 268)
            switch model.phase {
            case .welcome:
                welcome
            case .installing(let step):
                status(title: KMR.t("Installazione in corso…", "Installing…"), detail: stepText(step))
            case .done:
                status(title: KMR.t("Installata!", "Installed!"),
                       detail: KMR.t("Riapro Mac Mop dalla cartella Applicazioni…",
                                     "Reopening Mac Mop from the Applications folder…"))
            case .failed(let message):
                failure(message)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: model.phase)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Text(KMR.t("Benvenuto in Mac Mop", "Welcome to Mac Mop"))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.03, green: 0.12, blue: 0.4).opacity(0.45), radius: 10, y: 3)
                .entrance(appeared, delay: 0.12, reduceMotion: reduceMotion)
            Text(KMR.t("Pulisci, proteggi e velocizza il tuo Mac. Gratis, open source, senza tracciamento.",
                       "Clean, protect and speed up your Mac. Free, open source, no tracking."))
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                .padding(.top, 8)
                .entrance(appeared, delay: 0.2, reduceMotion: reduceMotion)

            InstallCallToAction(title: KMR.t("Installa in Applicazioni", "Install in Applications"),
                                reduceMotion: reduceMotion) { model.install() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 26)
                .entrance(appeared, delay: 0.3, reduceMotion: reduceMotion)

            HStack(spacing: 22) {
                Toggle(KMR.t("Espelli il disco dopo l'installazione", "Eject the disk after installing"),
                       isOn: $model.ejectAfterInstall)
                    .toggleStyle(.checkbox)
                    .disabled(model.sourceVolume == nil)
                Button(KMR.t("Apri senza installare", "Open without installing")) { skip() }
                    .buttonStyle(.link)
                    .tint(.white)
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.top, 18)
            .entrance(appeared, delay: 0.38, reduceMotion: reduceMotion)

            destinationLine
                .padding(.top, 16)
                .entrance(appeared, delay: 0.45, reduceMotion: reduceMotion)
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    @ViewBuilder
    private var destinationLine: some View {
        if let folder = model.destinationFolder {
            let name = FileManager.default.displayName(atPath: folder.path)
            let text = model.replacesExisting
                ? KMR.t("Verrà copiata in «\(name)». La versione precedente andrà nel Cestino.",
                        "It will be copied to “\(name)”. The previous version goes to the Trash.")
                : KMR.t("Verrà copiata in «\(name)».", "It will be copied to “\(name)”.")
            Label(text, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func status(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.03, green: 0.12, blue: 0.4).opacity(0.45), radius: 10, y: 3)
                .contentTransition(.opacity)
            Text(detail)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.opacity)
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(KMR.t("Installazione non riuscita", "Installation failed"))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text(KMR.t("Puoi installarla a mano: trascina l'icona di Mac Mop sulla cartella Applicazioni nella finestra del disco.",
                       "You can install it by hand: drag the Mac Mop icon onto the Applications folder in the disk window."))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button(KMR.t("Riprova", "Try Again")) { model.reset(); model.install() }
                    .buttonStyle(.borderedProminent)
                Button(KMR.t("Mostra nel Finder", "Show in Finder")) { model.showInFinder() }
                Button(KMR.t("Apri senza installare", "Open without installing")) { skip() }
            }
            .controlSize(.large)
            .padding(.top, 10)
        }
        .transition(.opacity)
    }

    private func stepText(_ step: InstallStep) -> String {
        switch step {
        case .copying: KMR.t("Copio Mac Mop nella cartella Applicazioni…", "Copying Mac Mop to the Applications folder…")
        case .replacing: KMR.t("Sposto la versione precedente nel Cestino…", "Moving the previous version to the Trash…")
        case .finishing: KMR.t("Ultimi ritocchi…", "Finishing up…")
        case .done: KMR.t("Fatto", "Done")
        }
    }

    private func skip() {
        InstallerWindowChrome.restore(window)
        onSkip()
    }

    // MARK: Debug snapshot (KMR_SNAPSHOT + KMR_FORCE_INSTALLER=1 [KMR_INSTALLER_DEMO=progress|done|failed])

    private func snapshotIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        if let demo = env["KMR_INSTALLER_DEMO"] { model.demo(demo) }
        guard let path = env["KMR_SNAPSHOT"] else { return }
        try? await Task.sleep(for: .seconds(Double(env["KMR_DELAY"] ?? "") ?? 2.5))
        guard let window = window ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 0)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Stage (scene + hero icon + Applications folder)

private struct InstallerStage: View {
    let phase: InstallerModel.Phase
    let t: Double
    let progress: Double
    let doneSince: Double?
    let appeared: Bool

    /// The app icon; unbundled debug builds (KMR_FORCE_INSTALLER from the
    /// build folder) borrow Resources/AppIcon.icns from the working copy.
    private static let appIcon: NSImage = {
        if Bundle.main.bundleIdentifier == nil,
           let icon = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns") {
            return icon
        }
        return NSApp.applicationIconImage ?? NSImage()
    }()
    private static let folderIcon = NSWorkspace.shared.icon(forFile: "/Applications")

    private var installing: Bool { phase != .welcome && !isFailed }
    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            let geom = InstallerArt.Geometry(size: s, doneSince: doneSince)
            let flight = installing ? InstallerArt.flightPoint(geom, progress) : nil
            ZStack {
                Canvas { ctx, size in
                    InstallerArt.scene(&ctx, size, t: t, geom: geom, flight: flight, progress: progress,
                                       installing: installing, doneSince: doneSince)
                }
                if installing {
                    folder(geom)
                }
                hero(geom, flight: flight)
            }
        }
        .accessibilityHidden(true)
    }

    private func hero(_ g: InstallerArt.Geometry, flight: InstallerArt.Flight?) -> some View {
        let bob = sin(t * 1.25) * 6
        let tilt = sin(t * 0.8) * 1.8
        let center = flight?.point ?? CGPoint(x: g.hero.x, y: g.hero.y + bob)
        let scale = flight?.scale ?? 1
        return Image(nsImage: Self.appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: g.iconSize, height: g.iconSize)
            .rotationEffect(.degrees(flight == nil ? tilt : (flight?.spin ?? 0)))
            .scaleEffect(appeared ? scale : 0.55)
            .opacity(appeared ? (flight?.opacity ?? 1) : 0)
            .shadow(color: Color(red: 0.02, green: 0.10, blue: 0.38).opacity(0.38), radius: 18, y: 12)
            .position(center)
    }

    private func folder(_ g: InstallerArt.Geometry) -> some View {
        let done = doneSince != nil
        let pop = doneSince.map { InstallerArt.springPop($0) } ?? 0
        let ringSize = g.folderSize * 1.42
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 6)
                .frame(width: ringSize, height: ringSize)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(AngularGradient(colors: [Color(red: 0.75, green: 0.92, blue: 1), .white, Color(red: 0.75, green: 0.92, blue: 1)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: ringSize, height: ringSize)
                .shadow(color: .white.opacity(0.6), radius: 6)
            Image(nsImage: Self.folderIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: g.folderSize, height: g.folderSize)
                .scaleEffect(1 + 0.12 * pop)
                .shadow(color: Color(red: 0.02, green: 0.10, blue: 0.38).opacity(0.3), radius: 12, y: 8)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .systemGreen))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .scaleEffect(min(1, (doneSince ?? 0) * 4) * (1 + 0.25 * pop))
                    .offset(x: ringSize * 0.36, y: ringSize * 0.36)
            }
        }
        .position(g.folder)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - Drawing

enum InstallerArt {
    static let stillTime: Double = 1.3

    struct Geometry {
        let size: CGSize
        let hero: CGPoint
        let start: CGPoint
        let folder: CGPoint
        let iconSize: CGFloat
        let folderSize: CGFloat

        init(size: CGSize, doneSince: Double? = nil) {
            self.size = size
            hero = CGPoint(x: size.width / 2, y: 150)
            start = CGPoint(x: size.width * 0.30, y: 150)
            // On success the folder glides to the centre of the stage.
            let settle = InstallerArt.ease(((doneSince ?? 0) - 0.15) / 0.7)
            folder = CGPoint(x: size.width * (0.70 - 0.20 * settle), y: 150)
            iconSize = 150
            folderSize = 116
        }
    }

    struct Flight {
        let point: CGPoint
        let scale: Double
        let opacity: Double
        let spin: Double
    }

    static func ease(_ x: Double) -> Double { let k = min(max(x, 0), 1); return k * k * (3 - 2 * k) }

    /// Where the flying icon is for overall progress p: glide from the hero
    /// spot to the start slot (first 15 %), arc into the folder, sink in.
    static func flightPoint(_ g: Geometry, _ p: Double) -> Flight {
        if p <= InstallStep.copying.fraction {
            let k = ease(p / InstallStep.copying.fraction)
            return Flight(point: CGPoint(x: g.hero.x + (g.start.x - g.hero.x) * k, y: g.hero.y),
                          scale: 1 - 0.12 * k, opacity: 1, spin: 0)
        }
        let k = ease((p - InstallStep.copying.fraction) / (0.92 - InstallStep.copying.fraction))
        let a = g.start, c = g.folder
        let ctrl = CGPoint(x: (a.x + c.x) / 2, y: a.y - 120)
        let u = 1 - k
        let pt = CGPoint(x: u * u * a.x + 2 * u * k * ctrl.x + k * k * c.x,
                         y: u * u * a.y + 2 * u * k * ctrl.y + k * k * c.y)
        let scale = 0.88 - 0.55 * k
        let opacity = p > 0.9 ? max(0, 1 - (p - 0.9) / 0.08) : 1
        return Flight(point: pt, scale: scale, opacity: opacity, spin: sin(k * .pi) * 14)
    }

    /// 0 → 1 → settles: a single elastic pop for the success moment.
    static func springPop(_ s: Double) -> Double {
        guard s > 0 else { return 0 }
        return exp(-4.5 * s) * sin(s * 13) * 1.4
    }

    static func hash(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    static func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    static func scene(_ ctx: inout GraphicsContext, _ s: CGSize, t: Double, geom: Geometry, flight: Flight?,
                      progress: Double, installing: Bool, doneSince: Double?) {
        let rect = CGRect(origin: .zero, size: s)
        // Base: the same sky-to-azure as the disk-image window.
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.80, green: 0.89, blue: 1.00), location: 0),
                .init(color: Color(red: 0.47, green: 0.66, blue: 0.97), location: 0.33),
                .init(color: Color(red: 0.22, green: 0.42, blue: 0.88), location: 0.68),
                .init(color: Color(red: 0.11, green: 0.25, blue: 0.70), location: 1),
            ]),
            startPoint: CGPoint(x: s.width * 0.35, y: 0), endPoint: CGPoint(x: s.width * 0.6, y: s.height)))

        aurora(&ctx, s, t)
        sheen(&ctx, s, t)
        bubbles(&ctx, s, t)

        if !installing {
            ripples(&ctx, CGPoint(x: geom.hero.x, y: geom.hero.y + geom.iconSize * 0.62), t)
            halo(&ctx, geom.hero, geom.iconSize, t)
            sparkles(&ctx, around: geom.hero, t: t, count: 30, inner: 95, outer: 250)
        } else {
            halo(&ctx, geom.folder, geom.folderSize * 0.9, t)
            if let flight { trail(&ctx, geom, progress, flight, t) }
            if let since = doneSince { burst(&ctx, geom.folder, since) }
            sparkles(&ctx, around: CGPoint(x: s.width / 2, y: geom.hero.y), t: t, count: 18, inner: 200, outer: 380)
        }
    }

    static func aurora(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let blobs: [(Double, Double, Double, Color, Double)] = [
            (0.12, 0.05, 0.62, .white, 0.55),
            (0.88, 0.18, 0.48, Color(red: 0.55, green: 0.90, blue: 1.0), 0.40),
            (0.80, 0.98, 0.62, Color(red: 0.45, green: 0.36, blue: 0.95), 0.40),
            (0.08, 0.92, 0.50, Color(red: 0.25, green: 0.70, blue: 1.0), 0.35),
            (0.50, 0.40, 0.40, Color(red: 0.85, green: 0.95, blue: 1.0), 0.18),
        ]
        ctx.drawLayer { layer in
            layer.blendMode = .screen
            for (i, b) in blobs.enumerated() {
                let wobbleX = sin(t * (0.07 + 0.02 * Double(i)) + Double(i) * 1.9) * 0.06
                let wobbleY = cos(t * (0.05 + 0.017 * Double(i)) + Double(i) * 2.3) * 0.05
                let c = CGPoint(x: (b.0 + wobbleX) * s.width, y: (b.1 + wobbleY) * s.height)
                let r = b.2 * s.width * (1 + 0.06 * sin(t * 0.3 + Double(i)))
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .radialGradient(Gradient(colors: [b.3.opacity(b.4), b.3.opacity(b.4 * 0.35), b.3.opacity(0)]),
                                                 center: c, startRadius: 0, endRadius: r))
            }
        }
    }

    /// Slow diagonal light sheens, like light crossing glass.
    static func sheen(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        ctx.drawLayer { layer in
            layer.translateBy(x: s.width / 2, y: s.height / 2)
            layer.rotate(by: .degrees(-28))
            let span = s.width * 1.9
            for (i, (w, speed, a)) in [(150.0, 26.0, 0.10), (40.0, 41.0, 0.14), (260.0, 17.0, 0.06)].enumerated() {
                let x = fract(t * speed / span + Double(i) * 0.37) * span - span / 2
                let r = CGRect(x: x - w / 2, y: -s.height, width: w, height: s.height * 2)
                layer.fill(Path(r), with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity(a), .white.opacity(0)]),
                    startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
            }
        }
    }

    /// Glass bubbles rising slowly: faint fill, lit rim, a specular spot.
    static func bubbles(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        for i in 0..<7 {
            let r = 12 + 34 * hash(i * 3 + 1)
            let speed = 0.012 + 0.018 * hash(i * 7 + 2)
            let ph = fract(t * speed + hash(i * 11 + 5))
            let x = hash(i * 5 + 3) * s.width + sin(t * 0.35 + Double(i) * 1.7) * 18
            let y = s.height + r - ph * (s.height + 2 * r)
            let fade = min(1, sin(ph * .pi) * 1.6)
            let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.02 * fade), .white.opacity(0.07 * fade), .white.opacity(0.16 * fade)]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            ctx.stroke(Path(ellipseIn: rect), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.42 * fade), .white.opacity(0.04 * fade)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)),
                lineWidth: 1.1)
            let spot = CGRect(x: x - r * 0.55, y: y - r * 0.6, width: r * 0.42, height: r * 0.26)
            ctx.fill(Path(ellipseIn: spot), with: .color(.white.opacity(0.35 * fade)))
        }
    }

    /// Soft pulsing glow behind an icon.
    static func halo(_ ctx: inout GraphicsContext, _ c: CGPoint, _ size: CGFloat, _ t: Double) {
        let breathe = 0.5 + 0.5 * sin(t * 1.6)
        let r = size * (0.95 + 0.08 * breathe)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(0.42 + 0.12 * breathe),
                                                         Color(red: 0.7, green: 0.9, blue: 1).opacity(0.18), .clear]),
                                       center: c, startRadius: 0, endRadius: r))
    }

    /// Water rings spreading under the floating icon (it is a mop, after all).
    static func ripples(_ ctx: inout GraphicsContext, _ c: CGPoint, _ t: Double) {
        let shadowW = 120.0 - 10 * sin(t * 1.25)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - shadowW / 2, y: c.y - 7, width: shadowW, height: 14)),
                 with: .radialGradient(Gradient(colors: [Color(red: 0.02, green: 0.1, blue: 0.4).opacity(0.28), .clear]),
                                       center: c, startRadius: 0, endRadius: shadowW / 2))
        for k in 0..<3 {
            let ph = fract(t / 3.2 + Double(k) / 3)
            let w = 70 + 240 * ph
            let h = w * 0.16
            let a = (1 - ph) * (1 - ph) * 0.5
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)),
                       with: .color(.white.opacity(a)), lineWidth: 1.4 - ph)
        }
    }

    static func star(_ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        let k = r * 0.24
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        return p
    }

    static func glowDot(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: Double, _ a: Double) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(a), .white.opacity(0)]),
                                       center: c, startRadius: 0, endRadius: r))
    }

    /// Twinkling four-point sparkles orbiting slowly around a centre.
    static func sparkles(_ ctx: inout GraphicsContext, around c: CGPoint, t: Double, count: Int, inner: Double, outer: Double) {
        for i in 0..<count {
            let dir = hash(i * 17) > 0.5 ? 1.0 : -1.0
            let ang = hash(i * 13 + 1) * 2 * .pi + t * (0.03 + 0.05 * hash(i * 3)) * dir
            let rr = inner + (outer - inner) * hash(i * 5 + 2)
            let rise = fract(t * 0.02 * (0.5 + hash(i * 23)) + hash(i * 29)) * 40 - 20
            let q = CGPoint(x: c.x + cos(ang) * rr, y: c.y + sin(ang) * rr * 0.62 - rise)
            let tw = pow(max(0, sin(t * (1.2 + 1.8 * hash(i * 31)) + hash(i * 37) * 6.28)), 3)
            guard tw > 0.02 else { continue }
            let size = 2.5 + 5.5 * hash(i * 41)
            glowDot(&ctx, q, size * 2.4, 0.35 * tw)
            ctx.fill(star(q, size * (0.6 + 0.4 * tw)), with: .color(.white.opacity(0.95 * tw)))
        }
    }

    /// Comet trail of droplets and sparkles behind the flying icon.
    static func trail(_ ctx: inout GraphicsContext, _ g: Geometry, _ p: Double, _ flight: Flight, _ t: Double) {
        guard p > InstallStep.copying.fraction + 0.01, p < 0.97 else { return }
        for k in 1...22 {
            let back = p - Double(k) * 0.011
            guard back > InstallStep.copying.fraction else { break }
            let q = flightPoint(g, back).point
            let fade = 1 - Double(k) / 23
            let jitter = CGPoint(x: sin(t * 7 + Double(k) * 1.3) * 5 * (1 - fade), y: cos(t * 6 + Double(k)) * 5 * (1 - fade))
            let pt = CGPoint(x: q.x + jitter.x, y: q.y + jitter.y)
            glowDot(&ctx, pt, 16 * fade + 4, 0.38 * fade)
            if k % 3 == 0 { ctx.fill(star(pt, 5 * fade + 1.5), with: .color(.white.opacity(0.9 * fade))) }
        }
    }

    /// Success: a ring of sparkles and droplets flying out of the folder.
    static func burst(_ ctx: inout GraphicsContext, _ c: CGPoint, _ since: Double) {
        let k = min(1, since / 1.1)
        guard k < 1 else { return }
        let e = 1 - pow(1 - k, 3)
        for i in 0..<26 {
            let ang = Double(i) / 26 * 2 * .pi + hash(i) * 0.3
            let r = 60 + 150 * e * (0.7 + 0.3 * hash(i * 7))
            let q = CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r * 0.85)
            let a = (1 - k)
            glowDot(&ctx, q, 10 * a + 2, 0.5 * a)
            ctx.fill(star(q, (i % 2 == 0 ? 6 : 3.5) * (1 - 0.5 * k)), with: .color(.white.opacity(a)))
        }
        let ring = 70 + 120 * e
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: 2 * ring, height: 2 * ring)),
                   with: .color(.white.opacity(0.45 * (1 - k))), lineWidth: 2.5 * (1 - k) + 0.5)
    }
}

// MARK: - Call to action

/// Big white capsule button with a light sheen sweeping across it.
private struct InstallCallToAction: View {
    let title: String
    let reduceMotion: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var sweep = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.down.app.fill")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .buttonStyle(CTAStyle(hovering: hovering, sweep: sweep))
        .onHover { hovering = $0 }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).delay(1.2).repeatForever(autoreverses: false)) { sweep = true }
        }
    }

    private struct CTAStyle: ButtonStyle {
        let hovering: Bool
        let sweep: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(Color(red: 0.07, green: 0.30, blue: 0.82))
                .padding(.horizontal, 34)
                .padding(.vertical, 15)
                .background {
                    ZStack {
                        Capsule().fill(LinearGradient(colors: [.white, Color(red: 0.90, green: 0.95, blue: 1)],
                                                      startPoint: .top, endPoint: .bottom))
                        // Light sheen sweeping under the label.
                        GeometryReader { geo in
                            LinearGradient(colors: [Color(red: 0.78, green: 0.89, blue: 1).opacity(0),
                                                    Color(red: 0.78, green: 0.89, blue: 1),
                                                    Color(red: 0.78, green: 0.89, blue: 1).opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 80, height: geo.size.height * 2)
                                .rotationEffect(.degrees(18))
                                .offset(x: sweep ? geo.size.width + 80 : -160, y: -geo.size.height / 2)
                        }
                        .clipShape(Capsule())
                    }
                    .allowsHitTesting(false)
                }
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                .shadow(color: Color(red: 0.03, green: 0.16, blue: 0.55).opacity(hovering ? 0.55 : 0.4),
                        radius: hovering ? 22 : 16, y: hovering ? 10 : 7)
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.035 : 1))
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
                .contentShape(Capsule())
        }
    }
}

// MARK: - Helpers

private extension View {
    /// Staggered fade-up on first appearance.
    func entrance(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.8).delay(delay), value: shown)
    }
}

/// Hides the title and the title-bar background so the scene runs under the
/// traffic lights (macOS 15+; the AppKit chrome below covers macOS 14).
private struct ImmersiveTitlebar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Makes the hosting window full-bleed (transparent title bar, fixed size,
/// draggable by the background) while the installer is shown, and restores
/// the standard main-window chrome when the user skips it.
struct InstallerWindowChrome: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.onWindow = { w in
            DispatchQueue.main.async { window = w }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            apply(window)
            // SwiftUI finishes configuring the window after this; apply again.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.apply(window)
                window.center()
            }
            onWindow?(window)
        }

        private func apply(_ window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(red: 0.47, green: 0.66, blue: 0.97, alpha: 1)
            window.setContentSize(InstallerView.size)
        }
    }

    static func restore(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.styleMask.remove(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor
        DispatchQueue.main.async {
            window.setContentSize(NSSize(width: 960, height: 620))
            window.center()
        }
    }
}
