import SwiftUI

/// The always-visible line of a row that opens, as a real button.
///
/// Only the header toggles, never the whole row. An expanded row holds selectable output, and a
/// click that lands there to select a line must not fold the row away under the pointer. A button
/// rather than a tap gesture, so the row answers to VoiceOver and to the keyboard.
struct ExpandableRowHeader<Content: View>: View {
    var isExpanded: Bool
    var onToggle: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: onToggle) {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapses this row" : "Expands this row")
    }
}
