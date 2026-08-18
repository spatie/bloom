import Testing
@testable import BatonCore

@Suite("Changed file tree")
struct ChangedFileTreeTests {
    private func file(_ path: String, additions: Int = 1, deletions: Int = 0) -> ChangedFile {
        ChangedFile(path: path, change: .modified, additions: additions, deletions: deletions)
    }

    @Test("An empty change set produces no rows")
    func emptyList() {
        #expect(ChangedFileTree.build(from: []).isEmpty)
        #expect(ChangedFileTree.rows(from: [], collapsed: []).isEmpty)
    }

    @Test("A path with nothing in it is dropped rather than becoming a nameless folder")
    func emptyPath() {
        #expect(ChangedFileTree.build(from: [file("")]).isEmpty)
    }

    @Test("A file at the repository root is a top level row, not a folder")
    func rootFile() {
        let nodes = ChangedFileTree.build(from: [file("README.md")])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "README.md")
        #expect(nodes[0].path == "README.md")
        #expect(nodes[0].isFolder == false)
        #expect(nodes[0].file?.path == "README.md")
    }

    @Test("A chain of folders with one child each is said on one row")
    func singleChildChainCollapses() {
        let nodes = ChangedFileTree.build(from: [
            file("app/Domain/CustomFields/Actions/ApplyCustomFieldValuesAction.php"),
            file("app/Domain/CustomFields/Exceptions/CouldNotSetCustomFieldValue.php"),
        ])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "app / Domain / CustomFields")
        // The identity is the deepest directory, so opening it cannot collide with anything else.
        #expect(nodes[0].path == "app/Domain/CustomFields")

        let children = nodes[0].children
        #expect(children.map(\.name) == ["Actions", "Exceptions"])
        #expect(children.map(\.isFolder) == [true, true])
        #expect(children[0].children.map(\.name) == ["ApplyCustomFieldValuesAction.php"])
        #expect(children[1].children.map(\.name) == ["CouldNotSetCustomFieldValue.php"])
    }

    @Test("A folder holding a single file keeps its own row")
    func singleFileDoesNotCollapseIntoItsFolder() {
        let nodes = ChangedFileTree.build(from: [file("tests/Unit/ThingTest.php")])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "tests / Unit")
        #expect(nodes[0].path == "tests/Unit")
        #expect(nodes[0].children.map(\.name) == ["ThingTest.php"])
    }

    @Test("Several files in one folder sit under one folder row, in name order")
    func multipleFilesInOneFolder() {
        let nodes = ChangedFileTree.build(from: [
            file("src/Zebra.swift"),
            file("src/apple.swift"),
            file("src/Banana.swift"),
        ])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "src")
        #expect(nodes[0].children.map(\.name) == ["apple.swift", "Banana.swift", "Zebra.swift"])
    }

    @Test("Deep nesting collapses to a single row down to the first branch")
    func deepNesting() {
        let nodes = ChangedFileTree.build(from: [file("a/b/c/d/e/f/g.txt")])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "a / b / c / d / e / f")
        #expect(nodes[0].path == "a/b/c/d/e/f")
        #expect(nodes[0].children.map(\.path) == ["a/b/c/d/e/f/g.txt"])
    }

    @Test("Collapsing stops where a folder branches")
    func collapsingStopsAtBranch() {
        let nodes = ChangedFileTree.build(from: [
            file("a/b/c/one.txt"),
            file("a/b/d/two.txt"),
        ])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "a / b")
        #expect(nodes[0].children.map(\.name) == ["c", "d"])
    }

    @Test("A folder holding both a file and a folder is not collapsed away")
    func mixedFolderDoesNotCollapse() {
        let nodes = ChangedFileTree.build(from: [
            file("app/Model.php"),
            file("app/Http/Controller.php"),
        ])

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "app")
        // Folders come before files, the way the Finder and git's own listings order them.
        #expect(nodes[0].children.map(\.name) == ["Http", "Model.php"])
    }

    @Test("Root files sort after root folders")
    func rootOrdering() {
        let nodes = ChangedFileTree.build(from: [
            file("README.md"),
            file("tests/ThingTest.php"),
            file("app/Model.php"),
        ])

        #expect(nodes.map(\.name) == ["app", "tests", "README.md"])
        #expect(nodes.last?.isFolder == false)
    }

    @Test("Files keep the stats and status they came in with")
    func filesCarryTheirChange() {
        let deleted = ChangedFile(path: "app/Old.php", change: .deleted, additions: 0, deletions: 12)
        let nodes = ChangedFileTree.build(from: [deleted])

        let leaf = nodes[0].children[0].file
        #expect(leaf?.change == .deleted)
        #expect(leaf?.deletions == 12)
        #expect(leaf?.additions == 0)
    }

    @Test("Flattening walks every open folder, depth first")
    func flatteningExpandedTree() {
        let nodes = ChangedFileTree.build(from: [
            file("app/Domain/Actions/Apply.php"),
            file("app/Domain/Exceptions/Boom.php"),
            file("README.md"),
        ])

        let rows = ChangedFileTree.rows(from: nodes, collapsed: [])

        #expect(rows.map(\.node.name) == [
            "app / Domain", "Actions", "Apply.php", "Exceptions", "Boom.php", "README.md",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 2, 0])
    }

    @Test("A collapsed folder hides everything under it and nothing else")
    func flatteningWithCollapsedFolder() {
        let nodes = ChangedFileTree.build(from: [
            file("app/Domain/Actions/Apply.php"),
            file("app/Domain/Exceptions/Boom.php"),
        ])

        let rows = ChangedFileTree.rows(from: nodes, collapsed: ["app/Domain/Actions"])

        #expect(rows.map(\.node.name) == ["app / Domain", "Actions", "Exceptions", "Boom.php"])
    }

    @Test("Collapsing the root row leaves one row")
    func flatteningWithCollapsedRoot() {
        let nodes = ChangedFileTree.build(from: [
            file("app/Domain/Actions/Apply.php"),
            file("app/Domain/Exceptions/Boom.php"),
        ])

        let rows = ChangedFileTree.rows(from: nodes, collapsed: ["app/Domain"])

        #expect(rows.map(\.node.name) == ["app / Domain"])
    }

    @Test("Every row has a unique identity, so the list can key on it")
    func rowIdentitiesAreUnique() {
        let nodes = ChangedFileTree.build(from: [
            file("app/Domain/Actions/Apply.php"),
            file("app/Domain/Actions/Other.php"),
            file("app/Http/Controller.php"),
            file("README.md"),
        ])

        let ids = ChangedFileTree.rows(from: nodes, collapsed: []).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("The tree holds every file it was given, whatever the shape")
    func nothingIsLost() {
        let paths = [
            "a/b/c/d.txt", "a/b/e.txt", "f.txt", "g/h.txt", "a/i/j/k.txt",
        ]

        let rows = ChangedFileTree.rows(
            from: ChangedFileTree.build(from: paths.map { file($0) }),
            collapsed: []
        )

        #expect(Set(rows.compactMap(\.node.file?.path)) == Set(paths))
    }
}
