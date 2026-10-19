import Foundation

/// A platform-neutral reading of one stored event. The host owns provider parsing so a browser
/// and a future phone client do not each learn Claude Code, Codex and Grok wire formats.
///
/// Rows are projected only for the requested page. A long transcript remains in the store until
/// a client asks for its rows, just as the Mac table decodes only what is on screen.
public struct TranscriptClientRow: Encodable, Sendable {
    public struct Question: Encodable, Sendable {
        public struct Option: Encodable, Sendable {
            public let label: String
            public let detail: String
            public let preview: String?
        }

        public let answerKey: String
        public let text: String
        public let header: String
        public let multiSelect: Bool
        public let allowsOther: Bool
        public let isSecret: Bool
        public let options: [Option]

        init(_ question: AgentQuestion) {
            answerKey = question.id
            text = question.question
            header = question.header
            multiSelect = question.multiSelect
            allowsOther = question.allowsOther
            isSecret = question.isSecret
            options = question.options.map { Option(label: $0.label, detail: $0.description, preview: $0.preview) }
        }
    }

    public struct FileReference: Encodable, Sendable {
        public let label: String
        public let path: String
        public let line: Int

        public init(label: String, path: String, line: Int = 1) {
            self.label = label
            self.path = path
            self.line = line
        }
    }
    public enum Kind: String, Encodable, Sendable {
        case user
        case assistant
        case thinking
        case tool
        case toolResult
        case permission
        case error
        case notice
        case session
        case plan
        case crew
        case turnEnd
    }

    public let seq: Int
    public let kind: Kind
    public let title: String
    public let text: String
    /// HTML from `MarkdownHTML`, which escapes raw markup and filters unsafe addresses.
    public let html: String?
    public let detail: String
    public let chips: [String]
    public let files: [FileReference]
    public let tint: String
    public let refID: String?
    public let parentToolUseID: String?
    public let requestID: String?
    public let isError: Bool
    public let canAnswer: Bool
    public let questions: [Question]
    public let planMode: String?

    private init(
        seq: Int, kind: Kind, title: String = "", text: String = "", html: String? = nil,
        detail: String = "", chips: [String] = [], files: [FileReference] = [], tint: String = "neutral",
        refID: String? = nil, parentToolUseID: String? = nil, requestID: String? = nil,
        isError: Bool = false, canAnswer: Bool = false, questions: [Question] = [], planMode: String? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.title = title
        self.text = text
        self.html = html
        self.detail = detail
        self.chips = chips
        self.files = files
        self.tint = tint
        self.refID = refID
        self.parentToolUseID = parentToolUseID
        self.requestID = requestID
        self.isError = isError
        self.canAnswer = canAnswer
        self.questions = questions
        self.planMode = planMode
    }

    public static func present(_ message: Message, worktree: String = "") -> Self? {
        let raw = String(decoding: message.payload, as: UTF8.self)
        let event = AgentEvent.decode(line: raw)
        let seq = message.seq
        switch message.kind {
        case .user:
            let typed = UserTurnPrompt.text(in: message.payload)
            if let review = ReviewTurn.split(typed) {
                return Self(
                    seq: seq, kind: .user, text: review.message,
                    chips: review.chips.map(\.label),
                    files: review.chips.compactMap { chip in
                        guard let path = FileChipTarget.resolve(chip.filePath, in: worktree).opens else { return nil }
                        return FileReference(label: chip.label, path: path, line: chip.line)
                    }
                )
            }
            let turn = AttachmentTrailer.split(typed)
            let segments = SentTurn.segments(in: turn.body)
            let instructions = segments.compactMap { segment -> String? in
                if case .instructions(let block) = segment { return block.title }
                return nil
            }
            let inlineFiles = segments.compactMap { segment -> FileReference? in
                guard case .file(let path) = segment,
                      let relative = FileChipTarget.resolve(path, in: worktree).opens else { return nil }
                return FileReference(label: AttachmentDraft.token(for: path), path: relative)
            }
            return Self(
                seq: seq, kind: .user, text: SentTurn.withoutInstructions(turn.body),
                chips: turn.paths.map { ($0 as NSString).lastPathComponent } + instructions,
                files: turn.paths.compactMap { path in
                    guard let relative = FileChipTarget.resolve(path, in: worktree).opens else { return nil }
                    return FileReference(label: (path as NSString).lastPathComponent, path: relative)
                } + inlineFiles
            )
        case .assistantText:
            guard case .assistantText(let block)? = event, !block.text.isEmpty else { return nil }
            return Self(
                seq: seq, kind: .assistant, text: block.text,
                html: MarkdownHTML.render(block.text, imagesAsAltText: true).html,
                files: references(in: block.text, worktree: worktree),
                parentToolUseID: block.parentToolUseID
            )
        case .thinking:
            guard case .thinking(let block)? = event, !block.text.isEmpty else { return nil }
            return Self(seq: seq, kind: .thinking, title: "Thinking", text: block.text,
                        parentToolUseID: block.parentToolUseID)
        case .toolUse:
            guard case .toolUse(let use)? = event else { return nil }
            if let plan = PlanRow.markdown(of: use, resultText: nil) {
                return Self(seq: seq, kind: .plan, title: "Plan", text: plan,
                            html: MarkdownHTML.render(plan, imagesAsAltText: true).html, refID: use.id,
                            parentToolUseID: use.parentToolUseID)
            }
            let presentation = TranscriptPresenter.present(use, worktree: worktree)
            return Self(
                seq: seq, kind: .tool, title: presentation.label,
                detail: presentation.detailLine,
                chips: presentation.chips.map(\.text),
                files: presentation.chips.compactMap { chip in
                    guard case .file(let path) = chip,
                          let relative = FileChipTarget.resolve(path, in: worktree).opens else { return nil }
                    return FileReference(label: chip.text, path: relative)
                }, tint: presentation.tint.rawValue,
                refID: use.id, parentToolUseID: use.parentToolUseID
            )
        case .toolResult:
            guard case .toolResult(let result)? = event else { return nil }
            return Self(
                seq: seq, kind: .toolResult, title: result.isError ? "Failed" : "Result",
                text: result.text, refID: result.toolUseID,
                parentToolUseID: result.parentToolUseID, isError: result.isError
            )
        case .permissionAsk:
            guard case .permissionAsk(let ask)? = event else { return nil }
            let questions = ask.isQuestion ? AgentQuestionnaire.questions(in: ask.input).map(Question.init) : []
            let planMode = ask.isPlanApproval
                ? PlanApproval.implementationMode(ask.implementationMode ?? .acceptEdits).rawValue : nil
            return Self(
                seq: seq, kind: .permission, title: ask.label,
                text: ask.summary.isEmpty ? ask.reason : ask.summary,
                detail: ask.reason, tint: "warning", refID: ask.toolUseID,
                requestID: ask.requestID, canAnswer: !ask.isQuestion || !questions.isEmpty,
                questions: questions, planMode: planMode
            )
        case .error:
            let exit = AgentExit.read(JSONValue.parse(message.payload))
            return Self(seq: seq, kind: .error, title: exit.title,
                        text: exit.summary, detail: exit.advice, tint: "negative", isError: true)
        case .notice:
            guard let sentence = ConversationNotResumed.sentence(fromNote: message.payload)
                ?? RateLimitNotice.sentence(forRateLimitEvent: message.payload) else { return nil }
            return Self(seq: seq, kind: .notice, title: "Notice", text: sentence)
        case .crew:
            guard let crew = CrewMessage.decode(message.payload), !crew.text.isEmpty else { return nil }
            return Self(seq: seq, kind: .crew, title: "Workspace message", text: crew.text,
                        html: MarkdownHTML.render(crew.text, imagesAsAltText: true).html)
        case .result:
            return Self(seq: seq, kind: .turnEnd, title: "Turn finished")
        case .system:
            guard !TranscriptRowInk.drawsNothing(kind: message.kind, payload: message.payload) else { return nil }
            switch event {
            case .contextCompacted:
                return Self(seq: seq, kind: .notice, title: "Conversation compacted")
            default:
                return nil
            }
        }
    }

    private static func references(in text: String, worktree: String) -> [FileReference] {
        func reference(_ url: URL?, label: String) -> FileReference? {
            guard let url, let location = SourceReference.location(url),
                  let path = FileChipTarget.resolve(location.path, in: worktree).opens else { return nil }
            return FileReference(label: label, path: path, line: location.line)
        }
        func inline(_ values: [MarkdownInline]) -> [FileReference] {
            values.flatMap { value -> [FileReference] in
                switch value {
                case .text(let value):
                    return SourceReference.links(in: value).compactMap { range, url in
                        reference(url, label: (value as NSString).substring(with: range))
                    }
                case .code(let value):
                    return reference(SourceReference.url(value), label: value).map { [$0] } ?? []
                case .link(let children, let address):
                    let label = children.map { child -> String in
                        switch child {
                        case .text(let text), .code(let text): text
                        default: ""
                        }
                    }.joined()
                    return reference(SourceReference.url(address), label: label).map { [$0] } ?? inline(children)
                case .image(let alt, let address):
                    return reference(SourceReference.url(address), label: alt).map { [$0] } ?? []
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    return inline(children)
                case .lineBreak: return []
                }
            }
        }
        func blocks(_ values: [MarkdownBlock]) -> [FileReference] {
            values.flatMap { block -> [FileReference] in
                switch block {
                case .paragraph(let values), .heading(_, let values): return inline(values)
                case .bulletList(let items, _), .numberedList(_, let items, _): return items.flatMap(blocks)
                case .taskList(let items): return items.flatMap { inline($0.inline) }
                case .blockQuote(let values): return blocks(values)
                case .table(let headers, let rows, _):
                    return headers.flatMap(inline) + rows.flatMap { $0.flatMap(inline) }
                case .codeBlock, .thematicBreak: return []
                }
            }
        }
        return blocks(MarkdownParser.parse(text))
    }
}
