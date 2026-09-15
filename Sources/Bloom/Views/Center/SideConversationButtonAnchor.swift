import SwiftUI

/// Where the side conversation button is, handed up from the composer footer to the chat pane so
/// the card can hang off it.
///
/// A preference rather than a measured frame in `@State`, because the button is three views down
/// inside a `ViewThatFits` in an overlay, and the pane that draws the card is the only thing that
/// needs to know. The first non-nil value wins: a pane has one footer showing the button, and the
/// side conversation's own composer never shows it.
struct SideConversationButtonAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
