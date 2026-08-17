import SwiftUI
import BatonCore

/// The transcript: the surface where a user watches an agent work.
///
/// It is a `ScrollView` over a `LazyVStack` rather than a `List` for one reason, which is that a
/// session can hold tens of thousands of rows and a `List` insists on knowing about all of them.
/// Here nothing is decoded, measured or styled until it is about to be on screen.
struct TranscriptView: View {
    private let transcript: TranscriptModel?

    /// Expansion is a property of this view, not of the session. Reopening a workspace should not
    /// restore forty open tool results, and the model has no business knowing what is unfolded.
    @State private var expanded: Set<Int> = []
    @State private var isNearBottom = true
    @State private var didPosition = false

    private static let coordinateSpace = "baton.transcript"
    /// Sentinel ids, negative so they can never collide with a row sequence number.
    private static let bottomID = -1
    private static let streamingID = -2
    /// How far off the bottom the user may be and still be considered to be following along.
    private static let stickyThreshold: CGFloat = 96

    /// Told whenever the user leaves, or returns to, the live end of the transcript. The composer
    /// uses it to decide whether a "jump to newest" pill is worth offering.
    private let onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)?

    init(
        transcript: TranscriptModel,
        onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.onScrolledUpChange = onScrolledUpChange
    }

    /// The call site holds an optional and should not have to unwrap it just to show an empty
    /// pane, so the optional case is an overload rather than the caller's problem.
    init(
        transcript: TranscriptModel?,
        onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.onScrolledUpChange = onScrolledUpChange
    }

    var body: some View {
        Group {
            if let transcript {
                list(transcript)
            } else {
                EmptyTranscriptView()
            }
        }
        .background(Palette.surface)
    }

    private func list(_ transcript: TranscriptModel) -> some View {
        GeometryReader { outer in
            let width = outer.size.width
            let viewport = outer.size.height

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(transcript.rows) { row in
                            rowView(row, transcript: transcript, width: width)
                                .id(row.seq)
                        }

                        if transcript.isRunning || transcript.isStreaming {
                            StreamingRowView(transcript: transcript)
                                .padding(.horizontal, 6)
                                .id(Self.streamingID)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .background(bottomProbe)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.coordinateSpace)
                .onPreferenceChange(BottomOffsetKey.self) { minY in
                    // The sentinel sits at the very end of the content, so its distance past the
                    // bottom edge of the viewport is exactly how far the user has scrolled up.
                    let near = minY - viewport < Self.stickyThreshold
                    Task { @MainActor in
                        guard isNearBottom != near else { return }
                        isNearBottom = near
                        onScrolledUpChange?(!near)
                    }
                }
                .onChange(of: transcript.rows.count, initial: true) { _, _ in
                    position(proxy, transcript)
                }
                .onChange(of: transcript.streamingText) { _, _ in follow(proxy, animated: false) }
                .onChange(of: transcript.streamingThinking) { _, _ in follow(proxy, animated: false) }
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
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow, transcript: TranscriptModel, width: CGFloat) -> some View {
        if TranscriptNoise.isHidden(row) {
            EmptyView()
        } else if row.kind == .result {
            TurnFooterView(rows: transcript.rows, row: row)
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 10)
        } else {
            TranscriptRowView(
                row: row,
                isExpanded: expanded.contains(row.seq),
                isNested: row.parentToolUseID != nil,
                maxBubbleWidth: max(240, (width - Metrics.gutter * 2) * 0.7),
                onToggle: { toggle(row.seq) }
            )
            .padding(.horizontal, 6)
        }
    }

    private var bottomProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: BottomOffsetKey.self,
                    value: proxy.frame(in: .named(Self.coordinateSpace)).minY
                )
        }
    }

    // MARK: Scrolling

    /// First paint lands on the first thing the user has not read, which is the whole point of
    /// leaving a session and coming back to it. After that the same handler just keeps the view
    /// pinned to the bottom while rows arrive.
    private func position(_ proxy: ScrollViewProxy, _ transcript: TranscriptModel) {
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
        guard isNearBottom else { return }
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

/// Reports where the end of the content sits inside the scroll view's own coordinate space.
///
/// The default is deliberately enormous. The probe lives at the end of a `LazyVStack`, so once the
/// user scrolls far enough up the probe stops being built and no value is reported at all. Reading
/// that silence as "infinitely far below the fold" is exactly right: it is the state where the
/// transcript must stop dragging the user back down.
private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// What the pane shows with no session behind it. Deliberately quiet: an empty transcript is a
/// normal state, not a problem to be announced.
struct EmptyTranscriptView: View {
    var body: some View {
        EmptyStateView(
            glyph: "text.alignleft",
            title: "No session",
            message: "Pick a workspace, or start a new one, and the agent's work shows up here."
        )
        .background(Palette.surface)
    }
}
