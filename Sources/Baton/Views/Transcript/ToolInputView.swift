import SwiftUI
import BatonCore

/// What a tool was asked to do, rendered per tool.
///
/// Every built-in tool gets the shape that suits it: a command as code, an edit as a two colour
/// before and after, a todo write as a checklist. A tool Baton has never heard of still gets its
/// arguments shown, and here, behind an explicit expand, pretty JSON is the honest answer.
struct ToolInputView: View {
    var name: String
    var input: JSONValue

    var body: some View {
        switch name {
        case "Bash":
            DetailCodeBlock(text: input["command"]?.stringValue ?? "")
            DetailChips(values: [
                input["timeout"]?.intValue.map { "timeout \($0)ms" },
                input["run_in_background"]?.boolValue == true ? "runs in the background" : nil,
            ])

        case "Read":
            DetailPathLabel(path: input["file_path"]?.stringValue ?? "")

        case "Write":
            DetailPathLabel(path: input["file_path"]?.stringValue ?? "")
            DetailCodeBlock(
                text: input["content"]?.stringValue ?? "",
                tint: Palette.diffAddBackground
            )

        case "Edit":
            DetailPathLabel(path: input["file_path"]?.stringValue ?? "")
            ToolReplacementView(
                old: input["old_string"]?.stringValue,
                new: input["new_string"]?.stringValue
            )

        case "MultiEdit":
            DetailPathLabel(path: input["file_path"]?.stringValue ?? "")
            ForEach(Array((input["edits"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, edit in
                ToolReplacementView(
                    old: edit["old_string"]?.stringValue,
                    new: edit["new_string"]?.stringValue
                )
            }

        case "NotebookEdit":
            DetailPathLabel(path: input["notebook_path"]?.stringValue ?? "")
            DetailCodeBlock(text: input["new_source"]?.stringValue ?? "")

        case "TodoWrite":
            TodoListView(todos: input["todos"]?.arrayValue ?? [])

        case "Task", "Agent":
            DetailCaption(text: input["description"]?.stringValue ?? "")
            DetailCodeBlock(text: input["prompt"]?.stringValue ?? "")

        case "ExitPlanMode":
            DetailCodeBlock(text: input["plan"]?.stringValue ?? "")

        case "WebFetch":
            DetailPathLabel(path: input["url"]?.stringValue ?? "")
            DetailCaption(text: input["prompt"]?.stringValue ?? "")

        case "AskUserQuestion":
            QuestionListView(questions: input["questions"]?.arrayValue ?? [])

        case "Grep", "Glob":
            DetailCodeBlock(text: input["pattern"]?.stringValue ?? "")
            DetailChips(values: [
                input["path"]?.stringValue.map { "in \($0)" },
                input["glob"]?.stringValue.map { "matching \($0)" },
                input["output_mode"]?.stringValue,
            ])

        default:
            DetailCodeBlock(text: input.prettyPrinted)
        }
    }
}
