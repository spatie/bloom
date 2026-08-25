import Foundation
import Testing
@testable import BloomCore

/// Left and Right in a tree, which is the half of a tree's keyboard a flat list has no answer for.
@Suite("A tree's keyboard")
struct TreeNavigationTests {

    /// Sources/            0, open
    ///   Bloom/            1, closed
    ///   BloomCore/        1, open
    ///     Store.swift     2
    ///     Git.swift       2
    /// README.md           0
    private let rows = [
        TreeRow(depth: 0, isDirectory: true, isExpanded: true),
        TreeRow(depth: 1, isDirectory: true, isExpanded: false),
        TreeRow(depth: 1, isDirectory: true, isExpanded: true),
        TreeRow(depth: 2, isDirectory: false, isExpanded: false),
        TreeRow(depth: 2, isDirectory: false, isExpanded: false),
        TreeRow(depth: 0, isDirectory: false, isExpanded: false),
    ]

    // MARK: - Right

    @Test("right opens a closed directory")
    func rightOpens() {
        #expect(TreeNavigation.step(.right, at: 1, in: rows) == .expand(1))
    }

    /// The half people forget. Without it, getting into an open folder means arrowing down.
    @Test("right steps into a directory that is already open")
    func rightSteps() {
        #expect(TreeNavigation.step(.right, at: 2, in: rows) == .move(3))
    }

    @Test("right on a file does nothing")
    func rightOnFile() {
        #expect(TreeNavigation.step(.right, at: 3, in: rows) == .none)
    }

    @Test("right on an open directory with nothing in it does nothing")
    func rightOnEmptyDirectory() {
        let empty = [
            TreeRow(depth: 0, isDirectory: true, isExpanded: true),
            TreeRow(depth: 0, isDirectory: false, isExpanded: false),
        ]
        #expect(TreeNavigation.step(.right, at: 0, in: empty) == .none)
    }

    // MARK: - Left

    @Test("left closes an open directory")
    func leftCloses() {
        #expect(TreeNavigation.step(.left, at: 2, in: rows) == .collapse(2))
    }

    /// The other half people forget, and the one that decides whether a tree can be walked at all
    /// without the pointer.
    @Test("left on a file steps out to the directory holding it")
    func leftOnFile() {
        #expect(TreeNavigation.step(.left, at: 3, in: rows) == .move(2))
    }

    @Test("left on a closed directory steps out to its parent")
    func leftOnClosedDirectory() {
        #expect(TreeNavigation.step(.left, at: 1, in: rows) == .move(0))
    }

    @Test("left at the top level has nowhere to go")
    func leftAtTheRoot() {
        #expect(TreeNavigation.step(.left, at: 5, in: rows) == .none)
        #expect(TreeNavigation.step(.left, at: 0, in: rows) == .collapse(0))
    }

    // MARK: - Everything else

    @Test("with nothing selected, neither key does anything")
    func noSelection() {
        #expect(TreeNavigation.step(.left, at: nil, in: rows) == .none)
        #expect(TreeNavigation.step(.right, at: nil, in: rows) == .none)
    }

    @Test("a row that is no longer there does nothing")
    func staleIndex() {
        #expect(TreeNavigation.step(.right, at: 99, in: rows) == .none)
        #expect(TreeNavigation.step(.right, at: 0, in: []) == .none)
    }

    @Test("the keys a tree leaves to the list", arguments: [
        ListKey.up, .down, .home, .end, .activate, .character("a"),
    ])
    func otherKeys(key: ListKey) {
        #expect(TreeNavigation.step(key, at: 2, in: rows) == .none)
    }
}
