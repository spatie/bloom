import SwiftUI

/// A second thing the footer's end of the row can do, drawn beside the primary button.
///
/// One caller, and it is the create sheet's "Just a terminal". It is a parameter rather than
/// something the footer knows about because the footer is the ordinary composer too, and a
/// control that cuts a worktree has no business being compiled into the bottom of every chat.
///
/// A value rather than a `ViewBuilder`: the footer is rebuilt three times by `ViewThatFits`, and
/// a closure returning a view would be three closures returning three views, each with its own
/// state. What is here is what a button needs and nothing else.
struct ComposerSecondaryAction {
    var title: String
    var systemImage: String
    var help: String
    /// Separate from the primary's `canSend`, because the two do not become available at the same
    /// moment. That is the entire point of this button in the create sheet: Create wants words
    /// and this one does not. See `WorkspaceStartPlan.canStart`.
    var isEnabled: Bool
    var action: @MainActor () -> Void
}

/// The button an action above is drawn as.
///
/// Bordered rather than prominent, and it keeps its words. Beside a filled capsule saying Create,
/// an outlined capsule reads as the other way to finish rather than as a control that got left
/// out, which is what a glyph on its own would have read as: nobody guesses that a terminal icon
/// in a create sheet means "create it now, with no chat".
struct ComposerSecondaryButton: View {
    var action: ComposerSecondaryAction

    var body: some View {
        Button(action: action.action) {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: action.systemImage)
                    .imageScale(.small)
                Text(action.title)
            }
            .font(Typo.labelEmphasis)
            .padding(.horizontal, Metrics.spacing)
            .frame(height: ComposerSendButton.glyph)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!action.isEnabled)
        .help(action.help)
    }
}
