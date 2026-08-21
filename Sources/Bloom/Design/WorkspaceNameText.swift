import SwiftUI
import BloomCore

/// A workspace's name, which resolves out of a scramble on the one occasion Bloom renames it.
///
/// A drop-in for `Text(workspace.name)`. It is a `View` rather than a `Text`, but every modifier
/// the call sites use on it (`font`, `lineLimit`, `truncationMode`, `foregroundStyle`) travels
/// through the environment, so adopting it is one word at the call site and nothing else.
///
/// ## The one thing it decides for itself is the weight
///
/// A workspace with a finished turn nobody has read is set heavier than one without, and that is
/// the same fact in the sidebar and on Home. It is settled here rather than at the two call sites
/// because that is exactly how the two came apart: the sidebar asked for `.medium`, Home was
/// written later and asked for `.semibold`, and the same workspace was a different weight in two
/// lists two hundred points apart. Whether a row is unread is still the caller's to say. What
/// that looks like is not.
///
/// ## Why it never changes the row's layout
///
/// Two things. Every frame `ScrambleReveal` produces has exactly as many characters as the final
/// name, with whitespace and punctuation left where they are. And the view is sized by a hidden
/// copy of the final name, with the animated copy drawn over it and clipped, so even a scramble
/// whose glyphs happen to be a shade wider cannot push the row's diff counts or its pin sideways.
/// The scramble alphabet leaves out the letters that are far off the mean width, so what is left
/// inside that fixed box barely breathes either.
///
/// ## Reduce Motion
///
/// Skipped outright, not shortened. The whole effect is motion for its own sake, and half of a
/// decorative animation is worse than none.
struct WorkspaceNameText: View {
    let workspaceID: WorkspaceID
    let name: String
    /// Whether this row has finished work nobody has read yet.
    ///
    /// Passed in rather than read off the workspace, because the flag alone is not the question in
    /// every list. Home lists archived workspaces, whose `unread` is a leftover with nothing
    /// behind it, and it says so by handing this `false`. See `HomeListRow`.
    let isUnread: Bool

    /// What an unread row's name weighs. The sidebar's value, which is the one the owner asked
    /// Home to match, and a step rather than a shout: on a list where a third of the rows can be
    /// unread at once, bold is a paragraph in bold.
    private static let unreadWeight: Font.Weight = .medium

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: String?

    init(_ workspace: Workspace, isUnread: Bool) {
        self.workspaceID = workspace.id
        self.name = workspace.name
        self.isUnread = isUnread
    }

    init(workspaceID: WorkspaceID, name: String, isUnread: Bool = false) {
        self.workspaceID = workspaceID
        self.name = name
        self.isUnread = isUnread
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The sizer. Never drawn, and it is what the row measures, so the box does not move
            // while the letters inside it churn.
            Text(name)
                .hidden()
                .accessibilityHidden(true)

            Text(frame ?? name)
                // VoiceOver is given the finished name throughout. Reading a scramble aloud would
                // be the one way this ornament could actively cost somebody something.
                .accessibilityLabel(name)
        }
        // On the stack rather than on the drawn copy, so the hidden sizer is measured at the same
        // weight. Set on the visible `Text` alone, an unread name would be measured light and
        // drawn heavy, and the last letter of every unread row would be clipped.
        .fontWeight(isUnread ? Self.unreadWeight : .regular)
        .clipped()
        .task(id: reveal?.id) { await play() }
    }

    private var reveal: WorkspaceNameReveal? {
        WorkspaceNameReveals.shared.reveal(for: workspaceID, showing: name)
    }

    private func play() async {
        guard let reveal, !reduceMotion else {
            frame = nil
            return
        }

        for step in 0...ScrambleReveal.steps {
            frame = ScrambleReveal.frame(target: name, step: step, seed: reveal.seed)
            guard step < ScrambleReveal.steps else { break }
            try? await Task.sleep(for: ScrambleReveal.interval)
            if Task.isCancelled { break }
        }

        // Back to drawing the plain name, so nothing downstream is ever looking at a copy.
        frame = nil
    }
}
