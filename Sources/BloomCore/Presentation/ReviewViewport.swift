import Foundation

/// Which diff blocks in the all-files review are close enough to the reader to draw.
///
/// **A block used to decide this from its own frame relative to the scroll view, and after a
/// programmatic jump that frame was never recomputed.** Scrolling moves the clip view without a
/// layout pass through the section content, so a block realised by the jump kept the frame it
/// had last reported. The review probe measured one spanning the whole visible rect (visible
/// 13183..13783, block 11352..16092) whose last scroll-relative frame was 4679..9419, which is
/// far below the viewport, so it drew nothing and the reader saw a blank diff. Pinned headers did
/// update; ordinary section content did not.
///
/// So the block now only tracks its frame in the review's document, which layout does keep
/// current, and the review publishes where the reader is looking. The two meet here.
///
/// `Double` rather than `CGFloat`, for the reason `ScrollEnd` gives.
public enum ReviewViewport {
    /// A block starts drawing half a viewport before it scrolls in from the top, and a viewport and
    /// a half below the top edge, so the reader scrolling down meets code that is already there.
    public static func isNear(top: Double, bottom: Double, visibleTop: Double, visibleHeight: Double) -> Bool {
        bottom > visibleTop - visibleHeight / 2 && top < visibleTop + visibleHeight * 1.5
    }

    /// The visible top the review publishes to its blocks, rounded to a quarter of the viewport.
    ///
    /// Publishing every offset would redraw every realised block's body on every pixel of a
    /// scroll. A quarter step moves the published top at most an eighth of a viewport from the
    /// real one, which the half viewport of lead in `isNear` absorbs, so nothing the reader can see
    /// is ever judged too far away to draw.
    public static func publishedTop(visibleTop: Double, visibleHeight: Double) -> Double {
        guard visibleHeight > 0 else { return visibleTop }
        let step = visibleHeight / 4
        return (visibleTop / step).rounded() * step
    }
}
