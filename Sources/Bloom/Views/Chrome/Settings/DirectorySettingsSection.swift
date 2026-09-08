import SwiftUI
import BloomCore

struct DirectorySettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var preferences = DirectoryPreferences()
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        Section("Project folders") {
            folderRow("New projects", path: preferences.projects, fallback: "Automatic",
                      message: "Choose where new projects are created.") {
                preferences.projects = $0
            }
            ForEach(preferences.additionalProjects, id: \.self) { path in
                HStack {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { preferences.additionalProjects.removeAll { $0 == path } }
                }
            }
            Button("Add Search Folder…") {
                Task {
                    guard let path = await ProjectFolderPicker.chooseTarget(
                        startingAt: nil, message: "Choose a folder containing your projects."
                    ),
                          !preferences.additionalProjects.contains(path) else { return }
                    preferences.additionalProjects.append(path)
                }
            }
            Text("Autocomplete also searches beside projects you have already added.")
                .settingsFootnote()
        }
        .disabled(!isLoaded)

        Section("Ask Bloom") {
            folderRow("Working directory", path: preferences.ask, fallback: "Bloom’s own folder",
                      message: "Choose the working directory for new Ask Bloom conversations.") {
                preferences.ask = $0
            }
            Text("New conversations start here. Existing conversations keep their working directory.")
                .settingsFootnote()
            if let error { Text(error).foregroundStyle(Palette.negative) }
        }
        .disabled(!isLoaded)
        .task {
            guard !isLoaded, let store = app.store else { return }
            preferences = await DirectoryPreferences.load(from: store)
            isLoaded = true
        }
        .onChange(of: preferences) { _, updated in
            guard isLoaded, let store = app.store else { return }
            let pending = saveTask
            saveTask = Task {
                await pending?.value
                do {
                    try await updated.save(to: store)
                    error = nil
                } catch {
                    self.error = error.readableMessage
                }
            }
        }
    }

    private func folderRow(
        _ title: String, path: String, fallback: String, message: String, set: @escaping (String) -> Void
    ) -> some View {
        SettingsRow(title) {
            HStack {
                Text(path.isEmpty ? fallback : (path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).help(path)
                Spacer()
                if !path.isEmpty { Button("Reset") { set("") } }
                Button("Choose…") {
                    Task {
                        if let chosen = await ProjectFolderPicker.chooseTarget(startingAt: path, message: message) { set(chosen) }
                    }
                }
            }
        }
    }
}
