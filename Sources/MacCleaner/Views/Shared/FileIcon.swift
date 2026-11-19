import SwiftUI
import AppKit

/// Finder icon of a file, folder or app, rasterised off the main thread.
///
/// `NSWorkspace.icon(forFile:)` returns an image that IconServices renders the
/// first time it is drawn: about 5 ms per icon on the main thread. A list of a
/// few hundred rows (System Data "Show more", review cards) beachballed for
/// seconds. Here each icon is drawn once, at row size, on a background thread,
/// and cached; rows show an empty square for the few milliseconds it takes.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 18

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = IconThumbnails.cached(path, size: size) ?? image {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: path) { image = await IconThumbnails.load(path, size: size) }
    }
}

@MainActor
enum IconThumbnails {
    private static var cache: [String: NSImage] = [:]

    private static func key(_ path: String, _ size: CGFloat) -> String { "\(Int(size))|\(path)" }

    static func cached(_ path: String, size: CGFloat) -> NSImage? { cache[key(path, size)] }

    static func load(_ path: String, size: CGFloat) async -> NSImage? {
        let k = key(path, size)
        if let hit = cache[k] { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let rendered = await Task.detached(priority: .userInitiated) { Rendered(path: path, points: size, scale: scale) }.value
        guard let cg = rendered.image else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        if cache.count > 4000 { cache.removeAll() }
        cache[k] = image
        return image
    }

    /// CGImage is immutable once created; the box only carries it back to the main actor.
    private struct Rendered: @unchecked Sendable {
        let image: CGImage?

        init(path: String, points: CGFloat, scale: CGFloat) {
            let px = max(1, Int((points * scale).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { image = nil; return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            image = ctx.makeImage()
        }
    }
}
