import Foundation
import Observation
import BloomCore

/// Holds the output style list for one checkout, and decides when it is worth reading again.
///
/// Built on the same terms as `SlashCommandCatalog`, and for the same reason: the scan is a walk
/// of two directories plus a bounded read per file, which is nothing once and pure waste on every
/// render. `ViewThatFits` builds the composer's footer three times per pass, so a footer that read
/// the disk in `body` would read it three times for one frame.
///
/// The built in styles are in the list before any scan finishes, because they are compiled into
/// this app the same way they are compiled into the CLI. So the menu is never empty and never
/// wrong; a custom style simply appears once the walk lands, without anything having to be
/// reopened. Nothing watches the filesystem: a person who has just written a style in another
/// window opens this menu long after `stalenessWindow` has passed.
@MainActor
@Observable
final class ComposerOutputStyleCatalog {
    private(set) var styles: [OutputStyle] = OutputStyle.builtIns

    private var loadedPath: String?
    private var loadedAt: Date?
    /// The scan already running, and the checkout it is running for, so a second caller joins it
    /// rather than starting a duplicate walk of the same directories.
    private var running: Task<[OutputStyle], Never>?
    private var runningPath: String?

    /// How long a list is taken on trust before opening the menu re-reads it.
    static let stalenessWindow: TimeInterval = 3

    /// One catalogue per checkout, shared by every footer pointing at it.
    ///
    /// Held on the same terms as `SlashCommandCatalog.shared(for:)` and for the same bug: the
    /// footer's own copy came and went with the pane, so switching tab threw away a list that had
    /// just been read off disk and scanned for it again. `refreshIfStale` already declined to
    /// re-read a list that was fresh; what it could not do was find one, because the object
    /// holding it had been destroyed with the view.
    ///
    /// Keyed on the project, which can be nil in the create window, where there is no checkout yet
    /// and the built in styles are the whole answer.
    private static var byProject: [String: ComposerOutputStyleCatalog] = [:]

    static func shared(for project: String?) -> ComposerOutputStyleCatalog {
        let key = project ?? ""
        if let held = byProject[key] { return held }
        let made = ComposerOutputStyleCatalog()
        byProject[key] = made
        return made
    }

    /// Re-reads only if the held list is for another checkout, or is old enough to have missed
    /// something. Cheap to call on every appearance, which is how the footer calls it.
    func refreshIfStale(project: String?, now: Date = Date()) async {
        if loadedPath == project,
           let loadedAt,
           now.timeIntervalSince(loadedAt) < Self.stalenessWindow {
            return
        }
        await scan(project: project)
    }

    /// The rows a picker should offer, with whatever this session is set to kept on the list.
    ///
    /// A style can be deleted, or renamed, while a session is still pointing at it. Dropping the
    /// name would make the picker a one-way door out of a setting that is still in force, which is
    /// the trap `ComposerOption.adding` was written for on the model menu.
    func options(includingCurrent current: String) -> [ComposerOption] {
        let known = styles.map { style in
            // The id and the label are the same for every style but one. A style is called what it
            // is called, by the CLI and by the person, so there is nothing to translate. The
            // exception is the default, whose stored value is the CLI's own lowercase key and
            // whose row is a word at the top of a menu.
            ComposerOption(
                id: style.name,
                label: style.name == OutputStyle.defaultName ? "Default" : style.name
            )
        }
        return ComposerOption.adding([current], to: known)
    }

    /// The sentence under the menu, which is whichever style is selected describing itself. An
    /// `NSMenu` row is one line of text, so four descriptions cannot sit beside four names, and
    /// the one worth reading is the one in force.
    func detail(of name: String) -> String? {
        styles.first { $0.name == name }?.detail
    }

    // MARK: - Disk

    private func scan(project: String?) async {
        let task: Task<[OutputStyle], Never>
        if let running, runningPath == project {
            task = running
        } else {
            let home = NSHomeDirectory()
            task = Task.detached(priority: .utility) {
                OutputStyleIndex.discover(home: home, project: project)
            }
            running = task
            runningPath = project
        }

        let found = await task.value
        // Superseded means another project's scan replaced this one while its disk walk was
        // out; its answer must not land. See `SlashCommandCatalog.scan` for the failure this
        // guard closes.
        guard running == task else { return }
        running = nil
        runningPath = nil

        loadedPath = project
        loadedAt = Date()
        // Assigning an identical list would still invalidate every view observing it, and on a
        // machine with no custom styles at all every scan returns exactly what is already held.
        if found != styles { styles = found }
    }
}
