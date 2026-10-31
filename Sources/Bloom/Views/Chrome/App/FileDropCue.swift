import SwiftUI

/// Which chats have a composer that is the target of a drag right now, so the transcript that will
/// hold the file is blurred and the cue is drawn over it. The box itself is tinted by its own
/// `ComposerDropHint`.
///
/// Keyed by chat and counted by composer, for the reason `ComposerDropHint` has a flag per source:
/// a drag moving from one part of the window to another delivers the exit and the enter in no fixed
/// order. The answer is written only when it changes, so it costs two writes per drag.
@MainActor
@Observable
final class FileDropActivity {
    static let shared = FileDropActivity()

    private(set) var targetedKeys = Set<String>()
    @ObservationIgnored private var keyByHint: [ObjectIdentifier: String] = [:]

    func update(_ hint: ComposerDropHint, isActive active: Bool) {
        keyByHint[ObjectIdentifier(hint)] = active ? hint.sessionKey : nil
        refresh()
    }

    func forget(_ id: ObjectIdentifier) {
        keyByHint[id] = nil
        refresh()
    }

    private func refresh() {
        let keys = Set(keyByHint.values)
        guard keys != targetedKeys else { return }
        targetedKeys = keys
        TranscriptBlur.apply(to: keys)
    }
}

/// An arrow and the words over a chat's conversation area, with no border and no fill: the blur is
/// `TranscriptBlur`'s, on the transcript itself. The rest of the window stays as it is and the
/// composer, which is drawn above, stays sharp and is the part that is tinted.
///
/// Reads the activity itself so that nothing above it redraws.
struct FileDropChatCue: View {
    var sessionKey: String

    private let activity = FileDropActivity.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let symbolSize: CGFloat = 40

    var body: some View {
        let isTargeted = activity.targetedKeys.contains(sessionKey)
        ZStack {
            if isTargeted {
                VStack(spacing: Metrics.spacingWide) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: Self.symbolSize, weight: .light))
                        .foregroundStyle(Palette.accent)
                    Text("Drop to attach")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : Motion.pane, value: isTargeted)
    }
}

extension View {
    /// For the SwiftUI drawn over a transcript, which the AppKit blur behind it cannot reach: the
    /// empty state and the pinned question stayed sharp in front of a blurred conversation.
    func blursWhileFileDragged(into sessionKey: String) -> some View {
        modifier(BlursWhileFileDragged(sessionKey: sessionKey))
    }
}

private struct BlursWhileFileDragged: ViewModifier {
    var sessionKey: String
    private let activity = FileDropActivity.shared

    /// About what the system's visual effect view does to what it sits over.
    private static let radius: CGFloat = 10

    func body(content: Content) -> some View {
        content.blur(radius: activity.targetedKeys.contains(sessionKey) ? Self.radius : 0)
    }
}
