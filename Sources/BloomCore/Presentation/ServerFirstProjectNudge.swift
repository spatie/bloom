import Foundation

/// What the sidebar draws under a server's heading while that server has no projects.
///
/// A server that has just been set up is a heading with nothing under it, and the one route to a
/// first project is Start a Project… inside the heading's actions menu, which nobody finds by
/// looking. So the first time a connected server turns out to be empty, the pane says so in a card
/// with that action on it. The card is the loudest thing in the column, which is why it is shown
/// once per server rather than every time the server is empty: closing it, or the server ever
/// having had a project, retires it for good, and an empty server after that gets the quiet
/// sentence every empty project already gets.
///
/// Nothing at all while the server is connecting, disconnected or being updated. The heading's own
/// status line is on screen then, and Start a Project is disabled, so a card offering it would be
/// offering a button that does nothing.
///
/// Hidden projects count as projects. A server whose only projects are hidden is a server the
/// owner has used and tidied, and greeting it with "Your server is ready" would be nagging.
public enum ServerFirstProjectNudge: Sendable, Equatable {
    /// The dismissible card with Start a Project… on it.
    case card
    /// The plain "No projects yet" sentence, once the card has been retired.
    case notice

    /// Where the retired servers are remembered, as one string so `@AppStorage` can hold it.
    public static let retiredKey = "server.sidebar.firstProjectNudge.retired"

    /// What to draw, or nil for nothing.
    ///
    /// - Parameters:
    ///   - isEnabled: whether remote servers are switched on at all. A catalogue can outlive the
    ///     switch, so it is asked rather than assumed.
    ///   - isConnected: whether there is a live connection that is not also connecting again or
    ///     being maintained.
    ///   - projectCount: the server's projects, hidden ones included, or nil while no catalogue
    ///     has arrived. An unloaded catalogue is not an empty server.
    ///   - isRetired: whether this server's card has been dismissed or has seen a project.
    public static func resolve(
        isEnabled: Bool,
        isConnected: Bool,
        projectCount: Int?,
        isRetired: Bool
    ) -> ServerFirstProjectNudge? {
        guard isEnabled, isConnected, let projectCount, projectCount == 0 else { return nil }
        return isRetired ? .notice : .card
    }

    /// The server ids in the stored string. Anything unreadable is read as nothing retired, which
    /// costs one card shown again rather than a card that can never be shown.
    public static func retired(in stored: String) -> Set<String> {
        guard let data = stored.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// The stored string with `serverID` retired as well.
    ///
    /// JSON rather than a joined string, because a server id carries a host and a path and there
    /// is no separator a path is guaranteed not to contain. Sorted so writing the same set twice
    /// writes the same string, and `@AppStorage` sees no change to publish.
    public static func retiring(_ serverID: String, in stored: String) -> String {
        var ids = retired(in: stored)
        ids.insert(serverID)
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return stored }
        return String(decoding: data, as: UTF8.self)
    }
}
