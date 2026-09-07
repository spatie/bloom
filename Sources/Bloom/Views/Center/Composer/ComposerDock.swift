import SwiftUI

/// A floating writing surface. Its clearance belongs to the transcript document, so the
/// newest message clears the glass without shortening the viewport while reading history.
struct ComposerDock<Content: View>: View {
    var showsJumpToNewest: Bool
    var onJumpToNewest: @MainActor @Sendable () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Metrics.spacingWide) {
            if showsJumpToNewest {
                JumpToNewestPill(action: onJumpToNewest)
            }

            content
        }
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
