import SwiftUI
import BloomCore

/// Every row of a session, and the rules for where the view sits among them.
///
/// It is a `ScrollView` over a `LazyVStack` rather than a `List` for one reason, which is that a
/// session can hold tens of thousands of rows and a `List` insists on knowing about all of them.
/// Here nothing is decoded, measured or styled until it is about to be on screen.
struct TranscriptListView: View {
    let transcript: TranscriptModel
    /// Only to explain an empty transcript: a workspace whose setup script is still running has a
    /// session but cannot have said anything yet.
    var isRunningSetup: Bool = false
    let onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Expansion is a property of this view, not of the session. Reopening a workspace should not
    /// restore forty open tool results, and the model has no business knowing what is unfolded.
    @State private var expanded: Set<Int> = []
    @State private var geometry = TranscriptGeometry()
    @State private var didPosition = false

    /// Only used to open a session on its end. An edge needs no identity, so this does not need
    /// the sentinel row the `ScrollViewReader` used to be pointed at.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// Sentinel id, negative so it can never collide with a row sequence number.
    private static let streamingID = -2
    /// How far off the bottom the user may be and still be considered to be following along.
    private static let stickyThreshold: CGFloat = 96
    /// A user bubble takes this share of the pane, and never gets narrower than the floor, so a
    /// long prompt wraps sensibly and a short one still reads as one side of a conversation.
    private static let bubbleShare: CGFloat = 0.7
    private static let bubbleFloor: CGFloat = 240

    /// Only once the rows are known to be absent, so a session that is still loading does not flash
    /// an empty state on its way in.
    private var showsPlaceholder: Bool {
        transcript.isLoaded
            && transcript.rows.isEmpty
            && !transcript.isRunning
            && !transcript.isStreaming
    }

    /// Already rounded, by `TranscriptGeometry.cap`, and rounded before it reaches this view's
    /// state rather than after. A cap that changed on every pixel of a drag failed the row
    /// equality check on every realised row, once a frame.
    private var maxBubbleWidth: CGFloat { geometry.bubbleCap }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.rows) { row in
                        if TranscriptNoise.isHidden(row) {
                            EmptyView()
                        } else if row.kind == .result {
                            // No top padding: the rule inside the footer carries its own air, and
                            // a couple of points added out here only ever made the gap above the
                            // rule differ from the gap below it.
                            TurnFooterView(rows: transcript.rows, row: row)
                                .padding(.horizontal, TranscriptLayout.inset)
                                .padding(.bottom, TranscriptLayout.block + TranscriptLayout.tight)
                                .id(row.seq)
                        } else {
                            TranscriptRowView(
                                row: row,
                                workspace: transcript.workspace,
                                isExpanded: expanded.contains(row.seq),
                                isNested: row.parentToolUseID != nil,
                                maxBubbleWidth: maxBubbleWidth,
                                onToggle: { toggle(row.seq) }
                            )
                            // Every pass over this list rebuilds every row the stack has already
                            // realised, and opening a long session realises all of them. Comparing
                            // the row's own values first is what keeps a second pass free.
                            .equatable()
                            .padding(.horizontal, TranscriptLayout.inset)
                            .id(row.seq)
                        }
                    }

                    StreamingTailView(transcript: transcript)
                        .padding(.horizontal, TranscriptLayout.inset)
                        .id(Self.streamingID)
                }
                .padding(.vertical, TranscriptLayout.block)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A conversation shorter than the pane hangs from the bottom, just above the composer,
            // rather than floating at the top with a field of white under it.
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollPosition($scrollPosition)
            // What keeps the view at the live end while a turn runs, and it replaces a `scrollTo`
            // that used to be issued on every row that arrived. Any scroll that names a position
            // inside a `LazyVStack` has to build and measure every row between the viewport and
            // that position, so following a turn re-rendered the entire transcript per row. An
            // anchor asks for none of that.
            //
            // Nil while the user has scrolled away, which is the whole of the rule that scroll
            // used to enforce by hand. Yanking someone back down as they read something further up
            // is the single most irritating thing a live log can do, and an absent anchor leaves
            // them exactly where they are.
            .defaultScrollAnchor(geometry.isNearBottom ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: TranscriptGeometry.self, of: Self.measure) { old, new in
                geometry = new
                if old.isNearBottom != new.isNearBottom {
                    onScrolledUpChange?(!new.isNearBottom)
                }
            }
            .onChange(of: transcript.rows.count, initial: true) { _, _ in
                position(proxy)
            }
            .onChange(of: transcript.scrollTargetSeq) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
                transcript.scrollTargetSeq = nil
            }
            .onChange(of: transcript.session.id) { _, _ in
                didPosition = false
                expanded.removeAll()
                // A session opens at its live end whatever the one being left was scrolled to,
                // and the anchor is read before the new rows arrive.
                geometry.isNearBottom = true
            }
            .task(id: transcript.session.id) {
                await transcript.load()
            }
            .overlay {
                if showsPlaceholder {
                    TranscriptPlaceholderView(isRunningSetup: isRunningSetup)
                }
            }
        }
    }

    /// How far the end of the content is below the bottom edge of the viewport. Negative when the
    /// content is shorter than the pane, which counts as being at the bottom.
    ///
    /// The bubble cap is worked out here, inside the projection, rather than in the body from a
    /// stored width. `onScrollGeometryChange` only calls its handler when the projected value
    /// changes, so rounding on this side of the line means a drag stops writing state, and stops
    /// re-running the list body, for the eleven points of travel between one cap and the next.
    private static func measure(_ scroll: ScrollGeometry) -> TranscriptGeometry {
        let distanceFromEnd = scroll.contentSize.height
            - scroll.contentOffset.y
            - scroll.containerSize.height
        return TranscriptGeometry(
            bubbleCap: TranscriptGeometry.cap(
                width: scroll.containerSize.width,
                share: bubbleShare,
                gutter: Metrics.gutter,
                floor: bubbleFloor
            ),
            isNearBottom: distanceFromEnd < stickyThreshold
        )
    }

    // MARK: Scrolling

    /// Where a session opens: on the first thing the user has not read, which is the whole point
    /// of leaving a session and coming back to it, and otherwise on its live end.
    ///
    /// Both of these resolve a position inside a `LazyVStack`, which is the expensive kind of
    /// scroll: it realises every row it passes. So it happens once per session rather than once
    /// per row that arrives, and keeping up with a running turn is the size-change anchor's job.
    private func position(_ proxy: ScrollViewProxy) {
        guard !transcript.rows.isEmpty, !didPosition else { return }
        didPosition = true

        if let unread = transcript.firstUnreadSeq, unread != transcript.rows.first?.seq {
            proxy.scrollTo(unread, anchor: .top)
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
        Task { await transcript.markAllRead() }
    }

    private func toggle(_ seq: Int) {
        if expanded.contains(seq) {
            expanded.remove(seq)
        } else {
            expanded.insert(seq)
        }
    }
}
