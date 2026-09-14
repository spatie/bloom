import SwiftUI
import BloomCore

struct FileIconsSettingsSection: View {
    @AppStorage(VSCodeIconsInstaller.defaultsKey) private var enabled = false
    private var model: FileIconThemeModel { .shared }

    var body: some View {
        Section("All files icons") {
            if model.pack != nil {
                Toggle("Use vscode-icons", isOn: $enabled)
            } else {
                HStack {
                    Text("vscode-icons")
                    Spacer()
                    if model.isInstalling {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    } else {
                        Button("Install vscode-icons") { model.install() }
                    }
                }
            }
            Text("File and folder icons for the All files tree. Installing also enables the icons.")
                .settingsFootnote()
            if let error = model.error {
                Text(error).foregroundStyle(.red).settingsFootnote()
            }
            Link("vscode-icons · Icon credits and licences", destination: VSCodeIconsInstaller.marketplaceURL)
                .settingsFootnote()
        }
        .task { await model.load() }
    }
}
