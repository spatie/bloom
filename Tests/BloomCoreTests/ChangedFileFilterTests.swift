import Testing
@testable import BloomCore

/// The Changes tab's filter field, and the two things it is not: the All files filter, and a way
/// to search the status letter.
@Suite("Changed file filter")
struct ChangedFileFilterTests {
    private let files = [
        ChangedFile(path: "README.md", change: .modified),
        ChangedFile(path: "app/Http/Controllers/UserController.php", change: .added),
        ChangedFile(path: "app/Http/Kernel.php", change: .modified),
        ChangedFile(path: "database/migrations/2024_create_users_table.php", change: .added),
        ChangedFile(path: "tests/Feature/UserTest.php", change: .modified),
    ]

    private func paths(_ files: [ChangedFile]) -> [String] {
        files.map(\.path)
    }

    // MARK: - No filter

    @Test("An empty needle is no filter at all, which is not the same answer as no matches")
    func emptyNeedleChangesNothing() {
        #expect(ChangedFileFilter.apply(to: files, needle: "") == nil)
        #expect(ChangedFileFilter.apply(to: files, needle: FileNeedle.canonical("  ")) == nil)
    }

    // MARK: - What survives

    @Test("A file is found by its name, case insensitively and by subsequence")
    func matchesByName() throws {
        for needle in ["usercontroller", "USERCON", "uc.php"] {
            let kept = try #require(
                ChangedFileFilter.apply(to: files, needle: FileNeedle.canonical(needle))
            )
            #expect(
                paths(kept).contains("app/Http/Controllers/UserController.php"),
                "\(needle) should find UserController.php"
            )
        }
    }

    @Test("A file is found by a folder it lives in, which is the whole reason this matches paths")
    func matchesByFolder() throws {
        // There is no folder node to match here: the Changes tree is built from these paths after
        // the filter has run, so a needle aimed at a directory has only the path to find.
        let kept = try #require(ChangedFileFilter.apply(to: files, needle: "migrations"))

        #expect(paths(kept) == ["database/migrations/2024_create_users_table.php"])
    }

    @Test("A path fragment matches the path it is a fragment of")
    func matchesByPathFragment() throws {
        let kept = try #require(ChangedFileFilter.apply(to: files, needle: "app/http"))

        #expect(paths(kept) == [
            "app/Http/Controllers/UserController.php",
            "app/Http/Kernel.php",
        ])
    }

    @Test("The diff's own order is kept, because the tree is rebuilt from what comes back")
    func orderIsPreserved() throws {
        let kept = try #require(ChangedFileFilter.apply(to: files, needle: "php"))

        #expect(paths(kept) == paths(files.filter { $0.path.hasSuffix(".php") }))
    }

    @Test("A needle nothing answers comes back empty rather than as the whole diff")
    func nothingMatches() throws {
        let kept = try #require(ChangedFileFilter.apply(to: files, needle: "zzqq"))

        #expect(kept.isEmpty)
    }

    // MARK: - The status letter

    @Test("The status letter is not searchable, and a single letter is not a status filter")
    func statusIsNotSearchable() throws {
        // `A` is added and `M` is modified, and neither is what this answers. What it answers is a
        // subsequence over the paths, which is why one letter is very nearly the whole diff: a
        // field that claimed to filter by status would be lying about which files it kept.
        let added = try #require(ChangedFileFilter.apply(to: files, needle: "a"))
        #expect(paths(added).contains("app/Http/Kernel.php"))
        #expect(added.allSatisfy { $0.change == .added } == false)
    }

    // MARK: - The tree that is rebuilt from the survivors

    @Test("A chain that stops branching under a filter is said on one row again")
    func chainsRecollapse() throws {
        // The reason this filters the files rather than pruning the built tree. Unfiltered, the
        // chain stops at `Http`, because that is where the tree branches into a folder and a file.
        // Narrowed to one file under it there is no branch left, so the chain runs one segment
        // further, and only a rebuild can say that: a tree pruned after the fact would still be
        // drawing the row it was built with.
        let whole = ChangedFileTree.build(from: files)
        #expect(whole.first?.name == "app / Http")

        let kept = try #require(ChangedFileFilter.apply(to: files, needle: "usercontroller"))
        let narrowed = ChangedFileTree.build(from: kept)

        #expect(narrowed.count == 1)
        #expect(narrowed[0].name == "app / Http / Controllers")
        #expect(narrowed[0].children.map(\.path) == ["app/Http/Controllers/UserController.php"])
    }

    @Test("Everything the filter keeps is drawn, because this tree has nothing shut")
    func nothingHasToBeOpened() throws {
        // The other half of the divergence from `FileTreeFilter`, which has to report which
        // folders to open because its tree is shut until somebody opens one. Here an empty
        // collapsed set is every row.
        let kept = try #require(ChangedFileFilter.apply(to: files, needle: "user"))
        let rows = ChangedFileTree.rows(from: ChangedFileTree.build(from: kept), collapsed: [])

        #expect(rows.filter { $0.node.file != nil }.map(\.node.path) == paths(kept).sorted())
    }
}
