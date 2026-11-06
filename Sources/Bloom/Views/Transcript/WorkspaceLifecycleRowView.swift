import SwiftUI
import BloomCore

struct WorkspaceLifecycleRowView: View {
    var note: WorkspaceLifecycleNote

    private var label: String {
        switch note.event {
        case .archived: "Archived"
        case .restored: "Restored"
        }
    }

    private var symbol: String {
        switch note.event {
        case .archived: "archivebox"
        case .restored: "arrow.uturn.backward"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: symbol, tint: Palette.textTertiary)

            Text(label)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .transcriptLabelColumn(label, font: Typo.label)

            Text(note.sentence)
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .transcriptRowFrame()
        .accessibilityElement(children: .combine)
    }
}
