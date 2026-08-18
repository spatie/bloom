import SwiftUI
import BloomCore

/// The wording Bloom sends to a coding agent when a button in the app stands in for a sentence the
/// user would otherwise have typed.
///
/// The form is generated from `PromptRegistry.all` rather than written out per prompt, so a second
/// prompt is one entry in that array and no work here at all.
struct PromptSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("""
                Some buttons in Bloom do their work by asking the workspace's agent, rather than \
                running the command themselves. The agent already knows this project's commit \
                conventions and its pull request template, which Bloom does not. These are the \
                words it is sent. Each request appears in the transcript and streams back like \
                anything you type yourself.
                """)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(PromptRegistry.all) { definition in
                Section(definition.title) {
                    PromptEditor(definition: definition)
                }
            }
        }
        .formStyle(.grouped)
    }
}
