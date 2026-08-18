import SwiftUI

/// The optional arguments of a tool call: a timeout, a glob, whether it ran in the background.
struct DetailChips: View {
    var values: [String?]

    private var present: [String] {
        values.compactMap(\.self).filter { !$0.isEmpty }
    }

    var body: some View {
        if !present.isEmpty {
            HStack(spacing: TranscriptLayout.tight * 2) {
                ForEach(present, id: \.self) { value in
                    Chip(text: value)
                }
            }
        }
    }
}
