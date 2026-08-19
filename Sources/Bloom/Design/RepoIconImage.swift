import SwiftUI
import AppKit
import BloomCore

/// A project's mark, baked into an `NSImage`, for the one place a SwiftUI view cannot go.
///
/// A menu item on this platform has three slots: a title, an image, and the state column the tick
/// is drawn in. They coexist, so a project menu can show which project you are in and what each
/// project looks like at the same time. What the image slot will not take is an arbitrary SwiftUI
/// view: handed one as a `Label`'s icon it does not merely fail to draw it, it takes the item's
/// title down with it and the menu comes up as a column of blank rows with a tick floating in it.
/// An `Image` is carried through intact. All of that is measured rather than assumed.
///
/// So the mark is rendered from `RepoIcon`, the same view the composer's chip and the sidebar rows
/// draw, which is what stops a project's colour, its initials or its artwork from differing
/// between the places it appears. Nothing here knows what a project mark looks like.
@MainActor
enum RepoIconImage {
    /// What the mark is drawn from, rather than which project it belongs to, so renaming a
    /// project or recolouring it produces a new tile instead of the old one coming back out.
    ///
    /// Nothing about a project's own artwork is in here, because `RepoIcon` resolves that at most
    /// once per launch: within one run of the app the mark is a function of the name and the
    /// accent alone. Anything that makes artwork reloadable has to invalidate this alongside the
    /// cache it reloads.
    private struct Key: Hashable {
        var name: String
        var accent: String?
        var size: CGFloat
        var scale: CGFloat
    }

    /// Rendering is not free and a menu's content closure runs on every redraw of the view that
    /// owns it, so each mark is drawn once per appearance it can have.
    private static var cache: [Key: NSImage] = [:]

    static func of(_ repo: Repo, size: CGFloat = Metrics.repoIcon) -> NSImage? {
        // The screen's own scale. This is the one place in the app a mark is drawn from pixels
        // rather than from vectors, and at 1x on a Retina display it is a soft square.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = Key(name: repo.name, accent: repo.accent, size: size, scale: scale)
        if let cached = cache[key] { return cached }

        let renderer = ImageRenderer(content: RepoIcon(repo: repo, size: size))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        cache[key] = image
        return image
    }
}
