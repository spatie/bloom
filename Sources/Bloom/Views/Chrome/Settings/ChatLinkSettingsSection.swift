import SwiftUI
import BloomCore

struct ChatLinkSettingsSection: View {
    @AppStorage(TranscriptLinkPreferences.key) private var schemes = ""

    var body: some View {
        ChatLinkSettingsContent(schemes: $schemes)
    }
}

/// The live settings controls, also used by the isolated capture gallery.
struct ChatLinkSettingsContent: View {
    @Binding var schemes: String

    private var allowed: Set<String> { TranscriptLinkPreferences.schemes(in: schemes) }

    private var ignored: [String] {
        schemes.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map(String.init)
            .filter { TranscriptLinkPreferences.additionalScheme($0) == nil }
    }

    var body: some View {
        Section {
            SettingsRow("Allowed schemes") {
                TextField("Allowed schemes", text: $schemes, prompt: Text("None"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Allowed app link schemes")
            }
            SettingsRow("Suggestions") {
                HStack(spacing: Metrics.spacingSmall) {
                    ForEach(TranscriptLinkPreferences.suggestions, id: \.self) { scheme in
                        Button(scheme) {
                            schemes = (allowed.union([scheme])).sorted().joined(separator: ", ")
                        }
                        .disabled(allowed.contains(scheme))
                        .accessibilityLabel("Allow \(scheme) links")
                    }
                }
            }
            if !ignored.isEmpty {
                Text("Ignored schemes: \(ignored.joined(separator: ", ")).")
                    .settingsFootnote()
            }
        } header: {
            Text("App links in chat")
        } footer: {
            Text("Allow chat links to open these apps when clicked. Separate scheme names with commas. Empty by default. Web and email links keep working. file, javascript and Bloom's own schemes are always blocked.")
                .settingsFootnote()
        }
    }
}
