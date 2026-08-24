import Testing
@testable import BloomCore

/// Which of five things Home says when it has nothing to list.
///
/// It was a five-branch `if` chain inside `HomeView`, mixed in with the `ContentUnavailableView`s
/// it produced. The order is load bearing and not obvious: a machine with no projects also has no
/// workspaces and also has an empty list, so the first three tests are all true at once and only
/// the first is right. Nothing could check that.
@Suite("What Home says when it has nothing")
struct HomeEmptyStateTests {
    private func resolve(
        hasProjects: Bool = true,
        hasAnyWorkspace: Bool = true,
        isListEmpty: Bool = true,
        query: String = "",
        hasProjectFilter: Bool = false,
        projectPhrase: String = "that project",
        archivedCount: Int = 0
    ) -> HomeEmptyState? {
        HomeEmptyState.resolve(
            hasProjects: hasProjects,
            hasAnyWorkspace: hasAnyWorkspace,
            isListEmpty: isListEmpty,
            query: query,
            hasProjectFilter: hasProjectFilter,
            projectPhrase: projectPhrase,
            archivedCount: archivedCount
        )
    }

    /// The whole reason the order matters: every later test is also true on a fresh machine.
    @Test("a machine with no projects is not reported as a search that matched nothing")
    func emptiestWins() {
        #expect(
            resolve(hasProjects: false, hasAnyWorkspace: false, query: "blue", hasProjectFilter: true)
                == .noProjects
        )
        #expect(
            resolve(hasAnyWorkspace: false, query: "blue", hasProjectFilter: true) == .noWorkspaces
        )
    }

    /// A list with rows in it is not an empty state, whatever else is set.
    @Test("a list with rows in it says nothing")
    func aFullListSaysNothing() {
        #expect(resolve(isListEmpty: false) == nil)
        #expect(resolve(isListEmpty: false, query: "blue", hasProjectFilter: true) == nil)
    }

    /// The search is asked before the project filter because a search is typed and a filter is
    /// left set: the thing the reader did last is the thing to undo first.
    @Test("a search that matched nothing is offered before a filter that hid everything")
    func theSearchIsUndoneFirst() {
        #expect(resolve(query: "blue", hasProjectFilter: true) == .noMatch(query: "blue"))
        #expect(resolve(hasProjectFilter: true) == .noneInChosenProjects(phrase: "that project"))
    }

    /// Whitespace is not a search. A query of two spaces would otherwise quote them back inside
    /// typographic quotes and offer to clear a search nobody typed.
    @Test("a query of whitespace is not a search")
    func whitespaceIsNotASearch() {
        #expect(resolve(query: "   ", archivedCount: 4) == .allArchived(count: 4))
        #expect(resolve(query: "  blue  ") == .noMatch(query: "blue"))
    }

    @Test("the last state left is everything being archived and hidden")
    func theLastOneIsArchived() {
        #expect(resolve(archivedCount: 9) == .allArchived(count: 9))
    }

    /// Every state is a different sentence with a different way out, which is the argument for
    /// there being five of them rather than one "nothing to show".
    @Test("no two states share a title, a message or a button")
    func theFiveAreDistinct() {
        let states: [HomeEmptyState] = [
            .noProjects, .noWorkspaces, .noMatch(query: "blue"),
            .noneInChosenProjects(phrase: "Bloom"), .allArchived(count: 3),
        ]
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(Set(states.map(\.message)).count == states.count)
        #expect(Set(states.map(\.actionTitle)).count == states.count)
        for state in states {
            #expect(!state.title.isEmpty)
            #expect(!state.symbol.isEmpty)
            #expect(state.message.hasSuffix("."))
        }
    }

    /// Typographic quotes: a straight pair in the one sentence that quotes the user reads as a
    /// string literal that escaped.
    @Test("the search sentence quotes the user properly")
    func theQuotesAreTypographic() {
        let message = HomeEmptyState.noMatch(query: "sidebar").message
        #expect(message.contains("\u{201C}sidebar\u{201D}"))
        #expect(!message.contains("\""))
    }
}
