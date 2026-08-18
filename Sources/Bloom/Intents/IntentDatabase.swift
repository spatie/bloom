import Foundation
import BloomCore

/// The read side of Bloom's automation surface.
///
/// Queries answer out of SQLite rather than out of `AppModel`, because a Shortcut can ask what
/// workspaces exist while Bloom has no window on screen, and an answer that depended on the
/// interface being up would fail at exactly the moment automation is worth having. The file is
/// opened in WAL mode, so this second connection reads happily alongside the app's own writes.
///
/// Nothing here writes. Anything that starts a process goes through the running app instead,
/// because the app owns those children and a detached agent would outlive whoever asked for it.
enum IntentDatabase {
    static func store() async throws -> Store {
        try await connection.store()
    }

    private static let connection = Connection()

    /// An actor purely to serialise the open. Two intents can be performed at once, and each of
    /// them opening the file would run the migrations twice against the same database.
    private actor Connection {
        private var opened: Store?

        func store() throws -> Store {
            if let opened { return opened }
            let store = try Store(path: try Store.defaultPath())
            self.opened = store
            return store
        }
    }
}
