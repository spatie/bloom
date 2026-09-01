import SwiftUI

/// The card a transcript shows while the pointer rests on a file chip, or on a tool row whose one
/// line does not fit in it.
///
/// **AppKit places it, this file does not.** The card is a `popover`, so `NSPopover` owns the
/// anchoring to the chip, the flip above when there is no room below, the clamp inside the screen,
/// the arrow that says which chip the card belongs to, and the grow-out-of-the-anchor-with-a-fade
/// it arrives with. All of that used to be arithmetic here, and every line of it was a line that
/// could put the card in the wrong place. A popover is a window of its own as well, which is what
/// makes the card immune to the pane's edges: the chips live in rows inside a `LazyVStack` inside
/// a `ScrollView`, where anything drawn beside a chip is clipped in three directions out of four.
///
/// **Measured first, presented second, and that is the whole of the bug it was written for.**
/// `AttachmentPreview` shows a spinner until Quick Look answers, and a popover sizes itself to its
/// content, so presenting on the first frame opens a popover around the spinner and then resizes
/// and re-places it a few milliseconds later. Measured on this transcript: the card came out
/// 136x136 while loading and 536x362 once the thumbnail arrived, four milliseconds apart, and the
/// old hand-placed card was drawn at three different origins inside fifteen milliseconds. Those
/// frames ARE the "appears harshly, in the wrong place" this was reported for. So the card is
/// built once out of sight, its size is read, and only a size that has stopped changing is handed
/// to the popover as a fixed frame. The popover then opens once, at the size it will keep. Total
/// cost, measured: 83ms between the hover committing and the card being on screen.
///
/// It reads `host.request` and the enclosing list does not, which is what keeps a hover from
/// re-running a body that holds a `ForEach` over every row in the session. That matters more than
/// it used to: the list draws the tail of a long session on arrival and the history lands behind
/// it, and a hover that invalidated the list would be a hover that re-laid out four thousand rows.
struct TranscriptHoverOverlay: View {
    var host: TranscriptHoverHost

    /// How long the card's size has to stop changing before it is believed.
    ///
    /// Quick Look answers in four to fourteen milliseconds for these files, so this is a few
    /// frames rather than a wait. It is added to `AttachmentChip`'s own 350ms hover delay, and the
    /// card lands a little over four tenths of a second after the pointer settles, which still
    /// reads as resting on something rather than as lag.
    private static let settleDelay = Duration.milliseconds(40)

    /// The size the card came out at, and what it was measured FOR.
    ///
    /// Keyed rather than a bare `CGSize`, because a size left over from the last card is worse
    /// than no size at all: it is a plausible number, so nothing suppresses the card, and it puts
    /// it somewhere wrong. Keyed on the pane's width too, since that is what caps the card.
    private struct Measurement: Hashable {
        var identity: String
        var availableWidth: CGFloat
        var size: CGSize

        func fits(_ request: TranscriptHoverRequest, availableWidth: CGFloat) -> Bool {
            identity == request.card.identity && self.availableWidth == availableWidth
        }
    }

    @State private var measured: Measurement?
    @State private var settled: Measurement?

    var body: some View {
        GeometryReader { geometry in
            let pane = geometry.frame(in: .global)
            let request = host.request
            let size = settled.flatMap { measurement in
                request.flatMap {
                    measurement.fits($0, availableWidth: pane.width) ? measurement.size : nil
                }
            }

            ZStack(alignment: .topLeading) {
                // The ruler: the same card, built at zero opacity to be measured and nothing else,
                // and gone the moment the popover has a size to open at. A file card asks Quick
                // Look for the same thumbnail the presented card will ask for, so the second
                // request is a cache hit rather than a second render; a row card holds two strings
                // the row already had and costs one text layout.
                if let request, size == nil {
                    card(for: request, availableWidth: pane.width)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                            measured = Measurement(
                                identity: request.card.identity,
                                availableWidth: pane.width,
                                size: newSize
                            )
                        }
                        .opacity(0)
                }

                Color.clear
                    .popover(
                        isPresented: Binding(
                            get: { size != nil },
                            // The pointer leaving the chip is what closes this, and it closes it by
                            // clearing the request. Whatever else AppKit dismisses for has to clear
                            // it too, or the card would be gone while the request still said it was
                            // up and the same chip would never open it again.
                            set: { if !$0 { host.request = nil } }
                        ),
                        // In the pane's own coordinates, which is what this view fills. `.bottom`
                        // asks for the card below the anchor, the position that reads as belonging
                        // to it; AppKit flips it above when there is no room, which is what
                        // anything in the last turn of a transcript always needs.
                        attachmentAnchor: .rect(.rect(anchor(for: request, in: pane))),
                        arrowEdge: .bottom
                    ) {
                        if let request, let size {
                            card(for: request, availableWidth: pane.width)
                                // Fixed, so the spinner Quick Look shows for its first frame cannot
                                // resize the popover out from under itself.
                                .frame(width: size.width, height: size.height)
                        }
                    }
            }
            // Restarted by every size the ruler reports, so what survives is the size that came
            // last and then stayed. `.task(id:)` cancels the previous wait for free.
            .task(id: measured) {
                guard let measured else {
                    settled = nil
                    return
                }
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled else { return }
                settled = measured
            }
        }
        // Neither the card nor the invisible sheet the popover is anchored to takes the pointer.
        // The sheet covers the whole transcript, and a transparent view that answered to clicks
        // would make every row underneath it unclickable.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func card(for request: TranscriptHoverRequest, availableWidth: CGFloat) -> some View {
        switch request.card {
        case .file(let attachment, let worktree):
            AttachmentCard(
                attachment: attachment, worktree: worktree, availableWidth: availableWidth
            )
        case .instructions(_, let body):
            // The title is the chip's, and the chip is what the pointer is on: repeating it as a
            // heading inside the card would say it twice, where the file card beside this one says
            // it none. It is in the identity above so two blocks cannot share a measurement.
            InstructionsCard(text: body, availableWidth: availableWidth)
        case .row(let title, let detail, let isCode):
            ToolRowCard(
                title: title, detail: detail, isCode: isCode, availableWidth: availableWidth
            )
        }
    }

    /// What the card is anchored to, in the pane's own coordinates: a chip, or a whole tool row.
    ///
    /// The hovered view reports it in window coordinates, which is the one space a row twelve
    /// levels deep and this view can both name, so the pane's own origin comes off it here.
    /// A zero-sized rect in the middle when there is no request: an anchor is still asked for while
    /// the popover is closing, and the middle is the one place that cannot make it fly off an edge.
    private func anchor(for request: TranscriptHoverRequest?, in pane: CGRect) -> CGRect {
        guard let request else {
            return CGRect(x: pane.width / 2, y: pane.height / 2, width: 0, height: 0)
        }
        return request.frame.offsetBy(dx: -pane.minX, dy: -pane.minY)
    }
}
