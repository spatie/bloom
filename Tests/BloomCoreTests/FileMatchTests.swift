import Testing
@testable import BloomCore

/// The `@mention` ranking, which lived beside the completion menu until nothing could test it.
@Suite("File match")
struct FileMatchTests {
    private let paths = [
        "Sources/App/Store.swift",
        "Sources/App/StoreObservation.swift",
        "Tests/StoreTests.swift",
        "Sources/Design/Theme.swift",
        "README.md",
    ]

    @Test("An empty query offers the first files as they came, unscored")
    func emptyQueryPassesThrough() {
        let matches = FileMatch.search(paths, query: "", limit: 3)
        #expect(matches.map(\.path) == Array(paths.prefix(3)))
        #expect(matches.allSatisfy { $0.score == 0 })
    }

    @Test("A hit in the file name outranks one that only matched folders")
    func nameHitOutranksFolderHit() {
        let candidates = [
            "store/Migrations.swift",
            "Sources/App/Store.swift",
        ]
        let matches = FileMatch.search(candidates, query: "store", limit: 10)
        #expect(matches.first?.path == "Sources/App/Store.swift")
    }

    @Test("Ties fall to the shorter path, then alphabetically")
    func tieBreaks() {
        let candidates = ["b/Theme.swift", "a/Theme.swift", "Theme.swift"]
        let matches = FileMatch.search(candidates, query: "theme", limit: 10)
        #expect(matches.first?.path == "Theme.swift")
        #expect(matches.map(\.path).suffix(2) == ["a/Theme.swift", "b/Theme.swift"])
    }

    @Test("A path the query does not match is not offered at all")
    func nonMatchesAreDropped() {
        let matches = FileMatch.search(paths, query: "zzz", limit: 10)
        #expect(matches.isEmpty)
    }

    @Test("The limit caps the answer after ranking, not before")
    func limitAppliesAfterRanking() {
        let matches = FileMatch.search(paths, query: "store", limit: 1)
        #expect(matches.count == 1)
        #expect(matches.first?.path == "Sources/App/Store.swift")
    }

    @Test("Name and directory split where the menu draws them apart")
    func nameAndDirectorySplit() {
        let match = FileMatch(path: "Sources/App/Store.swift", score: 0)
        #expect(match.fileName == "Store.swift")
        #expect(match.directory == "Sources/App")
    }
}
