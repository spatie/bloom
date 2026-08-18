import SwiftUI
import BatonCore

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

    /// Sentinel ids, negative so they can never collide with a row sequence number.
    private static let bottomID = -1
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

    private var maxBubbleWidth: CGFloat {
        max(Self.bubbleFloor, (geometry.width - Metrics.gutter * 2) * Self.bubbleShare)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.rows) { row in
                        if TranscriptNoise.isHidden(row) {
                            EmptyView()
                        } else if row.kind == .result {
                            TurnFooterView(rows: transcript.rows, row: row)
                                .padding(.horizontal, TranscriptLayout.inset)
                                .padding(.top, TranscriptLayout.tight)
                                .padding(.bottom, TranscriptLayout.block + TranscriptLayout.tight)
                                .id(row.seq)
                        } else {
                            TranscriptRowView(
                                row: row,
                                isExpanded: expanded.contains(row.seq),
                                isNested: row.parentToolUseID != nil,
                                maxBubbleWidth: maxBubbleWidth,
                                onToggle: { toggle(row.seq) }
                            )
                            .padding(.horizontal, TranscriptLayout.inset)
                            .id(row.seq)
                        }
                    }

                    StreamingTailView(transcript: transcript) {
                        follow(proxy, animated: false)
                    }
                    .padding(.horizontal, TranscriptLayout.inset)
                    .id(Self.streamingID)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.vertical, TranscriptLayout.block)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A conversation shorter than the pane hangs from the bottom, just above the composer,
            // rather than floating at the top with a field of white under it. Only the alignment
            // role: following new rows stays this view's own decision, made in `follow`.
            .defaultScrollAnchor(.bottom, for: .alignment)
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
    private static func measure(_ scroll: ScrollGeometry) -> TranscriptGeometry {
        let distanceFromEnd = scroll.contentSize.height
            - scroll.contentOffset.y
            - scroll.containerSize.height
        return TranscriptGeometry(
            width: scroll.containerSize.width,
            isNearBottom: distanceFromEnd < stickyThreshold
        )
    }

    // MARK: Scrolling

    /// First paint lands on the first thing the user has not read, which is the whole point of
    /// leaving a session and coming back to it. After that the same handler just keeps the view
    /// pinned to the bottom while rows arrive.
    private func position(_ proxy: ScrollViewProxy) {
        guard !transcript.rows.isEmpty else { return }

        guard didPosition else {
            didPosition = true
            if let unread = transcript.firstUnreadSeq, unread != transcript.rows.first?.seq {
                proxy.scrollTo(unread, anchor: .top)
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            Task { await transcript.markAllRead() }
            return
        }

        follow(proxy, animated: true)
    }

    /// Stick to the bottom, but only for someone who was already there. Yanking a user back down
    /// while they are reading something further up is the single most irritating thing a live log
    /// can do.
    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard geometry.isNearBottom else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func toggle(_ seq: Int) {
        if expanded.contains(seq) {
            expanded.remove(seq)
        } else {
            expanded.insert(seq)
        }
    }
}
