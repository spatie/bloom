import Foundation

/// An answer too long to build twice. Measuring a 140,674 byte answer off screen took as long as
/// drawing it, so an answer this long is measured only by the cell that draws it, and the table is
/// told an estimate from its size until then. Long answers are cut into parts now (see
/// `TranscriptAnswerParts`), so what still reaches this is a single block that long: a fence or a table.
public enum TranscriptLongAnswer {
    /// Two answers in the owner's 203 chats were longer than this.
    public static let threshold = 20_000

    /// Measured on that answer, tables and code included: 31,000 points for 140,674 bytes at the
    /// reading measure, which a wider pane does not change.
    public static let pointsPerByte = 0.22

    /// The height to tell the table before the row is drawn, or nil for a row measured as usual.
    public static func estimate(kind: MessageKind, payloadBytes: Int) -> Double? {
        guard kind == .assistantText, payloadBytes >= threshold else { return nil }
        return Double(payloadBytes) * pointsPerByte
    }
}
