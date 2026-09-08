import Foundation

/// Whether the pane under the header bar is showing what changed or the file itself.
///
/// In the core rather than beside the bar that draws it, because it is half of what
/// `FileBarControls` answers: what the copy button is called depends on which of the two you are
/// looking at, and that used to be an inline conditional in a view with nothing able to test it.
/// The raw values are what the segmented control shows, which is why they are capitalised.
public enum FileViewMode: String, Hashable, CaseIterable, Sendable {
    case diff = "Diff"
    case edit = "Edit"
}
