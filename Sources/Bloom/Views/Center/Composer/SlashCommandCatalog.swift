import Foundation
import Observation
import BloomCore

/// Holds the `/command` list for one workspace, and decides when it is worth reading again.
///
/// The scan is a walk of six directories plus a bounded read per file. That is a few milliseconds
/// once and pure waste on every keystroke, so it happens twice: when the composer first points at
/// a checkout, and again when the user opens the menu after the list has been sitting still for
/// `stalenessWindow`. Opening the menu is the only moment a stale list can be seen, and a person
/// who has just written a new skill in another window types `/` before they can notice it is
/// missing. Nothing watches the filesystem, because a watcher on `~/.claude` would have to be
/// alive for every workspace at once to answer a question that is only ever asked here.
@MainActor
@Observable
final class SlashCommandCatalog {
    private(set) var commands: [SlashCommand] = []
    /// Whether a scan has finished. The menu says something different before the first one lands
    /// than it does when the list is genuinely empty.
    private(set) var isLoaded = false

    private var loadedPath: String?
    private var loadedAt: Date?
    /// `commands` by name, for the lookup the composer does on every pass. Observed like the list
    /// it indexes, because the chip's description is drawn from it and has to arrive when the scan
    /// does.
    private var byName: [String: SlashCommand] = [:]
    /// The scan that is already running, and the checkout it is running for, so a second caller
    /// joins it rather than starting a duplicate walk of the same directories.
    private var running: Task<[SlashCommand], Never>?
    private var runningPath: String?

    /// How long a list is taken on trust before opening the menu re-reads it.
    static let stalenessWindow: TimeInterval = 3

    /// One catalogue per checkout, shared by every composer pointing at it.
    ///
    /// **A composer used to hold its own, and that turned a tab switch into a disk scan.** The
    /// centre pane is destroyed and rebuilt when the column changes tab, so the fresh catalogue
    /// that came with it had `loadedPath == nil` and walked six directories to depth six, up to
    /// five hundred entries each, reading the front of every file it found, for a list the last
    /// composer had already built. The walk is off the main actor, so what it cost was disk
    /// contention during the switch and a slash menu that showed its loading state again.
    ///
    /// Held for the life of the launch, like `ComposerModelCatalog.shared` and `FileIndex.shared`.
    /// One entry per checkout the window has visited, each a list of tens of commands, so there is
    /// nothing here worth evicting.
    private static var byPath: [String: SlashCommandCatalog] = [:]

    static func shared(for workspacePath: String) -> SlashCommandCatalog {
        if let held = byPath[workspacePath] { return held }
        let made = SlashCommandCatalog()
        byPath[workspacePath] = made
        return made
    }

    /// Builds the list for a checkout, and does nothing at all if it is already the one held.
    func load(workspacePath: String) async {
        guard loadedPath != workspacePath else { return }
        await scan(workspacePath: workspacePath)
    }

    /// Re-reads only if the held list is old enough to have missed something.
    func refreshIfStale(workspacePath: String, now: Date = Date()) async {
        if loadedPath == workspacePath,
           let loadedAt,
           now.timeIntervalSince(loadedAt) < Self.stalenessWindow {
            return
        }
        await scan(workspacePath: workspacePath)
    }

    /// Re-reads whatever the state of the held list.
    func reload(workspacePath: String) async {
        loadedAt = nil
        await scan(workspacePath: workspacePath)
    }

    /// What the catalogue knows about one name, or nothing.
    ///
    /// Nothing is a real answer and not an error: a draft restored from another machine, or a
    /// mistyped name, still leads with something the CLI will be handed, and the chip that draws
    /// it says only what it can stand behind.
    ///
    /// Indexed rather than searched. The composer asks this for the chip and for the chip's hover
    /// card on every pass, and a scan of every command and skill on the machine is a strange price
    /// for a lookup by name.
    func command(named name: String) -> SlashCommand? {
        byName[name]
    }

    /// Ranks the list against the text typed after the `/`.
    func matches(_ query: String) -> [SlashCommandMatch] {
        SlashCommand.rank(commands, query: query)
    }

    // MARK: - Disk

    private func scan(workspacePath: String) async {
        let task: Task<[SlashCommand], Never>
        if let running, runningPath == workspacePath {
            task = running
        } else {
            let home = NSHomeDirectory()
            task = Task.detached(priority: .utility) {
                SlashCommandIndex.discover(home: home, project: workspacePath)
            }
            running = task
            runningPath = workspacePath
        }

        let found = await task.value
        // Superseded means another checkout's scan replaced this one while its disk walk was
        // out. Its answer must not land: `await` does not stop for cancellation on a
        // non-throwing task, and a slow walk for workspace A that resumed after B's finished
        // used to write A's commands, and `loadedPath = A`, over the list B had just built.
        guard running == task else { return }
        running = nil
        runningPath = nil

        loadedPath = workspacePath
        loadedAt = Date()
        isLoaded = true
        // Assigning an identical list would still invalidate every view observing it, and this
        // runs every few seconds while a menu is open.
        guard found != commands else { return }
        commands = found
        // The FIRST definition of a name wins, which is what the linear search this replaced did.
        // Two files can define one name, and which of them the chip described is not a thing to
        // change while making the lookup cheaper.
        byName = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
