import SwiftUI
import BatonCore

/// One stored event, rendered.
///
/// The row decodes its own payload, and it does it in `body` rather than up front. A session can
/// hold tens of thousands of rows and the enclosing `LazyVStack` only ever builds the handful on
/// screen, so decoding here is the difference between opening a long transcript instantly and
/// parsing forty megabytes of JSON before the first frame. Every decode goes through
/// `TranscriptEventCache`, so a row that is rebuilt on every streamed token still only parses once.
///
/// Every kind except assistant prose, a user turn and an expanded row is exactly one line tall.
/// That is the whole design: an agent run reads as a list of actions, not a chat log.
struct TranscriptRowView: View {
    var row: TranscriptRow
    var isExpanded = false
    var isNested = false
    /// The width a user bubble is allowed to fill, handed down because the enclosing scroll view
    /// already measured it and a per row GeometryReader would not size to its content.
    var maxBubbleWidth: CGFloat = 560
    var onToggle: () -> Void = {}

    /// How much of the pane a user turn always leaves empty on its left, so it reads as one side
    /// of a conversation even when it is short.
    private static let userTurnInset: CGFloat = 32

    @State private var isHovered = false

    var body: some View {
        content
            .padding(.leading, isNested ? TranscriptLayout.nestIndent : 0)
            .overlay(alignment: .leading) {
                if isNested {
                    Rectangle()
                        .fill(Palette.border)
                        .frame(width: Metrics.hairline)
                        .padding(.leading, TranscriptLayout.inset)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .user: userTurn
        case .assistantText: prose
        case .thinking: thinkingRow
        case .toolUse: toolRow
        case .toolResult: orphanResult
        case .error: errorRow
        case .notice: noticeRow
        case .system: systemRow
        // A result row is a turn boundary, and the footer that renders it needs the rows around
        // it, so TranscriptView draws that one itself.
        case .result: EmptyView()
        }
    }

    // MARK: Decoding

    private var event: AgentEvent? {
        TranscriptEventCache.event(rowID: row.id, payload: row.payload)
    }

    /// Only decoded once a row is open, because a tool result is the largest payload in the file.
    private var toolResult: AgentToolResult? {
        guard isExpanded, let payload = row.resultPayload,
              case .toolResult(let result)? = TranscriptEventCache.event(rowID: row.id, payload: payload)
        else { return nil }
        return result
    }

    private var json: JSONValue? {
        TranscriptEventCache.json(rowID: row.id, payload: row.payload)
    }

    // MARK: Tools

    @ViewBuilder
    private var toolRow: some View {
        if case .toolUse(let use)? = event {
            let presentation = ToolPresenter.present(use)

            VStack(alignment: .leading, spacing: 0) {
                header(presentation)
                if isExpanded {
                    ToolDetailView(use: use, result: toolResult)
                        .padding(.leading, TranscriptLayout.detailIndent)
                        .padding(.trailing, TranscriptLayout.inset)
                        .padding(.bottom, TranscriptLayout.tight * 2)
                }
            }
            .modifier(ExpandableRow(isHovered: isHovered, isError: row.isError, onToggle: onToggle))
            .onHover { isHovered = $0 }
        }
    }

    private func header(_ presentation: ToolPresentation) -> some View {
        // A chip that repeats the detail replaces it: `Read [notes.txt]` rather than
        // `Read notes.txt [notes.txt]`.
        let showsDetail = !presentation.detail.isEmpty && !presentation.chips.contains(presentation.detail)

        return HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(
                symbol: presentation.glyph,
                tint: row.isError ? Palette.negative : presentation.tint
            )

            Text(presentation.label)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TranscriptLayout.labelWidth, alignment: .leading)

            if showsDetail {
                Text(presentation.detail)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            ForEach(Array(presentation.chips.enumerated()), id: \.offset) { _, chip in
                Chip(text: chip, monospaced: true)
                    .fixedSize()
            }

            Spacer(minLength: TranscriptLayout.tight)

            if row.isError {
                Text("error")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.negative)
            }
            if let duration = row.durationMS, duration > 0 {
                Text(TurnDuration.short(duration))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .frame(height: Metrics.rowHeight)
    }

    /// A tool result whose call never made it into the transcript. Rare, but it must not vanish.
    @ViewBuilder
    private var orphanResult: some View {
        if case .toolResult(let result)? = event {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "arrow.turn.down.right")
                Text(ToolPresenter.oneLine(result.text))
                    .font(Typo.label)
                    .foregroundStyle(result.isError ? Palette.negative : Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TranscriptLayout.inset)
            .frame(height: Metrics.rowHeight)
        }
    }

    // MARK: Prose

    @ViewBuilder
    private var prose: some View {
        if case .assistantText(let block)? = event, !block.text.isEmpty {
            MarkdownView(block.text)
                .font(Typo.body)
                .lineSpacing(TranscriptLayout.proseLeading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.vertical, TranscriptLayout.inset)
        }
    }

    private var userTurn: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Self.userTurnInset)
            Text(userText)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineSpacing(TranscriptLayout.proseLeading)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, TranscriptLayout.block)
                .padding(.vertical, TranscriptLayout.inset)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.corner)
                        .stroke(Palette.border, lineWidth: Metrics.hairline)
                }
                .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
    }

    /// A user turn is the line Baton itself wrote to stdin, so it is read straight out of the
    /// stored request rather than through the event decoder, which only knows about tool results.
    private var userText: String {
        guard let blocks = json?["message"]?["content"]?.arrayValue else { return "" }
        return blocks
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var thinkingRow: some View {
        if case .thinking(let block)? = event, !block.text.isEmpty {
            ThinkingRowView(text: block.text, isExpanded: isExpanded, onToggle: onToggle)
        }
    }

    // MARK: Notices

    private var errorRow: some View {
        let stderr = json?["stderr"]?.stringValue ?? ""
        let status = json?["status"]?.intValue

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "exclamationmark.triangle", tint: Palette.negative)
                Text(status.map { "Agent exited (\($0))" } ?? "Agent error")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.negative)
                    .frame(width: TranscriptLayout.labelWidth, alignment: .leading)
                Text(ToolPresenter.oneLine(stderr))
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: TranscriptLayout.tight)
                TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
            }
            .padding(.horizontal, TranscriptLayout.inset)
            .frame(height: Metrics.rowHeight)

            if isExpanded, !stderr.isEmpty {
                Text(stderr)
                    .font(Typo.code)
                    .foregroundStyle(Palette.negative)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TranscriptLayout.block)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.negative).frame(width: TranscriptLayout.rule)
                    }
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.bottom, TranscriptLayout.inset)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered, isError: true, onToggle: onToggle))
        .onHover { isHovered = $0 }
    }

    /// Rate limit news. Quiet on purpose: it is information, not a failure.
    private var noticeRow: some View {
        let info = json?["rate_limit_info"]
        let utilization = info?["utilization"]?.doubleValue ?? 0
        let window = (info?["rateLimitType"]?.stringValue ?? "").replacingOccurrences(of: "_", with: " ")

        return HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "gauge.with.dots.needle.33percent", tint: Palette.warning)
            Text("Rate limit")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: TranscriptLayout.labelWidth, alignment: .leading)
            Text(window.isEmpty
                ? "\(Int(utilization * 100))% used"
                : "\(Int(utilization * 100))% of the \(window) window used")
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .frame(height: Metrics.rowHeight)
    }

    @ViewBuilder
    private var systemRow: some View {
        if case .initialized(let info)? = event {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "bolt.horizontal.circle")
                Text("Session started")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: TranscriptLayout.labelWidth, alignment: .leading)
                if !info.model.isEmpty { Chip(text: info.model) }
                if !info.permissionMode.isEmpty { Chip(text: info.permissionMode) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TranscriptLayout.inset)
            .frame(height: Metrics.rowHeight)
        }
    }
}

// MARK: - Decode cache

private final class TranscriptPayloadKey: NSObject {
    let rowID: Int64
    let payload: Data
    private let cachedHash: Int

    init(rowID: Int64, payload: Data) {
        self.rowID = rowID
        self.payload = payload
        var hasher = Hasher()
        hasher.combine(rowID)
        hasher.combine(payload)
        cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptPayloadKey else { return false }
        return cachedHash == other.cachedHash
            && rowID == other.rowID
            && payload == other.payload
    }
}

private final class TranscriptEventBox {
    let value: AgentEvent?

    init(_ value: AgentEvent?) { self.value = value }
}

private final class TranscriptJSONBox {
    let value: JSONValue?

    init(_ value: JSONValue?) { self.value = value }
}

/// Prevents stable transcript rows from recursively decoding JSON on every streamed token.
///
/// The payload bytes are part of the key alongside the row ID because an updated store row may
/// retain its identity. Exact byte equality prevents a cached event from surviving that change.
@MainActor
enum TranscriptEventCache {
    private static let limit = 256
    private static let costLimit = 8 * 1_024 * 1_024

    private static let events: NSCache<TranscriptPayloadKey, TranscriptEventBox> = {
        let cache = NSCache<TranscriptPayloadKey, TranscriptEventBox>()
        cache.countLimit = limit
        cache.totalCostLimit = costLimit
        return cache
    }()

    private static let jsonValues: NSCache<TranscriptPayloadKey, TranscriptJSONBox> = {
        let cache = NSCache<TranscriptPayloadKey, TranscriptJSONBox>()
        cache.countLimit = limit
        cache.totalCostLimit = costLimit
        return cache
    }()

    static func event(rowID: Int64, payload: Data) -> AgentEvent? {
        let key = TranscriptPayloadKey(rowID: rowID, payload: payload)
        if let cached = events.object(forKey: key) { return cached.value }

        let value = AgentEvent.decode(line: String(decoding: payload, as: UTF8.self))
        events.setObject(TranscriptEventBox(value), forKey: key, cost: payload.count)
        return value
    }

    static func json(rowID: Int64, payload: Data) -> JSONValue? {
        let key = TranscriptPayloadKey(rowID: rowID, payload: payload)
        if let cached = jsonValues.object(forKey: key) { return cached.value }

        let value = JSONValue.parse(payload)
        jsonValues.setObject(TranscriptJSONBox(value), forKey: key, cost: payload.count)
        return value
    }
}

/// Hover, click to expand and the error rule, shared by every row that opens.
///
/// The hover fill comes from `rowBackground` rather than a fill of its own, so a transcript row
/// highlights exactly the way a sidebar row and a file row do, and follows the window's active
/// state with them.
private struct ExpandableRow: ViewModifier {
    var isHovered: Bool
    var isError: Bool
    var onToggle: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .rowBackground(isSelected: false, isHovered: isHovered)
            .overlay(alignment: .leading) {
                if isError {
                    Rectangle()
                        .fill(Palette.negative)
                        .frame(width: TranscriptLayout.rule)
                }
            }
            .onTapGesture(perform: onToggle)
    }
}

/// Whether a stored row is worth a line at all.
///
/// Hook payloads run to hundreds of kilobytes and say nothing a user wants to read, so they are
/// skipped by sniffing the first bytes of the raw line rather than by decoding it. Decoding a
/// megabyte of hook output only to throw it away is exactly the cost this avoids.
enum TranscriptNoise {
    private static let probeLength = 256
    private static let hookMarker = Data("\"hook_".utf8)

    static func isHidden(_ row: TranscriptRow) -> Bool {
        guard row.kind == .system else { return false }
        return row.payload.prefix(probeLength).range(of: hookMarker) != nil
    }
}
