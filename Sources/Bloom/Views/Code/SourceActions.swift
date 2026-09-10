import Foundation
import BloomCore

@MainActor
enum SourceActions {
    static func open(_ reference: String, path: String, model: WorkspaceModel, state: SourceEditorState) {
        state.navigationTask?.cancel()
        state.navigationTask = Task {
            let paths = await FileIndex.shared.files(workspacePath: model.workspace.path)
            guard !Task.isCancelled else { return }
            if let location = SourceSearch.resolve(reference, from: path, root: model.workspace.path, paths: paths) {
                state.message = nil
                FileReview.open(location: location, in: model)
            } else { state.message = "No workspace file matches \(reference)." }
        }
    }

    static func definition(at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState) {
        guard let source = state.textView?.string else { return }
        state.navigationTask?.cancel()
        state.message = "Finding definition…"
        state.navigationTask = Task {
            do {
                let language = state.languageOverride ?? Language.detect(path: path)
                let server = await SourceLanguageServers.shared.server(root: model.workspace.path, language: language)
                let locations = try await server.definition(root: model.workspace.path,
                    path: path, text: source, offset: offset, language: language)
                try Task.checkCancellation()
                guard state.textView?.string == source else {
                    state.message = "The file changed during the lookup. Try Go to Definition again."
                    return
                }
                state.message = locations.isEmpty ? "No definition found at this position." : nil
                if locations.count == 1, let location = locations.first { FileReview.open(location: location, in: model) } else { state.definitions = locations }
            } catch is CancellationError {
                // A newer navigation request owns the result now.
            } catch { state.message = error.localizedDescription }
        }
    }

    static func ask(path: String, model: WorkspaceModel, state: SourceEditorState) {
        guard let context = state.selectedContext(path: path), let destination = model.reviewDestination else {
            state.message = "Select code and choose a conversation below to ask about it."
            return
        }
        model.prepareTranscript(for: destination.id)
        model.existingTranscript(for: destination.id)?.appendSourceContext(context)
    }
}
