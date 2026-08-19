import AppKit
import BloomCore

/// One project's artwork, ready to draw.
struct RepoArtwork {
    var image: NSImage

    /// Whether the picture reaches the edges of the tile it is drawn in.
    ///
    /// An app icon and a favicon with its own ground are opaque rectangles, and a rectangle on the
    /// sidebar wants the same rounded corner and the same hairline every other tile in macOS has.
    /// A logo on transparency is a shape floating in the row, and a box drawn around it would be a
    /// box drawn around nothing. The two cases are told apart by looking rather than by guessing
    /// from the format, because both arrive as PNGs and SVGs in equal measure.
    var isFullBleed: Bool
}

/// The artwork behind a project's badge, read from the file `RepoIconDetector` picked.
///
/// Cached by path and read at most once per launch, because `RepoIcon` is drawn in the sidebar
/// section header, on every Home row, in every search hit and in the window title, and a badge
/// that touched the disk to draw itself would be doing it dozens of times a second. Detection has
/// already decided which file this is; all that is left is to open it.
///
/// A file that has gone, or that has stopped being an image since it was found, is answered with
/// nil, and nil is what makes `RepoIcon` draw the monogram. Nothing is unset in the database when
/// that happens: a project on an unmounted volume is not the user changing their mind, and the
/// badge is back the moment the volume is.
@MainActor
enum RepoIconArt {
    /// Keyed by path rather than by project, so two projects pointed at one file read it once, and
    /// so a project whose icon has been changed gets a new entry rather than a stale one.
    ///
    /// The value is a double optional on purpose: a stored nil is "this was tried and there is
    /// nothing there", which is the answer that must not be retried on every frame.
    private static var cache: [String: RepoArtwork?] = [:]

    static func artwork(for repo: Repo) -> RepoArtwork? {
        guard repo.hasIcon, let path = repo.iconPath else { return nil }
        if let cached = cache[path] { return cached }
        let artwork = load(path)
        cache[path] = artwork
        return artwork
    }

    /// Drops what was read for a path, so the next draw reads the file again.
    ///
    /// Called when the settings window changes a project's icon, which is the one moment a file at
    /// a path Bloom is already showing can become a different picture. A file edited on disk
    /// outside Bloom is picked up at the next launch: watching every project's icon for changes
    /// would cost more than it is worth to catch an edit almost nobody makes.
    static func forget(_ path: String?) {
        guard let path else { return }
        cache.removeValue(forKey: path)
        // The menu draws its marks from bitmaps of `RepoIcon` rather than from the view, so its
        // cache holds a copy of whatever this one used to answer.
        RepoIconImage.forgetAll()
    }

    private static func load(_ path: String) -> RepoArtwork? {
        let image: NSImage?
        if path.lowercased().hasSuffix(".icon") {
            image = composite(iconBundle: path)
        } else {
            // AppKit reads every format the detector accepts, and reads them better than a hand
            // rolled decoder would: an `.icns` or an `.ico` keeps all of its representations, so
            // drawing the badge at 16 points uses the artwork that was drawn for 16 points rather
            // than a downscale of the 1024 pixel one, and an SVG stays vector all the way down.
            image = NSImage(contentsOfFile: path)
        }
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        return RepoArtwork(image: image, isFullBleed: fillsItsTile(image))
    }

    // MARK: - Layered documents

    /// How large a layered document is flattened to. Comfortably above the largest badge, which is
    /// 28 points in the settings window, and small enough that a project costs one bitmap.
    private static let compositeSide: CGFloat = 256

    /// A macOS 26 Icon Composer document, drawn back to front into one image.
    ///
    /// An approximation, and knowingly so: the glass, the shadow and the specular pass that make
    /// the finished system icon belong to the compositor, and none of them can be reproduced here.
    /// What is left is the artwork itself, which at 16 points is all that survives anyway. It is
    /// also why `RepoIconFormat` ranks a flattened `.icns` above the document beside it.
    private static func composite(iconBundle path: String) -> NSImage? {
        let layers = RepoIconDetector.layers(ofIconBundle: path).compactMap(NSImage.init(contentsOfFile:))
        guard !layers.isEmpty else { return nil }

        let side = compositeSide
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        for layer in layers {
            layer.draw(
                in: NSRect(x: 0, y: 0, width: side, height: side),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        canvas.unlockFocus()
        return canvas
    }

    // MARK: - Shape

    /// Draws the picture the way the badge will and asks whether it covers the four edges.
    ///
    /// The midpoints of the edges rather than the corners, because an app icon's corners are
    /// deliberately transparent: it is already a rounded rectangle, and sampling those would report
    /// every Mac icon ever made as a floating shape. Sixteen pixels is plenty to answer a question
    /// about four of them.
    private static func fillsItsTile(_ image: NSImage) -> Bool {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // Fitted, not stretched, because that is what the badge does: a wide wordmark is
        // letterboxed there and so must be judged letterboxed here.
        image.draw(in: fitted(image.size, into: CGFloat(side)), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let middle = side / 2
        let edges = [(middle, 0), (middle, side - 1), (0, middle), (side - 1, middle)]
        return edges.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.9 }
    }

    private static func fitted(_ size: NSSize, into side: CGFloat) -> NSRect {
        let scale = min(side / size.width, side / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
    }
}
