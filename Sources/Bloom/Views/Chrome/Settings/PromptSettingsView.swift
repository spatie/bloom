import SwiftUI
import BloomCore

struct PromptSettingsView: View {
    @State private var selection: PromptID? = .createPullRequest
    @State private var customised: Set<PromptID> = []

    private var definition: PromptDefinition {
        PromptRegistry.definition(for: selection ?? .createPullRequest)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(PromptRegistry.all) { prompt in
                    VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                        Text(prompt.title)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(customised.contains(prompt.id) ? "Customised" : "Default")
                            .font(Typo.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Metrics.spacingSmall)
                    .tag(prompt.id)
                }
            }
            .listStyle(.plain)
            .frame(width: 180)
            .accessibilityLabel("Workflow prompts")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gutter) {
                    Text(definition.title)
                        .font(Typo.bodyEmphasis)

                    PromptEditor(definition: definition) {
                        refreshStatuses()
                    }
                    // A different prompt must never inherit the previous editor's draft or focus.
                    .id(definition.id)

                    Text("Changes save automatically and apply the next time Bloom uses this prompt.")
                        .settingsFootnote()
                }
                .padding(Metrics.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: refreshStatuses)
    }

    private func refreshStatuses() {
        let overrides = PromptOverrides()
        customised = Set(PromptRegistry.all.filter { overrides.isCustomised(for: $0.id) }.map(\.id))
    }
}
