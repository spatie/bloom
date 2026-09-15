import Testing
@testable import BloomCore

/// What the GitHub repository picker draws where its rows go.
///
/// It blanked the list for every search and reported an empty answer in the same red line as a
/// failure. These pin the order: busy before empty, rows kept while busy, sign in before error.
@Suite("What the GitHub repository picker shows")
struct GitHubRepositoryListStateTests {
    private func resolve(
        rowCount: Int = 0,
        query: String = "",
        page: Int = 1,
        isLoading: Bool = false,
        problem: String? = nil,
        needsServerSignIn: Bool = false,
        serverName: String? = nil
    ) -> GitHubRepositoryListState {
        GitHubRepositoryListState.resolve(
            rowCount: rowCount,
            query: query,
            page: page,
            isLoading: isLoading,
            problem: problem,
            needsServerSignIn: needsServerSignIn,
            serverName: serverName
        )
    }

    @Test("a first load with nothing yet draws placeholders and says what it is loading")
    func firstLoad() {
        #expect(resolve(isLoading: true) == .placeholder(.loading(serverName: nil)))
        #expect(resolve(isLoading: true, serverName: "Hetzner") == .placeholder(.loading(serverName: "Hetzner")))
        #expect(GitHubRepositoryListBusy.loading(serverName: "Hetzner").sentence.contains("Hetzner"))
    }

    @Test("a search names the trimmed query")
    func searching() {
        let state = resolve(query: " there-t ", isLoading: true)
        #expect(state == .placeholder(.searching(query: "there-t")))
        #expect(GitHubRepositoryListBusy.searching(query: "there-t").sentence == "Searching GitHub for \u{201C}there-t\u{201D}\u{2026}")
    }

    @Test("rows already loaded stay while a refresh or a changed search runs")
    func keepsRows() {
        #expect(resolve(rowCount: 12, isLoading: true) == .rows(busy: .loading(serverName: nil)))
        #expect(resolve(rowCount: 12, query: "bloom", isLoading: true) == .rows(busy: .searching(query: "bloom")))
        #expect(resolve(rowCount: 50, page: 2, isLoading: true) == .rows(busy: .loadingMore))
    }

    @Test("an empty answer is not an error, and a search and a listing say different things")
    func empty() {
        #expect(resolve() == .noRepositories)
        #expect(resolve(query: "there-t") == .noMatch(query: "there-t"))
        #expect(resolve(query: "there-t").message.contains("\u{201C}there-t\u{201D}"))
    }

    @Test("a failure with no rows is its own state, and a missing server sign in wins over it")
    func failure() {
        #expect(resolve(problem: "gh timed out") == .failed(message: "gh timed out"))
        #expect(resolve(problem: "gh timed out", needsServerSignIn: true) == .signInOnServer)
        #expect(resolve(rowCount: 3, problem: "page two failed") == .rows(busy: nil))
    }

    @Test("still loading is never reported as empty")
    func busyBeforeEmpty() {
        #expect(resolve(query: "x", isLoading: true, problem: "old", needsServerSignIn: true) == .placeholder(.searching(query: "x")))
    }
}
