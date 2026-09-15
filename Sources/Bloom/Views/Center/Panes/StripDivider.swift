import SwiftUI
import BloomCore

/// Which tab of the centre strip the pointer is over.
///
/// A box of its own rather than `@State` on `SessionTabsView`, for the reason `TabCarry` is: the
/// strip's body derives the whole tab list, and a hover crossing from one tab to the next would
/// rebuild it and every tab in it twice. Only the dividers read this, so a hover invalidates the
/// two or three rules beside the tab and nothing else.
@MainActor
@Observable
final class TabStripHover {
    private(set) var content: PaneContent?

    /// An exit only clears the tab it is about. Moving from one tab straight onto its neighbour
    /// can deliver the neighbour's enter before this tab's exit, and clearing unconditionally
    /// would leave the neighbour hovered with its rules drawn beside it.
    func set(_ content: PaneContent, isHovered: Bool) {
        if isHovered {
            if self.content != content { self.content = content }
        } else if self.content == content {
            self.content = nil
        }
    }
}

/// The rule in one gap of the centre strip, shown or not by `TabStripDividers`.
///
/// Placed in the row between two tabs in STORED order and never offset, so while a tab is carried
/// the rules stay where the slots are and the tabs slide past them. That is why the rule is asked
/// about the order the strip is drawing: the gap is a slot boundary, and the tabs either side of
/// it are whichever have slid there.
///
/// A view of its own so the pointer and the drag are read here rather than in the strip's body.
/// `carry.target` changes once per slot crossed and `hover.content` once per tab entered, and
/// either rebuilding the whole strip is the cost `TabCarry` was built to avoid.
struct StripDivider: View {
    /// The gap after this slot.
    var slot: Int
    var entries: [PaneContent]
    var selected: PaneContent?
    var carry: TabCarry
    var hover: TabStripHover
    /// Which tabs are busy. A busy tab wears a capsule of its own, so the rules against it go the
    /// way they do against the selected one. See `TabStripDividers`.
    var busy: BusySignalPlacement<PaneContent>

    var body: some View {
        TabStripSeparator(isHidden: !isShown)
    }

    private var isShown: Bool {
        let visible: [Bool]
        if let lift = carry.lift, lift.run == entries {
            // In the strip, the carried tab is drawn in its target slot and its neighbours have
            // made room. Out over the panes it is left faded in its own slot. Hover is ignored for
            // the whole drag: the tabs slide under a pointer that is holding one of them, and a
            // rule flickering off and on as each passes beneath it is noise.
            let drawn = carry.target.map { lift.geometry.order(lift.run, target: $0) } ?? lift.run
            visible = TabStripDividers.visible(
                in: drawn, selected: selected, hovered: nil, dragged: lift.content,
                busy: drawn.filter(busy.showsInTab)
            )
        } else {
            visible = TabStripDividers.visible(
                in: entries, selected: selected, hovered: hover.content, dragged: nil,
                busy: entries.filter(busy.showsInTab)
            )
        }
        return visible.indices.contains(slot) && visible[slot]
    }
}
