import Foundation
import BloomCore

@MainActor
enum SourceActions {
    static func open(_ reference: String, at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState, newTab: Bool = false) {
        let language = state.languageOverride ?? Language.detect(path: path)
        if language == .php || language == .blade {
            lookup(at: offset, path: path, model: model, state: state, references: false, newTab: newTab, fallbackReference: reference)
            return
        }
        state.navigationTask?.cancel()
        state.navigationTask = Task {
            let paths = await FileIndex.shared.files(workspacePath: model.workspace.path)
            guard !Task.isCancelled else { return }
            if let location = SourceSearch.resolve(reference, from: path, root: model.workspace.path, paths: paths) {
                state.message = nil
                open(location, model: model, newTab: newTab)
            } else { state.message = "No workspace file matches \(reference)." }
        }
    }

    static func definition(at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState) {
        lookup(at: offset, path: path, model: model, state: state, references: false)
    }

    static func references(at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState) {
        lookup(at: offset, path: path, model: model, state: state, references: true)
    }

    static func navigate(at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState, newTab: Bool = false) {
        lookup(at: offset, path: path, model: model, state: state, references: false, findUsagesAtDefinition: true, newTab: newTab)
    }

    private static func lookup(at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState, references: Bool, findUsagesAtDefinition: Bool = false, newTab: Bool = false, fallbackReference: String? = nil) {
        guard let source = state.textView?.string else { return }
        state.navigationTask?.cancel()
        state.message = references ? "Finding usages…" : "Finding definition…"
        state.navigationTask = Task {
            do {
                let language = state.languageOverride ?? Language.detect(path: path)
                let server = await SourceLanguageServers.shared.server(root: model.workspace.path, language: language)
                var showsUsages = references
                var found: [CodeLocation]
                if references {
                    found = try await server.references(root: model.workspace.path,
                        path: path, text: source, offset: offset, language: language)
                } else {
                    do {
                        found = try await SourceLanguageServers.shared.definition(root: model.workspace.path,
                            path: path, text: source, offset: offset, language: language)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard let fallbackReference else { throw error }
                        let paths = await FileIndex.shared.files(workspacePath: model.workspace.path)
                        guard let location = SourceSearch.resolve(fallbackReference, from: path, root: model.workspace.path, paths: paths) else { throw error }
                        found = [location]
                    }
                    if found.isEmpty, let fallbackReference {
                        let paths = await FileIndex.shared.files(workspacePath: model.workspace.path)
                        if let location = SourceSearch.resolve(fallbackReference, from: path, root: model.workspace.path, paths: paths) { found = [location] }
                    }
                }
                try Task.checkCancellation()
                if findUsagesAtDefinition, found.contains(where: {
                    $0.matchesSymbol(path: path, root: model.workspace.path, text: source, offset: offset)
                }) {
                    showsUsages = true
                    state.message = "Finding usages…"
                    found = try await server.references(root: model.workspace.path,
                        path: path, text: source, offset: offset, language: language)
                }
                let locations = await CodeLocation.suggestions(found, root: model.workspace.path)
                try Task.checkCancellation()
                guard state.textView?.string == source else {
                    state.message = "The file changed during the lookup. Try again."
                    return
                }
                state.message = locations.isEmpty ? (showsUsages ? "No usages found at this position." : "No definition found at this position.") : nil
                if locations.count == 1, let location = locations.first { open(location, model: model, newTab: newTab) } else if !locations.isEmpty {
                    state.textView?.showDefinitions(locations, root: model.workspace.path, offset: offset, title: showsUsages ? "Usages" : "Definitions") { location in
                        open(location, model: model, newTab: newTab)
                    }
                }
            } catch is CancellationError {
                // A newer navigation request owns the result now.
            } catch { state.message = error.localizedDescription }
        }
    }

    private static func open(_ location: CodeLocation, model: WorkspaceModel, newTab: Bool) {
        if newTab {
            let reference = "\(location.displayPath(relativeTo: model.workspace.path)):\(location.line):\(location.column)"
            FileReview.openInNewTab(path: reference, in: model)
        } else {
            FileReview.open(location: location, in: model)
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
