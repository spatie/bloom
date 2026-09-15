import Foundation

/// What the GitHub repository picker draws where its rows go, and what each of those says.
///
/// The picker used to blank its list the moment a search began and say nothing until `gh`
/// answered, which on a remote server is several seconds of an empty white box with a small
/// spinner in the footer beside a greyed out Refresh. It read as broken rather than busy. And a
/// finished search that found nothing said "No matching repositories." in red under the list, as
/// if an empty answer were an error, while a real error said the same thing in the same place.
///
/// So there are distinct states because there are distinct facts: working with nothing to show
/// yet, working over rows that are about to be replaced, finished with nothing, and failed. The
/// order they are asked in is the part that is easy to get wrong, which is why it lives here.
public enum GitHubRepositoryListState: Sendable, Equatable {
    /// Rows are showing. `busy` is set while a refresh, a changed search or the next page runs
    /// over them, so the rows already loaded stay in view rather than being blanked.
    case rows(busy: GitHubRepositoryListBusy?)
    /// Working, with no rows yet. The view draws placeholder rows under the sentence.
    case placeholder(GitHubRepositoryListBusy)
    /// The account's own listing came back empty.
    case noRepositories
    /// A search finished and matched nothing.
    case noMatch(query: String)
    /// The request failed and there are no rows to fall back on.
    case failed(message: String)
    /// A remote server whose `gh` is not signed in, which has its own way out.
    case signInOnServer

    /// - Parameters:
    ///   - rowCount: rows currently held, which may belong to the previous search.
    ///   - page: the page being loaded or last loaded; above one means "load more".
    ///   - serverName: the remote server's name, or nil when `gh` runs on this Mac.
    public static func resolve(
        rowCount: Int,
        query: String,
        page: Int,
        isLoading: Bool,
        problem: String?,
        needsServerSignIn: Bool,
        serverName: String?
    ) -> GitHubRepositoryListState {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLoading {
            let busy: GitHubRepositoryListBusy
            if page > 1, rowCount > 0 {
                busy = .loadingMore
            } else if needle.isEmpty {
                busy = .loading(serverName: serverName)
            } else {
                busy = .searching(query: needle)
            }
            return rowCount > 0 ? .rows(busy: busy) : .placeholder(busy)
        }
        if rowCount > 0 { return .rows(busy: nil) }
        // Sign in before the error, because the missing sign in is what caused the error and the
        // button that fixes it is the useful thing to show.
        if needsServerSignIn { return .signInOnServer }
        if let problem { return .failed(message: problem) }
        return needle.isEmpty ? .noRepositories : .noMatch(query: needle)
    }

    public var title: String {
        switch self {
        case .rows, .placeholder: ""
        case .noRepositories: "No repositories"
        case .noMatch: "No matching repositories"
        case .failed: "Could not load repositories"
        case .signInOnServer: "Sign in to GitHub on your server"
        }
    }

    public var symbol: String {
        switch self {
        case .rows, .placeholder: ""
        case .noRepositories: "folder"
        case .noMatch: "magnifyingglass"
        case .failed: "exclamationmark.triangle"
        case .signInOnServer: "person.crop.circle.badge.exclamationmark"
        }
    }

    public var message: String {
        switch self {
        case .rows, .placeholder, .signInOnServer: ""
        case .noRepositories: "The GitHub account signed in here cannot reach any repositories yet."
        case let .noMatch(query): "Nothing on GitHub matches \u{201C}\(query)\u{201D}. Try the owner/name form."
        case let .failed(message): message
        }
    }
}

/// What the picker is waiting for, which decides the sentence it shows while it waits.
public enum GitHubRepositoryListBusy: Sendable, Equatable {
    case loading(serverName: String?)
    case searching(query: String)
    case loadingMore

    /// Names the machine when it is not this one, because a remote `gh` is the slow case and the
    /// reader should know the wait is the server's rather than GitHub's alone.
    public var sentence: String {
        switch self {
        case .loading(nil): "Loading your repositories from GitHub\u{2026}"
        case let .loading(serverName?): "Asking \(serverName) for your GitHub repositories\u{2026}"
        case let .searching(query): "Searching GitHub for \u{201C}\(query)\u{201D}\u{2026}"
        case .loadingMore: "Loading more repositories\u{2026}"
        }
    }
}
