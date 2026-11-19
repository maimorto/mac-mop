import SwiftUI
import MacCleanerKit

public struct ScanButton: View {
    let title: String
    let subtitle: String?
    let theme: ModuleTheme
    let isScanning: Bool
    let progress: Double
    let orbDiameter: CGFloat
    let action: () -> Void

    public init(
        title: String = L10n.tr("扫描", "Scan", "Сканировать"),
        subtitle: String? = nil,
        theme: ModuleTheme = .smartScan,
        isScanning: Bool = false,
        progress: Double = 0,
        orbDiameter: CGFloat = 128,
        action: @escaping () -> Void
    ) {
        self.orbDiameter = orbDiameter
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.isScanning = isScanning
        self.progress = progress
        self.action = action
    }

    public var body: some View {
        if isScanning {
            scanningContent
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var scanningContent: some View {
        RadarProgress(progress: progress, theme: theme, size: 110)
    }
}

public struct ScanProgressRing: View {
    let progress: Double
    let phase: String
    let detail: String?
    let theme: ModuleTheme
    let indeterminate: Bool
    let creeps: Bool
    @Environment(\.currentModule) private var module
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var budget = MotionBudget.shared
    /// When the reported progress last changed, and its value then.
    @State private var lastTarget: Double = 0
    /// What was on screen when the last update arrived (start of the glide).
    @State private var glideFrom: Double = 0
    @State private var lastChange = Date()
    @State private var started = Date()
    /// Recent progress steps (time, ring position): each throws a few sparks.
    @State private var bursts: [RingBurst] = []

    public init(progress: Double, phase: String, detail: String? = nil, theme: ModuleTheme = .smartScan,
                indeterminate: Bool = false, creeps: Bool = true) {
        self.creeps = creeps
        self.progress = progress
        self.phase = phase
        self.detail = detail
        self.theme = theme
        self.indeterminate = indeterminate
    }

    /// Real progress with a short glide; creeps only when updates are sparse
    /// (see ProgressCreep). Never moves backwards.
    private func displayed(at now: Date) -> Double {
        ProgressCreep.displayed(progress: progress, target: lastTarget, glideFrom: glideFrom,
                                waited: now.timeIntervalSince(lastChange), creeps: creeps)
    }

    public var body: some View {
        let tint = module?.group.tint ?? KMR.accent
        let running = budget.ambientAllowed(reduceMotion: reduceMotion)
        // 30 fps while animating; once a second otherwise (background, Low
        // Power, Reduce Motion) so the percentage and the clock stay current.
        TimelineView(.animation(minimumInterval: running ? 1.0 / 30.0 : 1.0)) { context in
            let now = context.date
            let shown = indeterminate ? 0 : displayed(at: now)
            let spin = running ? now.timeIntervalSince(started) : 0.9
            VStack(spacing: 22) {
                ZStack {
                    Canvas { ctx, size in
                        RingArt.draw(&ctx, size, shown: shown, spin: spin, tint: tint,
                                     indeterminate: indeterminate,
                                     bursts: running ? bursts : [], now: now.timeIntervalSinceReferenceDate)
                    }
                    .frame(width: 260, height: 260)
                    ScanMotifCanvas(item: module, progress: shown,
                                    time: running ? now.timeIntervalSinceReferenceDate : nil, size: 170)
                }
                .frame(width: 220, height: 220)
                .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(indeterminate ? "—" : "\(Int((shown * 100).rounded(.down)))%")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: shown))
                    Text(phase)
                        .font(.headline)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.25), value: phase)
                    HStack(spacing: 6) {
                        if let detail {
                            Text(detail).lineLimit(1).truncationMode(.middle)
                            Text("·")
                        }
                        Text(Self.elapsed(now.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            started = Date(); lastChange = Date(); lastTarget = progress; glideFrom = progress
            if let module { ScanActivity.shared.begin(module) }
        }
        .onDisappear { if let module { ScanActivity.shared.end(module) } }
        .onChange(of: progress) { old, v in
            // Re-base on what is on screen so the ring never moves backwards.
            let now = Date()
            let onScreen = displayed(at: now)
            glideFrom = onScreen
            lastTarget = max(v, onScreen)
            lastChange = now
            if v - old > 0.004, !indeterminate {
                let ref = now.timeIntervalSinceReferenceDate
                bursts = bursts.filter { ref - $0.time < RingArt.burstLife } + [RingBurst(time: ref, at: lastTarget)]
                if bursts.count > 6 { bursts.removeFirst(bursts.count - 6) }
            }
        }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let n = Int(s)
        return n < 60 ? "\(n) s" : "\(n / 60) min \(n % 60) s"
    }
}

struct RingBurst: Equatable {
    let time: Double
    let at: Double
}

/// The progress ring, drawn in one Canvas pass: a glass track with a slow
/// light sweep, the gradient arc with a soft glow, a glint running along it,
/// tick marks that light up behind the tip, a comet head, and sparks thrown
/// from the tip on each real progress step.
enum RingArt {
    static let burstLife = 0.9

    private static func hash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    private static func arc(_ c: CGPoint, _ r: Double, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        return p
    }

    private static func disc(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func pt(_ c: CGPoint, _ r: Double, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, shown: Double, spin: Double, tint: Color,
                     indeterminate: Bool, bursts: [RingBurst], now: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = 108.0
        let lw = 7.0
        let top = -Double.pi / 2

        // Glass track: tinted body, bright rim on top, darker below.
        let track = disc(c, R)
        ctx.stroke(track, with: .color(tint.opacity(0.13)), lineWidth: lw + 3)
        ctx.stroke(track, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.45), location: 0),
                             .init(color: .white.opacity(0.0), location: 0.45),
                             .init(color: .black.opacity(0.06), location: 1)]),
            startPoint: CGPoint(x: c.x, y: c.y - R), endPoint: CGPoint(x: c.x, y: c.y + R)), lineWidth: lw + 3)
        ctx.stroke(disc(c, R + (lw + 3) / 2), with: .color(.white.opacity(0.18)), lineWidth: 0.6)
        ctx.stroke(disc(c, R - (lw + 3) / 2), with: .color(.black.opacity(0.06)), lineWidth: 0.6)
        // Slow light sweep around the glass.
        ctx.stroke(track, with: .conicGradient(Gradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.35), location: 0.06),
            .init(color: .white.opacity(0), location: 0.14),
            .init(color: .white.opacity(0), location: 1),
        ]), center: c, angle: .radians(spin * 0.9)), lineWidth: lw + 3)

        // Outer ticks: lit up to the tip, brightest just behind it.
        let ticks = 60
        for i in 0..<ticks {
            let f = Double(i) / Double(ticks)
            let a = top + f * 2 * .pi
            let lit = !indeterminate && f <= shown
            let near = lit ? exp(-(shown - f) * 14) : 0
            let major = i % 5 == 0
            var tk = Path()
            tk.move(to: pt(c, R + 9, a)); tk.addLine(to: pt(c, R + (major ? 14 : 12), a))
            ctx.stroke(tk, with: .color(lit ? tint.opacity(0.45 + 0.55 * near) : Color.primary.opacity(0.10)),
                       style: StrokeStyle(lineWidth: major ? 1.4 : 1, lineCap: .round))
        }

        if indeterminate {
            for (k, speed) in [(0, 3.6), (1, -2.2)] {
                let a0 = spin * speed + Double(k) * .pi
                let len = 0.9 + 0.35 * sin(spin * 1.7 + Double(k))
                let seg = arc(c, R, a0, a0 + len)
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 5))
                    l.stroke(seg, with: .color(tint.opacity(0.6)), lineWidth: lw + 2)
                }
                ctx.stroke(seg, with: .conicGradient(Gradient(colors: [tint.opacity(0), tint]), center: c,
                                                     angle: .radians(a0)),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let head = pt(c, R, a0 + len)
                ctx.fill(disc(head, 7), with: .radialGradient(Gradient(colors: [.white, tint.opacity(0)]),
                                                             center: head, startRadius: 0, endRadius: 7))
            }
            return
        }

        let end = top + 2 * .pi * max(0.004, shown)
        let filled = arc(c, R, top, end)
        // Glow under the arc.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 6))
            l.stroke(filled, with: .color(tint.opacity(0.55)), style: StrokeStyle(lineWidth: lw + 3, lineCap: .round))
        }
        ctx.stroke(filled, with: .conicGradient(Gradient(colors: [tint.opacity(0.5), tint]), center: c,
                                                angle: .radians(top)),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))
        // Specular line along the arc (glass bead).
        ctx.stroke(arc(c, R - lw * 0.18, top, end), with: .color(.white.opacity(0.28)),
                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        // Travelling glint.
        let g = (spin * 0.6).truncatingRemainder(dividingBy: 1)
        let gEnd = top + 2 * .pi * shown * g
        let gStart = max(top, gEnd - 0.28)
        if gEnd > gStart {
            var l = ctx
            l.blendMode = .plusLighter
            l.stroke(arc(c, R, gStart, gEnd), with: .conicGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(0.9)]), center: c, angle: .radians(gStart)),
                style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        // Comet head with a pulsing halo.
        let tip = pt(c, R, end)
        let pulse = 0.5 + 0.5 * sin(spin * 5)
        ctx.fill(disc(tip, 12 + 3 * pulse), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.55), tint.opacity(0)]), center: tip, startRadius: 0, endRadius: 12 + 3 * pulse))
        ctx.fill(disc(tip, 4.6), with: .color(.white))

        // Sparks from each progress step.
        for (bi, b) in bursts.enumerated() {
            let age = now - b.time
            guard age >= 0, age < burstLife else { continue }
            let x = age / burstLife
            let a = top + 2 * .pi * b.at
            let origin = pt(c, R, a)
            for k in 0..<10 {
                let seed = Int(b.time * 1000) % 100_000 + bi * 31 + k
                let dir = a + (hash(seed) - 0.5) * 2.2 + (k % 2 == 0 ? 0 : .pi)
                let dist = (14 + 26 * hash(seed + 7)) * (1 - pow(1 - x, 3))
                let q = CGPoint(x: origin.x + cos(dir) * dist, y: origin.y + sin(dir) * dist + 10 * x * x)
                let r = (1.2 + 1.6 * hash(seed + 3)) * (1 - x)
                ctx.fill(disc(q, r * 2.6), with: .color(tint.opacity(0.25 * (1 - x))))
                ctx.fill(disc(q, r), with: .color(.white.opacity(1 - x)))
            }
            if x < 0.5 {
                let y = x / 0.5
                ctx.stroke(disc(origin, 5 + 14 * y), with: .color(tint.opacity(0.6 * (1 - y))), lineWidth: 1.2)
            }
        }
    }
}
