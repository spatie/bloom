import SwiftUI
import BloomCore

/// The panel that opens over the composer while the user is typing an `@mention`.
///
/// It renders and nothing else. Selection and the arrow keys live in `ComposerView`, because the
/// text view keeps first responder the whole time and is the only thing that sees the key events.
struct FileMentionMenu: View {
    var matches: [FileMatch]
    var query: String
    var selectedIndex: Int
    /// What the room on the menu's side of the composer allows. The default is the cap a menu
    /// keeps even with a whole transcript above it.
    var maxHeight: CGFloat = MenuLayout.maxHeight
    var onPick: @MainActor (FileMatch) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    var body: some View {
        MenuPanel {
            if matches.isEmpty {
                MenuEmptyRow(
                    text: query.isEmpty ? "No files in this workspace" : "No file matches \(query)"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                                FileMentionRow(
                                    match: match,
                                    isSelected: index == selectedIndex,
                                    onPick: { onPick(match) },
                                    onHover: { onHighlight(index) }
                                )
                                .id(index)
                            }
                        }
                        .padding(Metrics.spacingSmall)
                    }
                    .frame(maxHeight: maxHeight)
                    // No anchor, so the arrow keys scroll the least they can get away with.
                    // Pinning to the bottom threw the highlighted row to the far edge every time
                    // the user stepped upwards, which no Mac menu does.
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }
        }
    }
}
