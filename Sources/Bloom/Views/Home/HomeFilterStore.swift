import SwiftUI
import Observation

/// Where Home's filter lives between visits.
///
/// `HomeView` is created and thrown away every time the selection moves off Home and back, so a
/// filter held in its `@State` is reset by opening a workspace and clicking Home again. A user who
/// narrows the list to one project, opens something from it and comes back to a list of everything
/// has been silently overruled by the app.
///
/// This is the same decision `AppModel.searchQuery` already makes for the Search screen, and for
/// the same reason. It belongs on `AppModel` beside that property rather than in a singleton of
/// its own: it is app state, not view state. It is here only because this change does not own
/// `AppModel`. See the report that came with it.
///
/// Deliberately not persisted to disk. "Showing archived" is a thing you turn on to go and look
/// at something, not a preference, and an app that starts up showing archived workspaces because
/// of something you did last Tuesday is one that has to be worked out rather than read.
@MainActor
@Observable
final class HomeFilterStore {
    static let shared = HomeFilterStore()

    var filter = HomeFilter()

    private init() {}
}
