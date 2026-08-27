import SwiftUI

/// The `@@` line, showing the enclosing function git found. Quiet, because it is orientation
/// rather than content.
///
/// The glyph is the enclosing scope, which is what the line says whenever git can name one. It
/// used to be a left-and-right arrow, which on a band directly above a diff that really does
/// scroll sideways read as a scrolling hint.
///
/// Which hunks get one at all is `DiffHunkHeading`, not this view: only the ones the reader
/// reaches after lines the pane did not print.
struct DiffHunkHeaderView: View {
    var text: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "curlybraces")
                .font(Typo.micro)
                .imageScale(.small)
                // Decoration: the scope is in the text beside it, and every comparable glyph down
                // this column is already hidden.
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.codeTiny)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, CodeMetrics.textInset)
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        .background(Palette.surfaceSunken)
    }
}
