import Testing
@testable import BloomCore

/// What Home says when it has nothing to list.
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
        scope: HomeScope = .all,
        hasProjectFilter: Bool = false,
        projectPhrase: String = "that project"
    ) -> HomeEmptyState? {
        HomeEmptyState.resolve(
            hasProjects: hasProjects,
            hasAnyWorkspace: hasAnyWorkspace,
            isListEmpty: isListEmpty,
            query: query,
            scope: scope,
            hasProjectFilter: hasProjectFilter,
            projectPhrase: projectPhrase
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
        #expect(resolve(query: "blue", hasProjectFilter: true) == .noMatch(query: "blue", scope: .all))
        #expect(resolve(hasProjectFilter: true) == .noneInChosenProjects(phrase: "that project"))
    }

    /// Whitespace is not a search. A query of two spaces would otherwise quote them back inside
    /// typographic quotes and offer to clear a search nobody typed.
    @Test("a query of whitespace is not a search")
    func whitespaceIsNotASearch() {
        #expect(resolve(query: "   ", scope: .archived) == .emptyScope(.archived))
        #expect(resolve(query: "  blue  ") == .noMatch(query: "blue", scope: .all))
    }

    /// The chip is the last thing left to blame, and it names itself rather than saying "nothing
    /// to show" about a machine that is full of work.
    @Test("the last state left is the chip that is lit")
    func theLastOneIsTheScope() {
        #expect(resolve(scope: .archived) == .emptyScope(.archived))
        #expect(resolve(scope: .needsYou) == .emptyScope(.needsYou))
        #expect(resolve(scope: .running) == .emptyScope(.running))
        #expect(resolve(scope: .live) == .emptyScope(.live))
    }

    /// Every state is a different sentence with a different way out, which is the argument for
    /// there being several of them rather than one "nothing to show".
    @Test("no two states share a title, a message or a button")
    func theStatesAreDistinct() {
        let states: [HomeEmptyState] = [
            .noProjects, .noWorkspaces, .noMatch(query: "blue", scope: .all),
            .noneInChosenProjects(phrase: "Bloom"), .emptyScope(.archived),
        ]
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(Set(states.map(\.message)).count == states.count)
        for state in states {
            #expect(!state.title.isEmpty)
            #expect(!state.symbol.isEmpty)
            #expect(state.message.hasSuffix("."))
        }
    }

    /// Every empty scope says something of its own. "Nothing is waiting for you" and "No agent is
    /// running" are different facts about the same machine, and a shared sentence would leave the
    /// reader unable to tell which chip they were looking at.
    @Test("each empty chip has a sentence of its own")
    func eachScopeSaysSomethingDifferent() {
        let scopes: [HomeScope] = [.needsYou, .running, .live, .archived]
        let states = scopes.map { HomeEmptyState.emptyScope($0) }
        #expect(Set(states.map(\.title)).count == scopes.count)
        #expect(Set(states.map(\.message)).count == scopes.count)
        for state in states { #expect(state.message.hasSuffix(".")) }
    }

    /// The first state is the only one with two ways out, and the prominent one is the one that
    /// needs no folder. Bloom used to offer this reader nothing but a file panel, which is the
    /// wrong door for somebody whose project does not exist yet.
    @Test("only the state with no projects offers a second button")
    func onlyTheFirstStateHasTwoWaysOut() {
        #expect(HomeEmptyState.noProjects.actionTitle == "New project")
        #expect(HomeEmptyState.noProjects.secondaryActionTitle == "Add a project folder")
        let others: [HomeEmptyState] = [
            .noWorkspaces, .noMatch(query: "blue", scope: .all),
            .noneInChosenProjects(phrase: "Bloom"), .emptyScope(.archived),
        ]
        for state in others {
            #expect(state.secondaryActionTitle == nil, "\(state)")
        }
    }

    /// A search narrowed to transcripts that found nothing did not fail to find a workspace, and
    /// saying it did would send the reader looking for a name they never typed.
    @Test("a search says which kind of thing it failed to find")
    func theSearchSentenceFollowsTheScope() {
        let all = HomeEmptyState.noMatch(query: "sidebar", scope: .all)
        let transcripts = HomeEmptyState.noMatch(query: "sidebar", scope: .transcripts)
        let workspaces = HomeEmptyState.noMatch(query: "sidebar", scope: .workspaces)
        #expect(all.message != transcripts.message)
        #expect(workspaces.message != transcripts.message)
        #expect(transcripts.title != workspaces.title)
    }

    /// Typographic quotes: a straight pair in the one sentence that quotes the user reads as a
    /// string literal that escaped.
    @Test("the search sentence quotes the user properly")
    func theQuotesAreTypographic() {
        for scope in HomeScope.allCases {
            let message = HomeEmptyState.noMatch(query: "sidebar", scope: scope).message
            #expect(message.contains("\u{201C}sidebar\u{201D}"))
            #expect(!message.contains("\""))
        }
    }
}
