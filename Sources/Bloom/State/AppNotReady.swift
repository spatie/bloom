import Foundation

/// Bloom was asked to do something before it had finished starting.
///
/// `AppModel` builds its store and its `WorkspaceManager` in a task after the scene exists, so for
/// the first moments of a launch there is genuinely nothing to do the work with. Every caller used
/// to answer that with a silent nil, which reads to a Shortcut as "it did not work" with no reason
/// attached, and reads to a person as nothing at all.
enum AppNotReady: Error, CustomStringConvertible {
    case stillStartingUp

    var description: String {
        switch self {
        case .stillStartingUp:
            "Bloom is still starting up, so there was nothing to do the work with yet. Try again."
        }
    }
}
