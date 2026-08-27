import SwiftUI
import Observation
import BloomCore

/// Which window a setup dialog belongs to.
///
/// The main window and the Settings window are two scenes, and every "Add project" control exists
/// in one of them. A single shared presenter with no idea which one asked would put a sheet on
/// both at once, so the request carries where it came from and each scene presents only its own.
enum ProjectSetupSurface: Sendable, Equatable {
    case main
    case settings
}

/// The one way Bloom offers to make a folder into a project.
///
/// Everything that adds a project through the file panel goes through `AppModel.addRepository`,
/// and what is left of that is the Settings window's project list, the create window's empty state
/// and `project_add` over the bridge. None of them decides anything. They ask for a folder and
/// hand it over, so the offer below is reached identically from all of them.
///
/// The main window's own routes no longer come this way. The sidebar's `+`, Home's empty state,
/// the toolbar and the File menu all raise `StartProjectSheet`, which asks the same questions of
/// the same folder and answers them in one field rather than behind a file panel. This offer
/// stays because Settings is a separate scene and cannot present the main window's sheet, and
/// because the GitHub half of it lives nowhere else.
@MainActor
@Observable
final class ProjectSetup {
    static let shared = ProjectSetup()

    /// A folder that could become a repository, waiting for the user to say how.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        var path: String
        var contents: FolderContents
        var surface: ProjectSetupSurface
        /// Set when git on this Mac has no name or address configured, in which case no commit
        /// can be made and the offer is refused before anything is done rather than half way
        /// through it.
        var identityProblem: String?

        var folderName: String { (path as NSString).lastPathComponent }

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    /// Non-nil while the dialog is up.
    var request: Request?

    /// What to do once the folder really is a repository. Set by `AppModel`, which is the only
    /// thing that knows how to add one.
    @ObservationIgnored var onReady: ((String) async -> Void)?

    func present(_ request: Request) {
        self.request = request
    }

    func dismiss() {
        request = nil
    }

    /// True while a request belongs to this scene, so two windows never raise the same sheet.
    func isPresenting(_ surface: ProjectSetupSurface) -> Bool {
        request?.surface == surface
    }

    /// Which half of the dialog a capture run wants to see, from `--project-setup-choice github`.
    ///
    /// The GitHub half only appears once its radio button has been pressed, and a capture run has
    /// no way to press one. Without this the owner picker, the name field and the availability
    /// line could not be looked at at all, which is exactly the situation that leaves an interface
    /// shipping unseen. Nil in every ordinary launch, and it changes nothing but which option
    /// starts selected.
    static var capturedChoice: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--project-setup-choice"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

extension Binding where Value == ProjectSetup.Request? {
    /// Narrows the shared request to one scene.
    ///
    /// Both windows bind to the same presenter, and a `.sheet(item:)` on each would otherwise
    /// raise the same dialog twice, once per window. Reads as nil unless the request came from
    /// this scene, and refuses to write when it did not, so dismissing in one window cannot clear
    /// a request the other is showing.
    func on(_ surface: ProjectSetupSurface) -> Binding<ProjectSetup.Request?> {
        Binding(
            get: { wrappedValue?.surface == surface ? wrappedValue : nil },
            set: { updated in
                guard wrappedValue?.surface == surface else { return }
                wrappedValue = updated
            }
        )
    }
}

extension Notification.Name {
    /// Hands a folder to `AppModel.addRepository` from outside the file panel.
    ///
    /// The only way into this dialog is an `NSOpenPanel`, and a modal file panel cannot be
    /// answered by anything but a person, so without this the offer could not be looked at
    /// without asking one for a screenshot. `Snapshot`'s `--project-setup` posts it. Nothing
    /// short-circuits: the path goes through the same inspection, the same verdict and the same
    /// walk as a folder somebody chose.
    static let bloomOfferProjectSetup = Notification.Name("bloomOfferProjectSetup")
}
