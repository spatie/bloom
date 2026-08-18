import SwiftUI

/// A list above and a detail below, with the list giving up room as soon as there is something
/// to show underneath it.
struct VSplitLayout<Top: View, Bottom: View>: View {
    // The built views rather than the builders. Storing an escaping `@ViewBuilder` closure on a
    // view keeps it alive across updates for no benefit; the synthesized initializer still takes
    // the trailing closures at the call site.
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    var hasBottom: Bool

    var body: some View {
        VStack(spacing: 0) {
            top
                .frame(maxHeight: hasBottom ? InspectorLayout.listHeight : .infinity)
            if hasBottom {
                Hairline()
                bottom
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
