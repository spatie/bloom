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
                label: style.name == OutputStyle.defaultName ? "Default" : style.name,
                // On the row rather than under the picker. It was one footnote describing the
                // style already chosen, because an `NSMenu` row is one line of text and four
                // descriptions cannot sit beside four names; the picker is a panel of two line
                // rows now, so all four are readable before one is picked.
                detail: style.detail
            )
        }
        // Whatever the session is set to, kept on the list even if the style has since been
        // deleted or renamed. It arrives with no sentence, which is honest: there is no file left
        // to read one out of.
        return ComposerOption.adding([current], to: known)
    }

    /// One style's own sentence, for a caller drawing a list it did not build.
    ///
    /// The composer no longer asks: its rows carry a sentence each. What is left is the Settings
    /// screen, whose picker is a `Picker` inside a `Form` and whose subtitle line is the platform's
    /// own place for this. It is a settings row rather than a menu of consequences, so it keeps the
    /// system control.
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
