import SwiftUI
import MacCleanerKit

// Themed scan animations. Each module gets its own motif that tells the story
// of what the scan is doing: a vortex swallowing junk, a radar revealing
// blips, a fingerprint being enrolled, Wi-Fi waves finding access points, a
// revving gauge, meshing gears, jiggling app tiles, a treemap subdividing,
// two documents merging, a shredder. Every motif is a single Canvas pass
// inside one TimelineView that only runs while a scan is on screen, and
// pauses (showing a composed still frame) when the app is in the
// background, in Low Power Mode or with Reduce Motion.

enum ScanMotif {
    case sweep, radar, fingerprint, waves, gauge, gears, appGrid, treemap, merge, shred
    case layers, chain, checklist, unbox, network, eye, sleepyApps, platter

    init(_ item: SidebarItem?) {
        switch item {
        case .malwareRemoval, .browserExtensions, .appPermissions: self = .radar
        case .privacy: self = .fingerprint
        case .wifiNetworks: self = .waves
        case .optimization: self = .gauge
        case .maintenance: self = .gears
        case .uninstaller, .extensions, .updater: self = .appGrid
        case .unusedApps: self = .sleepyApps
        case .spaceLens, .largeOldFiles: self = .treemap
        case .duplicates: self = .merge
        case .shredder: self = .shred
        case .systemData: self = .layers
        case .persistence: self = .chain
        case .securityCheck: self = .checklist
        case .packages: self = .unbox
        case .ports: self = .network
        case .applePrivacy: self = .eye
        case .storageExtras: self = .platter
        default: self = .sweep
        }
    }
}

/// Standalone themed animation with its own 30 fps clock.
struct ThemedScanAnimation: View {
    let item: SidebarItem?
    let progress: Double
    var size: CGFloat = 200

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var budget = MotionBudget.shared

    init(item: SidebarItem?, progress: Double, size: CGFloat = 200) {
        self.item = item
        self.progress = progress
        self.size = size
    }

    var body: some View {
        let running = budget.ambientAllowed(reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
            ScanMotifCanvas(item: item, progress: progress,
                            time: running ? context.date.timeIntervalSinceReferenceDate : nil, size: size)
        }
    }
}

/// One frame of a module's motif at `time` (nil = the composed still frame).
/// Used inside a TimelineView that already ticks (ScanProgressRing), so the
/// motif doesn't run a second clock.
struct ScanMotifCanvas: View {
    let item: SidebarItem?
    let progress: Double
    let time: Double?
    var size: CGFloat = 200

    var body: some View {
        let motif = ScanMotif(item)
        let tint = item?.group.tint ?? KMR.accent
        let p = min(max(progress, 0), 1)
        let icon = item?.icon ?? "shield.lefthalf.filled"
        let side = size
        let t = time ?? ScanArt.stillTime
        Canvas { ctx, sz in
            ScanArt.ambient(&ctx, sz, t, tint)
            ScanArt.draw(motif, &ctx, sz, t: t, p: p, tint: tint)
        } symbols: {
            switch motif {
            case .radar:
                Image(systemName: icon)
                    .font(.system(size: side * 0.15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .tag(0)
            case .chain:
                Image(systemName: "power")
                    .font(.system(size: side * 0.12, weight: .bold))
                    .foregroundStyle(.white)
                    .tag(1)
            case .network:
                Image(systemName: "laptopcomputer")
                    .font(.system(size: side * 0.12, weight: .semibold))
                    .foregroundStyle(.white)
                    .tag(2)
            case .layers:
                ForEach(0..<3, id: \.self) { k in
                    Image(systemName: ["checkmark", "eye.fill", "lock.fill"][k])
                        .font(.system(size: side * 0.06, weight: .bold))
                        .foregroundStyle(.white)
                        .tag(3 + k)
                }
            default:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Drawing

private struct RidgeSegment: Sendable {
    let path: Path
    let ridge: Int
}

private enum ScanArt {
    /// Time used for the still frame (Reduce Motion, background, Low Power):
    /// every motif reads well at this instant.
    static let stillTime: Double = 0.9

    static func draw(_ m: ScanMotif, _ ctx: inout GraphicsContext, _ s: CGSize, t: Double, p: Double, tint: Color) {
        switch m {
        case .sweep: sweep(&ctx, s, t, p, tint)
        case .radar: radar(&ctx, s, t, p, tint)
        case .fingerprint: fingerprint(&ctx, s, t, p, tint)
        case .waves: waves(&ctx, s, t, p, tint)
        case .gauge: gauge(&ctx, s, t, p, tint)
        case .gears: gears(&ctx, s, t, p, tint)
        case .appGrid: appGrid(&ctx, s, t, p, tint)
        case .treemap: treemap(&ctx, s, t, p, tint)
        case .merge: merge(&ctx, s, t, p, tint)
        case .shred: shred(&ctx, s, t, p, tint)
        case .layers: layers(&ctx, s, t, p, tint)
        case .chain: chain(&ctx, s, t, p, tint)
        case .checklist: checklist(&ctx, s, t, p, tint)
        case .unbox: unbox(&ctx, s, t, p, tint)
        case .network: network(&ctx, s, t, p, tint)
        case .eye: eye(&ctx, s, t, p, tint)
        case .sleepyApps: sleepyApps(&ctx, s, t, p, tint)
        case .platter: platter(&ctx, s, t, p, tint)
        }
    }

    // MARK: Math & easing

    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
    static func fract(_ x: Double) -> Double { x - floor(x) }
    static func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }

    /// Deterministic 0..<1 noise from an integer (SplitMix64).
    static func hash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let u = clamp((x - a) / (b - a))
        return u * u * (3 - 2 * u)
    }
    static func easeInOut(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func easeOut(_ x: Double) -> Double { let x = clamp(x); return 1 - pow(1 - x, 3) }
    static func easeIn(_ x: Double) -> Double { let x = clamp(x); return x * x * x }
    /// Under-damped spring step: 0 → 1 with a soft overshoot.
    static func spring(_ x: Double, damping: Double = 7, freq: Double = 1.6) -> Double {
        x <= 0 ? 0 : 1 - exp(-damping * x) * cos(2 * .pi * freq * x)
    }

    // MARK: Geometry helpers

    static func pt(_ c: CGPoint, _ r: Double, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }
    static func disc(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }
    static func arc(_ c: CGPoint, _ r: Double, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        return p
    }
    static func ellipseArc(_ c: CGPoint, _ rx: Double, _ ry: Double, _ a0: Double, _ a1: Double, steps: Int = 14) -> Path {
        var p = Path()
        for k in 0...steps {
            let a = a0 + (a1 - a0) * Double(k) / Double(steps)
            let q = CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
            if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
    static func triangle(_ r: Double) -> Path {
        var p = Path()
        for k in 0..<3 {
            let q = pt(.zero, r, -Double.pi / 2 + Double(k) * 2 * .pi / 3)
            if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
    /// Four-point sparkle with concave sides.
    static func sparkle(_ c: CGPoint, _ r: Double, _ rot: Double) -> Path {
        var p = Path()
        p.move(to: pt(c, r, rot))
        for k in 0..<4 {
            let a = rot + Double(k) * .pi / 2
            p.addQuadCurve(to: pt(c, r, a + .pi / 2), control: pt(c, r * 0.14, a + .pi / 4))
        }
        p.closeSubpath()
        return p
    }
    /// Check mark centred on the origin, `w` wide.
    static func check(_ w: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -0.42 * w, y: 0.02 * w))
        p.addLine(to: CGPoint(x: -0.12 * w, y: 0.30 * w))
        p.addLine(to: CGPoint(x: 0.44 * w, y: -0.30 * w))
        return p
    }
    static func glow(_ ctx: inout GraphicsContext, _ radius: Double, _ body: (inout GraphicsContext) -> Void) {
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            body(&layer)
        }
    }
    static func softDot(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: Double, _ color: Color, _ alpha: Double) {
        ctx.fill(disc(c, r), with: .radialGradient(
            Gradient(colors: [color.opacity(alpha), color.opacity(0)]), center: c, startRadius: 0, endRadius: r))
    }

    // MARK: - Cleanup: a vortex swallowing junk

    // A tilted accretion disc seen in perspective. Junk fragments spiral in
    // with Kepler-like acceleration, heat up to white and are absorbed by a
    // glowing core that flares on every absorption and grows with progress.
    // Particles behind the core are drawn before it, those in front after.

    static func sweep(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let R = s.width * 0.48
        let tilt = 0.40
        let coreR = R * (0.11 + 0.07 * p)

        let breathe = 0.5 + 0.5 * sin(t * 1.4)
        ctx.fill(disc(c, R), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.20 + 0.08 * breathe), tint.opacity(0.05), tint.opacity(0)]),
            center: c, startRadius: 0, endRadius: R))

        let n = 46
        var flash = 0.0
        for pass in 0..<2 {
            if pass == 1 { vortexCore(&ctx, c, coreR, tilt, flash, t, tint) }

            // Orbit streaks: inner orbits travel faster.
            for k in 0..<5 {
                let rr = R * (0.30 + 0.16 * Double(k))
                let omega = 1.6 / pow(Double(k) + 1, 0.9)
                for seg in 0..<3 {
                    let a0 = Double(seg) * 2 * .pi / 3 + t * omega + Double(k) * 0.9
                    let mid = sin(a0 + 0.55)
                    if (mid >= 0) != (pass == 1) { continue }
                    let o = (0.14 + 0.20 * (mid * 0.5 + 0.5)) * (1 - 0.12 * Double(k))
                    ctx.stroke(ellipseArc(c, rr, rr * tilt, a0, a0 + 1.1),
                               with: .color(tint.opacity(o)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }

            for i in 0..<n {
                let life = 2.4 + 1.8 * hash(i)
                let cyc = t / life + hash(i + 500)
                let ph = fract(cyc)
                let gen = Int(floor(cyc))
                if pass == 0 { flash += smooth(0.84, 0.96, ph) * (1 - smooth(0.96, 1, ph)) }
                let (q, depth) = vortexPoint(c, R, coreR, tilt, i, gen, ph)
                if (depth >= 0) != (pass == 1) { continue }

                let near = depth * 0.5 + 0.5
                let alpha = smooth(0, 0.1, ph) * (1 - smooth(0.9, 1, ph)) * (0.65 + 0.35 * near)
                let sz = (2.0 + 3.8 * hash(i + 77)) * (1 - 0.55 * ph) * (0.85 + 0.3 * near)

                let (q0, _) = vortexPoint(c, R, coreR, tilt, i, gen, max(0, ph - 0.04))
                ctx.stroke(line(q0, q), with: .color(tint.opacity(alpha * 0.35)),
                           style: StrokeStyle(lineWidth: max(0.6, sz * 0.6), lineCap: .round))

                var g = ctx
                g.translateBy(x: q.x, y: q.y)
                g.rotate(by: .radians(t * (1 + 3 * hash(i + 9)) + Double(i)))
                let col = GraphicsContext.Shading.color(tint.opacity(alpha))
                switch i % 3 {
                case 0:
                    g.fill(Path(roundedRect: CGRect(x: -sz / 2, y: -sz / 2, width: sz, height: sz),
                                cornerRadius: sz * 0.22), with: col)
                case 1:
                    g.fill(triangle(sz * 0.65), with: col)
                default:
                    g.fill(disc(.zero, sz * 0.5), with: col)
                }
                let hot = smooth(0.76, 0.95, ph) * (1 - smooth(0.95, 1, ph))
                if hot > 0.01 { g.fill(disc(.zero, sz * 0.6), with: .color(.white.opacity(hot))) }
            }
        }
    }

    static func vortexPoint(_ c: CGPoint, _ R: Double, _ coreR: Double, _ tilt: Double,
                            _ i: Int, _ gen: Int, _ ph: Double) -> (CGPoint, Double) {
        let a0 = hash(i * 977 + gen * 131) * 2 * .pi
        let r = coreR * 0.6 + (R * 0.98 - coreR * 0.6) * (1 - pow(ph, 1.5))
        let a = a0 + 1.3 * ph + 3.6 * ph * ph * ph
        let lift = (hash(i * 31 + gen * 7) - 0.5) * R * 0.85 * (1 - ph) * (1 - ph)
        return (CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * tilt - lift), sin(a))
    }

    static func vortexCore(_ ctx: inout GraphicsContext, _ c: CGPoint, _ coreR: Double, _ tilt: Double,
                           _ flash: Double, _ t: Double, _ tint: Color) {
        let f = min(flash, 1.6)
        let ringRx = coreR * 1.75
        let ring = GraphicsContext.Shading.color(.white.opacity(0.30 + 0.30 * f))
        glow(&ctx, 9) { $0.fill(disc(c, coreR * 1.9 + f * 3), with: .color(tint.opacity(0.5 + 0.2 * f))) }
        ctx.stroke(ellipseArc(c, ringRx, ringRx * tilt, .pi, 2 * .pi), with: ring, lineWidth: 1.1)
        ctx.fill(disc(c, coreR), with: .radialGradient(
            Gradient(colors: [.white, tint.opacity(0.9), tint]),
            center: CGPoint(x: c.x - coreR * 0.3, y: c.y - coreR * 0.35), startRadius: 0, endRadius: coreR * 1.4))
        ctx.stroke(ellipseArc(c, ringRx, ringRx * tilt, 0, .pi), with: ring, lineWidth: 1.1)
        let r = coreR * (0.75 + 0.35 * f + 0.08 * sin(t * 3))
        ctx.fill(sparkle(c, r, t * 0.5), with: .color(.white.opacity(0.92)))
    }

    // MARK: - Protection: radar with sonar pings

    // Flat top-down scope. A bezel of ticks fills with progress and glows in
    // the beam's wake; the beam leaves a conic afterglow. Blips are revealed
    // only as the beam crosses them: a white flash, a sonar ripple, then a
    // slow tint decay. Every revolution relocates them and sends a pulse out
    // of the centre shield.

    static func radar(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let R = s.width * 0.48
        let face = R * 0.84
        let period = 3.0
        let rev = t / period
        let beam = fract(rev) * 2 * .pi - .pi / 2

        ctx.fill(disc(c, face), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.15), tint.opacity(0.04)]), center: c, startRadius: 0, endRadius: face))

        // Range rings and spokes.
        for k in 1...3 {
            let rr = face * Double(k) / 3
            ctx.stroke(disc(c, rr), with: .color(tint.opacity(k == 3 ? 0.35 : 0.16)),
                       style: StrokeStyle(lineWidth: k == 3 ? 1 : 0.75, dash: k == 2 ? [2, 3] : []))
        }
        var spokes = Path()
        for k in 0..<8 {
            let a = Double(k) * .pi / 4
            spokes.move(to: pt(c, face * 0.22, a))
            spokes.addLine(to: pt(c, face, a))
        }
        ctx.stroke(spokes, with: .color(tint.opacity(0.09)), lineWidth: 0.75)

        // Bezel ticks: lit by progress, glowing in the beam's wake.
        let ticks = 72
        for i in 0..<ticks {
            let f = Double(i) / Double(ticks)
            let a = f * 2 * .pi - .pi / 2
            let wake = exp(-fract((beam - a) / (2 * .pi)) * 9)
            let lit = f < p
            let major = i % 6 == 0
            let tk = line(pt(c, R * (major ? 0.875 : 0.905), a), pt(c, R * 0.965, a))
            let style = StrokeStyle(lineWidth: major ? 1.6 : 1.0, lineCap: .round)
            ctx.stroke(tk, with: .color(tint.opacity(min(1, (lit ? 0.8 : 0.16) + 0.3 * wake))), style: style)
            if wake > 0.08 { ctx.stroke(tk, with: .color(.white.opacity(wake * 0.6)), style: style) }
        }

        // Beam afterglow.
        ctx.fill(disc(c, face), with: .conicGradient(
            Gradient(stops: [
                .init(color: tint.opacity(0), location: 0),
                .init(color: tint.opacity(0), location: 0.68),
                .init(color: tint.opacity(0.16), location: 0.9),
                .init(color: tint.opacity(0.55), location: 1),
            ]), center: c, angle: .radians(beam)))

        // Blips, revealed as the beam passes their (fixed) bearing.
        let slots = 7
        for i in 0..<slots {
            let theta = (Double(i) + 0.15 + 0.7 * hash(i + 40)) / Double(slots) * 2 * .pi - .pi / 2
            let hitAt = (theta + .pi / 2) / (2 * .pi)
            let k = floor(rev - hitAt)
            let age = (rev - hitAt - k) * period
            let seed = Int(k) * 13 + i
            guard age < 2.6, hash(seed * 7 + 3) < 0.45 + 0.4 * p else { continue }
            let q = pt(c, face * (0.22 + 0.68 * hash(seed * 5 + 1)), theta)
            let fade = exp(-age * 1.3)
            softDot(&ctx, q, 9, tint, 0.7 * fade)
            if age < 1.1 {
                let x = age / 1.1
                ctx.stroke(disc(q, 3 + 15 * easeOut(x)), with: .color(tint.opacity(0.8 * (1 - x) * (1 - x))), lineWidth: 1)
            }
            let dotR = 2.2 + 1.8 * exp(-age * 5)
            ctx.fill(disc(q, dotR), with: .color(tint.opacity(0.25 + 0.75 * fade)))
            ctx.fill(disc(q, dotR * 0.8), with: .color(.white.opacity(exp(-age * 6))))
        }

        // Leading edge.
        let tip = pt(c, face, beam)
        let edge = line(c, tip)
        glow(&ctx, 3) { $0.stroke(edge, with: .color(tint), lineWidth: 3) }
        ctx.stroke(edge, with: .linearGradient(Gradient(colors: [tint.opacity(0.2), .white.opacity(0.95)]),
                                               startPoint: c, endPoint: tip), lineWidth: 1.3)

        // Centre pulse once per revolution.
        let age0 = fract(rev) * period
        if age0 < 1.8 {
            let x = age0 / 1.8
            ctx.stroke(disc(c, face * 0.2 + face * 0.75 * easeOut(x)),
                       with: .color(tint.opacity(0.45 * (1 - x))), lineWidth: 1.5 * (1 - x) + 0.5)
        }
        let hub = disc(c, face * 0.21)
        ctx.fill(hub, with: .radialGradient(Gradient(colors: [tint.opacity(0.30), tint.opacity(0.10)]),
                                            center: c, startRadius: 0, endRadius: face * 0.21))
        ctx.stroke(hub, with: .color(tint.opacity(0.45)), lineWidth: 1)
        if let symbol = ctx.resolveSymbol(id: 0) {
            var g = ctx
            g.translateBy(x: c.x, y: c.y)
            let k = 1 + 0.09 * exp(-age0 * 6) * cos(age0 * 14)
            g.scaleBy(x: k, y: k)
            g.draw(symbol, at: .zero)
        }
    }

    // MARK: - Privacy: Touch ID / Face ID enrolment

    // A procedural fingerprint whorl. Ridges are drawn on progressively (stroke
    // trim) as progress grows, a horizontal scanner sweeps up and down with a
    // trailing light sheet and lights the ridges it crosses, and a Face ID
    // style ring of ticks extends with a spring as each segment enrols.

    static let ridgeSegments: [RidgeSegment] = {
        var out: [RidgeSegment] = []
        for k in 0..<8 {
            let kd = Double(k)
            let rk = 0.12 + 0.11 * kd
            let open = k == 0 ? 1.4 : asin(min(0.95, 0.11 / (rk * 0.84)))
            let start = Double.pi / 2 + open
            let end = Double.pi * 2.5 - open
            var spans: [(Double, Double)] = [(start, end)]
            if k >= 2 {
                let b = 1.5 * Double.pi + (hash(k * 11) - 0.5) * 2.4
                let hw = 0.10 + 0.06 * hash(k * 5)
                if b - hw > start, b + hw < end { spans = [(start, b - hw), (b + hw, end)] }
            }
            for (a0, a1) in spans {
                var p = Path()
                let steps = max(8, Int((a1 - a0) / 0.07))
                for j in 0...steps {
                    let a = a0 + (a1 - a0) * Double(j) / Double(steps)
                    let r = rk * (1 + 0.045 * sin(2 * a + kd) + 0.025 * sin(3 * a + 1.3 * kd))
                    let q = CGPoint(x: cos(a) * r * 0.84, y: sin(a) * r * 1.02 - 0.06)
                    if j == 0 { p.move(to: q) } else { p.addLine(to: q) }
                }
                out.append(RidgeSegment(path: p, ridge: k))
            }
        }
        // Two flat ridges under the whorl.
        for (j, rad) in [1.78, 1.92].enumerated() {
            var p = Path()
            for i in 0...16 {
                let a = Double.pi / 2 + (Double(i) / 16 - 0.5) * (0.52 - 0.08 * Double(j))
                let q = CGPoint(x: cos(a) * rad, y: -1.0 + sin(a) * rad)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            out.append(RidgeSegment(path: p, ridge: 8))
        }
        return out
    }()

    static func fingerprint(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let S = w * 0.33

        // Face ID ring.
        let ticks = 64
        let rIn = w * 0.405, rOut = w * 0.475
        let shimmer = fract(t * 0.28)
        for i in 0..<ticks {
            let f = Double(i) / Double(ticks)
            let a = f * 2 * .pi - .pi / 2
            let since = p - f
            var len: Double
            var col: Color
            if since > 0 {
                let frontier = exp(-since * 30)
                len = lerp(0.35, 1.0, spring(since * 24)) * (1 + 0.08 * frontier * sin(t * 7 - f * 40))
                col = tint.opacity(0.85 + 0.15 * frontier)
            } else {
                var d = abs(f - shimmer); d = min(d, 1 - d)
                let bump = exp(-pow(d * Double(ticks) / 5, 2))
                len = 0.32 + 0.22 * bump
                col = tint.opacity(0.20 + 0.30 * bump)
            }
            let tk = line(pt(c, rOut - (rOut - rIn) * len, a), pt(c, rOut, a))
            ctx.stroke(tk, with: .color(col), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // Scanner position: eased ping-pong.
        let u = fract(t / 2.6)
        let tri = u < 0.5 ? u * 2 : 2 - u * 2
        let top = c.y - S * 0.98, bottom = c.y + S * 0.90
        let scanY = lerp(top, bottom, easeInOut(tri))
        let dir = u < 0.5 ? 1.0 : -1.0

        // Ridges.
        let xf = CGAffineTransform(a: S, b: 0, c: 0, d: S, tx: c.x, ty: c.y)
        let style = StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)
        let band = Gradient(stops: [.init(color: tint.opacity(0), location: 0),
                                    .init(color: tint, location: 0.5),
                                    .init(color: tint.opacity(0), location: 1)])
        let core = Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                    .init(color: .white.opacity(0.95), location: 0.5),
                                    .init(color: .white.opacity(0), location: 1)])
        for seg in ridgeSegments {
            let path = seg.path.applying(xf)
            ctx.stroke(path, with: .color(tint.opacity(0.16)), style: style)
            let reveal = clamp(p * 10 - Double(seg.ridge))
            if reveal > 0 {
                ctx.stroke(reveal >= 1 ? path : path.trimmedPath(from: 0, to: reveal),
                           with: .color(tint.opacity(0.88)), style: style)
            }
            ctx.stroke(path, with: .linearGradient(band, startPoint: CGPoint(x: 0, y: scanY - 22),
                                                   endPoint: CGPoint(x: 0, y: scanY + 22)), style: style)
            ctx.stroke(path, with: .linearGradient(core, startPoint: CGPoint(x: 0, y: scanY - 7),
                                                   endPoint: CGPoint(x: 0, y: scanY + 7)), style: style)
        }

        // Scan line with trailing light sheet, clipped to the sensor.
        let clipR = S * 1.02
        let dy = scanY - c.y
        let half = sqrt(max(0, clipR * clipR - dy * dy))
        guard half > 2 else { return }
        var cl = ctx
        cl.clip(to: disc(c, clipR))
        let sheetH = 28.0
        let far = scanY - dir * sheetH
        cl.fill(Path(CGRect(x: c.x - half, y: min(far, scanY), width: half * 2, height: sheetH)),
                with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0)]),
                                      startPoint: CGPoint(x: 0, y: scanY), endPoint: CGPoint(x: 0, y: far)))
        let bar = Path(roundedRect: CGRect(x: c.x - half, y: scanY - 0.8, width: half * 2, height: 1.6), cornerRadius: 0.8)
        let across = Gradient(stops: [.init(color: tint.opacity(0), location: 0),
                                      .init(color: tint, location: 0.25),
                                      .init(color: .white, location: 0.5),
                                      .init(color: tint, location: 0.75),
                                      .init(color: tint.opacity(0), location: 1)])
        let shade = GraphicsContext.Shading.linearGradient(across, startPoint: CGPoint(x: c.x - half, y: 0),
                                                           endPoint: CGPoint(x: c.x + half, y: 0))
        glow(&cl, 4) { $0.fill(bar, with: shade) }
        cl.fill(bar, with: shade)
    }

    // MARK: - Wi-Fi: emanating waves find access points

    // A directional fan, not rings: the Wi-Fi glyph lights dot → arc → arc →
    // arc like a travelling pulse, which then leaves the glyph as a wavefront.
    // Access points light up exactly when a wavefront reaches them (ripple and
    // a fading link line back to the source); more are discovered as progress
    // grows, and signal bars under the glyph fill with progress.

    static func waves(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let O = CGPoint(x: c.x, y: c.y + w * 0.17)
        let up = -Double.pi / 2
        let spread = 0.78

        // Fan backdrop.
        var fan = Path()
        fan.move(to: O)
        fan.addArc(center: O, radius: w * 0.62, startAngle: .radians(up - spread), endAngle: .radians(up + spread), clockwise: false)
        fan.closeSubpath()
        ctx.fill(fan, with: .radialGradient(Gradient(colors: [tint.opacity(0.14), tint.opacity(0)]),
                                            center: O, startRadius: w * 0.05, endRadius: w * 0.62))
        for rr in [0.40, 0.52] {
            ctx.stroke(arc(O, w * rr, up - spread, up + spread), with: .color(tint.opacity(0.10)),
                       style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 3]))
        }

        // Wavefronts.
        let emit = 1.1, life = 2.0
        let r0 = w * 0.30, r1 = w * 0.64
        let e = t / emit
        for j in 0..<2 {
            let age = (fract(e) + Double(j)) * emit
            guard age < life else { continue }
            let x = age / life
            let r = r0 + (r1 - r0) * easeOut(x)
            let wave = arc(O, r, up - spread * (1 - 0.15 * x), up + spread * (1 - 0.15 * x))
            let o = (1 - x) * (1 - x)
            if x < 0.4 { glow(&ctx, 3) { $0.stroke(wave, with: .color(tint.opacity(o * 0.8)), lineWidth: 4) } }
            ctx.stroke(wave, with: .color(tint.opacity(o * 0.9)),
                       style: StrokeStyle(lineWidth: lerp(3, 0.6, x), lineCap: .round))
        }

        // Access points.
        for i in 0..<6 {
            let rho = w * (0.36 + 0.24 * hash(i * 3 + 1))
            let ang = up + (hash(i * 3 + 2) - 0.5) * 2 * 0.62
            let q = pt(O, rho, ang)
            let show = smooth(0, 1, 1.5 + p * 5 - Double(i))
            guard show > 0 else { continue }
            let xr = clamp((rho - r0) / (r1 - r0))
            let tHit = (1 - pow(1 - xr, 1.0 / 3.0)) * life
            let ageP = fract((t - tHit) / emit) * emit
            let ping = exp(-ageP * 3)
            ctx.stroke(line(O, q), with: .color(tint.opacity(0.22 * exp(-ageP * 2.5) * show)),
                       style: StrokeStyle(lineWidth: 0.75, dash: [2, 2.5]))
            softDot(&ctx, q, 8, tint, 0.7 * ping * show)
            if ageP < 0.9 {
                let x = ageP / 0.9
                ctx.stroke(disc(q, 2 + 10 * easeOut(x)), with: .color(tint.opacity(0.7 * (1 - x) * show)), lineWidth: 1)
            }
            ctx.fill(disc(q, 2.2 + 0.8 * ping), with: .color(tint.opacity((0.45 + 0.55 * ping) * show)))
            ctx.fill(disc(q, 1.4), with: .color(.white.opacity(ping * show)))
        }

        // Glyph: a pulse runs dot → arc 3 and becomes the next wavefront.
        let u = fract(e)
        let lw = w * 0.045
        for j in 0..<4 {
            let centre = 0.55 + 0.125 * Double(j)
            let d = fract(u - centre + 0.5) - 0.5
            let level = exp(-pow(d / 0.11, 2))
            let col = tint.opacity(0.35 + 0.65 * level)
            if j == 0 {
                ctx.fill(disc(O, lw * 0.8), with: .color(col))
                if level > 0.05 { softDot(&ctx, O, lw * 2.2, tint, level * 0.6) }
            } else {
                let rr = w * (0.08 + 0.075 * Double(j - 1))
                let a = arc(O, rr, up - 0.80, up + 0.80)
                if level > 0.05 { glow(&ctx, 3) { $0.stroke(a, with: .color(tint.opacity(level)), lineWidth: lw) } }
                ctx.stroke(a, with: .color(col), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                if level > 0.05 {
                    ctx.stroke(a, with: .color(.white.opacity(level * 0.5)), style: StrokeStyle(lineWidth: lw * 0.35, lineCap: .round))
                }
            }
        }

        // Signal bars (progress).
        let bw = w * 0.03, gap = w * 0.018
        let baseY = c.y + w * 0.37
        let x0 = c.x - (4 * bw + 3 * gap) / 2
        for j in 0..<4 {
            let h = w * (0.03 + 0.022 * Double(j))
            let rect = CGRect(x: x0 + Double(j) * (bw + gap), y: baseY - h, width: bw, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: bw * 0.35), with: .color(tint.opacity(0.18)))
            let fill = clamp(p * 4 - Double(j))
            guard fill > 0 else { continue }
            let fh = h * min(spring(fill * 2.2), 1.08)
            ctx.fill(Path(roundedRect: CGRect(x: rect.minX, y: baseY - fh, width: bw, height: fh), cornerRadius: bw * 0.35),
                     with: .linearGradient(Gradient(colors: [tint.opacity(0.75), tint]),
                                           startPoint: CGPoint(x: 0, y: baseY - h), endPoint: CGPoint(x: 0, y: baseY)))
        }
    }

    // MARK: - Optimization: a revving gauge

    // A 270° instrument. The needle rests at the progress value, then
    // periodically "revs": it climbs with ease-in-out and falls back on a
    // damped spring that overshoots below rest, with engine vibration and a
    // motion-blur ghost. Ticks light up to the needle, brightest near it, and
    // boost chevrons climb under the hub.

    static func gaugeValue(_ t: Double, _ p: Double) -> Double {
        let base = 0.06 + 0.86 * p
        let period = 3.4
        let u = fract(t / period) * period
        let amp = min(0.24, 1.02 - base)
        var v: Double
        if u < 0.5 {
            v = base + amp * easeInOut(u / 0.5)
        } else {
            let tau = u - 0.5
            v = base + amp * exp(-4.2 * tau) * cos(2 * .pi * 1.5 * tau)
        }
        v += 0.004 * sin(t * 41) + 0.003 * sin(t * 27.3)
        return clamp(v, 0, 1.02)
    }

    static func gauge(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let c = CGPoint(x: s.width / 2, y: s.height * 0.53)
        let R = s.width * 0.43
        let a0 = 0.75 * Double.pi, sweep = 1.5 * Double.pi
        func ang(_ v: Double) -> Double { a0 + sweep * v }
        let v = gaugeValue(t, p)
        let vc = min(v, 1)

        ctx.fill(disc(c, R), with: .radialGradient(Gradient(colors: [tint.opacity(0.12), tint.opacity(0.02)]),
                                                   center: c, startRadius: 0, endRadius: R))

        // Band.
        let bandR = R * 0.97
        let band = StrokeStyle(lineWidth: 6, lineCap: .round)
        ctx.stroke(arc(c, bandR, a0, a0 + sweep), with: .color(tint.opacity(0.14)), style: band)
        ctx.stroke(arc(c, bandR, a0, ang(max(vc, 0.005))), with: .conicGradient(
            Gradient(stops: [.init(color: tint.opacity(0.35), location: 0), .init(color: tint, location: 0.75)]),
            center: c, angle: .radians(a0)), style: band)
        let tipP = pt(c, bandR, ang(vc))
        glow(&ctx, 5) { $0.fill(disc(tipP, 6), with: .color(tint)) }
        ctx.fill(disc(tipP, 2.4), with: .color(.white.opacity(0.95)))

        // Ticks.
        let N = 40
        for i in 0...N {
            let f = Double(i) / Double(N)
            let a = ang(f)
            let major = i % 5 == 0
            let tk = line(pt(c, R * (major ? 0.70 : 0.77), a), pt(c, R * 0.86, a))
            let st = StrokeStyle(lineWidth: major ? 2.2 : 1.2, lineCap: .round)
            if f <= v {
                let near = exp(-(v - f) * 14)
                ctx.stroke(tk, with: .color(tint.opacity(0.5 + 0.5 * near)), style: st)
                if near > 0.4 { ctx.stroke(tk, with: .color(.white.opacity((near - 0.4) * 0.9)), style: st) }
            } else {
                ctx.stroke(tk, with: .color(Color.gray.opacity(0.32)), style: st)
            }
        }

        // Boost chevrons climbing under the hub.
        let revU = fract(t / 3.4) * 3.4
        let boost = revU < 0.7 ? 1.0 : 0.45
        for k in 0..<3 {
            let y = c.y + R * (0.62 - 0.13 * Double(k))
            let phase = fract(t * 1.2 - Double(k) * 0.18)
            let lit = exp(-pow((phase - 0.3) / 0.15, 2)) * boost
            var ch = Path()
            ch.move(to: CGPoint(x: c.x - R * 0.11, y: y + R * 0.045))
            ch.addLine(to: CGPoint(x: c.x, y: y - R * 0.045))
            ch.addLine(to: CGPoint(x: c.x + R * 0.11, y: y + R * 0.045))
            ctx.stroke(ch, with: .color(tint.opacity(0.18 + 0.8 * lit)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        // Needle with motion-blur ghosts.
        func needle(_ v: Double) -> Path {
            let a = ang(min(v, 1.02))
            let n = a + .pi / 2
            let tip = pt(c, R * 0.80, a)
            let tail = pt(c, R * 0.16, a + .pi)
            var path = Path()
            path.move(to: tip)
            path.addLine(to: pt(c, 3.2, n))
            path.addLine(to: pt(tail, 2.0, n))
            path.addLine(to: pt(tail, 2.0, n + .pi))
            path.addLine(to: pt(c, 3.2, n + .pi))
            path.closeSubpath()
            return path
        }
        for k in 1...3 {
            ctx.fill(needle(gaugeValue(t - Double(k) * 0.022, p)), with: .color(Color.primary.opacity(0.10)))
        }
        let tip = pt(c, R * 0.80, ang(min(v, 1.02)))
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2))
            l.fill(needle(v), with: .linearGradient(Gradient(colors: [.primary, .primary, tint]),
                                                    startPoint: c, endPoint: tip))
            l.fill(disc(c, 7), with: .color(.primary))
        }
        ctx.fill(disc(c, 3.6), with: .color(tint))
        ctx.fill(disc(CGPoint(x: c.x - 1.2, y: c.y - 1.2), 1.1), with: .color(.white.opacity(0.8)))
    }

    // MARK: - Maintenance: meshing gears

    // Three procedurally drawn gears with real involute-ish teeth and the same
    // module, so they mesh tooth-in-gap. They advance like an escapement: one
    // tooth per beat with a spring settle, with sparks at the mesh point on
    // every beat. A blurred gear in the background gives depth. The big
    // gear's hub carries a fixed progress arc.

    static let gear14 = gearPath(teeth: 14, windows: 5)
    static let gear9 = gearPath(teeth: 9, windows: 3)
    static let gear7 = gearPath(teeth: 7, windows: 0)
    static let gear18 = gearPath(teeth: 18, windows: 6)

    static func gearPath(teeth n: Int, windows: Int) -> Path {
        let N = Double(n)
        let pitch = 2 * Double.pi / N
        let tip = 1 + 1.8 / N, root = 1 - 2.2 / N
        var p = Path()
        for k in 0..<n {
            let a = Double(k) * pitch
            let rootLeft = pt(.zero, root, a - 0.30 * pitch)
            if k == 0 { p.move(to: rootLeft) } else { p.addLine(to: rootLeft) }
            p.addLine(to: pt(.zero, tip, a - 0.17 * pitch))
            p.addArc(center: .zero, radius: tip, startAngle: .radians(a - 0.17 * pitch),
                     endAngle: .radians(a + 0.17 * pitch), clockwise: false)
            p.addLine(to: pt(.zero, root, a + 0.30 * pitch))
            p.addArc(center: .zero, radius: root, startAngle: .radians(a + 0.30 * pitch),
                     endAngle: .radians(a + 0.70 * pitch), clockwise: false)
        }
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: -0.17, y: -0.17, width: 0.34, height: 0.34))
        guard windows > 0 else { return p }
        let inner = 0.36, outer = root - 0.16, spoke = 0.16
        let span = 2 * Double.pi / Double(windows)
        for wi in 0..<windows {
            let b = Double(wi) * span
            var win = Path()
            win.addArc(center: .zero, radius: outer, startAngle: .radians(b + spoke / (2 * outer)),
                       endAngle: .radians(b + span - spoke / (2 * outer)), clockwise: false)
            win.addArc(center: .zero, radius: inner, startAngle: .radians(b + span - spoke / (2 * inner)),
                       endAngle: .radians(b + spoke / (2 * inner)), clockwise: true)
            win.closeSubpath()
            p.addPath(win)
        }
        return p
    }

    static func drawGear(_ ctx: inout GraphicsContext, _ unit: Path, _ c: CGPoint, _ theta: Double, _ r: Double, _ tint: Color) {
        let xf = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: theta).scaledBy(x: r, y: r)
        let path = unit.applying(xf)
        let eo = FillStyle(eoFill: true)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [tint.opacity(0.95), tint.opacity(0.62)]),
                                             startPoint: CGPoint(x: c.x - r, y: c.y - r),
                                             endPoint: CGPoint(x: c.x + r, y: c.y + r)), style: eo)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [.white.opacity(0.34), .white.opacity(0)]),
                                             startPoint: CGPoint(x: c.x, y: c.y - r * 1.3),
                                             endPoint: CGPoint(x: c.x, y: c.y + r * 0.2)), style: eo)
        ctx.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.7)
    }

    static func gears(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        var ctx = ctx
        ctx.clip(to: disc(c, w * 0.5))
        let m = w * 0.032
        let NA = 14.0, NB = 9.0, NC = 7.0
        let rA = m * NA / 2, rB = m * NB / 2, rC = m * NC / 2
        let cA = CGPoint(x: c.x, y: c.y + w * 0.08)
        let phiB = -58 * Double.pi / 180, phiC = 205 * Double.pi / 180
        let cB = pt(cA, rA + rB, phiB)
        let cC = pt(cA, rA + rC, phiC)

        let beat = 1.0
        let bt = t / beat
        let step = floor(bt) + spring(fract(bt) * 2.4, damping: 6.5, freq: 1.4)
        let thA = step * 2 * .pi / NA
        let thB = (phiB + .pi + .pi / NB) - (thA - phiB) * NA / NB
        let thC = (phiC + .pi + .pi / NC) - (thA - phiC) * NA / NC

        // Out-of-focus background gear.
        glow(&ctx, 2.5) { l in
            let r = w * 0.26
            let path = gear18.applying(CGAffineTransform(translationX: c.x + w * 0.30, y: c.y + w * 0.30)
                .rotated(by: -t * 0.12).scaledBy(x: r, y: r))
            l.fill(path, with: .color(tint.opacity(0.12)), style: FillStyle(eoFill: true))
        }

        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 3))
            drawGear(&l, gear9, cB, thB, rB, tint)
            drawGear(&l, gear7, cC, thC, rC, tint)
            drawGear(&l, gear14, cA, thA, rA, tint)
        }

        // Hub progress arc (does not rotate).
        let hubR = rA * 0.27
        ctx.stroke(disc(cA, hubR), with: .color(.black.opacity(0.22)), lineWidth: 2.6)
        if p > 0.001 {
            ctx.stroke(arc(cA, hubR, -.pi / 2, -.pi / 2 + 2 * .pi * p), with: .color(.white.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }

        // Sparks at the mesh points on every beat.
        let since = fract(bt) * beat
        guard since < 0.4 else { return }
        let x = since / 0.4
        let beatIdx = Int(floor(bt))
        for (j, phi) in [phiB, phiC].enumerated() {
            let contact = pt(cA, rA, phi)
            for k in 0..<5 {
                let seed = beatIdx * 17 + k * 3 + j * 101
                let dirA = phi + (hash(seed) < 0.5 ? .pi / 2 : -.pi / 2) + (hash(seed + 1) - 0.5) * 1.2
                let q = pt(contact, w * (0.03 + 0.08 * hash(seed + 2)) * easeOut(x), dirA)
                let col: Color = k % 2 == 0 ? .white : tint
                ctx.fill(disc(q, 1.3 * (1 - x) + 0.3), with: .color(col.opacity((1 - x) * 0.95)))
            }
        }
    }

    // MARK: - Applications: jiggling tiles, lifted and flipped one by one

    // A 3×3 grid of app tiles in iOS edit-mode jiggle (the universal "about to
    // uninstall" gesture). A focus visits tiles in a scattered order: the tile
    // lifts on a spring with a growing shadow, does a full 3D flip showing a
    // check on its back, and settles. Tiles already reviewed (progress) stop
    // jiggling, brighten and get a badge that pops in.

    static let appColors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .indigo, .yellow]
    static let appOrder = [4, 0, 2, 8, 6, 1, 5, 7, 3]
    static let appRank = [1, 5, 2, 8, 0, 6, 4, 7, 3]

    static func appGlyph(_ g: inout GraphicsContext, _ i: Int, _ ts: Double) {
        let white = GraphicsContext.Shading.color(.white.opacity(0.92))
        switch i % 6 {
        case 0:
            g.stroke(disc(.zero, ts * 0.2), with: white, lineWidth: ts * 0.08)
        case 1:
            var tri = triangle(ts * 0.22)
            tri = tri.applying(CGAffineTransform(rotationAngle: .pi / 2))
            g.fill(tri, with: white)
        case 2:
            g.fill(sparkle(.zero, ts * 0.26, 0), with: white)
        case 3:
            for k in -1...1 {
                g.fill(Path(roundedRect: CGRect(x: -ts * 0.2, y: Double(k) * ts * 0.12 - ts * 0.03,
                                                width: ts * (k == 0 ? 0.32 : 0.4), height: ts * 0.06),
                            cornerRadius: ts * 0.03), with: white)
            }
        case 4:
            g.fill(disc(.zero, ts * 0.12), with: white)
            g.stroke(ellipseArc(.zero, ts * 0.28, ts * 0.1, 0, 2 * .pi, steps: 24), with: white, lineWidth: ts * 0.04)
        default:
            for k in 0..<4 {
                let x = (k % 2 == 0 ? -1.0 : 0.1) * ts * 0.2, y = (k < 2 ? -1.0 : 0.1) * ts * 0.2
                g.fill(Path(roundedRect: CGRect(x: x, y: y, width: ts * 0.16, height: ts * 0.16), cornerRadius: ts * 0.04), with: white)
            }
        }
    }

    static func appGrid(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let ts = w * 0.19, step = ts + w * 0.065
        let beatLen = 0.9
        let beat = t / beatLen
        let focus = appOrder[Int(floor(beat)) % 9]
        let u = fract(beat)
        let checkedCount = Int(floor(p * 9 + 1e-6))
        let newest = fract(p * 9)

        // Draw the focused tile last so it lifts above its neighbours.
        for n in 0..<9 {
            let i = n < 8 ? (n >= focus ? n + 1 : n) : focus
            let rank = appRank[i]
            let center = CGPoint(x: c.x + Double(i % 3 - 1) * step, y: c.y + Double(i / 3 - 1) * step)
            let checked = rank < checkedCount
            let isFocus = i == focus
            var lift = 0.0, flip = 0.0
            if isFocus {
                lift = easeOut(u / 0.22) * (1 - easeInOut((u - 0.72) / 0.28))
                flip = easeInOut((u - 0.18) / 0.55) * 2 * .pi
            }
            let wig = checked ? 0 : sin(t * 2 * .pi * 2.2 + Double(i) * 1.9) * 0.03
            let scale = 1 + 0.16 * lift
            let cosF = cos(flip)
            let sx = max(abs(cosF), 0.03) * scale
            let sy = scale * (1 + 0.05 * abs(sin(flip)))

            if lift > 0.01 {
                var sh = ctx
                sh.addFilter(.blur(radius: 3 + 5 * lift))
                let sw = ts * sx * 0.9
                sh.fill(Path(roundedRect: CGRect(x: center.x - sw / 2, y: center.y - ts * 0.45 + 3 + 6 * lift,
                                                 width: sw, height: ts * 0.9), cornerRadius: ts * 0.24),
                        with: .color(.black.opacity(0.3 * lift)))
            }

            var g = ctx
            g.translateBy(x: center.x, y: center.y - 4 * lift)
            g.rotate(by: .radians(wig))
            g.scaleBy(x: sx, y: sy)
            let rect = CGRect(x: -ts / 2, y: -ts / 2, width: ts, height: ts)
            let tile = Path(roundedRect: rect, cornerRadius: ts * 0.24, style: .continuous)
            let topP = CGPoint(x: 0, y: rect.minY), botP = CGPoint(x: 0, y: rect.maxY)
            if cosF >= 0 {
                let color = appColors[i]
                let dim = checked || isFocus ? 1.0 : 0.5
                g.fill(tile, with: .linearGradient(Gradient(colors: [color.opacity(dim), color.opacity(dim * 0.78)]),
                                                   startPoint: topP, endPoint: botP))
                g.fill(tile, with: .linearGradient(Gradient(colors: [.white.opacity(0.3), .white.opacity(0)]),
                                                   startPoint: topP, endPoint: .zero))
                appGlyph(&g, i, ts)
            } else {
                g.fill(tile, with: .linearGradient(Gradient(colors: [tint, tint.opacity(0.72)]),
                                                   startPoint: topP, endPoint: botP))
                let draw = easeOut((u - 0.38) / 0.18)
                if draw > 0 {
                    g.stroke(check(ts * 0.5).trimmedPath(from: 0, to: draw), with: .color(.white),
                             style: StrokeStyle(lineWidth: ts * 0.09, lineCap: .round, lineJoin: .round))
                }
            }
            let shade = (1 - abs(cosF)) * 0.45
            if shade > 0.01 { g.fill(tile, with: .color(.black.opacity(shade))) }

            if checked {
                let pop = rank == checkedCount - 1 ? min(spring(newest * 12), 1.2) : 1
                let bc = CGPoint(x: rect.maxX - ts * 0.04, y: rect.minY + ts * 0.04)
                let br = ts * 0.17 * pop
                g.fill(disc(bc, br + 1), with: .color(.black.opacity(0.15)))
                g.fill(disc(bc, br), with: .color(.white))
                var cg = g
                cg.translateBy(x: bc.x, y: bc.y)
                cg.stroke(check(br * 1.1), with: .color(tint),
                          style: StrokeStyle(lineWidth: br * 0.32, lineCap: .round, lineJoin: .round))
            }
        }
    }

    // MARK: - Space Lens / large files: a treemap subdividing

    // Slice-and-dice treemap that subdivides level by level as progress grows:
    // at the frontier a white divider grows out from the middle, then the two
    // halves spring apart and take their own shade. Split ratios breathe so
    // the map feels alive, a light sheen sweeps across the tiles, big tiles
    // carry file-name hints and the largest tile is outlined as the find.

    static func treemap(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let side = s.width * 0.68
        let frame = CGRect(x: (s.width - side) / 2, y: (s.height - side) / 2, width: side, height: side)
        let level = 1 + p * 4
        var all = Path()
        var best = CGRect.zero

        ctx.fill(Path(roundedRect: frame.insetBy(dx: -3, dy: -3), cornerRadius: 9, style: .continuous),
                 with: .color(tint.opacity(0.08)))
        treeNode(&ctx, frame, 0, 0, level, t, tint, &all, &best)

        // Sheen.
        let x = fract(t / 3.2) * 1.8 - 0.4
        let a = CGPoint(x: frame.minX + side * x, y: frame.minY + side * x)
        ctx.fill(all, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                             .init(color: .white.opacity(0.22), location: 0.5),
                             .init(color: .white.opacity(0), location: 1)]),
            startPoint: CGPoint(x: a.x - 18, y: a.y - 18), endPoint: CGPoint(x: a.x + 18, y: a.y + 18)))

        // Largest tile highlight.
        if best.width > 4 {
            let pulse = 0.5 + 0.5 * sin(t * 3)
            let hl = Path(roundedRect: best, cornerRadius: min(5, min(best.width, best.height) * 0.3), style: .continuous)
            glow(&ctx, 4) { $0.stroke(hl, with: .color(tint.opacity(0.6 + 0.4 * pulse)), lineWidth: 3) }
            ctx.stroke(hl, with: .color(.white.opacity(0.55 + 0.4 * pulse)), lineWidth: 1.4)
        }
    }

    static func treeTone(_ idx: Int, _ d: Int) -> Double { 0.30 + 0.5 * hash(idx * 3 + 11) + 0.04 * Double(d) }

    static func treeNode(_ ctx: inout GraphicsContext, _ r: CGRect, _ d: Int, _ idx: Int, _ level: Double,
                         _ t: Double, _ tint: Color, _ all: inout Path, _ best: inout CGRect) {
        let split = level - Double(d)
        if split <= 0 || d >= 5 {
            treeLeaf(&ctx, r, idx, treeTone(idx, d), 1, tint, &all, &best)
            return
        }
        let ratio = 0.36 + 0.28 * hash(idx * 7 + 1) + 0.025 * sin(t * 0.7 + Double(idx))
        let vertical = r.width >= r.height
        var a = r, b = r
        if vertical {
            a.size.width = r.width * ratio
            b.origin.x = r.minX + a.width
            b.size.width = r.width - a.width
        } else {
            a.size.height = r.height * ratio
            b.origin.y = r.minY + a.height
            b.size.height = r.height - a.height
        }
        if split >= 1 {
            treeNode(&ctx, a, d + 1, idx * 2 + 1, level, t, tint, &all, &best)
            treeNode(&ctx, b, d + 1, idx * 2 + 2, level, t, tint, &all, &best)
            return
        }
        let parentTone = treeTone(idx, d)
        if split < 0.5 {
            treeLeaf(&ctx, r, idx, parentTone, 1, tint, &all, &best)
            let grow = easeOut(split / 0.5)
            let (p0, p1): (CGPoint, CGPoint) = vertical
                ? (CGPoint(x: a.maxX, y: r.midY - r.height * 0.5 * grow), CGPoint(x: a.maxX, y: r.midY + r.height * 0.5 * grow))
                : (CGPoint(x: r.midX - r.width * 0.5 * grow, y: a.maxY), CGPoint(x: r.midX + r.width * 0.5 * grow, y: a.maxY))
            let divider = line(p0, p1)
            glow(&ctx, 3) { $0.stroke(divider, with: .color(.white.opacity(0.8)), lineWidth: 2.5) }
            ctx.stroke(divider, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        } else {
            let k = (split - 0.5) / 0.5
            let gap = spring(k * 2)
            let mix = smooth(0, 0.6, k)
            treeLeaf(&ctx, a, idx * 2 + 1, lerp(parentTone, treeTone(idx * 2 + 1, d + 1), mix), gap, tint, &all, &best)
            treeLeaf(&ctx, b, idx * 2 + 2, lerp(parentTone, treeTone(idx * 2 + 2, d + 1), mix), gap, tint, &all, &best)
        }
    }

    static func treeLeaf(_ ctx: inout GraphicsContext, _ r: CGRect, _ idx: Int, _ tone: Double, _ gap: Double,
                         _ tint: Color, _ all: inout Path, _ best: inout CGRect) {
        let rr = r.insetBy(dx: 1.3 * gap, dy: 1.3 * gap)
        guard rr.width > 1, rr.height > 1 else { return }
        let path = Path(roundedRect: rr, cornerRadius: min(5, min(rr.width, rr.height) * 0.3), style: .continuous)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [tint.opacity(tone), tint.opacity(tone * 0.7)]),
                                             startPoint: CGPoint(x: rr.minX, y: rr.minY),
                                             endPoint: CGPoint(x: rr.maxX, y: rr.maxY)))
        all.addPath(path)
        if rr.width * rr.height > best.width * best.height { best = rr }
        if rr.width > 26, rr.height > 18 {
            let lw = min(rr.width * 0.5, 30)
            ctx.fill(Path(roundedRect: CGRect(x: rr.minX + 4, y: rr.minY + 4, width: lw, height: 2.5), cornerRadius: 1.25),
                     with: .color(.white.opacity(0.7)))
            ctx.fill(Path(roundedRect: CGRect(x: rr.minX + 4, y: rr.minY + 9, width: lw * 0.6, height: 2.5), cornerRadius: 1.25),
                     with: .color(.white.opacity(0.4)))
        }
    }

    // MARK: - Duplicates: two documents converge and merge

    // Two tilted documents float apart with parallax bobbing while a compare
    // pass highlights matching lines on both, bridged by connectors. They
    // glide together, square up and collide: the duplicate dissolves into the
    // original, which pops on a spring while two rings pulse out and a check
    // badge draws on. Then the copy slides out again. A stack behind the
    // original grows with progress (duplicates resolved).

    static func paperOutline(_ w: Double, _ h: Double) -> (Path, Path) {
        let r = 4.0, fold = w * 0.24
        let x0 = -w / 2, y0 = -h / 2, x1 = w / 2, y1 = h / 2
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - fold, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y0 + fold))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x0, y: y1), radius: r)
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y0), radius: r)
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: r)
        p.closeSubpath()
        var f = Path()
        f.move(to: CGPoint(x: x1 - fold, y: y0))
        f.addLine(to: CGPoint(x: x1 - fold, y: y0 + fold - 2))
        f.addQuadCurve(to: CGPoint(x: x1 - fold + 2, y: y0 + fold), control: CGPoint(x: x1 - fold, y: y0 + fold))
        f.addLine(to: CGPoint(x: x1, y: y0 + fold))
        f.closeSubpath()
        return (p, f)
    }

    static let docRows: [Double] = [0.55, 0.72, 0.64, 0.70, 0.48, 0.60]

    static func rowY(_ h: Double, _ k: Int) -> Double { -h / 2 + h * (0.34 + 0.105 * Double(k)) }

    static func docCard(_ ctx: inout GraphicsContext, _ c: CGPoint, _ w: Double, _ h: Double, rot: Double,
                        scale: Double, alpha: Double, tint: Color, row: Int?, rowGlow: Double) {
        guard alpha > 0.01 else { return }
        var g = ctx
        g.opacity = alpha
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(rot))
        g.scaleBy(x: scale, y: scale)
        let (outline, fold) = paperOutline(w, h)
        g.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3))
            l.fill(outline, with: .linearGradient(Gradient(colors: [Color(white: 0.99), Color(white: 0.89)]),
                                                  startPoint: CGPoint(x: 0, y: -h / 2), endPoint: CGPoint(x: 0, y: h / 2)))
        }
        g.stroke(outline, with: .color(tint.opacity(0.35)), lineWidth: 0.8)
        g.fill(fold, with: .color(Color(white: 0.78)))
        let pad = w * 0.16
        g.fill(Path(roundedRect: CGRect(x: -w / 2 + pad, y: -h / 2 + h * 0.15, width: (w - 2 * pad) * 0.42, height: 3.2),
                    cornerRadius: 1.6), with: .color(tint.opacity(0.85)))
        for (k, len) in docRows.enumerated() {
            let y = rowY(h, k)
            let hl = k == row ? rowGlow : 0
            g.fill(Path(roundedRect: CGRect(x: -w / 2 + pad, y: y - 1.1, width: (w - 2 * pad) * len, height: 2.2), cornerRadius: 1.1),
                   with: .color(hl > 0.01 ? tint.opacity(0.35 + 0.65 * hl) : Color.gray.opacity(0.45)))
        }
    }

    static func merge(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let dw = w * 0.30, dh = w * 0.38
        let period = 3.6
        let u = fract(t / period)
        let apart = w * 0.17

        let approach = easeInOut((u - 0.30) / 0.22)
        let separate = easeInOut((u - 0.86) / 0.14)
        let k = approach * (1 - separate)
        let tau = (u - 0.52) * period
        let merged = u >= 0.52 && u < 0.86
        let bob = sin(t * 1.7)
        let bob2 = sin(t * 1.7 + 1.1)

        let left = CGPoint(x: c.x - apart * (1 - k), y: c.y + bob * 1.8 * (1 - k))
        let right = CGPoint(x: c.x + apart * (1 - k), y: c.y + bob2 * 2.4 * (1 - k))
        let rotL = -0.13 * (1 - k), rotR = 0.13 * (1 - k)
        let dupAlpha = merged ? 1 - easeOut(tau / 0.3) : (u >= 0.86 ? separate : 1)
        let pop = merged ? 1 + 0.09 * exp(-5 * tau) * sin(2 * .pi * 1.7 * tau) : 1

        // Compare pass while apart.
        var row: Int?
        var rowGlow = 0.0
        if u < 0.30 {
            let x = u / 0.30 * 6
            row = min(5, Int(x))
            rowGlow = sin(.pi * fract(x))
        }

        // Impact rings and glow.
        if merged {
            softDot(&ctx, c, w * 0.36, tint, 0.55 * exp(-tau * 3.5))
            for j in 0..<2 {
                let age = tau - Double(j) * 0.15
                guard age > 0, age < 1.2 else { continue }
                let x = age / 1.2
                ctx.stroke(disc(c, w * 0.18 + w * 0.30 * easeOut(x)),
                           with: .color(tint.opacity(0.75 * pow(1 - x, 1.5))), lineWidth: 2 * (1 - x) + 0.5)
            }
        }

        // Duplicate (behind).
        docCard(&ctx, right, dw, dh, rot: rotR, scale: 0.94, alpha: dupAlpha * 0.92, tint: tint, row: row, rowGlow: rowGlow)

        // Stack of resolved duplicates behind the original.
        let stack = Int(p * 3.999)
        if stack > 0 {
            for j in stride(from: stack, through: 1, by: -1) {
                var g = ctx
                g.translateBy(x: left.x - 3 * Double(j), y: left.y - 3 * Double(j))
                g.rotate(by: .radians(rotL))
                let (outline, _) = paperOutline(dw, dh)
                g.fill(outline, with: .color(Color(white: 0.93 - 0.05 * Double(j))))
                g.stroke(outline, with: .color(tint.opacity(0.3)), lineWidth: 0.7)
            }
        }

        // Original (front).
        docCard(&ctx, left, dw, dh, rot: rotL, scale: pop, alpha: 1, tint: tint, row: row, rowGlow: rowGlow)

        // Connectors between matching rows.
        if let row, rowGlow > 0.02 {
            let lp = CGAffineTransform(translationX: left.x, y: left.y).rotated(by: rotL)
            let rp = CGAffineTransform(translationX: right.x, y: right.y).rotated(by: rotR).scaledBy(x: 0.94, y: 0.94)
            let y = rowY(dh, row)
            let a = CGPoint(x: dw * 0.42, y: y).applying(lp)
            let b = CGPoint(x: -dw * 0.42, y: y).applying(rp)
            ctx.stroke(line(a, b), with: .color(tint.opacity(0.8 * rowGlow)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 2.5]))
            ctx.fill(disc(a, 2), with: .color(tint.opacity(rowGlow)))
            ctx.fill(disc(b, 2), with: .color(tint.opacity(rowGlow)))
        }

        // Check badge.
        let badgeIn = merged ? spring((tau - 0.18) * 3) : (u >= 0.86 ? 1 - separate : 0)
        if badgeIn > 0.01 {
            let bc = CGPoint(x: c.x + dw * 0.36 * pop, y: c.y + dh * 0.38 * pop)
            let br = w * 0.075 * badgeIn
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: tint.opacity(0.6), radius: 5))
                l.fill(disc(bc, br), with: .color(tint))
            }
            let draw = merged ? easeOut((tau - 0.3) / 0.3) : 1
            if draw > 0 {
                var g = ctx
                g.translateBy(x: bc.x, y: bc.y)
                g.stroke(check(br * 1.1).trimmedPath(from: 0, to: draw), with: .color(.white),
                         style: StrokeStyle(lineWidth: br * 0.28, lineCap: .round, lineJoin: .round))
            }
        }
    }

    // MARK: - Shredder: a page fed through a slot

    // A shredder in light perspective (top face with a slot, front face with
    // a progress LED). A page drops in, settles on a spring and is fed down
    // with motor vibration; a cutting light glows in the slot. Below, the page
    // emerges as curling strips that carry fragments of its text lines; when
    // the page is through, the strips drop away under gravity and fan out
    // while confetti trickles down.

    static let shredLines: [(Double, Double)] = [(0.12, 0.40), (0.24, 0.70), (0.34, 0.62), (0.44, 0.72), (0.54, 0.50), (0.64, 0.66), (0.74, 0.58), (0.84, 0.44)]

    static func shred(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        var ctx2 = ctx
        ctx2.clip(to: disc(c, w * 0.5))

        let slotY = c.y - w * 0.02
        let bodyW = w * 0.66, topH = w * 0.06, frontH = w * 0.085
        let bodyTop = slotY - topH / 2
        let bodyBottom = slotY + topH / 2 + frontH
        let docW = w * 0.40, docH = w * 0.44
        let docX = c.x - docW / 2
        let period = 3.0
        let u = fract(t / period)
        let enterEnd = 0.22, feedEnd = 0.82
        let enter = easeOut(u / enterEnd)
        let feedK = clamp((u - enterEnd) / (feedEnd - enterEnd))
        let fed = docH * feedK
        let feeding = u > enterEnd && u < feedEnd
        let jitter = feeding ? sin(t * 90) * 0.5 + sin(t * 57) * 0.3 : 0
        let strips = 7
        let sw = docW / Double(strips)

        // Strips (current page attached or falling, previous page falling).
        var below = ctx2
        below.clip(to: Path(CGRect(x: 0, y: bodyBottom - 1, width: s.width, height: s.height)))
        if u < feedEnd {
            drawStrips(&below, docX + jitter, bodyBottom, sw, strips, length: fed, docH: docH, fall: 0, t: t, tint: tint)
        } else {
            drawStrips(&below, docX, bodyBottom, sw, strips, length: docH, docH: docH, fall: (u - feedEnd) * period, t: t, tint: tint)
        }
        let prevFall = (u + 1 - feedEnd) * period
        if prevFall < 1.2 {
            drawStrips(&below, docX, bodyBottom, sw, strips, length: docH, docH: docH, fall: prevFall, t: t, tint: tint)
        }

        // Confetti.
        for i in 0..<12 {
            let ph = fract(t / 0.9 + hash(i))
            let gen = Int(floor(t / 0.9 + hash(i)))
            let x = docX + hash(i * 7 + gen * 13) * docW
            let y = bodyBottom + 4 + hash(i + gen * 3) * max(fed, docH * 0.3) * 0.6 + ph * ph * w * 0.22
            let o = (1 - ph) * (feeding ? 0.9 : 0.35)
            var g = below
            g.translateBy(x: x, y: y)
            g.rotate(by: .radians(t * 6 + Double(i)))
            g.fill(Path(CGRect(x: -1, y: -1.6, width: 2, height: 3.2)), with: .color((i % 3 == 0 ? tint : Color(white: 0.92)).opacity(o)))
        }

        // Top face, back half (behind the page).
        let topRect = CGRect(x: c.x - bodyW / 2, y: bodyTop, width: bodyW, height: topH)
        let topFace = Path(roundedRect: topRect, cornerRadius: 5, style: .continuous)
        let topShade = GraphicsContext.Shading.linearGradient(Gradient(colors: [Color(white: 0.70), Color(white: 0.52)]),
                                                              startPoint: CGPoint(x: 0, y: bodyTop),
                                                              endPoint: CGPoint(x: 0, y: bodyTop + topH))
        ctx2.fill(topFace, with: topShade)
        ctx2.fill(topFace, with: .color(tint.opacity(0.12)))

        // The page above the slot.
        let docBottom = slotY - (1 - enter) * docH * 0.25 + fed
        let docTop = docBottom - docH
        let settle = (1 - spring(u / enterEnd * 1.3)) * -0.12
        var above = ctx2
        above.clip(to: Path(CGRect(x: 0, y: 0, width: s.width, height: slotY)))
        above.opacity = smooth(0, 0.6, enter)
        above.translateBy(x: c.x + jitter, y: docTop + docH / 2)
        above.rotate(by: .radians(settle))
        let (outline, fold) = paperOutline(docW, docH)
        above.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2))
            l.fill(outline, with: .linearGradient(Gradient(colors: [Color(white: 0.99), Color(white: 0.9)]),
                                                  startPoint: CGPoint(x: 0, y: -docH / 2), endPoint: CGPoint(x: 0, y: docH / 2)))
        }
        above.stroke(outline, with: .color(tint.opacity(0.35)), lineWidth: 0.8)
        above.fill(fold, with: .color(Color(white: 0.78)))
        for (k, (ly, len)) in shredLines.enumerated() {
            above.fill(Path(roundedRect: CGRect(x: -docW / 2 + docW * 0.14, y: -docH / 2 + docH * ly - 1.1,
                                                width: docW * 0.72 * len, height: k == 0 ? 3 : 2.2), cornerRadius: 1.1),
                       with: .color(k == 0 ? tint.opacity(0.85) : Color.gray.opacity(0.45)))
        }

        // Top face, front half (over the page), slot and cutting light.
        var front = ctx2
        front.clip(to: Path(CGRect(x: 0, y: slotY, width: s.width, height: s.height)))
        front.fill(topFace, with: topShade)
        front.fill(topFace, with: .color(tint.opacity(0.12)))
        let slot = Path(roundedRect: CGRect(x: docX - 5, y: slotY - 1.4, width: docW + 10, height: 2.8), cornerRadius: 1.4)
        ctx2.fill(slot, with: .color(.black.opacity(0.8)))
        let cut = feeding ? 0.7 + 0.3 * sin(t * 30) : 0.15
        glow(&ctx2, 4) { $0.fill(slot, with: .color(tint.opacity(cut))) }
        ctx2.fill(Path(CGRect(x: docX, y: slotY - 0.4, width: docW, height: 0.8)), with: .color(tint.opacity(cut)))

        // Front face with progress LED.
        let frontRect = CGRect(x: c.x - bodyW / 2, y: bodyTop + topH - 2, width: bodyW, height: frontH + 2)
        let frontFace = Path(roundedRect: frontRect, cornerRadius: 6, style: .continuous)
        ctx2.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3))
            l.fill(frontFace, with: .linearGradient(Gradient(colors: [Color(white: 0.40), Color(white: 0.24)]),
                                                    startPoint: CGPoint(x: 0, y: frontRect.minY), endPoint: CGPoint(x: 0, y: frontRect.maxY)))
        }
        ctx2.fill(frontFace, with: .color(tint.opacity(0.14)))
        ctx2.fill(Path(CGRect(x: frontRect.minX + 4, y: frontRect.minY + 2, width: bodyW - 8, height: 0.8)),
                  with: .color(.white.opacity(0.25)))
        let ledW = bodyW * 0.56
        let led = CGRect(x: c.x - ledW / 2 - 6, y: frontRect.midY - 1.5, width: ledW, height: 3)
        ctx2.fill(Path(roundedRect: led, cornerRadius: 1.5), with: .color(.black.opacity(0.45)))
        if p > 0.005 {
            let lit = Path(roundedRect: CGRect(x: led.minX, y: led.minY, width: max(3, ledW * p), height: 3), cornerRadius: 1.5)
            glow(&ctx2, 3) { $0.fill(lit, with: .color(tint)) }
            ctx2.fill(lit, with: .color(tint))
        }
        let dot = CGPoint(x: led.maxX + 8, y: frontRect.midY)
        let blink = feeding ? 0.55 + 0.45 * sin(t * 8) : 0.35
        softDot(&ctx2, dot, 5, tint, blink)
        ctx2.fill(disc(dot, 1.6), with: .color(tint.opacity(0.6 + 0.4 * blink)))
    }

    static func drawStrips(_ ctx: inout GraphicsContext, _ x0: Double, _ top: Double, _ sw: Double, _ n: Int,
                           length L: Double, docH: Double, fall: Double, t: Double, tint: Color) {
        guard L > 0.5 else { return }
        let alpha = 1 - smooth(0.25, 1.0, fall)
        guard alpha > 0.01 else { return }
        let drop = 0.5 * 420 * fall * fall
        let paper = GraphicsContext.Shading.color(Color(white: 0.96).opacity(alpha))
        let edge = GraphicsContext.Shading.color(Color.gray.opacity(0.55 * alpha))
        let segs = 6
        for i in 0..<n {
            let spreadX = (Double(i) - Double(n - 1) / 2) * fall * 22
            let bx = x0 + Double(i) * sw + 0.7 + spreadX
            let width = sw - 1.4
            let amp = (fall > 0 ? 1.8 : 1.0) * 0.05
            func off(_ d: Double) -> Double {
                sin(d * 0.11 + t * 4 + Double(i) * 1.9) * (d / docH) * docH * amp + (Double(i) - 3) * d * 0.02 * (fall > 0 ? 1 : 0.4)
            }
            var path = Path()
            for j in 0...segs {
                let d = L * Double(j) / Double(segs)
                let q = CGPoint(x: bx + off(d), y: top + drop + d)
                if j == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            for j in stride(from: segs, through: 0, by: -1) {
                let d = L * Double(j) / Double(segs)
                path.addLine(to: CGPoint(x: bx + width + off(d), y: top + drop + d))
            }
            path.closeSubpath()
            ctx.fill(path, with: paper)
            ctx.stroke(path, with: edge, lineWidth: 0.6)

            // Fragments of the text lines this strip carries.
            let f0 = Double(i) / Double(n), f1 = Double(i + 1) / Double(n)
            for (k, (ly, len)) in shredLines.enumerated() {
                let lx0 = 0.14, lx1 = 0.14 + 0.72 * len
                guard lx1 > f0, lx0 < f1 else { continue }
                let d = docH * ly - docH + L
                guard d >= 0, d <= L else { continue }
                let xs = bx + max(0, (lx0 - f0) / (f1 - f0)) * width
                let xe = bx + min(1, (lx1 - f0) / (f1 - f0)) * width
                let h = k == 0 ? 3.0 : 2.2
                ctx.fill(Path(CGRect(x: xs + off(d), y: top + drop + d - h / 2, width: max(0, xe - xs), height: h)),
                         with: .color((k == 0 ? tint.opacity(0.85) : Color.gray.opacity(0.5)).opacity(alpha)))
            }
        }
    }
}

// MARK: - Ambient depth (all motifs)

extension ScanArt {
    /// Shared backdrop under every motif: a breathing halo that gives depth
    /// and a few out-of-focus motes drifting upward at different speeds
    /// (parallax), so even a calm motif never looks frozen.
    static func ambient(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ tint: Color) {
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let R = s.width * 0.5
        let breathe = 0.5 + 0.5 * sin(t * 0.9)
        ctx.fill(disc(c, R), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.07 + 0.04 * breathe), tint.opacity(0.03), tint.opacity(0)]),
            center: CGPoint(x: c.x, y: c.y - R * 0.12), startRadius: 0, endRadius: R))
        for i in 0..<12 {
            let depth = hash(i * 7 + 3)                    // 0 = far, 1 = near
            let speed = 0.025 + 0.05 * depth
            let ph = fract(t * speed + hash(i))
            let ang = hash(i * 13 + 1) * 2 * .pi + sin(t * 0.3 + Double(i)) * 0.25
            let rr = R * (0.30 + 0.62 * hash(i * 5 + 2))
            let q = CGPoint(x: c.x + cos(ang) * rr, y: c.y + sin(ang) * rr * 0.9 - (ph - 0.5) * R * 0.5)
            let a = sin(ph * .pi) * (0.10 + 0.22 * depth) * (0.6 + 0.4 * sin(t * 2.3 + Double(i) * 1.7))
            softDot(&ctx, q, 2 + 5 * depth, tint, max(0, a))
        }
    }
}

// MARK: - New motifs

extension ScanArt {
    static let binColors: [Color] = [Color(nsColor: .systemGreen), Color(nsColor: .systemOrange), Color(nsColor: .systemGray)]

    // MARK: System Data: storage layers sorted into bins

    // An isometric stack of storage slabs. The top slab lifts on a spring,
    // flies along an arc and drops into the bin of its kind (safe / review /
    // protected); the bin squashes, splashes and its level rises. A new slab
    // falls onto the stack with a bounce. Bin levels grow with progress.

    static func slab(_ ctx: inout GraphicsContext, _ c: CGPoint, _ a: Double, _ b: Double, _ h: Double,
                     _ color: Color, _ alpha: Double) {
        guard alpha > 0.01 else { return }
        var top = Path()
        top.move(to: CGPoint(x: c.x, y: c.y - b)); top.addLine(to: CGPoint(x: c.x + a, y: c.y))
        top.addLine(to: CGPoint(x: c.x, y: c.y + b)); top.addLine(to: CGPoint(x: c.x - a, y: c.y)); top.closeSubpath()
        var left = Path()
        left.move(to: CGPoint(x: c.x - a, y: c.y)); left.addLine(to: CGPoint(x: c.x, y: c.y + b))
        left.addLine(to: CGPoint(x: c.x, y: c.y + b + h)); left.addLine(to: CGPoint(x: c.x - a, y: c.y + h)); left.closeSubpath()
        var right = Path()
        right.move(to: CGPoint(x: c.x, y: c.y + b)); right.addLine(to: CGPoint(x: c.x + a, y: c.y))
        right.addLine(to: CGPoint(x: c.x + a, y: c.y + h)); right.addLine(to: CGPoint(x: c.x, y: c.y + b + h)); right.closeSubpath()
        ctx.fill(left, with: .color(color.opacity(0.78 * alpha)))
        ctx.fill(right, with: .color(color.opacity(0.58 * alpha)))
        ctx.fill(top, with: .linearGradient(Gradient(colors: [color.opacity(alpha), color.opacity(0.85 * alpha)]),
                                            startPoint: CGPoint(x: c.x - a, y: c.y), endPoint: CGPoint(x: c.x + a, y: c.y)))
        ctx.stroke(top, with: .color(.white.opacity(0.45 * alpha)), lineWidth: 0.8)
        // LED strip on the front edge.
        ctx.stroke(line(CGPoint(x: c.x - a * 0.7, y: c.y + h * 0.55 + b * 0.3), CGPoint(x: c.x - a * 0.35, y: c.y + h * 0.55 + b * 0.65)),
                   with: .color(.white.opacity(0.7 * alpha)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }

    static func layers(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let a = w * 0.17, b = w * 0.06, h = w * 0.04
        let gap = h + w * 0.012
        let baseY = c.y - w * 0.02
        let period = 1.25
        let cyc = t / period
        let n = Int(floor(cyc))
        let u = fract(cyc)
        func kind(_ k: Int) -> Int { Int(hash(k * 37 + 5) * 3) % 3 }

        // Bins.
        let binW = w * 0.2, binH = w * 0.15
        let binTop = c.y + w * 0.2
        let landing = 0.62
        let levels = [0.9, 0.55, 0.75]
        var binX: [Double] = []
        for j in 0..<3 { binX.append(c.x + Double(j - 1) * w * 0.27) }

        // Stack: three resting slabs (they settle a little when the top one
        // lifts off) plus the one that falls in at the end.
        let settle = exp(-u * period * 6) * sin(u * period * 20) * 1.5
        for j in 0..<3 {
            let y = baseY - Double(j) * gap + settle * Double(j) / 2
            slab(&ctx, CGPoint(x: c.x, y: y), a, b, h, binColors[(j + 2) % 3], 0.95)
        }
        // Departing slab (top of the stack, index n).
        let lift = spring(clamp(u / 0.35), damping: 6, freq: 1.2)
        let fly = easeInOut((u - 0.12) / (landing - 0.12))
        let k0 = kind(n)
        let p0 = CGPoint(x: c.x, y: baseY - 3 * gap - w * 0.05 * lift)
        let p1 = CGPoint(x: binX[k0], y: binTop - w * 0.01)
        let ctl = CGPoint(x: (p0.x + p1.x) / 2 + (p1.x - c.x) * 0.6, y: p0.y - w * 0.16)
        let mt = 1 - fly
        let q = CGPoint(x: mt * mt * p0.x + 2 * mt * fly * ctl.x + fly * fly * p1.x,
                        y: mt * mt * p0.y + 2 * mt * fly * ctl.y + fly * fly * p1.y)
        let shrink = lerp(1, 0.42, fly)
        if u < landing + 0.04 {
            // Trail.
            for k in 1...4 {
                let f2 = max(0, fly - Double(k) * 0.05)
                let m2 = 1 - f2
                let q2 = CGPoint(x: m2 * m2 * p0.x + 2 * m2 * f2 * ctl.x + f2 * f2 * p1.x,
                                 y: m2 * m2 * p0.y + 2 * m2 * f2 * ctl.y + f2 * f2 * p1.y)
                softDot(&ctx, q2, w * 0.04 * shrink, binColors[k0], 0.25 * (1 - Double(k) / 5) * smooth(0, 0.1, fly))
            }
            var g = ctx
            g.translateBy(x: q.x, y: q.y)
            g.rotate(by: .radians(sin(fly * .pi) * 0.5 * (p1.x >= c.x ? 1 : -1)))
            g.scaleBy(x: shrink, y: shrink)
            slab(&g, .zero, a, b, h, binColors[k0], 1 - smooth(landing - 0.06, landing + 0.04, u))
        }
        // New slab drops on the stack with a bounce (it becomes the 4th).
        let drop = clamp((u - 0.55) / 0.45)
        if drop > 0 {
            let y = (baseY - 3 * gap) - w * 0.3 * (1 - min(spring(drop, damping: 6, freq: 1.4), 1.2))
            slab(&ctx, CGPoint(x: c.x, y: y), a, b, h, binColors[kind(n + 1)], smooth(0, 0.2, drop))
        }

        // Bins, drawn last: the slab vanishes into them.
        for j in 0..<3 {
            let color = binColors[j]
            let hitAge = (u - landing) * period
            let isHit = j == k0 && hitAge >= 0
            let squash = isHit ? exp(-hitAge * 7) * cos(hitAge * 26) * 0.12 : 0
            let bw = binW * (1 + squash), bh = binH * (1 - squash)
            let rect = CGRect(x: binX[j] - bw / 2, y: binTop + binH - bh, width: bw, height: bh)
            let shape = Path(roundedRect: rect, cornerRadius: w * 0.03, style: .continuous)
            ctx.fill(shape, with: .color(color.opacity(0.16)))
            // Level with a sloshing surface.
            let lvl = clamp(0.12 + levels[j] * p * 0.85) * bh
            var liquid = Path()
            let topY = rect.maxY - lvl
            liquid.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for k in 0...10 {
                let x = rect.minX + bw * Double(k) / 10
                let slosh = (isHit ? 2.5 * exp(-hitAge * 4) : 0.8) * sin(Double(k) * 0.9 + t * 5 + Double(j))
                liquid.addLine(to: CGPoint(x: x, y: topY + slosh))
            }
            liquid.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            liquid.closeSubpath()
            var lg = ctx
            lg.clip(to: shape)
            lg.fill(liquid, with: .linearGradient(Gradient(colors: [color.opacity(0.95), color.opacity(0.7)]),
                                                  startPoint: CGPoint(x: 0, y: topY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            ctx.stroke(shape, with: .color(color.opacity(0.75)), lineWidth: 1.2)
            // Rim highlight and glyph.
            ctx.stroke(line(CGPoint(x: rect.minX + 4, y: rect.minY + 1.5), CGPoint(x: rect.maxX - 4, y: rect.minY + 1.5)),
                       with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            if let sym = ctx.resolveSymbol(id: 3 + j) {
                ctx.draw(sym, at: CGPoint(x: binX[j], y: rect.maxY - bh * 0.38))
            }
            if isHit, hitAge < 0.6 {
                let x = hitAge / 0.6
                glow(&ctx, 4) { $0.fill(disc(CGPoint(x: binX[j], y: rect.minY), w * 0.05 * (1 - x)), with: .color(color)) }
                for d in 0..<6 {
                    let ang = -Double.pi / 2 + (Double(d) - 2.5) * 0.4
                    let qq = pt(CGPoint(x: binX[j], y: rect.minY), w * 0.12 * easeOut(x), ang)
                    ctx.fill(disc(CGPoint(x: qq.x, y: qq.y + w * 0.08 * x * x), 1.6 * (1 - x)), with: .color(color.opacity(1 - x)))
                }
            }
        }
    }

    // MARK: Persistence: power-on chain

    // A power button in the centre presses on a spring and sends a pulse up a
    // spoke and around a ring of launch items. Each item lights as the pulse
    // reaches it (pop + ripple); one per cycle is flagged for review in
    // orange. Items already checked (progress) keep a small tick.

    static func chain(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let R = w * 0.36
        let nodes = 8
        let period = 3.4
        let cyc = t / period
        let u = fract(cyc)
        let gen = Int(floor(cyc))
        let flagged = Int(hash(gen * 19 + 7) * Double(nodes))
        let orange = Color(nsColor: .systemOrange)
        let checked = Int(floor(p * Double(nodes) + 1e-6))
        func ang(_ i: Int) -> Double { -Double.pi / 2 + Double(i) * 2 * .pi / Double(nodes) }
        // Pulse position: 0..0.12 press, 0.12..0.22 spoke, 0.22..0.92 ring.
        let ringU = clamp((u - 0.22) / 0.70)
        let pulseA = -Double.pi / 2 + ringU * 2 * .pi * Double(nodes - 1) / Double(nodes)

        // Ring track and spoke.
        ctx.stroke(disc(c, R), with: .color(tint.opacity(0.16)), style: StrokeStyle(lineWidth: 2.4))
        let spokeU = clamp((u - 0.12) / 0.10)
        ctx.stroke(line(pt(c, w * 0.13, -.pi / 2), pt(c, R, -.pi / 2)), with: .color(tint.opacity(0.18)), lineWidth: 2)
        if u > 0.12 {
            let tipR = lerp(w * 0.13, R, easeIn(spokeU))
            ctx.stroke(line(pt(c, w * 0.13, -.pi / 2), pt(c, tipR, -.pi / 2)),
                       with: .color(tint.opacity(0.9 * (1 - smooth(0.6, 0.95, u)))), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        // Lit arc behind the pulse.
        if ringU > 0 {
            let lit = arc(c, R, -.pi / 2, pulseA)
            let fade = 1 - smooth(0.9, 1, u)
            glow(&ctx, 3) { $0.stroke(lit, with: .color(tint.opacity(0.6 * fade)), lineWidth: 4) }
            ctx.stroke(lit, with: .color(tint.opacity(0.85 * fade)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            if u < 0.92 {
                let head = pt(c, R, pulseA)
                softDot(&ctx, head, 10, tint, 0.9)
                ctx.fill(disc(head, 2.6), with: .color(.white))
            }
        }

        // Nodes.
        let ns = w * 0.12
        for i in 0..<nodes {
            let q = pt(c, R, ang(i))
            let tArr = i == 0 ? 0.22 : 0.22 + 0.70 * Double(i) / Double(nodes)
            let age = (u - tArr) * period
            let on = age >= 0 && u < 0.97
            let pop = on ? min(spring(age * 1.4, damping: 5, freq: 1.8), 1.25) : 0
            let isFlag = i == flagged && on
            let col = isFlag ? orange : tint
            let scale = 0.86 + 0.14 * pop
            let rect = CGRect(x: q.x - ns * scale / 2, y: q.y - ns * scale / 2, width: ns * scale, height: ns * scale)
            let tile = Path(roundedRect: rect, cornerRadius: ns * 0.28 * scale, style: .continuous)
            if on {
                glow(&ctx, 5) { $0.fill(tile, with: .color(col.opacity(0.55 * exp(-age * 1.5) + 0.15))) }
            }
            ctx.fill(tile, with: .linearGradient(
                Gradient(colors: on ? [col, col.opacity(0.75)] : [tint.opacity(0.28), tint.opacity(0.18)]),
                startPoint: CGPoint(x: q.x, y: rect.minY), endPoint: CGPoint(x: q.x, y: rect.maxY)))
            ctx.stroke(tile, with: .color(.white.opacity(on ? 0.5 : 0.15)), lineWidth: 0.8)
            var g = ctx
            g.translateBy(x: q.x, y: q.y)
            g.scaleBy(x: scale, y: scale)
            g.opacity = on ? 1 : 0.55
            appGlyph(&g, i, ns)
            if on, age < 0.9 {
                let x = age / 0.9
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -ns * 0.5 * easeOut(x), dy: -ns * 0.5 * easeOut(x)),
                                cornerRadius: ns * 0.4), with: .color(col.opacity(0.7 * (1 - x))), lineWidth: 1)
            }
            if isFlag, age > 0 {
                let blink = 0.5 + 0.5 * cos(age * 9)
                let bc = CGPoint(x: rect.maxX, y: rect.minY)
                ctx.fill(disc(bc, 4.2), with: .color(orange.opacity(0.6 + 0.4 * blink)))
                ctx.fill(Path(roundedRect: CGRect(x: bc.x - 0.6, y: bc.y - 2.6, width: 1.2, height: 3.2), cornerRadius: 0.6), with: .color(.white))
                ctx.fill(disc(CGPoint(x: bc.x, y: bc.y + 1.9), 0.7), with: .color(.white))
            } else if i < checked {
                let bc = CGPoint(x: rect.maxX, y: rect.minY)
                ctx.fill(disc(bc, 4.2), with: .color(.white))
                var cg = ctx
                cg.translateBy(x: bc.x, y: bc.y)
                cg.stroke(check(5), with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }

        // Power button: press dip, spring back, flash.
        let press = u < 0.12 ? sin(u / 0.12 * .pi) : 0
        let back = u >= 0.12 ? exp(-(u - 0.12) * period * 5) * sin((u - 0.12) * period * 22) * 0.06 : 0
        let br = w * 0.13 * (1 - 0.1 * press + back)
        let flash = exp(-max(0, u - 0.1) * period * 3)
        glow(&ctx, 8) { $0.fill(disc(c, br * (1.1 + 0.3 * flash)), with: .color(tint.opacity(0.35 + 0.4 * flash))) }
        ctx.fill(disc(c, br), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.95), tint.opacity(0.75)]),
            center: CGPoint(x: c.x - br * 0.3, y: c.y - br * 0.4), startRadius: 0, endRadius: br * 1.4))
        ctx.stroke(disc(c, br), with: .color(.white.opacity(0.35)), lineWidth: 1)
        if let sym = ctx.resolveSymbol(id: 1) {
            var g = ctx
            g.translateBy(x: c.x, y: c.y)
            g.scaleBy(x: 1 - 0.1 * press, y: 1 - 0.1 * press)
            g.draw(sym, at: .zero)
        }
    }

    // MARK: Security check: shield assembling, checklist ticking

    static func shieldPath(_ c: CGPoint, _ w: Double, _ h: Double) -> Path {
        var p = Path()
        let top = c.y - h / 2, bot = c.y + h / 2
        p.move(to: CGPoint(x: c.x, y: top))
        p.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: top + h * 0.14), control: CGPoint(x: c.x + w * 0.28, y: top + h * 0.1))
        p.addCurve(to: CGPoint(x: c.x, y: bot), control1: CGPoint(x: c.x + w / 2, y: top + h * 0.62),
                   control2: CGPoint(x: c.x + w * 0.2, y: bot - h * 0.12))
        p.addCurve(to: CGPoint(x: c.x - w / 2, y: top + h * 0.14), control1: CGPoint(x: c.x - w * 0.2, y: bot - h * 0.12),
                   control2: CGPoint(x: c.x - w / 2, y: top + h * 0.62))
        p.addQuadCurve(to: CGPoint(x: c.x, y: top), control: CGPoint(x: c.x - w * 0.28, y: top + h * 0.1))
        p.closeSubpath()
        return p
    }

    // Armour plates fill the shield one by one with progress (the newest
    // slides in on a spring); a light runs around the rim; three checklist
    // rows tick in sequence every cycle, then a sheen sweeps the shield and a
    // ring pulses out.

    static func checklist(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2 - w * 0.01)
        let sw = w * 0.56, sh = w * 0.66
        let shield = shieldPath(c, sw, sh)
        let period = 3.0
        let u = fract(t / period)
        let top = c.y - sh / 2

        // Pulse ring at the end of each cycle.
        if u > 0.8 {
            let x = (u - 0.8) / 0.2
            var g = ctx
            g.translateBy(x: c.x, y: c.y)
            let k = 1 + 0.35 * easeOut(x)
            g.scaleBy(x: k, y: k)
            g.translateBy(x: -c.x, y: -c.y)
            g.stroke(shield, with: .color(tint.opacity(0.5 * (1 - x))), lineWidth: 1.5)
        }

        // Body and plates.
        glow(&ctx, 10) { $0.fill(shield, with: .color(tint.opacity(0.25))) }
        ctx.fill(shield, with: .color(tint.opacity(0.14)))
        var g = ctx
        g.clip(to: shield)
        let plates = 6
        let filled = p * Double(plates)
        for k in 0..<plates {
            let f = clamp(filled - Double(k))
            guard f > 0 else { continue }
            let y0 = top + sh * Double(plates - 1 - k) / Double(plates)
            let slide = (1 - min(spring(f * 1.2, damping: 6, freq: 1.3), 1.15)) * sw * (k % 2 == 0 ? -1 : 1)
            let rect = CGRect(x: c.x - sw / 2 + slide, y: y0 + 0.8, width: sw, height: sh / Double(plates) - 1.6)
            g.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [tint.opacity(0.9), tint.opacity(0.65)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            g.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)), with: .color(.white.opacity(0.35)))
        }
        // Sheen.
        let sx = c.x - sw + (sw * 2) * easeInOut((u - 0.72) / 0.22)
        if u > 0.7, u < 0.96 {
            var band = Path()
            band.move(to: CGPoint(x: sx - 10, y: top - 4)); band.addLine(to: CGPoint(x: sx + 4, y: top - 4))
            band.addLine(to: CGPoint(x: sx - 18, y: top + sh + 4)); band.addLine(to: CGPoint(x: sx - 32, y: top + sh + 4))
            band.closeSubpath()
            g.fill(band, with: .color(.white.opacity(0.45)))
        }
        ctx.stroke(shield, with: .linearGradient(Gradient(colors: [.white.opacity(0.7), tint.opacity(0.8)]),
                                                 startPoint: CGPoint(x: c.x, y: top), endPoint: CGPoint(x: c.x, y: top + sh)),
                   lineWidth: 1.6)
        // Light running round the rim.
        let runner = fract(t / 2.2)
        let seg = shield.trimmedPath(from: max(0, runner - 0.12), to: runner)
        glow(&ctx, 3) { $0.stroke(seg, with: .color(tint), lineWidth: 4) }
        ctx.stroke(seg, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        // Checklist rows.
        let rowX = c.x - sw * 0.24
        for k in 0..<3 {
            let y = c.y - sh * 0.16 + Double(k) * sh * 0.17
            let tk = u - (0.12 + 0.18 * Double(k))
            let pop = tk > 0 ? min(spring(tk * 2.2, damping: 5, freq: 1.8), 1.2) : 0
            let r = w * 0.035
            let bc = CGPoint(x: rowX, y: y)
            ctx.fill(disc(bc, r * (0.9 + 0.2 * pop)), with: .color(.white.opacity(0.25 + 0.75 * min(pop, 1))))
            if tk > 0 {
                var cg = ctx
                cg.translateBy(x: bc.x, y: bc.y)
                cg.stroke(check(r * 1.25).trimmedPath(from: 0, to: easeOut(tk / 0.15)), with: .color(tint),
                          style: StrokeStyle(lineWidth: r * 0.4, lineCap: .round, lineJoin: .round))
            }
            let len = sw * [0.42, 0.34, 0.38][k]
            ctx.fill(Path(roundedRect: CGRect(x: rowX + r * 1.8, y: y - 1.6, width: len, height: 3.2), cornerRadius: 1.6),
                     with: .color(.white.opacity(0.35 + 0.5 * min(pop, 1))))
        }
    }

    // MARK: Packages: boxes unpacking into files

    // A cardboard box bobs as its flaps spring open; files pop out on arcs and
    // settle on a shelf above it, one slot per step of progress, while the
    // newest bounces into place. A tape strip glints across the box.

    static let fileColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo]

    static func fileIcon(_ ctx: inout GraphicsContext, _ c: CGPoint, _ size: Double, _ color: Color, rot: Double, alpha: Double) {
        guard alpha > 0.01 else { return }
        var g = ctx
        g.opacity = alpha
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(rot))
        let w = size * 0.78, h = size
        let (outline, fold) = paperOutline(w, h)
        g.fill(outline, with: .linearGradient(Gradient(colors: [Color(white: 0.99), Color(white: 0.88)]),
                                              startPoint: CGPoint(x: 0, y: -h / 2), endPoint: CGPoint(x: 0, y: h / 2)))
        g.stroke(outline, with: .color(.black.opacity(0.12)), lineWidth: 0.6)
        g.fill(fold, with: .color(Color(white: 0.8)))
        g.fill(Path(roundedRect: CGRect(x: -w * 0.36, y: h * 0.12, width: w * 0.72, height: h * 0.22), cornerRadius: 1.5),
               with: .color(color))
        for k in 0..<2 {
            g.fill(Path(roundedRect: CGRect(x: -w * 0.3, y: -h * 0.18 + Double(k) * h * 0.12, width: w * (k == 0 ? 0.5 : 0.36), height: 1.6),
                        cornerRadius: 0.8), with: .color(.gray.opacity(0.5)))
        }
    }

    static func unbox(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let brown = Color(nsColor: .systemBrown)
        let bw = w * 0.42, bh = w * 0.26
        let boxTop = c.y + w * 0.1
        let emit = 0.55
        let e = t / emit
        let lastEmit = fract(e) * emit
        let bob = exp(-lastEmit * 9) * sin(lastEmit * 30) * 0.05
        let open = 0.8 + 0.2 * sin(t * 1.7)

        // Shelf of unpacked files (progress).
        let slots = 7
        let settled = Int(floor(p * Double(slots) + 1e-6))
        let newest = fract(p * Double(slots))
        for k in 0..<slots {
            let a = -Double.pi / 2 + (Double(k) - Double(slots - 1) / 2) * 0.36
            let q = pt(CGPoint(x: c.x, y: boxTop + w * 0.06), w * 0.4, a)
            if k < settled {
                let pop = k == settled - 1 ? min(spring(newest * 8), 1.2) : 1
                let hover = sin(t * 2 + Double(k)) * 1.2
                fileIcon(&ctx, CGPoint(x: q.x, y: q.y + hover), w * 0.11 * pop, fileColors[k % fileColors.count],
                         rot: (Double(k) - 3) * 0.08, alpha: 1)
            } else {
                ctx.stroke(Path(roundedRect: CGRect(x: q.x - w * 0.04, y: q.y - w * 0.055, width: w * 0.08, height: w * 0.11),
                                cornerRadius: 2), with: .color(tint.opacity(0.2)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
            }
        }

        // Flying files: each leaves the box on an arc and fades near the shelf.
        let inBox = CGPoint(x: c.x, y: boxTop + bh * 0.2)
        for j in 0..<3 {
            let age = (fract(e) + Double(j)) * emit
            let life = 1.5
            guard age < life else { continue }
            let x = age / life
            let gen = Int(floor(e)) - j
            let dir = (hash(gen * 11) - 0.5) * 2
            let px = inBox.x + dir * w * 0.34 * easeOut(x)
            let py = inBox.y - w * 0.55 * sin(min(x, 0.95) * .pi * 0.62) + w * 0.1 * x * x
            let size = w * lerp(0.05, 0.12, easeOut(x / 0.4))
            let alpha = smooth(0, 0.08, x) * (1 - smooth(0.75, 1, x))
            fileIcon(&ctx, CGPoint(x: px, y: py), size, fileColors[(gen % 7 + 7) % 7], rot: dir * x * 1.2, alpha: alpha)
            if x < 0.3 { softDot(&ctx, CGPoint(x: px, y: py), w * 0.06, .white, 0.4 * (1 - x / 0.3)) }
        }

        // Box.
        var g = ctx
        g.translateBy(x: c.x, y: boxTop + bh)
        g.scaleBy(x: 1 + bob, y: 1 - bob)
        g.translateBy(x: -c.x, y: -(boxTop + bh))
        let front = CGRect(x: c.x - bw / 2, y: boxTop, width: bw, height: bh)
        // Inside (dark) visible between flaps.
        var inside = Path()
        inside.move(to: CGPoint(x: front.minX, y: boxTop)); inside.addLine(to: CGPoint(x: front.minX + bw * 0.12, y: boxTop - bh * 0.22))
        inside.addLine(to: CGPoint(x: front.maxX - bw * 0.12, y: boxTop - bh * 0.22)); inside.addLine(to: CGPoint(x: front.maxX, y: boxTop))
        inside.closeSubpath()
        g.fill(inside, with: .color(brown.opacity(0.55)))
        g.fill(inside, with: .color(.black.opacity(0.35)))
        softDot(&g, CGPoint(x: c.x, y: boxTop - bh * 0.1), bw * 0.4, .white, 0.25 + 0.25 * exp(-lastEmit * 4))
        // Flaps.
        for side in [-1.0, 1.0] {
            let hingeOuter = CGPoint(x: c.x + side * bw / 2, y: boxTop)
            let hingeInner = CGPoint(x: c.x, y: boxTop)
            let lift = bh * 0.55 * open
            let out = bw * 0.18 * open
            var flap = Path()
            flap.move(to: hingeInner); flap.addLine(to: hingeOuter)
            flap.addLine(to: CGPoint(x: hingeOuter.x + side * out, y: boxTop - lift))
            flap.addLine(to: CGPoint(x: hingeInner.x + side * out * 0.3, y: boxTop - lift * 0.9))
            flap.closeSubpath()
            g.fill(flap, with: .linearGradient(Gradient(colors: [brown.opacity(0.75), brown.opacity(0.95)]),
                                               startPoint: CGPoint(x: c.x, y: boxTop - lift), endPoint: CGPoint(x: c.x, y: boxTop)))
            g.stroke(flap, with: .color(.white.opacity(0.18)), lineWidth: 0.7)
        }
        let body = Path(roundedRect: front, cornerRadius: 3)
        g.fill(body, with: .linearGradient(Gradient(colors: [brown, brown.opacity(0.78)]),
                                           startPoint: CGPoint(x: c.x, y: front.minY), endPoint: CGPoint(x: c.x, y: front.maxY)))
        // Tape with a glint.
        let tape = CGRect(x: c.x - bw * 0.08, y: front.minY, width: bw * 0.16, height: bh)
        g.fill(Path(tape), with: .color(tint.opacity(0.55)))
        let gx = fract(t / 2.6) * 1.6 - 0.3
        if gx > 0, gx < 1 {
            var gl = g
            gl.clip(to: body)
            gl.fill(Path(CGRect(x: front.minX + bw * gx - 6, y: front.minY, width: 8, height: bh)),
                    with: .color(.white.opacity(0.22)))
        }
        // "This side up" arrows.
        for k in 0..<2 {
            let ax = front.minX + bw * (0.2 + 0.6 * Double(k))
            var arrow = Path()
            arrow.move(to: CGPoint(x: ax, y: front.maxY - bh * 0.25)); arrow.addLine(to: CGPoint(x: ax, y: front.minY + bh * 0.3))
            arrow.move(to: CGPoint(x: ax - 3, y: front.minY + bh * 0.42)); arrow.addLine(to: CGPoint(x: ax, y: front.minY + bh * 0.3))
            arrow.addLine(to: CGPoint(x: ax + 3, y: front.minY + bh * 0.42))
            g.stroke(arrow, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Ports: network with packets flowing

    // The Mac sits in the middle with a ring of port lights. Peer devices
    // orbit slowly on a tilted ring; packets travel along the links in both
    // directions, and an open port flashes when one arrives. More ports and
    // peers light up as progress grows.

    static func network(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let peers = 6
        let R = w * 0.38
        let spin = t * 0.12
        var pos: [CGPoint] = []
        var depth: [Double] = []
        for i in 0..<peers {
            let a = spin + Double(i) * 2 * .pi / Double(peers) + 0.3 * hash(i)
            let rr = R * (0.88 + 0.12 * hash(i + 9))
            pos.append(CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr * 0.78 + sin(t * 1.3 + Double(i)) * 2))
            depth.append(0.5 + 0.5 * sin(a))
        }
        let shown = 2 + Int(floor(p * Double(peers - 2) + 1e-6))

        // Mesh between neighbours.
        for i in 0..<peers {
            let j = (i + 1) % peers
            ctx.stroke(line(pos[i], pos[j]), with: .color(tint.opacity(0.10)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        }
        // Links with packets.
        var portFlash = [Double](repeating: 0, count: 12)
        for i in 0..<peers {
            let on = i < shown
            let q = pos[i]
            let mid = CGPoint(x: (c.x + q.x) / 2 + (q.y - c.y) * 0.18, y: (c.y + q.y) / 2 - (q.x - c.x) * 0.18)
            var link = Path()
            link.move(to: c); link.addQuadCurve(to: q, control: mid)
            ctx.stroke(link, with: .color(tint.opacity(on ? 0.28 : 0.08)), lineWidth: on ? 1.2 : 0.8)
            guard on else { continue }
            for k in 0..<2 {
                let inbound = k == 1
                let speed = 0.55 + 0.3 * hash(i * 3 + k)
                let ph = fract(t * speed + hash(i * 7 + k * 5))
                let f = inbound ? 1 - ph : ph
                let m = 1 - f
                let pq = CGPoint(x: m * m * c.x + 2 * m * f * mid.x + f * f * q.x,
                                 y: m * m * c.y + 2 * m * f * mid.y + f * f * q.y)
                let col: Color = inbound ? .white : tint
                softDot(&ctx, pq, 7, tint, 0.5)
                ctx.fill(disc(pq, 2.2), with: .color(col.opacity(0.95)))
                if inbound, ph > 0.88 { portFlash[(i * 2) % 12] = max(portFlash[(i * 2) % 12], (ph - 0.88) / 0.12) }
            }
        }
        // Peer nodes, far ones dimmer and smaller.
        for i in 0..<peers {
            let on = i < shown
            let d = depth[i]
            let r = w * (0.045 + 0.02 * d)
            let q = pos[i]
            if on { softDot(&ctx, q, r * 2.4, tint, 0.35 + 0.2 * sin(t * 3 + Double(i))) }
            ctx.fill(disc(q, r), with: .radialGradient(Gradient(colors: [on ? tint : tint.opacity(0.35), on ? tint.opacity(0.7) : tint.opacity(0.2)]),
                                                     center: CGPoint(x: q.x - r * 0.3, y: q.y - r * 0.4), startRadius: 0, endRadius: r * 1.5))
            ctx.stroke(disc(q, r * 0.55), with: .color(.white.opacity(on ? 0.75 : 0.3)), lineWidth: 0.8)
            ctx.stroke(ellipseArc(q, r * 0.55, r * 0.22, 0, 2 * .pi, steps: 16), with: .color(.white.opacity(on ? 0.6 : 0.25)), lineWidth: 0.6)
        }
        // The Mac and its ports.
        let hubR = w * 0.14
        glow(&ctx, 8) { $0.fill(disc(c, hubR), with: .color(tint.opacity(0.45))) }
        ctx.fill(disc(c, hubR), with: .radialGradient(Gradient(colors: [tint.opacity(0.95), tint.opacity(0.7)]),
                                                     center: CGPoint(x: c.x - hubR * 0.3, y: c.y - hubR * 0.4),
                                                     startRadius: 0, endRadius: hubR * 1.4))
        ctx.stroke(disc(c, hubR), with: .color(.white.opacity(0.35)), lineWidth: 1)
        let open = Int(floor(3 + p * 9))
        for k in 0..<12 {
            let a = -Double.pi / 2 + Double(k) * 2 * .pi / 12 + t * 0.2
            let q = pt(c, hubR * 1.28, a)
            let lit = k < open
            let fl = portFlash[k]
            ctx.fill(disc(q, 1.8 + 1.4 * fl), with: .color(lit ? (fl > 0 ? Color.white : tint) : tint.opacity(0.25)))
            if fl > 0 { softDot(&ctx, q, 6, tint, fl) }
        }
        if let sym = ctx.resolveSymbol(id: 2) { ctx.draw(sym, at: c) }
    }

    // MARK: Apple privacy: an eye closing with sparkles

    // An eye looks around with quick saccades (spring settle), then the lid
    // closes, a slash draws across it and sparkles twinkle out; it reopens a
    // little sleepier each time as progress grows, and stays closed at 100 %.

    static func eyeOutline(_ c: CGPoint, _ w: Double, _ open: Double) -> Path {
        var p = Path()
        let h = w * 0.36 * open
        p.move(to: CGPoint(x: c.x - w / 2, y: c.y))
        p.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y - h))
        p.addQuadCurve(to: CGPoint(x: c.x - w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y + h))
        p.closeSubpath()
        return p
    }

    static func eye(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        let ew = w * 0.66
        let period = 3.8
        let cyc = t / period
        let u = fract(cyc)
        let maxOpen = p >= 0.98 ? 0.0 : 1 - 0.45 * p
        var open: Double
        if u < 0.55 { open = maxOpen }
        else if u < 0.66 { open = maxOpen * (1 - easeIn((u - 0.55) / 0.11)) }
        else if u < 0.9 { open = 0 }
        else { open = maxOpen * spring((u - 0.9) / 0.1 * 0.6, damping: 6, freq: 1.2) }
        open = clamp(open, 0, 1.05)

        // Gaze: saccades every 0.6 s with spring settle.
        let sacc = t / 0.6
        let si = Int(floor(sacc))
        let su = fract(sacc)
        func target(_ k: Int) -> CGPoint {
            CGPoint(x: (hash(k * 17) - 0.5) * ew * 0.42, y: (hash(k * 23 + 1) - 0.5) * ew * 0.12)
        }
        let a0 = target(si - 1), a1 = target(si)
        let mv = min(spring(su * 1.6, damping: 8, freq: 1.4), 1.1)
        let gaze = CGPoint(x: c.x + lerp(a0.x, a1.x, mv), y: c.y + lerp(a0.y, a1.y, mv))

        let outline = eyeOutline(c, ew, max(open, 0.02))
        glow(&ctx, 8) { $0.fill(outline, with: .color(tint.opacity(0.25 * open))) }
        if open > 0.03 {
            ctx.fill(outline, with: .linearGradient(Gradient(colors: [Color(white: 0.98), Color(white: 0.88)]),
                                                    startPoint: CGPoint(x: c.x, y: c.y - ew * 0.2), endPoint: CGPoint(x: c.x, y: c.y + ew * 0.2)))
            var g = ctx
            g.clip(to: outline)
            let ir = ew * 0.17
            g.fill(disc(gaze, ir), with: .radialGradient(Gradient(colors: [tint.opacity(0.65), tint, tint.opacity(0.9)]),
                                                         center: gaze, startRadius: ir * 0.2, endRadius: ir))
            // Iris fibres.
            for k in 0..<14 {
                let a = Double(k) * 2 * .pi / 14 + t * 0.2
                g.stroke(line(pt(gaze, ir * 0.45, a), pt(gaze, ir * 0.92, a)), with: .color(.white.opacity(0.18)), lineWidth: 0.6)
            }
            let pupil = ir * (0.42 + 0.06 * sin(t * 1.3))
            g.fill(disc(gaze, pupil), with: .color(Color(white: 0.08)))
            g.fill(disc(CGPoint(x: gaze.x - ir * 0.32, y: gaze.y - ir * 0.34), ir * 0.18), with: .color(.white.opacity(0.9)))
            g.fill(disc(CGPoint(x: gaze.x + ir * 0.25, y: gaze.y + ir * 0.28), ir * 0.07), with: .color(.white.opacity(0.6)))
            // Upper-lid shadow.
            g.fill(Path(CGRect(x: c.x - ew / 2, y: c.y - ew * 0.3, width: ew, height: ew * 0.14)),
                   with: .linearGradient(Gradient(colors: [.black.opacity(0.18), .black.opacity(0)]),
                                         startPoint: CGPoint(x: c.x, y: c.y - ew * 0.2 * open), endPoint: CGPoint(x: c.x, y: c.y - ew * 0.05)))
        }
        ctx.stroke(outline, with: .color(tint), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))

        // Closed: lid curve with lashes, slash, sparkles.
        let closed = 1 - smooth(0.02, 0.1, open)
        if closed > 0.01 {
            var lid = Path()
            lid.move(to: CGPoint(x: c.x - ew / 2, y: c.y))
            lid.addQuadCurve(to: CGPoint(x: c.x + ew / 2, y: c.y), control: CGPoint(x: c.x, y: c.y + ew * 0.16))
            ctx.stroke(lid, with: .color(tint.opacity(closed)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            for k in 0..<5 {
                let f = 0.2 + 0.15 * Double(k)
                let x = c.x - ew / 2 + ew * f
                let y = c.y + ew * 0.16 * 2 * f * (1 - f)
                let ang = Double.pi / 2 + (f - 0.5) * 1.2
                ctx.stroke(line(CGPoint(x: x, y: y), pt(CGPoint(x: x, y: y), ew * 0.07, ang)),
                           with: .color(tint.opacity(closed)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            let slashU = clamp((u - 0.66) / 0.12)
            if slashU > 0 || p >= 0.98 {
                let su2 = p >= 0.98 ? 1 : easeOut(slashU)
                let a = CGPoint(x: c.x - ew * 0.42, y: c.y - ew * 0.36)
                let b = CGPoint(x: c.x + ew * 0.42, y: c.y + ew * 0.36)
                let slash = line(a, b).trimmedPath(from: 0, to: su2)
                glow(&ctx, 3) { $0.stroke(slash, with: .color(tint.opacity(closed)), lineWidth: 5) }
                ctx.stroke(slash, with: .color(tint.opacity(closed)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.stroke(slash, with: .color(.white.opacity(0.6 * closed)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            for k in 0..<6 {
                let st = u - 0.68 - 0.03 * Double(k)
                guard st > 0 || p >= 0.98 else { continue }
                let life = p >= 0.98 ? fract(t * 0.6 + hash(k)) : st / 0.25
                guard life < 1 else { continue }
                let ang = hash(k * 5 + Int(floor(cyc))) * 2 * .pi
                let q = pt(c, ew * (0.35 + 0.25 * easeOut(life)), ang)
                let r = w * (0.025 + 0.025 * hash(k + 3)) * sin(life * .pi)
                glow(&ctx, 2) { $0.fill(sparkle(q, r * 1.3, t), with: .color(tint.opacity(0.8))) }
                ctx.fill(sparkle(q, r, t * 2 + Double(k)), with: .color(.white))
            }
        }
    }

    // MARK: Unused apps: tiles falling asleep

    // A grid of app tiles; a magnifier with a little clock visits them. Apps
    // found unused (more with progress) fade to grey, droop and breathe out
    // "z"s, while a crescent moon glows above with twinkling stars.

    static func zGlyph(_ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - r, y: c.y - r)); p.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x - r, y: c.y + r)); p.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
        return p
    }

    static func sleepyApps(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2, y: s.height / 2 + w * 0.06)
        let ts = w * 0.17, step = ts + w * 0.05
        let unusedSet = [0, 2, 4, 6, 7]
        let found = Int(floor(p * Double(unusedSet.count) + 0.6))
        let newest = fract(p * Double(unusedSet.count) + 0.6)

        // Moon and stars.
        let mc = CGPoint(x: c.x + w * 0.3, y: c.y - w * 0.42)
        let mr = w * 0.07
        glow(&ctx, 6) { $0.fill(disc(mc, mr * 1.2), with: .color(Color.yellow.opacity(0.35 + 0.1 * sin(t * 1.5)))) }
        var moon = Path(ellipseIn: CGRect(x: mc.x - mr, y: mc.y - mr, width: mr * 2, height: mr * 2))
        moon = moon.subtracting(Path(ellipseIn: CGRect(x: mc.x - mr * 0.45, y: mc.y - mr * 1.25, width: mr * 2, height: mr * 2)))
        ctx.fill(moon, with: .color(Color(nsColor: .systemYellow)))
        for k in 0..<4 {
            let q = CGPoint(x: c.x + (hash(k * 3) - 0.6) * w * 0.7, y: c.y - w * (0.36 + 0.1 * hash(k * 3 + 1)))
            let tw = 0.5 + 0.5 * sin(t * (2 + hash(k)) * 2 + Double(k) * 2)
            ctx.fill(sparkle(q, 2 + 2.5 * tw, 0), with: .color(tint.opacity(0.3 + 0.5 * tw)))
        }

        // Inspector visits tiles in a scattered order.
        let beat = t / 1.0
        let order = [4, 0, 8, 2, 6, 1, 7, 3, 5]
        let focus = order[Int(floor(beat)) % 9]
        let fu = fract(beat)

        for i in 0..<9 {
            let center = CGPoint(x: c.x + Double(i % 3 - 1) * step, y: c.y + Double(i / 3 - 1) * step)
            let ui = unusedSet.firstIndex(of: i)
            let asleep = ui.map { $0 < found } ?? false
            let fresh = ui.map { $0 == found - 1 } ?? false
            let doze = asleep ? (fresh ? min(newest * 4, 1) : 1) : 0
            let breath = asleep ? sin(t * 1.6 + Double(i)) * 0.04 : 0
            let isFocus = i == focus
            let lift = isFocus ? sin(clamp(fu / 0.9) * .pi) : 0
            var g = ctx
            g.translateBy(x: center.x, y: center.y + doze * 2 - lift * 3)
            g.rotate(by: .radians(doze * (i % 2 == 0 ? -0.12 : 0.1) + breath))
            g.scaleBy(x: 1 + 0.1 * lift, y: 1 + 0.1 * lift - 0.04 * doze)
            let rect = CGRect(x: -ts / 2, y: -ts / 2, width: ts, height: ts)
            let tile = Path(roundedRect: rect, cornerRadius: ts * 0.24, style: .continuous)
            let col = appColors[i]
            g.fill(tile, with: .linearGradient(Gradient(colors: [col, col.opacity(0.78)]),
                                               startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            if doze > 0 { g.fill(tile, with: .color(Color(white: 0.55).opacity(0.75 * doze))) }
            g.fill(tile, with: .linearGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0)]),
                                               startPoint: CGPoint(x: 0, y: rect.minY), endPoint: .zero))
            appGlyph(&g, i, ts)
            if doze > 0 {
                // Closed eyes on a sleeping tile.
                for sx in [-1.0, 1.0] {
                    g.stroke(arc(CGPoint(x: sx * ts * 0.17, y: ts * 0.18), ts * 0.07, 0.2, .pi - 0.2),
                             with: .color(.white.opacity(0.9 * doze)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            if isFocus {
                g.stroke(tile, with: .color(.white.opacity(0.8 * lift)), lineWidth: 1.5)
            }
            // Zs drifting up.
            if asleep {
                for k in 0..<2 {
                    let zp = fract(t * 0.45 + hash(i * 5 + k) + Double(k) * 0.5)
                    let zq = CGPoint(x: center.x + ts * 0.35 + zp * ts * 0.5 + sin(zp * 6 + Double(i)) * 2,
                                     y: center.y - ts * 0.4 - zp * ts * 0.9)
                    let zr = ts * (0.07 + 0.08 * zp)
                    ctx.stroke(zGlyph(zq, zr), with: .color(tint.opacity(doze * sin(zp * .pi) * 0.95)),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
        }
        // Clock badge riding on the focused tile.
        let fcenter = CGPoint(x: c.x + Double(focus % 3 - 1) * step + ts * 0.42, y: c.y + Double(focus / 3 - 1) * step - ts * 0.42)
        let br = ts * 0.24
        let pop = min(spring(fu * 3, damping: 6, freq: 1.6), 1.15) * (1 - smooth(0.85, 1, fu))
        if pop > 0.02 {
            ctx.fill(disc(fcenter, br * pop + 1), with: .color(.black.opacity(0.18)))
            ctx.fill(disc(fcenter, br * pop), with: .color(.white))
            ctx.stroke(disc(fcenter, br * pop * 0.78), with: .color(tint), lineWidth: 1.2)
            let hand = t * 4
            ctx.stroke(line(fcenter, pt(fcenter, br * 0.6 * pop, hand)), with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            ctx.stroke(line(fcenter, pt(fcenter, br * 0.4 * pop, hand / 12 - .pi / 2)), with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    // MARK: Extra space: a spinning platter revealing hidden sectors

    // A disk platter spins (rotating sheen) while the read head seeks between
    // tracks with a springy overshoot. Sectors light up under the head as
    // hidden space is found; more stay lit as progress grows.

    static func platter(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double, _ p: Double, _ tint: Color) {
        let w = s.width
        let c = CGPoint(x: s.width / 2 - w * 0.04, y: s.height / 2 - w * 0.02)
        let R = w * 0.4
        let spinA = t * 2.2

        // Platter body.
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4))
            l.fill(disc(c, R), with: .radialGradient(Gradient(colors: [Color(white: 0.92), Color(white: 0.72), Color(white: 0.84)]),
                                                     center: c, startRadius: R * 0.1, endRadius: R))
        }
        ctx.fill(disc(c, R), with: .color(tint.opacity(0.12)))
        ctx.fill(disc(c, R), with: .conicGradient(Gradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.55), location: 0.08),
            .init(color: .white.opacity(0), location: 0.2),
            .init(color: .white.opacity(0), location: 0.5),
            .init(color: .white.opacity(0.4), location: 0.58),
            .init(color: .white.opacity(0), location: 0.7),
        ]), center: c, angle: .radians(spinA * 0.15)))
        // Tracks and sectors.
        let tracks = 5
        for k in 0..<tracks {
            let rr = R * (0.36 + 0.13 * Double(k))
            ctx.stroke(disc(c, rr), with: .color(.black.opacity(0.08)), lineWidth: 0.6)
        }
        // Head seek.
        let seek = t / 0.9
        let si = Int(floor(seek))
        let su = fract(seek)
        let trackOf: (Int) -> Int = { Int(hash($0 * 29 + 3) * Double(tracks)) % tracks }
        let tr0 = Double(trackOf(si - 1)), tr1 = Double(trackOf(si))
        let mv = min(spring(su * 1.5, damping: 7, freq: 1.6), 1.12)
        let headTrack = lerp(tr0, tr1, mv)
        let headR = R * (0.36 + 0.13 * headTrack)
        let pivot = CGPoint(x: c.x + R * 1.02, y: c.y + R * 0.98)
        let armLen = hypot(pivot.x - c.x, pivot.y - c.y) * 0.98
        // Head position: intersection of the arm circle and the track circle.
        let d = hypot(pivot.x - c.x, pivot.y - c.y)
        let aa = (headR * headR - armLen * armLen + d * d) / (2 * d)
        let hh = sqrt(max(0, headR * headR - aa * aa))
        let ux = (pivot.x - c.x) / d, uy = (pivot.y - c.y) / d
        let head = CGPoint(x: c.x + aa * ux - hh * uy, y: c.y + aa * uy + hh * ux)
        let headAng = atan2(head.y - c.y, head.x - c.x)

        // Sectors: fixed in platter space, rotate with it.
        let found = 4 + Int(p * 18)
        for i in 0..<22 {
            let k = trackOf(i * 7 + 100)
            let rr = R * (0.36 + 0.13 * Double(k))
            let a0 = hash(i * 13 + 2) * 2 * .pi + spinA
            let span = 0.35 + 0.3 * hash(i + 40)
            let lit = i < found
            // Light up when passing under the head.
            let rel = fract((headAng - a0) / (2 * .pi))
            let under = abs(Double(k) - headTrack) < 0.5 ? exp(-rel * 6) : 0
            guard lit || under > 0.05 else { continue }
            let segP = arc(c, rr, a0, a0 + span)
            let o = (lit ? 0.55 : 0) + 0.45 * under
            if under > 0.2 { glow(&ctx, 3) { $0.stroke(segP, with: .color(tint.opacity(under)), lineWidth: 6) } }
            ctx.stroke(segP, with: .color(tint.opacity(min(1, o))), style: StrokeStyle(lineWidth: R * 0.075, lineCap: .butt))
        }
        // Spindle.
        ctx.fill(disc(c, R * 0.2), with: .radialGradient(Gradient(colors: [Color(white: 0.98), Color(white: 0.7)]),
                                                         center: CGPoint(x: c.x - R * 0.05, y: c.y - R * 0.06), startRadius: 0, endRadius: R * 0.22))
        ctx.stroke(disc(c, R * 0.2), with: .color(.black.opacity(0.12)), lineWidth: 0.8)
        for k in 0..<6 {
            ctx.fill(disc(pt(c, R * 0.12, spinA + Double(k) * .pi / 3), 1.2), with: .color(.black.opacity(0.25)))
        }
        ctx.fill(disc(c, R * 0.05), with: .color(tint))

        // Arm.
        var arm = Path()
        arm.move(to: pivot); arm.addLine(to: head)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.35), radius: 3, x: 1, y: 3))
            l.stroke(arm, with: .linearGradient(Gradient(colors: [Color(white: 0.95), Color(white: 0.65)]),
                                               startPoint: pivot, endPoint: head),
                     style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        }
        ctx.fill(disc(pivot, w * 0.05), with: .radialGradient(Gradient(colors: [Color(white: 0.95), Color(white: 0.6)]),
                                                             center: CGPoint(x: pivot.x - 2, y: pivot.y - 2), startRadius: 0, endRadius: w * 0.06))
        ctx.fill(disc(pivot, w * 0.018), with: .color(tint))
        softDot(&ctx, head, 9, tint, 0.85)
        ctx.fill(disc(head, 2.8), with: .color(.white))
    }
}
