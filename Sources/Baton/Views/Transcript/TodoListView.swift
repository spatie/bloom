import SwiftUI
import BatonCore

/// The agent's own plan, as it last wrote it.
struct TodoListView: View {
    var todos: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.proseLeading) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = todo["status"]?.stringValue ?? "pending"

                HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.inset) {
                    Image(systemName: Self.glyph(status))
                        .font(Typo.caption)
                        .imageScale(.medium)
                        .foregroundStyle(Self.tint(status))
                        .accessibilityHidden(true)

                    Text(Self.text(of: todo, status: status))
                        .font(Typo.label)
                        .foregroundStyle(status == "completed" ? Palette.textTertiary : Palette.textPrimary)
                        .strikethrough(status == "completed", color: Palette.textTertiary)
                }
            }
        }
    }

    /// An item in progress carries a second wording ("Reading the store" rather than "Read the
    /// store"), and that is the one worth showing while it is happening.
    private static func text(of todo: JSONValue, status: String) -> String {
        if status == "in_progress" {
            return todo["activeForm"]?.stringValue ?? todo["content"]?.stringValue ?? ""
        }
        return todo["content"]?.stringValue ?? ""
    }

    private static func glyph(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.square.fill"
        case "in_progress": "square.dashed.inset.filled"
        default: "square"
        }
    }

    private static func tint(_ status: String) -> Color {
        switch status {
        case "completed": Palette.positive
        case "in_progress": Palette.accent
        default: Palette.textTertiary
        }
    }
}
