import SwiftUI
import BloomCore

/// Everything a collapsed tool row hides: the full input, and the result the tool gave back.
///
/// This view is only ever built for a row the user has explicitly expanded, which is what makes it
/// affordable to be generous here.
struct ToolDetailView: View {
    var name: String
    var input: JSONValue
    var result: String?
    var isError: Bool = false
    /// Set when the call never ran, in which case the sentence below the input is an explanation
    /// rather than output and is drawn as one. See `ToolRefusalView`.
    var refusal: ToolRefusal?
    var refusalReason: String = ""
    var hasImages: Bool = false

    init(
        name: String,
        input: JSONValue,
        result: String? = nil,
        isError: Bool = false,
        refusal: ToolRefusal? = nil,
        refusalReason: String = "",
        hasImages: Bool = false
    ) {
        self.name = name
        self.input = input
        self.result = result
        self.isError = isError
        self.refusal = refusal
        self.refusalReason = refusalReason
        self.hasImages = hasImages
    }

    init(use: AgentToolUse, result: AgentToolResult?, refusal: ToolRefusal? = nil, refusalReason: String = "") {
        // The row carries the refusal because it is folded in as the result arrives and is
        // available while the row is closed; the decoded result carries its own copy for the
        // callers that have no row. Either one is enough for the row to be right.
        self.init(
            name: use.name,
            input: use.input,
            result: result?.text,
            isError: result?.isError ?? false,
            refusal: refusal ?? result?.refusal,
            refusalReason: refusalReason,
            hasImages: result?.hasImages ?? false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            ToolInputView(name: name, input: input)

            if let refusal {
                ToolRefusalView(refusal: refusal, reason: refusalReason.isEmpty ? (result ?? "") : refusalReason)
            } else if let result, !result.isEmpty {
                ToolResultView(text: result, isError: isError)
            } else if hasImages {
                DetailCaption(text: "The tool returned an image.")
            }
        }
        .padding(.top, TranscriptLayout.inset)
        .textSelection(.enabled)
    }
}
