import SwiftUI
import BloomCore

struct FileIconsSettingsSection: View {
    @AppStorage(FileIconPack.defaultsKey) private var storedChoice = FileIconPack.defaultChoice.rawValue
    private var choice: FileIconPack { FileIconPack.resolve(storedChoice) }
    private var library: FileIconPackLibrary { FileIconThemeModel.shared.library }

    var body: some View {
        Section("All files icons") {
            Picker("Icon pack", selection: selection) {
                ForEach(FileIconPack.allCases) { pack in
                    Text(pack.title).tag(pack.rawValue)
                }
            }
            Text("vscode-icons is selected by default. Each pack downloads once when selected, then works offline.")
                .settingsFootnote()
            if library.loading.contains(choice) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Installing \(choice.title)…").foregroundStyle(.secondary)
                }
            } else if let error = library.errors[choice] {
                Text("Could not install \(choice.title): \(error)")
                    .foregroundStyle(.red)
                    .settingsFootnote()
                Button("Retry installation") { library.prepare(choice, retry: true) }
            } else if library.packs[choice] != nil {
                Text("Installed").settingsFootnote()
            }
            if let download = choice.download {
                Link("\(choice.title) · Icon credits and licences", destination: download.marketplaceURL)
                    .settingsFootnote()
            }
        }
        .task(id: choice) { library.prepare(choice) }
    }

    private var selection: Binding<String> {
        Binding(get: { choice.rawValue }, set: { storedChoice = $0 })
    }
}
