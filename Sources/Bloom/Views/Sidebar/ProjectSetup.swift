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
/// Everything that adds a project goes through `AppModel.addRepository`, and there are four
/// routes into it: the sidebar's plus and its empty state, Home's empty state, the toolbar, the
/// File menu's Add Project Folder at shift-command-O, and the Settings window's project list.
/// None of them decides anything. They ask for a folder and hand it over, so the offer below is
/// reached identically from all of them.
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
