import SwiftUI

/// A block of literal text inside an expanded row: a command, a file's new contents, one side of an
/// edit. Long blocks are cut until asked for, because the row is a detail view and not a pager.
struct DetailCodeBlock: View {
    var text: String
    var tint: Color = Palette.surfaceSunken

    @State private var showsAll = false

    var body: some View {
        if !text.isEmpty {
            let capped = TextCap.cap(text, lines: showsAll ? .max : TextCap.lineCap)

            VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
                Text(capped.text)
                    .font(Typo.code)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TranscriptLayout.inset)
                    .background(tint, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))

                if capped.truncated, !showsAll {
                    Button("Show all") { showsAll = true }
                        .buttonStyle(.link)
                        .font(Typo.caption)
                }
            }
        }
    }
}
