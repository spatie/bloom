import Foundation

/// The baseline follows successful I/O, while text written during that I/O remains the user's draft.
public struct SourceDraft: Sendable {
    public var baseline: EditableFile
    public var text: String
    public var isDirty: Bool { text != baseline.text }

    public init(baseline: EditableFile, text: String) { self.baseline = baseline; self.text = text }

    /// False leaves both versions intact for comparison instead of replacing unsaved text.
    public mutating func acceptDisk(_ file: EditableFile) -> Bool {
        guard !isDirty || text == file.text else { return false }
        baseline = file
        text = file.text
        return true
    }

    public mutating func didSave(_ file: EditableFile) { baseline = file }
}
