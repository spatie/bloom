import SwiftUI
import BloomCore

/// A workspace's name, which resolves out of a scramble on the one occasion Bloom renames it.
///
/// A drop-in for `Text(workspace.name)`. It is a `View` rather than a `Text`, but every modifier
/// the call sites use on it (`font`, `fontWeight`, `lineLimit`, `truncationMode`, `foregroundStyle`)
/// travels through the environment, so adopting it is one word at the call site and nothing else.
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
    let workspaceID: String
    let name: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: String?

    init(_ workspace: Workspace) {
        self.workspaceID = workspace.id
        self.name = workspace.name
    }

    init(workspaceID: String, name: String) {
        self.workspaceID = workspaceID
        self.name = name
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
