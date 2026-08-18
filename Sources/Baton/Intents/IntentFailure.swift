import AppIntents
import Foundation

/// What an intent says when it cannot do the thing. Shortcuts shows this sentence verbatim, so
/// each one names what was being attempted rather than reporting a failure in the abstract.
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case unknownProject
    case unknownWorkspace
    case appNeverAppeared
    case workspaceNeverArrived(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unknownProject:
            "That project is no longer one of Baton's. Add its folder in Baton and try again."
        case .unknownWorkspace:
            "That workspace no longer exists in Baton."
        case .appNeverAppeared:
            "Baton did not finish opening, so there was nowhere to send the request."
        case .workspaceNeverArrived(let prompt):
            "Baton did not finish creating a workspace for \"\(prompt)\". It may still be working: check the app."
        }
    }
}
