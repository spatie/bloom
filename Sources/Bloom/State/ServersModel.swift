import Foundation
import Observation
import BloomCore

/// The state behind the Servers pane: the list, and what the last look at each one found.
///
/// It exists because a `View` runs no subprocess. Everything on this screen is either a store call
/// or an `ssh`, and both of those belong on the far side of a type the pane can hold rather than
/// inside a `body` that runs again on every redraw. The decisions themselves are further away
/// still: `SSHDestination.parse`, `ServerProbe.parse`, `Bloomd.decide` and `ServerVerdict` all
/// live in the core with tests over them, and what is left here is sequencing and the two pieces
/// of per-window state (which row is selected, which rows are being looked at) that no store has
/// an opinion about.
@MainActor
@Observable
final class ServersModel {
    private(set) var servers: [Server] = []
    /// What the last checkup found on each server, for as long as this window is open.
    ///
    /// In memory rather than in the store, deliberately. A row's state and its one sentence are
    /// worth keeping across a relaunch; a tool inventory is a photograph of a machine somebody
    /// else may have installed something on ten minutes ago, and a stale one drawn confidently is
    /// worse than an empty pane with a Check button on it.
    private(set) var facts: [ServerID: ServerFacts] = [:]
    private(set) var actions: [ServerID: BloomdAction] = [:]
    /// Which rows have a look in flight, so two clicks do not start two.
    private(set) var busy: Set<ServerID> = []
    /// What the Add field should say went wrong, or nil.
    private(set) var addProblem: String?

    var selection: ServerID?

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    // MARK: - The list

    func load() async {
        servers = (try? await store.servers()) ?? []
        if selection == nil || !servers.contains(where: { $0.id == selection }) {
            selection = servers.first?.id
        }
    }

    var selected: Server? {
        servers.first { $0.id == selection }
    }

    // MARK: - Adding and removing

    /// Reads what was typed, writes a row, and immediately goes and looks.
    ///
    /// The row is written BEFORE the look, which is the only ordering that survives a server that
    /// does not answer: a twenty second probe that fails on a row nobody has saved yet leaves the
    /// user with an empty field and nothing to retry.
    func add(_ text: String) async {
        addProblem = nil
        let destination: SSHDestination
        do {
            destination = try SSHDestination.parse(text)
        } catch let problem as SSHDestinationProblem {
            addProblem = problem.description
            return
        } catch {
            addProblem = "\(error)"
            return
        }

        guard !servers.contains(where: { $0.destination == destination }) else {
            addProblem = "\(destination.display) is already in the list."
            return
        }

        let server = Server(label: destination.suggestedLabel, destination: destination)
        do {
            _ = try await store.insert(server)
        } catch {
            addProblem = "Could not save it: \(error)"
            return
        }
        await load()
        selection = server.id
        await check(server.id)
    }

    func remove(_ id: ServerID) async {
        try? await store.deleteServer(id: id)
        facts[id] = nil
        actions[id] = nil
        await load()
    }

    func rename(_ id: ServerID, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await store.update(serverID: id) { $0.label = trimmed }
        await load()
    }

    func dismissAddProblem() {
        addProblem = nil
    }

    // MARK: - Looking

    /// Probe it, install `bloomd` if it needs it, and file the answer.
    ///
    /// Nobody is asked about the install. See `ServerCheckup`: noticing that the file on the
    /// server is not the file in the bundle and copying it over the connection that is already
    /// open is the whole of "so it works seamless".
    func check(_ id: ServerID) async {
        guard !busy.contains(id), let server = servers.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        defer { busy.remove(id) }

        _ = try? await store.markServerProbing(serverID: id)
        await load()

        let checkup = ServerCheckup(
            runner: SSHCommandRunner(destination: server.destination),
            source: Self.bloomdSource
        )

        do {
            let outcome = try await checkup.run()
            facts[id] = outcome.facts
            actions[id] = outcome.action
            _ = try? await store.recordProbe(
                serverID: id,
                verdict: outcome.verdict,
                bloomdVersion: outcome.bloomdVersion
            )
        } catch {
            // Whatever went wrong, the row has to end up with a state and a sentence. The mapping
            // is `ServerVerdict.failed`, in the core, so the pane never invents a message.
            facts[id] = nil
            actions[id] = nil
            _ = try? await store.recordProbe(
                serverID: id,
                verdict: .failed(error),
                bloomdVersion: nil
            )
        }
        await load()
    }

    func checkAll() async {
        // One at a time rather than a task group. Each of these opens an SSH connection and the
        // person watching is reading the list top to bottom; four spinners settling at once is
        // less legible than four settling in order, and nothing here is fast enough for the
        // difference to be about speed.
        for server in servers {
            await check(server.id)
        }
    }

    // MARK: - What this build ships

    /// The `bloomd.py` inside this app bundle, read once.
    ///
    /// Read at first use and kept, because it is a file in the bundle and cannot change while the
    /// app is running. Nil when the build has no copy of it, which `ServerCheckup` reports as the
    /// broken build it is rather than as a broken server.
    static let bloomdSource: String? = {
        guard let path = Bloomd.sourcePath() else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }()

    /// The version this build would install, for the row that says so.
    static var shippingBloomdVersion: String? {
        bloomdSource.flatMap(Bloomd.version(of:))
    }
}
