import SwiftUI
import AppKit
import MacCleanerKit

// Stats-style live menu-bar items (RAM, battery, network, CPU). Every
// compound label is drawn into one NSImage set on the status button. Images are cached per item and only redrawn when
// the displayed string changes; digits are monospaced and each item has a
// fixed width (sized for its widest value) so nothing jitters.

/// Shared-defaults keys for showing/hiding the extra menu-bar items.
enum MenuItemKey {
    static let ram = "menuItemRAM"
    static let battery = "menuItemBattery"
    static let network = "menuItemNetwork"
    static let cpu = "menuItemCPU"
}

@MainActor
enum MenuBarLabelImages {
    private static var cache: [String: (key: String, image: NSImage)] = [:]
    /// Last image per item (used by the KMR_MENU_LABELS debug dump).
    static var rendered: [String: NSImage] { cache.mapValues(\.image) }

    static let height: CGFloat = 22
    private static let captionFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    /// Baselines (flipped, from the top) of the caption and the value of a stack.
    private static let captionBaseline: CGFloat = 8.5
    private static let valueBaseline: CGFloat = 20.5

    private static func cached(_ slot: String, _ key: String, _ make: () -> NSImage) -> NSImage {
        if let c = cache[slot], c.key == key { return c.image }
        let image = make()
        cache[slot] = (key, image)
        return image
    }

    private static func width(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Draws `s` with its baseline at `baseline` (flipped context), centred on `midX`.
    private static func draw(_ s: String, font: NSFont, midX: CGFloat, baseline: CGFloat, color: NSColor = .black) {
        let w = width(s, font)
        (s as NSString).draw(with: NSRect(x: midX - w / 2, y: baseline, width: w + 2, height: font.pointSize),
                             options: [], attributes: [.font: font, .foregroundColor: color])
    }

    private static func stackWidth(_ caption: String, _ widest: String) -> CGFloat {
        max(width(caption, captionFont), width(widest, valueFont))
    }

    private static func drawStack(_ caption: String, _ value: String, midX: CGFloat) {
        draw(caption, font: captionFont, midX: midX, baseline: captionBaseline)
        draw(value, font: valueFont, midX: midX, baseline: valueBaseline)
    }

    /// Tiny caption above a bold value ("RAM" over "85%"). Template image, so
    /// the menu bar tints it for light/dark and wallpaper vibrancy. The width
    /// is fixed for the widest value, with no padding of its own.
    static func stacked(slot: String, caption: String, value: String, widest: String = "100%") -> NSImage {
        cached(slot, caption + "|" + value) {
            let w = stackWidth(caption, widest)
            let image = NSImage(size: NSSize(width: w, height: height), flipped: true) { r in
                drawStack(caption, value, midX: r.width / 2)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = "\(caption) \(value)"
            return image
        }
    }

    /// The Mac Mop item: the mop glyph, then (unless the user picked
    /// "icon only") a caption/value stack such as "SSD" over "81 GB".
    static func main(caption: String?, value: String, widest: String) -> NSImage {
        cached("main", "\(caption ?? "-")|\(value)|\(widest)") {
            let mop = MenuAssets.mop
            let mopSize = mop.map { NSSize(width: $0.size.width * 18 / max($0.size.height, 1), height: 18) } ?? .zero
            let gap: CGFloat = caption == nil ? 0 : 2
            let textW = caption.map { stackWidth($0, widest) } ?? 0
            let image = NSImage(size: NSSize(width: ceil(mopSize.width + gap + textW), height: height), flipped: true) { r in
                mop?.draw(in: NSRect(x: 0, y: (height - mopSize.height) / 2, width: mopSize.width, height: mopSize.height))
                if let caption { drawStack(caption, value, midX: mopSize.width + gap + textW / 2) }
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = [MCConstants.appName, caption, caption == nil ? nil : value].compactMap { $0 }.joined(separator: " ")
            return image
        }
    }

    /// Upload over download, each with a coloured dot (red up, blue down) like
    /// Stats. Colour needs a non-template image; the text uses labelColor,
    /// which AppKit resolves against the status item's appearance at draw time.
    static func network(up: String, down: String) -> NSImage {
        cached("network", up + "|" + down) {
            // compactRate never needs more than "9,9 MB/s" / "99 KB/s".
            let textW = ["99\u{2009}KB/s", "9,9\u{2009}MB/s", "99\u{2009}MB/s", "9,9\u{2009}GB/s"].map { width($0, rateFont) }.max() ?? 40
            let dot: CGFloat = 4, gap: CGFloat = 3
            let image = NSImage(size: NSSize(width: dot + gap + textW, height: height), flipped: true) { r in
                let lineH = rateFont.ascender - rateFont.descender
                for (i, line) in [(up, NSColor.systemRed), (down, NSColor.systemBlue)].enumerated() {
                    let y: CGFloat = i == 0 ? 0 : height - lineH
                    let baseline = y + rateFont.ascender
                    line.1.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 0, y: baseline - rateFont.capHeight / 2 - dot / 2, width: dot, height: dot)).fill()
                    let attrs: [NSAttributedString.Key: Any] = [.font: rateFont, .foregroundColor: NSColor.labelColor]
                    (line.0 as NSString).draw(at: NSPoint(x: r.width - width(line.0, rateFont), y: y), withAttributes: attrs)
                }
                return true
            }
            image.isTemplate = false
            image.accessibilityDescription = "Upload \(up), download \(down)"
            return image
        }
    }

    /// "39%" followed by a battery outline filled to the charge level, with a
    /// bolt while on power. Template image.
    static func battery(level: Double, charging: Bool, onAC: Bool) -> NSImage {
        let pct = Int((min(max(level, 0), 1) * 100).rounded())
        let text = "\(pct)%"
        return cached("battery", "\(pct)|\(charging)|\(onAC)") {
            let textW = width("100%", percentFont)
            let bodyW: CGFloat = 18, bodyH: CGFloat = 10, nub: CGFloat = 1.5, gap: CGFloat = 2
            let image = NSImage(size: NSSize(width: ceil(textW + gap + bodyW + nub + 0.5), height: height), flipped: true) { r in
                let attrs: [NSAttributedString.Key: Any] = [.font: percentFont, .foregroundColor: NSColor.black]
                let ty = (height - (percentFont.ascender - percentFont.descender)) / 2
                (text as NSString).draw(at: NSPoint(x: textW - width(text, percentFont), y: ty), withAttributes: attrs)

                guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                NSColor.black.set()
                let body = NSRect(x: textW + gap, y: (height - bodyH) / 2, width: bodyW, height: bodyH)
                let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.8, yRadius: 2.8)
                outline.lineWidth = 1
                NSColor.black.withAlphaComponent(0.45).setStroke()
                outline.stroke()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.5, y: body.midY - 1.75, width: nub, height: 3.5),
                             xRadius: 1, yRadius: 1).fill()
                let inner = body.insetBy(dx: 1.75, dy: 1.75)
                let fill = NSRect(x: inner.minX, y: inner.minY, width: max(2, inner.width * CGFloat(pct) / 100), height: inner.height)
                NSBezierPath(roundedRect: fill, xRadius: 1.2, yRadius: 1.2).fill()
                if charging || onAC {
                    let bolt = boltPath(in: NSRect(x: body.midX - 3.5, y: body.minY - 1.5, width: 7, height: bodyH + 3))
                    // Knock a gap around the bolt, then draw it solid.
                    ctx.setBlendMode(.destinationOut)
                    bolt.lineWidth = 2
                    bolt.stroke()
                    bolt.fill()
                    ctx.setBlendMode(.normal)
                    bolt.fill()
                }
                ctx.endTransparencyLayer()
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = "Battery \(text)" + (charging ? ", charging" : "")
            return image
        }
    }

    static func boltPath(in r: NSRect) -> NSBezierPath {
        // Flipped coordinates: y grows downward.
        let pts: [(CGFloat, CGFloat)] = [(0.62, 0), (0.08, 0.58), (0.46, 0.58), (0.36, 1), (0.92, 0.40), (0.54, 0.40)]
        let p = NSBezierPath()
        for (i, pt) in pts.enumerated() {
            let point = NSPoint(x: r.minX + pt.0 * r.width, y: r.minY + pt.1 * r.height)
            if i == 0 { p.move(to: point) } else { p.line(to: point) }
        }
        p.close()
        return p
    }

    /// Free space for the menu bar, decimal like Finder: "81 GB", "1,2 TB".
    static func compactDisk(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1e9
        if gb < 999.5 { return "\(Int(gb.rounded())) GB" }
        return (gb / 1000).formatted(.number.precision(.fractionLength(1)).locale(UIText.locale)) + " TB"
    }

    /// "42 KB/s", "4,2 MB/s", "42 MB/s", "1,2 GB/s": decimal units, never
    /// more than two digits (one decimal below 10), so the column stays narrow.
    /// A thin space separates number and unit.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        func one(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1)).locale(UIText.locale)) }
        let kb = max(bytesPerSecond, 0) / 1000
        if kb < 99.5 { return "\(Int(kb.rounded()))\u{2009}KB/s" }
        let mb = kb / 1000
        if mb < 9.95 { return one(mb) + "\u{2009}MB/s" }
        if mb < 99.5 { return "\(Int(mb.rounded()))\u{2009}MB/s" }
        return one(mb / 1000) + "\u{2009}GB/s"
    }
}

/// Images shipped next to the helper (scripts/build-dmg.sh copies
/// Resources/MenuBarMop*.png and MenuMopColor*.png into its bundle). Under
/// `swift run` / the debug hooks there is no bundle: fall back to the repo's
/// Resources folder when started from the repo root.
@MainActor
enum MenuAssets {
    /// Monochrome template mop (tinted by the menu bar), 18 pt tall.
    static let mop = image("MenuBarMop", template: true)
    /// Full-colour mop without the app icon's white plate, for the popup header.
    static let mopColor = image("MenuMopColor", template: false)

    private static func image(_ name: String, template: Bool) -> NSImage? {
        var image = Bundle.main.image(forResource: name)
        if image == nil {
            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
            if let base = NSImageRep(contentsOf: dir.appendingPathComponent("\(name).png")) {
                let multi = NSImage(size: base.size)
                multi.addRepresentation(base)
                for suffix in ["@2x", "@3x"] {
                    if let rep = NSImageRep(contentsOf: dir.appendingPathComponent("\(name)\(suffix).png")) {
                        rep.size = base.size
                        multi.addRepresentation(rep)
                    }
                }
                image = multi
            }
        }
        image?.isTemplate = template
        return image
    }
}
