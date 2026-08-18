import Testing
import Foundation
@testable import BloomCore

/// The preview under the "files to copy" field is only worth showing if it agrees with the copier
/// exactly. A preview that is cleverer than the thing it previews is a lie in a new direction.
@Suite("Files to copy", .scratchDirectory)
struct FilesToCopyPlanTests {
    private func makeRepo(files: [String] = [], directories: [String] = []) throws -> String {
        let root = TestScratch.unique("bloom-globs")
        let manager = FileManager.default
        try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
        for directory in directories {
            try manager.createDirectory(
                atPath: (root as NSString).appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        for file in files {
            let full = (root as NSString).appendingPathComponent(file)
            try manager.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try "x".write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("the default pattern finds the env files and nothing else")
    func defaultPattern() throws {
        let repo = try makeRepo(files: [".env", ".env.local", "README.md", "src/.env"])

        let plan = FilesToCopyResolver.resolve(patterns: [".env*"], in: repo)

        #expect(plan.matches.map(\.path) == [".env", ".env.local"])
        #expect(plan.fileCount == 2)
        #expect(plan.unmatchedPatterns.isEmpty)
    }

    @Test("a pattern with a directory in it searches that directory")
    func patternWithADirectory() throws {
        let repo = try makeRepo(files: ["certs/one.pem", "certs/two.pem", "certs/notes.txt"])

        let plan = FilesToCopyResolver.resolve(patterns: ["certs/*.pem"], in: repo)

        #expect(plan.matches.map(\.path) == ["certs/one.pem", "certs/two.pem"])
    }

    @Test("a pattern that matches nothing is named, rather than silently contributing nothing")
    func unmatchedPatternsAreReported() throws {
        let repo = try makeRepo(files: [".env"])

        let plan = FilesToCopyResolver.resolve(patterns: [".env*", "*.pem", "nope/*"], in: repo)

        #expect(plan.fileCount == 1)
        #expect(plan.unmatchedPatterns == ["*.pem", "nope/*"])
    }

    @Test("a directory that matches is listed as matched but not counted as copied")
    func directoriesAreMatchedAndSkipped() throws {
        let repo = try makeRepo(files: [".env"], directories: [".envs"])

        let plan = FilesToCopyResolver.resolve(patterns: [".env*"], in: repo)

        #expect(plan.fileCount == 1)
        #expect(plan.directoryCount == 1)
        #expect(plan.matches.first { $0.isDirectory }?.path == ".envs")
    }

    @Test("two patterns matching the same file count it once, as the copier copies it once")
    func overlappingPatternsDoNotDoubleCount() throws {
        let repo = try makeRepo(files: [".env"])

        let plan = FilesToCopyResolver.resolve(patterns: [".env*", ".env"], in: repo)

        #expect(plan.fileCount == 1)
        #expect(plan.matches.count == 1)
    }

    @Test("a repository that is no longer on disk says so instead of blaming the patterns")
    func missingRepositoryIsItsOwnAnswer() {
        let plan = FilesToCopyResolver.resolve(patterns: [".env*"], in: "/nowhere/at/all")

        #expect(plan.repoExists == false)
        #expect(plan.fileCount == 0)
        #expect(plan.unmatchedPatterns.isEmpty)
    }

    @Test("a pattern matching thousands of files is capped, and says that it was")
    func hugeResultsAreCapped() throws {
        let repo = try makeRepo()
        for index in 0..<500 {
            try "x".write(
                toFile: (repo as NSString).appendingPathComponent("file\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let plan = FilesToCopyResolver.resolve(patterns: ["*.txt"], in: repo, limit: 50)

        #expect(plan.fileCount == 500)
        #expect(plan.matches.count == 50)
        #expect(plan.isTruncated)
    }

    /// The whole reason the resolver exists as a separate function rather than as a call into the
    /// copier: the copier writes files, and a preview that ran on every keystroke must not.
    @Test("the preview names exactly the files the copier copies", .tags(.destructive))
    func filesToCopyMatchesTheCopier() async throws {
        let repo = try makeRepo(
            files: [".env", ".env.local", "certs/one.pem", "certs/two.pem", "README.md", "src/.env"],
            directories: [".envs"]
        )
        let destination = TestScratch.unique("bloom-globs-dest")
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        let patterns = [".env*", "certs/*.pem", "*.nothing"]
        let manager = WorkspaceManager(store: try makeTestStore("globs"))
        try manager.copyFiles(patterns, from: repo, to: destination)

        var copied: [String] = []
        let walker = FileManager.default.enumerator(atPath: destination)
        while let entry = walker?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            let full = (destination as NSString).appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
                copied.append(entry)
            }
        }

        let plan = FilesToCopyResolver.resolve(patterns: patterns, in: repo)
        #expect(plan.matches.filter { !$0.isDirectory }.map(\.path).sorted() == copied.sorted())
    }
}
