import SwiftUI
import BatonCore

/// Everything a collapsed tool row hides: the full input, and the result the tool gave back.
///
/// This view is only ever built for a row the user has explicitly expanded, which is what makes it
/// affordable to be generous here.
struct ToolDetailView: View {
    var name: String
    var input: JSONValue
    var result: String?
    var isError: Bool = false
    var hasImages: Bool = false

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
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            ToolInputView(name: name, input: input)

            if let result, !result.isEmpty {
                ToolResultView(text: result, isError: isError)
            } else if hasImages {
                DetailCaption(text: "The tool returned an image.")
            }
        }
        .padding(.vertical, TranscriptLayout.inset)
        .textSelection(.enabled)
    }
}
