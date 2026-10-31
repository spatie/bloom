import Observation

/// Whether a drag is headed for this composer, from every place that can tell: the window, the text
/// view and the drop surface around the box. The box tints itself from it, and `FileDropActivity`
/// draws the cue over the chat from it. Its own object so that only the glass redraws when it
/// flips: the prompt's body parses the whole draft and has no business running because a pointer
/// crossed the window.
///
/// One flag per source, each with a single writer. Moving from the window onto the editor delivers
/// the exit and the enter in no fixed order, and a shared flag would go dark under a pointer that
/// is on it.
@MainActor
@Observable
final class ComposerDropHint {
    enum Source {
        /// `WindowFileDrop`: the drag is somewhere else in the window and will land here.
        case window
        /// The text view, which takes a drag before the box does.
        case editor
        /// The drop surface around the box: the padding, the chips and the footer.
        case box
    }

    /// The chat this box writes into, which is what the cue over its transcript is keyed on.
    @ObservationIgnored var sessionKey: String?

    private var isFromWindow = false
    private var isOverEditor = false
    private var isOverBox = false

    var isShown: Bool { isFromWindow || isOverEditor || isOverBox }

    func set(_ source: Source, _ isOn: Bool) {
        switch source {
        case .window: isFromWindow = isOn
        case .editor: isOverEditor = isOn
        case .box: isOverBox = isOn
        }
        FileDropActivity.shared.update(self, isActive: isShown)
    }

    /// A composer that goes away mid drag must not leave its chat blurred.
    isolated deinit { FileDropActivity.shared.forget(ObjectIdentifier(self)) }
}
