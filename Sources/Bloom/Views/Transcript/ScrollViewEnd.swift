import AppKit
import BloomCore

/// Where the end of a scroll view is, in one spelling.
///
/// There were five of them and they were the same number: `TranscriptTable` asked
/// `TranscriptAnchor.end`, the glide and the follower subtracted two heights each, and the two
/// probes subtracted a `frame` height from a `bounds` height. They all move the same clip view,
/// and five copies of a number that has to agree with itself is how a jump lands short of where
/// the follower thinks the end is.
///
/// **`frame` for the document and `bounds` for the clip, which is not a formatting choice.** The
/// offset all of this is compared against is `contentView.bounds.origin.y`, which is in the clip
/// view's coordinate space, and the document's `frame` is expressed in that space while its
/// `bounds` is expressed in its own. AppKit clamps a scroll against the document's frame
/// (`NSClipView.constrainBoundsRect`), so the frame is the one that cannot disagree with where
/// the view is allowed to go. The two are equal for a document with no magnification and no
/// transform, which is every scroll view here today, so nothing changes for the five callers.
extension NSScrollView {
    /// The furthest down this view can be scrolled. Never negative: content that fits in the
    /// viewport has no end below the reader to go to.
    var endOffset: CGFloat {
        CGFloat(TranscriptAnchor.end(
            contentHeight: Double(documentView?.frame.height ?? 0),
            viewportHeight: Double(contentView.bounds.height)
        ))
    }

    /// How far the viewport is from that end, in points.
    var distanceFromEnd: CGFloat {
        max(0, endOffset - contentView.bounds.origin.y)
    }

    /// Whether a viewport put at the end is still exactly there.
    ///
    /// `TranscriptAnchor.isAtEnd`'s question, "did the instruction survive", and not
    /// `ScrollEnd.isAtEnd`'s "is the reader still following along". Ninety points short passes the
    /// second and fails this one, and ninety points short is the newest row half off the window.
    var isAtEnd: Bool {
        TranscriptAnchor.isAtEnd(
            offset: Double(contentView.bounds.origin.y),
            contentHeight: Double(documentView?.frame.height ?? 0),
            viewportHeight: Double(contentView.bounds.height)
        )
    }
}
