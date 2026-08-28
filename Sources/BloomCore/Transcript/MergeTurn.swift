import Foundation

/// The visible parts of a merge request Bloom sent on the user's behalf.
public struct MergeTurnRecord: Equatable, Sendable {
    public var message: String
    public var instructions: String

    public init(message: String, instructions: String) {
        self.message = message
        self.instructions = instructions
    }
}

/// Recognises the merge context Bloom appends to a generated user turn.
///
/// The agent still receives the complete text. This parser only lets the transcript present the
/// fixed safety rules as a compact attachment instead of making them look like words the user
/// typed. Matching the complete canonical block keeps ordinary messages untouched.
public enum MergeTurn {
    public static func split(_ text: String) -> MergeTurnRecord? {
        let marker = "\n\n\(MergeInstructions.canonical)"
        guard let range = text.range(of: marker) else { return nil }

        let before = String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")

        guard !message.isEmpty else { return nil }
        return MergeTurnRecord(message: message, instructions: MergeInstructions.canonical)
    }
}
