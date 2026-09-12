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

    static func lookupInDiff(at offset: Int, view: CodeTextView, lines: [DiffLine?], source: String,
                             path: String, model: WorkspaceModel, references: Bool, automatic: Bool,
                             newTab: Bool, onOpen: @escaping (CodeLocation, Bool) -> Void) {
        let state = model.paneStores.sourceFile((model.workspace.path as NSString).appendingPathComponent(path))
        state.navigationTask?.cancel()
        guard let sourceOffset = DiffDocument.sourceOffset(in: lines, offset: offset, source: source) else {
            state.message = "This diff line is not in the current file. Open the current source to navigate."
            return
        }
        lookup(at: sourceOffset, path: path, model: model, state: state, references: references,
               findUsagesAtDefinition: automatic, newTab: newTab, fallbackReference: view.reference(at: offset), sourceOverride: source,
               anchor: view, anchorOffset: offset, onOpen: onOpen)
    }

    private static func lookup(at offset: Int, path: String, model: WorkspaceModel, state: SourceEditorState, references: Bool, findUsagesAtDefinition: Bool = false, newTab: Bool = false, fallbackReference: String? = nil, sourceOverride: String? = nil, anchor: CodeTextView? = nil, anchorOffset: Int? = nil, onOpen: ((CodeLocation, Bool) -> Void)? = nil) {
        guard let source = sourceOverride ?? state.textView?.string else { return }
        let textView = anchor ?? state.textView
        let displayed = textView?.string
        let openResult = onOpen ?? { open($0, model: model, newTab: $1) }
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
                guard textView?.window != nil, textView?.string == displayed else {
                    state.message = "The file changed during the lookup. Try again."
                    return
                }
                state.message = locations.isEmpty ? (showsUsages ? "No usages found at this position." : "No definition found at this position.") : nil
                if locations.count == 1, let location = locations.first { openResult(location, newTab) } else if !locations.isEmpty {
                    textView?.showDefinitions(locations, root: model.workspace.path, offset: anchorOffset ?? offset, title: showsUsages ? "Usages" : "Definitions") { location in
                        openResult(location, newTab)
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
