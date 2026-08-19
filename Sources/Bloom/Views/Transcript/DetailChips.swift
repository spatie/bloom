import SwiftUI

/// The optional arguments of a tool call: a timeout, a glob, whether it ran in the background.
///
/// Written as text rather than as plated chips. A chip is how this app draws a thing you can pick
/// up: a file, a model, a permission mode. A timeout is a footnote to the command above it, and
/// on a plate it read as the loudest thing in an open row while saying the least.
struct DetailChips: View {
    var values: [String?]

    private var present: [String] {
        values.compactMap(\.self).filter { !$0.isEmpty }
    }

    var body: some View {
        if !present.isEmpty {
            Text(present.joined(separator: "  ·  "))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}
