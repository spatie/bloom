import Foundation

/// One candidate for an `@mention`.
///
/// The directory is carried separately from the file name because the menu shows them with
/// different weight: people recognise `Store.swift` first and only then care which folder it came
/// from. It lived beside the completion menu, which put the ranking a keystroke rides on where
/// no test could reach it; it is a pure function of the tracked paths and the query, so it lives
/// with `FuzzyMatch` instead.
public struct FileMatch: Identifiable, Hashable, Sendable {
    /// Path relative to the workspace root, which is exactly what gets inserted in the draft.
    public var path: String
    public var score: Int

    public var id: String { path }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var directory: String {
        (path as NSString).deletingLastPathComponent
    }

    /// Ranks the whole candidate list against what the user typed after the `@`.
    ///
    /// Pure and nonisolated so it can run off the main actor: a large repository has tens of
    /// thousands of tracked files and this is called on every keystroke.
    public nonisolated static func search(_ paths: [String], query: String, limit: Int) -> [FileMatch] {
        guard !query.isEmpty else {
            return paths.prefix(limit).map { FileMatch(path: $0, score: 0) }
        }

        var found: [FileMatch] = []
        found.reserveCapacity(min(paths.count, limit * 4))

        for path in paths {
            guard let score = FuzzyMatch.score(path, query: query) else { continue }
            // A hit inside the file name beats one that only matched folder names, because people
            // type the file they are thinking of, not the folder it lives in.
            let nameBonus = FuzzyMatch.score((path as NSString).lastPathComponent, query: query) ?? 0
            found.append(FileMatch(path: path, score: score + nameBonus))
        }

        found.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
        return Array(found.prefix(limit))
    }
}
