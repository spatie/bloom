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
    /// The scan that is already running, and the checkout it is running for, so a second caller
    /// joins it rather than starting a duplicate walk of the same directories.
    private var running: Task<[SlashCommand], Never>?
    private var runningPath: String?

    /// How long a list is taken on trust before opening the menu re-reads it.
    static let stalenessWindow: TimeInterval = 3

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
        if running == task {
            running = nil
            runningPath = nil
        }

        loadedPath = workspacePath
        loadedAt = Date()
        isLoaded = true
        // Assigning an identical list would still invalidate every view observing it, and this
        // runs every few seconds while a menu is open.
        if found != commands { commands = found }
    }
}
