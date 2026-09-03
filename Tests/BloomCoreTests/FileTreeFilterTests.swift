import Testing
@testable import BloomCore

/// The All files tab's filter field, which is a pure function over the listing and the needle.
@Suite("File tree filter")
struct FileTreeFilterTests {
    private let index = FileTreeNode.index([
        "README.md",
        "app/Http/Controllers/UserController.php",
        "app/Http/Kernel.php",
        "app/models/User.php",
        "app/models/Invoice.php",
        "tests/Feature/UserTest.php",
    ])

    private func rows(_ outcome: FileTreeFilter.Outcome) -> [String] {
        FileTreeRowItem.flatten(children: outcome.children, expanded: outcome.open)
            .map(\.node.path)
    }

    // MARK: - No filter

    @Test("An empty needle is no filter at all, which is not the same answer as no matches")
    func emptyNeedleChangesNothing() {
        #expect(FileTreeFilter.apply(to: index, needle: "") == nil)
        #expect(FileTreeFilter.apply(to: index, needle: FileNeedle.canonical("   ")) == nil)
    }

    @Test("Whitespace is trimmed and case folded before anything is asked of the needle")
    func needleIsCanonical() {
        // Shared with the Changes tab's filter, which is the one thing the two are not allowed to
        // disagree about. See `FileNeedle`.
        #expect(FileNeedle.canonical("  UserCon ") == "usercon")
    }

    // MARK: - What survives

    @Test("A folder survives because a file inside it matched, and opens to show it")
    func ancestorSurvivesForItsDescendant() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "usercon"))

        #expect(rows(outcome) == [
            "app",
            "app/Http",
            "app/Http/Controllers",
            "app/Http/Controllers/UserController.php",
        ])
        // Every folder above the match is open, because a file cannot be shown without them.
        #expect(outcome.open == ["app", "app/Http", "app/Http/Controllers"])
        #expect(outcome.isEmpty == false)
    }

    @Test("A folder holding nothing that matched is gone, sibling files included")
    func siblingsAreNotDraggedIn() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "usercon"))
        let paths = rows(outcome)

        #expect(paths.contains("app/models") == false)
        #expect(paths.contains("app/Http/Kernel.php") == false)
        #expect(paths.contains("README.md") == false)
    }

    @Test("A folder that matched by its own name shows its children")
    func selfMatchedFolderKeepsItsChildren() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "models"))

        #expect(rows(outcome) == [
            "app",
            "app/models",
            "app/models/Invoice.php",
            "app/models/User.php",
        ])
        // Kept whole and unjudged: neither file is named anything like "models".
        #expect(outcome.open.contains("app/models"))
    }

    @Test("A matched folder opens one level, not its whole subtree")
    func selfMatchedFolderOpensOneLevel() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "http"))

        #expect(rows(outcome) == [
            "app",
            "app/Http",
            "app/Http/Controllers",
            "app/Http/Kernel.php",
        ])
        // `Controllers` is drawn and closed. Opening it as well would answer a folder's name with
        // every file under it, which is the listing the reader typed to escape.
        #expect(outcome.open.contains("app/Http/Controllers") == false)
    }

    // MARK: - How it matches

    @Test("Matching is case insensitive and by subsequence, not by prefix")
    func matchingIsForgiving() throws {
        for needle in ["usercon", "USERCON", "uc.php", "controller"] {
            let outcome = try #require(FileTreeFilter.apply(to: index, needle: needle.lowercased()))
            #expect(
                rows(outcome).contains("app/Http/Controllers/UserController.php"),
                "\(needle) should find UserController.php"
            )
        }
    }

    @Test("A needle with a slash in it is matched against the path rather than the name")
    func slashMatchesThePath() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "app/mod"))
        let paths = rows(outcome)

        #expect(paths.contains("app/models/User.php"))
        #expect(paths.contains("app/models/Invoice.php"))
        #expect(paths.contains("tests/Feature/UserTest.php") == false)
    }

    @Test("A needle nothing answers says so, rather than answering with the whole tree")
    func nothingMatches() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "zzqq"))

        #expect(outcome.isEmpty)
        #expect(rows(outcome).isEmpty)
        #expect(outcome.open.isEmpty)
    }

    @Test("A directory nothing survived in is left out rather than kept as an empty entry")
    func prunedIndexStaysSmall() throws {
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "usercon"))

        #expect(outcome.children.keys.sorted() == ["", "app", "app/Http", "app/Http/Controllers"])
    }

    // MARK: - The reader's own expansion

    @Test("Clearing the filter puts every folder back where the reader had it")
    func expansionSurvivesAFilter() throws {
        // Somebody opened their way down to the models folder and nowhere else.
        let reader: Set<String> = ["app", "app/models"]
        let before = FileTreeRowItem.flatten(children: index, expanded: reader).map(\.node.path)

        // They type a needle that opens three folders they never touched.
        let outcome = try #require(FileTreeFilter.apply(to: index, needle: "usercon"))
        #expect(outcome.open.contains("app/Http/Controllers"))
        #expect(rows(outcome) != before)

        // Clearing the field is `apply` answering nil, so the tree is flattened over the reader's
        // own set again. Nothing above ever wrote to it.
        #expect(FileTreeFilter.apply(to: index, needle: "") == nil)
        let after = FileTreeRowItem.flatten(children: index, expanded: reader).map(\.node.path)
        #expect(after == before)
    }
}
