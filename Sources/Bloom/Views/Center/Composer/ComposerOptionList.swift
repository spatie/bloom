import SwiftUI
import BloomCore

/// The rows of a footer picker that has something to say about each of them, as a panel rather
/// than as an `NSMenu`.
///
/// **Why this is not a menu.** `ComposerOptionMenu` is still a menu and still right for the model
/// and the effort, whose rows are names and adjectives that describe themselves. The permission
/// mode and the output style are different: each row has a sentence, the vendor wrote it, and an
/// `NSMenu` row is one line with nowhere to put it. Both pickers worked around that the same way,
/// with a greyed footnote under the whole menu describing the row already chosen, and the owner
/// read the permission one and said "I cannot see what the option does before picking it". The
/// footnote was the workaround; the one line row was the limitation; the limitation is what went.
///
/// The panel is separate from `ComposerOptionPicker`, which is the chip and the popover it hangs
/// off, so that it can be drawn where no popover can be: `ComposerPickerGallery` photographs
/// exactly this view, in both appearances, rather than a second copy of it that could drift.
///
/// Keyboard: the arrows walk the rows and wrap the way a menu does, Return takes the highlighted
/// one, Escape closes. It has no field to type into, so `MenuKeyHost` is what takes the keys; see
/// its head for why that is an `NSView`.
struct ComposerOptionList: View {
    var options: [ComposerOption]
    /// A disabled line at the foot, for the one thing the picker has to say that no row of it can
    /// say. Today that is `ComposerControls.permissionModeNote`, which is about the conversation
    /// rather than about any mode in it.
    var footnote: String?
    var selection: String
    /// What the list is a list of, over the rows. Kept from the menu this replaced, where it was
    /// the picker's own name for anyone reading a bare column of adjectives.
    var heading: String
    var onSelect: @MainActor (String) -> Void
    var onClose: @MainActor () -> Void

    /// Which row Return would take. Not the same as `selection`, which is the setting in force and
    /// keeps its tick wherever the highlight goes.
    ///
    /// Held as the id rather than as an index, for the reason `QuickPromptMenu` writes down: a
    /// list can change under the panel (the output styles land from a disk walk while it is open)
    /// and an index then points at whatever has moved into that slot.
    @State private var highlighted: String?
    /// How tall the rows actually are, so the scroll view can be told a height rather than left to
    /// take whatever it is offered. See `height(for:)`.
    @State private var contentHeight: CGFloat = 0

    /// The same width the quick prompt panel opens at, and it is the same decision: the two hang
    /// off buttons two inches apart in the same footer, and one of them being narrower would read
    /// as two panels rather than as one window's idea of a panel. The rows here carry a vendor's
    /// sentence, which at 320 wrapped to four lines and made a four row picker as tall as the
    /// composer it opened over.
    static let width: CGFloat = 380

    /// How far the rows are held off the panel's edge. A highlight drawn flush to the edge runs
    /// its rounded corners into the panel's own rounding and reads as a band painted across the
    /// popover. `QuickPromptMenu` measured the same number.
    private static let listInset: CGFloat = Metrics.spacingWide
    /// Enough for the built-in output styles without scrolling. A repository can still carry
    /// more custom styles than fit comfortably, so genuinely long lists remain scrollable.
    private static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headingRow
            Hairline()
            rows

            if let footnote, !footnote.isEmpty {
                Hairline()
                Text(footnote)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.listInset + Metrics.spacing)
                    .padding(.vertical, Metrics.spacingWide)
            }
        }
        .frame(width: Self.width)
        // The panel's own keyboard, behind the rows so every click still reaches one.
        .background(MenuKeyHost(onKey: handle(key:)))
        .onAppear {
            // Opening on the setting in force, so the first Down is one step from where the
            // reader is rather than one step from the top of the list.
            highlighted = selection
        }
    }

    private var headingRow: some View {
        // Uppercased here rather than through `textCase`, which is what the two other uppercased
        // micro labels in this window do, and set with the tracking the scale carries for exactly
        // this: capitals at ten points set nearly solid.
        Text(heading.uppercased())
            .font(Typo.micro)
            .tracking(Typo.microTracking)
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.listInset + Metrics.spacing)
            .padding(.vertical, Metrics.spacingWide)
    }

    /// The list, given an explicit height rather than a maximum one.
    ///
    /// **A `ScrollView` takes the height it is offered, not the height of what is in it**, which
    /// inside a popover means two different wrong answers on the same panel. The failure and the
    /// fix are both `QuickPromptMenu.rows(_:)`, whose note is worth reading before changing this:
    /// the rows are measured, the scroll view is told what to be, and the number is clamped so a
    /// long list scrolls instead of growing past the window.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options) { option in
                        ComposerOptionRow(
                            option: option,
                            isSelected: option.id == selection,
                            isHighlighted: option.id == highlighted,
                            onPick: { pick(option.id) },
                            onHover: { highlighted = option.id }
                        )
                        .id(option.id)
                    }
                }
                .padding(.horizontal, Self.listInset)
                .padding(.vertical, Metrics.spacingSmall)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: height(for: options.count))
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    /// What the scroll view is told to be. The measurement wins once there is one, and until then
    /// a guess from the row count stands in, because `onGeometryChange` cannot report a height
    /// before a layout has happened and the panel visibly grew on opening without it.
    private func height(for count: Int) -> CGFloat {
        let measured = contentHeight > 0 ? contentHeight : Self.estimatedHeight(rows: count)
        return min(max(measured, Metrics.rowHeight), Self.maxListHeight)
    }

    /// A name, a sentence on one line under it, and the row's own padding. Only close enough that
    /// nobody sees the correction on the next pass.
    private static func estimatedHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * (Metrics.rowHeight + Metrics.gutter) + Metrics.spacingWide
    }

    private func pick(_ id: String) {
        // Closed first, so the keyboard goes back to the composer rather than to a panel that is
        // about to be taken away.
        onClose()
        onSelect(id)
    }

    /// The panel's whole keyboard. Where the highlight lands is `MenuRows`, in the core, because a
    /// decision taken in a view is a decision nothing can test.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .up, .down:
            let ids = options.map(\.id)
            highlighted = MenuRows.stepped(from: highlighted, by: key == .up ? -1 : 1, in: ids)
            return true
        case .returnKey, .commandReturn:
            guard let highlighted else { return false }
            pick(highlighted)
            return true
        case .escape:
            onClose()
            return true
        case .tab:
            return false
        }
    }
}
