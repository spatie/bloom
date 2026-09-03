import SwiftUI
import BloomCore

/// The agent's own plan, as it last wrote it.
struct TodoListView: View {
    var todos: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = todo["status"]?.stringValue ?? "pending"

                HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
                    Image(systemName: Self.glyph(status))
                        .font(Typo.label)
                        .imageScale(.small)
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

    /// The item being worked on is `running`, not the accent.
    ///
    /// Those two used to be one value, so a finished item and the one in hand were the same colour
    /// in the same list and only the box's shape told them apart. That is the report `Palette.running`
    /// carries, met here for the same reason it was met in the sidebar: this is a plan being worked
    /// through, and which line is being worked on is the thing the list is read for.
    private static func tint(_ status: String) -> Color {
        switch status {
        case "completed": Palette.positive
        case "in_progress": Palette.running
        default: Palette.textTertiary
        }
    }
}
