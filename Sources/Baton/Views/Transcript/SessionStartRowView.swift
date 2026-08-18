import SwiftUI
import BatonCore

/// The line that opens a session.
///
/// The CLI reports what it started with as storage identifiers (`opus-5-1m`, `acceptEdits`), and
/// those are not words. They are shown the way the composer's own pickers show them, so the same
/// setting reads the same everywhere in the app.
struct SessionStartRowView: View {
    var info: AgentInit

    private var modelLabel: String {
        ComposerOption.label(for: info.model, in: ComposerOption.models)
    }

    private var permissionLabel: String {
        PermissionMode(rawValue: info.permissionMode)?.label ?? ComposerOption.titleCased(info.permissionMode)
    }

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "bolt.horizontal.circle")

            Text("Session started")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: TranscriptLayout.labelWidth, alignment: .leading)

            if !info.model.isEmpty {
                Chip(text: modelLabel)
            }
            if !info.permissionMode.isEmpty {
                Chip(text: permissionLabel)
            }

            Spacer(minLength: 0)
        }
        .transcriptRowFrame()
    }
}
