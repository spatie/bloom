import SwiftUI
import BloomCore

/// One capture page: what it is called, how big it is drawn, whether it needs the keyboard, and
/// what it draws.
///
/// **A registry rather than an enum, and that is a merge decision rather than a taste one.**
/// `GalleryChoice` had nine cases and four parallel switches over them, `title`, `size`,
/// `needsFocus` and `galleryView`, all in `Snapshot.swift`. Adding a page meant appending in four
/// places in one file, so any two agents adding a page at the same time conflicted in four hunks
/// each. Five hit that in a single day. A value per page, declared in the page's own file, makes
/// adding one a new file plus one line in an array: a conflict git resolves rather than four it
/// does not.
///
/// **The exhaustiveness argument survives the change**, which is the thing that made the switches
/// worth keeping. `needsFocus`'s doc comment argued that a `switch` forces a new page to answer
/// the question rather than silently inheriting `false`. A memberwise initialiser with no default
/// value does exactly the same: the compiler will not let a `Gallery` be built without an answer.
/// So none of these have defaults, deliberately, and the one that looks most like it wants one is
/// the one that must not have it.
struct Gallery {
    /// What `--gallery` is given on the command line, and what the written file is named after.
    ///
    /// `name` and not `id`, and this is not `Identifiable`: it is an argument somebody types, not
    /// an identifier for a row, and the house rule about bare `String` ids is right that the two
    /// should not look alike. Nothing here needs an identity anyway; the array is walked, not
    /// diffed.
    let name: String
    /// The heading drawn on the page.
    let title: String
    /// How big it is rendered. Offscreen, so this is the whole of the layout.
    let size: CGSize
    /// Whether this page has to be photographed in the key window of the active app.
    ///
    /// True only where the state under review is a field somebody is typing in: a text view draws
    /// its focus ring nowhere else. Taking the keys is a rude thing to do to whoever is using the
    /// machine, so a page that does not need them does not ask.
    ///
    /// No default, deliberately. See the type's own note.
    let needsFocus: Bool
    /// The page itself. `AnyView` because these are collected into one array, and a capture page
    /// is drawn once offscreen, which is the one place type erasure costs nothing worth counting.
    let view: @MainActor (AppModel) -> AnyView

    init(
        name: String,
        title: String,
        size: CGSize,
        needsFocus: Bool,
        view: @escaping @MainActor (AppModel) -> AnyView
    ) {
        self.name = name
        self.title = title
        self.size = size
        self.needsFocus = needsFocus
        self.view = view
    }
}

extension Snapshot {
    /// Every capture page, in the order `--gallery` lists them.
    ///
    /// One line per page and nothing else, which is the point: a page is added by writing its own
    /// file and appending here. `Gallery.reviewComments` and its siblings live beside the views
    /// they describe.
    static let galleries: [Gallery] = [
        .reviewComments,
        .inspectorTabs,
        .diffScope,
        .pendingDelete,
        .runningGlyph,
        .statusColumn,
        .retries,
        .subagentRows,
        .subagentOutput,
        .paneTabs,
        .sidebarSelection,
        .quickPrompts,
        .composerPickers,
        .hoverCard,
        .panelTabs,
        .browserToolbar,
        .systemAccent,
        .activityRule,
        .sidebarIndent,
        .runningColour,
        .proseLeading,
        .welcomeOffers,
        .crewMessages,
        .diffRun,
        .postcard,
    ]

    /// The page `--gallery` names, falling back to the first rather than failing: a capture run
    /// with a typo in it should still produce something to look at.
    static func gallery(named name: String?) -> Gallery {
        galleries.first { $0.name == name } ?? galleries[0]
    }
}
