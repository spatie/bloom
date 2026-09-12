import SwiftUI
import BloomUI

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
        BloomDiffHunkHeader(
            spacing: InspectorLayout.gap, inset: CodeMetrics.textInset,
            width: width, height: CodeMetrics.rowHeight,
            foreground: Palette.textTertiary, surface: Palette.surfaceSunken
        ) {
            Image(systemName: "curlybraces").font(Typo.micro).imageScale(.small)
        } title: {
            Text(text).font(Typo.codeTiny)
        }
    }
}
