import Foundation
import Observation
import BloomCore

/// Each opening captures its workspace so an index arriving late cannot open another project's file.
@MainActor
@Observable
final class FileSearchModel {
    let workspace: Workspace
    private(set) var query = ""
    var highlighted: Int?
    private(set) var matches: [FileMatch] = []
    private(set) var isLoading = true

    init(workspace: Workspace) { self.workspace = workspace }

    func type(_ text: String) {
        guard query != text else { return }
        query = text
        // Return must never open a result for the previous query while the new search starts.
        matches = []
        highlighted = nil
        isLoading = true
    }

    func search() async {
        isLoading = true
        matches = []
        highlighted = nil
        let query = FileNeedle.canonical(CodeLocation.parse(query).path)
        let paths = await FileIndex.shared.files(workspacePath: workspace.path)
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) {
            FileMatch.search(paths, query: query, limit: 100)
        }.value
        guard !Task.isCancelled else { return }
        matches = found
        highlighted = found.isEmpty ? nil : 0
        isLoading = false
    }

    func move(_ key: ListKey) {
        highlighted = ListNavigation.destination(for: key, from: highlighted, count: matches.count)
    }

    var selected: FileMatch? {
        guard let highlighted, matches.indices.contains(highlighted) else { return nil }
        return matches[highlighted]
    }
}
