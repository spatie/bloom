import SwiftUI

/// Keeps low-information screens visually consistent so every feature does not invent its own
/// placeholder.
///
/// A thin skin over `ContentUnavailableView`, which is the system's own empty state: it wraps its
/// message instead of demanding one long line (the hand-built stack this replaced forced the
/// inspector wider than its own pane and was then clipped), and it follows the platform's spacing
/// and text styles for free.
struct EmptyStateView: View {
    let glyph: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: glyph)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    // Tinted explicitly, like every other prominent button in the app: untinted
                    // it follows the system accent and renders as grey glass on macOS 26.
                    .tint(Palette.accentFill)
            }
        }
    }
}
