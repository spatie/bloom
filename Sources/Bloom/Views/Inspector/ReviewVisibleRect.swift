import SwiftUI
import BloomCore

/// The coordinate space an all-files review's stack is named, so a frame read inside it is a
/// position in the document rather than relative to the scroll view. Layout keeps a document
/// frame current; a programmatic scroll does not keep a scroll-relative one current, which is
/// what `ReviewViewport` explains.
enum ReviewDocument {
    /// Read from geometry transforms, which are Sendable closures, so it cannot be actor isolated.
    nonisolated static let space = "review-document"
}

extension EnvironmentValues {
    /// Where the reader of the all-files review is looking, in `ReviewDocument.space`, at the
    /// quarter viewport steps `ReviewViewport.publishedTop` rounds to. Nil outside a review.
    @Entry var reviewVisibleRect: CGRect?
}

extension View {
    /// Publishes a scroll view's visible rect to the diff blocks inside it. The stack inside must
    /// be named `ReviewDocument.space` for the blocks' frames to be in the same coordinates.
    func publishesReviewVisibleRect() -> some View {
        modifier(ReviewVisibleRectPublisher())
    }
}

private struct ReviewVisibleRectPublisher: ViewModifier {
    @State private var published: CGRect?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGRect.self) { geometry in
                let visible = geometry.visibleRect
                let top = ReviewViewport.publishedTop(visibleTop: visible.minY, visibleHeight: visible.height)
                return CGRect(x: 0, y: top, width: 0, height: visible.height)
            } action: { _, rect in
                published = rect
            }
            .environment(\.reviewVisibleRect, published)
    }
}
