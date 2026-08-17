import SwiftUI
import BatonCore

/// Everything a collapsed tool row hides: the full input, and the result the tool gave back.
///
/// This view is only ever built for a row the user has explicitly expanded, which is what makes it
/// affordable to be generous here. A tool result can be megabytes, so the output is capped until
/// asked for: SwiftUI will happily try to lay out a hundred thousand lines of text and then stop
/// being a usable application.
struct ToolDetailView: View {
    var name: String
    var input: JSONValue
    var result: String?
    var isError: Bool = false
    var hasImages: Bool = false

    /// Result output beyond this many lines is folded away behind a button.
    private static let resultLineCap = 500
    /// Even "show everything" has a ceiling, because a Text view is not a pager.
    private static let hardCharacterCap = 400_000

    @State private var showsFullResult = false

    init(name: String, input: JSONValue, result: String? = nil, isError: Bool = false, hasImages: Bool = false) {
        self.name = name
        self.input = input
        self.result = result
        self.isError = isError
        self.hasImages = hasImages
    }

    init(use: AgentToolUse, result: AgentToolResult?) {
        self.init(
            name: use.name,
            input: use.input,
            result: result?.text,
            isError: result?.isError ?? false,
            hasImages: result?.hasImages ?? false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputSection
            if let result, !result.isEmpty {
                resultSection(result)
            } else if hasImages {
                caption("The tool returned an image.")
            }
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
    }

    // MARK: Input

    @ViewBuilder
    private var inputSection: some View {
        switch name {
        case "Bash":
            code(input["command"]?.stringValue ?? "")
            metadata([
                input["timeout"]?.intValue.map { "timeout \($0)ms" },
                input["run_in_background"]?.boolValue == true ? "runs in the background" : nil,
            ])

        case "Read":
            path(input["file_path"]?.stringValue ?? "")

        case "Write":
            path(input["file_path"]?.stringValue ?? "")
            code(input["content"]?.stringValue ?? "", tint: Palette.diffAddBackground)

        case "Edit":
            path(input["file_path"]?.stringValue ?? "")
            replacement(old: input["old_string"]?.stringValue, new: input["new_string"]?.stringValue)

        case "MultiEdit":
            path(input["file_path"]?.stringValue ?? "")
            ForEach(Array((input["edits"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, edit in
                replacement(old: edit["old_string"]?.stringValue, new: edit["new_string"]?.stringValue)
            }

        case "NotebookEdit":
            path(input["notebook_path"]?.stringValue ?? "")
            code(input["new_source"]?.stringValue ?? "")

        case "TodoWrite":
            todoList

        case "Task", "Agent":
            caption(input["description"]?.stringValue ?? "")
            code(input["prompt"]?.stringValue ?? "")

        case "ExitPlanMode":
            code(input["plan"]?.stringValue ?? "")

        case "WebFetch":
            path(input["url"]?.stringValue ?? "")
            caption(input["prompt"]?.stringValue ?? "")

        case "AskUserQuestion":
            questionList

        case "Grep", "Glob":
            code(input["pattern"]?.stringValue ?? "")
            metadata([
                input["path"]?.stringValue.map { "in \($0)" },
                input["glob"]?.stringValue.map { "matching \($0)" },
                input["output_mode"]?.stringValue,
            ])

        default:
            // A tool with no bespoke renderer still deserves its arguments shown, and here, behind
            // an explicit expand, pretty JSON is the honest answer.
            code(input.prettyPrinted)
        }
    }

    private var todoList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((input["todos"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, todo in
                let status = todo["status"]?.stringValue ?? "pending"
                let text = status == "in_progress"
                    ? (todo["activeForm"]?.stringValue ?? todo["content"]?.stringValue ?? "")
                    : (todo["content"]?.stringValue ?? "")

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.todoGlyph(status))
                        .font(.system(size: 10))
                        .foregroundStyle(Self.todoTint(status))
                    Text(text)
                        .font(Typo.label)
                        .foregroundStyle(status == "completed" ? Palette.textTertiary : Palette.textPrimary)
                        .strikethrough(status == "completed", color: Palette.textTertiary)
                }
            }
        }
    }

    private var questionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((input["questions"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(question["question"]?.stringValue ?? "")
                        .font(Typo.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                    ForEach(Array((question["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, option in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(Palette.textTertiary)
                            Text(option["label"]?.stringValue ?? "")
                                .font(Typo.label)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Result

    @ViewBuilder
    private func resultSection(_ text: String) -> some View {
        let capped = Self.cap(text, lines: showsFullResult ? Int.max : Self.resultLineCap)

        VStack(alignment: .leading, spacing: 4) {
            Text(capped.text)
                .font(Typo.code)
                .foregroundStyle(isError ? Palette.negative : Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isError ? Palette.negative : Palette.border)
                        .frame(width: 2)
                }

            if capped.truncated, !showsFullResult {
                Button("Show all output") { showsFullResult = true }
                    .buttonStyle(.plain)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.accent)
                    .padding(.leading, 8)
            }
        }
    }

    // MARK: Pieces

    private func path(_ value: String) -> some View {
        Text(value)
            .font(Typo.codeSmall)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func caption(_ value: String) -> some View {
        Group {
            if value.isEmpty {
                EmptyView()
            } else {
                Text(value)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func metadata(_ values: [String?]) -> some View {
        let present = values.compactMap(\.self).filter { !$0.isEmpty }
        return Group {
            if present.isEmpty {
                EmptyView()
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(present.enumerated()), id: \.offset) { _, value in
                        Chip(text: value)
                    }
                }
            }
        }
    }

    private func code(_ value: String, tint: Color = Palette.surfaceSunken) -> some View {
        Group {
            if value.isEmpty {
                EmptyView()
            } else {
                Text(Self.cap(value, lines: showsFullResult ? Int.max : Self.resultLineCap).text)
                    .font(Typo.code)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(tint, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
            }
        }
    }

    /// An Edit reads as a two colour before and after, which is the closest a one-file view gets
    /// to a diff without running one.
    @ViewBuilder
    private func replacement(old: String?, new: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let old, !old.isEmpty {
                code(old, tint: Palette.diffDeleteBackground)
            }
            if let new, !new.isEmpty {
                code(new, tint: Palette.diffAddBackground)
            }
        }
    }

    // MARK: Capping

    /// Cuts a string at a line count without splitting it into an array first, because a tool
    /// result can be tens of megabytes and `split` on that allocates the whole thing twice.
    static func cap(_ text: String, lines: Int) -> (text: String, truncated: Bool) {
        var seen = 0
        var index = text.startIndex
        var characters = 0

        while index < text.endIndex {
            if characters >= hardCharacterCap {
                return (String(text[text.startIndex..<index]), true)
            }
            if text[index] == "\n" {
                seen += 1
                if seen >= lines {
                    return (String(text[text.startIndex..<index]), true)
                }
            }
            index = text.index(after: index)
            characters += 1
        }
        return (text, false)
    }

    private static func todoGlyph(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.square.fill"
        case "in_progress": "square.dashed.inset.filled"
        default: "square"
        }
    }

    private static func todoTint(_ status: String) -> Color {
        switch status {
        case "completed": Palette.positive
        case "in_progress": Palette.accent
        default: Palette.textTertiary
        }
    }
}
