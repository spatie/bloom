import SwiftUI
import BloomCore

/// The marks a quick prompt can be given: a couple of dozen SF Symbols and no search.
///
/// **Drawn inside the form rather than floating behind an icon well.** The form is already inside
/// the composer's popover, and a second popover opened from within the first is an argument about
/// which of the two owns the next click, which is the same reason the row carries a pencil instead
/// of a menu. Eighteen symbols are one band of six by three, so the whole choice is on screen and
/// nothing is hidden behind a control that would have to be opened.
///
/// The point of the mark is telling five rows apart at a glance rather than expressing anything,
/// which is why there is no symbol browser: picking from six thousand would be a bigger decision
/// than the prompt itself.
struct QuickPromptSymbolGrid: View {
    @Binding var symbol: String

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Metrics.spacingSmall), count: 6
    )

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: Metrics.spacingSmall) {
            ForEach(QuickPrompt.symbols, id: \.self) { name in
                Button {
                    symbol = name
                } label: {
                    Image(systemName: name)
                        .imageScale(.small)
                        .foregroundStyle(
                            name == symbol ? Palette.selectedEmphasizedText : Palette.textSecondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.rowHeight - Metrics.spacingSmall)
                        .background {
                            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                                .fill(name == symbol ? Palette.selectedEmphasized : Palette.surfaceSunken)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(name == symbol ? .isSelected : [])
            }
        }
    }
}
