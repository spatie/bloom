import Foundation
import Synchronization

/// Bloom's end of the bridge: one listening socket for the whole app, one connection per running
/// agent process, and one identity per connection.
///
/// **It never constructs an `AgentRunner`, and nothing added to it ever may.** One runner per
/// session is held today in main-actor UI object identity: `AppModel.workspaceModels`,
/// `WorkspaceModel.transcript(for:)` and `TranscriptModel.ensureRunner`, whose sibling
/// `makeRunner` is documented as the one place a backend becomes a process. A handler that built
/// its own runner would put a second CLI process on the same session row and the same worktree,
/// both writing `agent_session_id` and both editing the same files. Every operation that needs a
/// runner (starting a child's first turn, delivering a message or a report) hops to the main actor
/// and goes through the doors the UI uses. `whoami` needs no runner, so phase one only has to
/// establish the rule.
///
/// It also holds no database connection of its own. `Store` is an actor whose `update` methods
/// re-read inside the actor, so a handler on a background task may call them directly; what it
/// must never do is open a second `SQLiteDatabase` on the file, because the cross-connection
/// sequence race is what `UNIQUE(session_id, seq)` and the retry in `appendNext` exist to survive
/// rather than to invite.
public final class BridgeServer: Sendable {
    private let store: Store
    private let toolbox: BridgeToolbox
    public let registry: BridgeRegistry
    public let socketPath: String
    /// Said out loud where the app can log it. The core has no logger of its own and should not
    /// grow one for this.
    private let note: @Sendable (String) -> Void

    private let listener = Mutex<UnixSocketListener?>(nil)

    /// The owner's standalone token, on disk beside the database. See `BridgeOwnerToken` for why
    /// this one persists when no session token does.
    public let ownerToken: BridgeOwnerToken

    public init(
        store: Store,
        socketPath: String,
        registry: BridgeRegistry = BridgeRegistry(),
        toolbox: BridgeToolbox = .standard,
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.socketPath = socketPath
        self.registry = registry
        self.toolbox = toolbox
        self.note = note
        self.ownerToken = BridgeOwnerToken.beside(databasePath: store.path)
    }

    /// The socket for the instance holding this store's database.
    public convenience init(
        store: Store,
        registry: BridgeRegistry = BridgeRegistry(),
        toolbox: BridgeToolbox = .standard,
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.init(
            store: store,
            socketPath: try BridgeSocketPath.derive(databasePath: store.path),
            registry: registry,
            toolbox: toolbox,
            note: note
        )
    }

    /// `[weak self]` rather than `[self]`, and it is the difference between a server that can be
    /// let go of and one that can only be told to `stop()`.
    ///
    /// The accept handler is held by the `DispatchSource`, the source by the listener and the
    /// listener by this server, so a strong capture here closed the ring and nothing in it was
    /// ever released. A server dropped out of scope went on listening, and its socket file stayed
    /// on disk because the listener's `deinit`, which is what removes it, could not run. On a real
    /// installation only one server is ever built and the socket name is derived from the database
    /// path, so a successor unlinks it before binding and nobody notices; in a test suite that
    /// builds one per case it left 44 sockets and 19 config directories behind.
    ///
    /// A connection already being served does hold the server, through the `Task` below, for as
    /// long as that agent is talking. That is not the cycle: it ends when the conversation does.
    public func start() throws {
        try listener.withLock { held in
            guard held == nil else { return }
            held = try UnixSocketListener(path: socketPath) { [weak self] connection in
                guard let self else {
                    // The server this socket belonged to is gone, so nothing will ever answer.
                    // Closing beats leaving the caller waiting on a hello that is not coming.
                    connection.close()
                    return
                }
                Task { await self.serve(connection) }
            }
        }
        sweepConfigDirectory()
        admitOwner()
        note("bridge listening on \(socketPath)")
    }

    // MARK: The owner's own client

    /// Reads the standalone token off disk, minting one the first time, and lets it through the
    /// handshake.
    ///
    /// Done at start rather than when the Settings pane is opened, because the configuration the
    /// owner pasted months ago has to work on this launch without anybody visiting a settings
    /// window first. A failure is survivable and is not an alert: everything else on this socket
    /// still works, and the only thing lost is a door nobody may be using.
    private func admitOwner() {
        do {
            registry.admit(ownerToken: try ownerToken.load())
        } catch {
            note("could not read the standalone bridge token: \(error.readableMessage)")
        }
    }

    /// What the owner pastes into their own MCP configuration, or nil when this build has no shim
    /// to point at, which is a bundle assembled without one and every test that did not ask for a
    /// bridge.
    ///
    /// The role in it is `owner`, and like every other role in an attachment it is carried for
    /// diagnostics only: the server resolves the real one from the token. See
    /// `BridgeProtocol.roleVariable`.
    public func ownerAttachment() -> BridgeAttachment? {
        guard let shimPath = BridgeRegistration.shimPath() else { return nil }
        guard let token = try? ownerToken.load() else { return nil }
        registry.admit(ownerToken: token)
        return BridgeAttachment(
            shimPath: shimPath,
            socketPath: socketPath,
            token: token,
            role: .owner
        )
    }

    /// Revokes the standalone token and issues its replacement.
    ///
    /// The old one stops being answered the moment this returns, so whatever the owner pasted
    /// somewhere goes dead. That is the point of the button, and the pane offering it says so.
    @discardableResult
    public func regenerateOwnerToken() throws -> String {
        let token = try ownerToken.regenerate()
        registry.admit(ownerToken: token)
        note("the standalone bridge token was regenerated")
        return token
    }

    public func stop() {
        listener.withLock { held in
            held?.stop()
            held = nil
        }
    }

    /// What a session's shim is told, minted fresh. Called once per runner, which is once per
    /// session per launch of the app, by whoever is about to build that process's argv.
    ///
    /// The role comes off the workspace row rather than from the caller, so a caller cannot state
    /// one. A workspace with a parent is a child, and having a parent is the whole test.
    public func attach(
        session: Session,
        workspace: Workspace,
        shimPath: String
    ) -> BridgeAttachment {
        let role = BridgeRole(origin: workspace.origin)
        let token = registry.mint(sessionID: session.id, workspaceID: workspace.id, role: role)
        return BridgeAttachment(
            shimPath: shimPath,
            socketPath: socketPath,
            token: token,
            role: role
        )
    }

    /// The same, plus whatever this chat's backend needs written to disk first.
    ///
    /// Nil when there is no shim to point at, which is a build assembled without one and every
    /// test that did not ask for a bridge. The chat then runs with no bridge tools, which is what
    /// every chat had before this existed, rather than failing to start.
    public func register(session: Session, workspace: Workspace) -> BridgeHandle? {
        guard let shimPath = BridgeRegistration.shimPath() else {
            note("no bloom-bridge beside the running executable, so \(session.id) gets no bridge")
            return nil
        }
        let attachment = attach(session: session, workspace: workspace, shimPath: shimPath)
        switch session.agentKind {
        case .claudeCode, .cursor, .openCode:
            do {
                let path = try BridgeRegistration.writeClaudeConfig(
                    attachment,
                    sessionID: session.id,
                    directory: configDirectory
                )
                sweepConfigDirectory()
                return BridgeHandle(attachment: attachment, mcpConfigPath: path)
            } catch {
                // A chat with no bridge is a chat as it was last week. A chat that refused to
                // start because a scratch file could not be written would be a regression.
                note("could not write the bridge config for \(session.id): \(error.readableMessage)")
                return nil
            }
        case .codex:
            return BridgeHandle(attachment: attachment, mcpConfigPath: nil)
        }
    }

    /// Drops a session's token and the config file that carried it.
    ///
    /// The token is refused at the handshake from this moment, so the file is a dead letter: it
    /// names a shim binary and a socket that will answer it with "Bloom does not recognise this
    /// token". Leaving it behind is what filled the config directory with 63 of them.
    public func retire(sessionID: SessionID) {
        registry.retire(sessionID: sessionID)
        try? FileManager.default.removeItem(atPath: configPath(for: sessionID))
    }

    /// Removes every config file whose token nothing could still use.
    ///
    /// Nothing removed these, and unlike the socket beside them they are one per session rather
    /// than one per instance, so they only ever grew. Tokens live in memory for one launch, which
    /// makes the test cheap and exact: a file whose session is not currently minted is a file no
    /// handshake can ever accept again, whether its session was retired a minute ago or its whole
    /// launch ended last week. Run when the server starts, which clears out everything a previous
    /// launch left, and after each registration, so a long-running app does not accumulate the
    /// sessions it has finished with.
    ///
    /// Failures are ignored on purpose. A chat must not fail to start because a scratch file in a
    /// temporary directory could not be deleted.
    public func sweepConfigDirectory() {
        let live = registry.liveSessions
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: configDirectory) else { return }
        for name in names where name.hasSuffix(Self.configSuffix) {
            let session = SessionID(rawValue: String(name.dropLast(Self.configSuffix.count)))
            guard !live.contains(session) else { continue }
            try? manager.removeItem(atPath: (configDirectory as NSString).appendingPathComponent(name))
        }
    }

    static let configSuffix = ".mcp.json"

    public func configPath(for sessionID: SessionID) -> String {
        (configDirectory as NSString).appendingPathComponent("\(sessionID)\(Self.configSuffix)")
    }

    /// Where the per-session Claude Code config files live: one directory per instance, named from
    /// the same fingerprint as the socket beside it, so Bloom and Bloom Dev cannot read each
    /// other's. Mode 0700, and each file inside it 0600.
    public var configDirectory: String {
        (socketPath as NSString).deletingPathExtension + ".d"
    }

    // MARK: One connection

    private func serve(_ connection: UnixSocketConnection) async {
        var iterator = connection.lines.makeAsyncIterator()

        // The hello, first line and nothing before it. A connection that sends MCP straight away
        // is a connection that did not come from a shim of this version, and it is refused rather
        // than guessed at.
        guard let opening = await iterator.next() else {
            connection.close()
            return
        }
        guard let identity = await handshake(opening, on: connection) else {
            connection.close()
            return
        }

        let dispatch = BridgeDispatch(store: store, identity: identity, toolbox: toolbox)
        while let line = await iterator.next() {
            if let reply = await dispatch.respond(to: line) {
                connection.writeLine(reply)
            }
        }
        connection.close()
    }

    /// Answers the hello and says who is calling, or refuses in one sentence.
    ///
    /// The version is judged before the token, so a shim from a newer bundle meeting an older
    /// running Bloom is told about the version rather than about an unknown token, which is what
    /// it would otherwise look like: the token really would be unknown, because it was minted by
    /// the other copy.
    private func handshake(_ line: String, on connection: UnixSocketConnection) async -> BridgeIdentity? {
        guard let data = line.data(using: .utf8),
              let hello = try? JSONDecoder().decode(BridgeHello.self, from: data)
        else {
            refuse("This is Bloom's workspace bridge and that was not a hello frame.", on: connection)
            return nil
        }
        if let problem = BridgeProtocol.problem(with: hello) {
            refuse(problem, on: connection)
            note("bridge refused a shim speaking protocol \(hello.version)")
            return nil
        }
        guard let identity = registry.identity(forToken: hello.token) else {
            // The ordinary cause is a config file left over from a previous launch: tokens live in
            // memory, so every one of them is retired by a quit.
            refuse(
                "Bloom does not recognise this token. It was minted by a previous launch; "
                    + "quit and reopen Bloom.",
                on: connection
            )
            return nil
        }
        if hello.role != identity.role.rawValue {
            // Logged and ignored. The environment is the shim's claim and anything running as the
            // user can make it; the database is the answer.
            note("bridge caller claimed role \(hello.role) and is \(identity.role.rawValue)")
        }
        connection.writeLine(encode(BridgeWelcome.accepting()))
        return identity
    }

    private func refuse(_ problem: String, on connection: UnixSocketConnection) {
        connection.writeLine(encode(BridgeWelcome.refusing(problem)))
    }

    private func encode(_ welcome: BridgeWelcome) -> String {
        guard let data = try? JSONEncoder().encode(welcome) else {
            // Unreachable for three fields of plain types. Answered with something the shim can
            // still parse rather than with silence, because silence is the one outcome the
            // handshake exists to prevent.
            return #"{"version":\#(BridgeProtocol.version),"accepted":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
