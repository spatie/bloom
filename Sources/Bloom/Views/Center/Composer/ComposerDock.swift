import SwiftUI

/// A floating writing surface. Its clearance belongs to the transcript document, so the
/// newest message clears the glass without shortening the viewport while reading history.
struct ComposerDock<Content: View>: View {
    var showsJumpToNewest: Bool
    var onJumpToNewest: @MainActor @Sendable () -> Void
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: Metrics.spacingSmall) {
            VStack(spacing: Metrics.spacingWide) {
                if showsJumpToNewest {
                    JumpToNewestPill(action: onJumpToNewest)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                }

                content
            }
        }
        .animation(reduceMotion ? nil : Motion.pane, value: showsJumpToNewest)
    }
}

enum ComposerLayout {
    static let corner: CGFloat = 22
    static let horizontalInset: CGFloat = 16
    static let bottomInset: CGFloat = 14
    static let textClearance: CGFloat = 12
}

extension EnvironmentValues {
    /// Absent on archived transcripts and other read-only presentations.
    @Entry var composerRoom: ComposerRoom?
}
