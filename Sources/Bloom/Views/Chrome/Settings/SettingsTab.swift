import AppKit

/// The settings window's tabs.
///
/// A named value rather than the position a tab happens to sit in, so a reordering cannot silently
/// change which pane the window opens on.
enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case appearance
    case notifications
    case projects
    case models
    case agents
    case prompts
    case approvals
    case tools
    /// Coupling a client the owner runs themselves. See `CommandLineSettingsView`.
    ///
    /// It was called Terminal, and that was the wrong word twice over: nothing in the pane is
    /// about the terminal Bloom draws, and the settings that ARE, its text size and whether a
    /// shell survives a quit, live in Appearance. Somebody hunting for a terminal font size
    /// clicked Terminal and got `claude mcp add --scope user`.
    case commandLine
    // **There was a `storage` case and there is no pane for it any more.** It was a sidebar
    // screen before it was a tab, and it is Home's Archived chip now: the same archived
    // workspaces, with the size, the order and the totals that were the only things this window
    // held and that list did not. A tab whose whole content is somewhere else is the second copy
    // this app has spent its evenings removing.
    case about

    /// The tab's name in the row.
    ///
    /// Here rather than at every `Tab` call site, so that `SettingsTabRow` measures the
    /// words the window actually draws instead of a second copy of them.
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .projects: "Projects"
        case .models: "Models"
        case .agents: "Agents"
        case .prompts: "Prompts"
        case .approvals: "Approvals"
        case .tools: "Tools"
        case .commandLine: "Command Line"
        case .about: "About"
        }
    }
}

/// How wide the window has to be before every tab is on it.
///
/// A `Settings` scene's `TabView` is an `NSToolbar` in preference style, icon over label, and a
/// toolbar with more items than fit does not wrap or scroll them: it folds the tail behind a `»`.
/// The window's minimum was 640 and its doc argued only about the widest form row, which is a
/// different question from the row above it, so Settings opened with its last panes already
/// hidden in an overflow menu nobody has a reason to look in.
///
/// **Measured off the titles rather than written down as a number**, so renaming a pane or adding
/// one moves the minimum with it, which is the failure that put the number 640 next to a dozen
/// tabs in the first place. The measuring itself is `TranscriptLabelWidth`'s trick and is memoised
/// for the same reason: one CoreText run, and the answer cannot change while the app is running.
///
/// What is NOT measured is the toolbar's own allowance around a label and the floor it puts under
/// a short one. Those are AppKit's, they are published nowhere, and the two values below are an
/// estimate. They are deliberately generous: a settings window a few points wider than it needs
/// costs desk space, and one a few points narrower hides four panes. If the row still folds, these
/// two are the numbers to raise.
@MainActor
enum SettingsTabRow {
    /// Around a preference item's label, both sides together.
    private static let allowance: CGFloat = 20
    /// Under a short label, because an item is at least as wide as the glyph and its padding.
    /// Not called `floor`, which is a function in scope here and would read as a call.
    private static let shortest: CGFloat = 60
    /// The toolbar's own inset at the two ends of the row.
    private static let ends: CGFloat = 24

    private static var memo: CGFloat?

    static var width: CGFloat {
        if let memo { return memo }

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let measured = SettingsTab.allCases.reduce(ends) { total, tab in
            let label = (tab.title as NSString).size(withAttributes: [.font: font]).width
            return total + max(shortest, label.rounded(.up) + allowance)
        }
        memo = measured
        return measured
    }
}
