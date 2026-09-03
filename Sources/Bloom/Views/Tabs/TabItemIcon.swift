import AppKit
import SwiftUI
import BloomCore

/// What a tab wears in front of its title.
///
/// Two cases, because a web page is the only tab whose mark is not Bloom's to choose. A
/// conversation, a shell, a review and a note are named by `PaneGlyph`; a page brings its own, the
/// way it does in every browser, and it is a picture from the network rather than a system glyph.
///
/// **The distinction is in the type because it is in the layout.** A page's icon arrives a second
/// or so after the tab does, and a slot that is a symbol's intrinsic width one moment and a
/// picture's the next is a tab whose title moves as the page loads. So `page` gets a fixed square
/// whether it holds the icon or the globe standing in for it, and `symbol` is left exactly as it
/// was, which is what keeps a chat tab measuring what it has always measured.
enum TabItemIcon: Equatable {
    /// A name from `PaneGlyph`.
    case symbol(String)
    /// A web page: its own icon once there is one, and the globe until then, or for ever.
    case page(NSImage?)
}

/// The icon slot itself.
///
/// A favicon is content from the page drawn inside Bloom's own chrome, so it is given a box and
/// clipped to it rather than allowed to say how big it is. `BrowserFaviconStore` has already
/// refused anything decoding larger than the square the page was asked for, and has already said
/// it is not a template image, which is the difference between a picture in a tab and a mark
/// wearing the tab's own ink.
struct TabItemIconView: View {
    var icon: TabItemIcon
    var ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The square a page's mark is drawn in, and the square the globe is centred in. A point over
    /// `Metrics.glyph`: an icon with a ground of its own needs slightly more room than a stroked
    /// glyph before the two read as the same size.
    static let pageSize: CGFloat = 14

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .imageScale(.small)
                .foregroundStyle(ink)
        case .page(let image):
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: PaneGlyph.browser)
                        .imageScale(.small)
                        .foregroundStyle(ink)
                }
            }
            .frame(width: Self.pageSize, height: Self.pageSize)
            .clipped()
            // One crossfade in a box that does not move, rather than a tab that relays out around
            // the icon landing. Dropped rather than slowed for Reduce Motion, which is what the
            // rest of the window does with it: the icon still arrives, on the frame it decoded.
            .animation(reduceMotion ? nil : Motion.hover, value: image != nil)
        }
    }
}
