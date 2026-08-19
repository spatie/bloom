import Foundation

/// What "files to copy" would actually copy, worked out against the repository on disk.
///
/// A glob you cannot see the effect of is a guess, and this one is a guess with consequences: the
/// files it names are the gitignored ones a new worktree needs to run at all, so getting it wrong
/// shows up much later as a workspace that will not boot. Resolving it while the pattern is being
/// typed turns the field into something that can be checked.
///
/// Deliberately a mirror of `WorkspaceManager.copyFiles` rather than a better matcher. A preview
/// that resolved more cleverly than the copier would be a lie in the opposite direction, so
/// `filesToCopyMatchesTheCopier` in the test suite pins the two together against the real thing.
public struct FilesToCopyPlan: Sendable, Hashable {
    public struct Match: Sendable, Hashable, Identifiable {
        /// Relative to the repository root, which is how the pattern is written.
        public var path: String
        public var bytes: Int64
        /// Matched by the pattern, but skipped: the copier copies files, not trees.
        public var isDirectory: Bool

        public var id: String { path }

        public init(path: String, bytes: Int64, isDirectory: Bool) {
            self.path = path
            self.bytes = bytes
            self.isDirectory = isDirectory
        }
    }

    /// False when the repository folder has been moved or deleted since it was added. Every other
    /// field is then empty, and the screen says so rather than showing "0 files" as though the
    /// patterns were at fault.
    public var repoExists: Bool = true
    /// The matches, at most `limit` of them, sorted by path.
    public var matches: [Match] = []
    /// How many files would be copied, counting past `limit`.
    public var fileCount: Int = 0
    /// How many matched entries are directories, which are matched and then skipped.
    public var directoryCount: Int = 0
    /// Patterns that matched nothing at all. Usually a typo, sometimes just a file this machine
    /// has not created yet.
    public var unmatchedPatterns: [String] = []
    /// True when more matched than `matches` holds.
    public var isTruncated: Bool = false

    public init() {}
}

public enum FilesToCopyResolver {
    /// Enough to see that a pattern is doing what you meant, and few enough that a `*` pointed at
    /// `node_modules` cannot fill the window or the memory it is drawn from.
    public static let defaultLimit = 200

    /// Blocking filesystem work. Call it off the main actor.
    public static func resolve(
        patterns: [String],
        in repo: String,
        limit: Int = defaultLimit
    ) -> FilesToCopyPlan {
        var plan = FilesToCopyPlan()
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: repo, isDirectory: &isDirectory), isDirectory.boolValue else {
            plan.repoExists = false
            return plan
        }

        var seen = Set<String>()
        var found: [FilesToCopyPlan.Match] = []

        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let directory = (trimmed as NSString).deletingLastPathComponent
            let filePattern = (trimmed as NSString).lastPathComponent
            let searchDirectory = directory.isEmpty
                ? repo
                : (repo as NSString).appendingPathComponent(directory)

            guard let entries = try? manager.contentsOfDirectory(atPath: searchDirectory) else {
                plan.unmatchedPatterns.append(trimmed)
                continue
            }

            var matchedAnything = false
            for entry in entries where matches(entry, pattern: filePattern) {
                let relative = directory.isEmpty ? entry : "\(directory)/\(entry)"
                let absolute = (searchDirectory as NSString).appendingPathComponent(entry)

                var entryIsDirectory: ObjCBool = false
                guard manager.fileExists(atPath: absolute, isDirectory: &entryIsDirectory) else { continue }
                matchedAnything = true
                guard seen.insert(relative).inserted else { continue }

                if entryIsDirectory.boolValue {
                    plan.directoryCount += 1
                    found.append(.init(path: relative, bytes: 0, isDirectory: true))
                    continue
                }

                plan.fileCount += 1
                let size = try? manager.attributesOfItem(atPath: absolute)[.size]
                found.append(
                    .init(path: relative, bytes: (size as? NSNumber)?.int64Value ?? 0, isDirectory: false)
                )
            }

            if !matchedAnything { plan.unmatchedPatterns.append(trimmed) }
        }

        found.sort { $0.path < $1.path }
        plan.isTruncated = found.count > limit
        plan.matches = Array(found.prefix(limit))
        return plan
    }

    /// The copier's own rule: a pattern with no wildcard is an exact name, and anything else goes
    /// to `fnmatch`, which is why `.env*` matches `.env.local` and `src/*.pem` searches `src`.
    public static func matches(_ name: String, pattern: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else { return name == pattern }
        return fnmatch(pattern, name, 0) == 0
    }
}
