import Foundation
import Testing
@testable import BloomCore

/// The one bridge token that survives a relaunch, and the command that carries it out of the app.
@Suite("The owner's bridge token", .scratchDirectory)
struct BridgeOwnerTokenTests {
    private func token(_ label: String = "owner") -> BridgeOwnerToken {
        BridgeOwnerToken(path: TestScratch.unique(label) + "/bridge-owner-token")
    }

    @Test("the first read mints one and writes it where the second read finds it")
    func persists() throws {
        let store = token()

        let first = try store.load()
        let second = try store.load()

        #expect(!first.isEmpty)
        #expect(first == second)
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    /// The point of the whole type. A session token is rebuilt at every process start and a
    /// pasted configuration is not, so this one has to read back the same across what is, for a
    /// file, the same thing as a relaunch: a completely new instance pointed at the same path.
    @Test("a fresh instance on the same path reads back the same token")
    func survivesARelaunch() throws {
        let path = TestScratch.unique("relaunch") + "/bridge-owner-token"

        let before = try BridgeOwnerToken(path: path).load()
        let after = try BridgeOwnerToken(path: path).load()

        #expect(before == after)
    }

    @Test("the file and the directory holding it are not readable by anybody else")
    func modes() throws {
        let store = token("modes")
        _ = try store.load()

        let manager = FileManager.default
        let file = try manager.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber
        let directory = (store.path as NSString).deletingLastPathComponent
        let folder = try manager.attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber

        #expect(file?.int16Value == 0o600)
        #expect(folder?.int16Value == 0o700)
    }

    @Test("regenerating replaces it, which is the whole of revoking it")
    func regenerates() throws {
        let store = token("regen")
        let first = try store.load()

        let second = try store.regenerate()

        #expect(first != second)
        #expect(try store.load() == second)
    }

    /// The file is plain text in a directory a person can open, so an editor's trailing newline
    /// must not turn into a token that no longer matches what was pasted.
    @Test("whitespace around a hand edited token is ignored")
    func trimmed() throws {
        let store = token("trimmed")
        let written = try store.load()
        try Data("\n  \(written)  \n".utf8).write(to: URL(fileURLWithPath: store.path))

        #expect(try store.load() == written)
    }

    /// A Bloom that cannot be coupled to anything until somebody deletes a file they were never
    /// told about is worse than one that mints again.
    @Test("an empty file is treated as no file at all")
    func emptyFileRemints() throws {
        let store = token("empty")
        _ = try store.load()
        try Data("\n".utf8).write(to: URL(fileURLWithPath: store.path))

        #expect(!(try store.load().isEmpty))
    }

    @Test("it lives beside the database, so two copies of Bloom cannot share one")
    func besideTheDatabase() {
        let one = BridgeOwnerToken.beside(databasePath: "/x/Bloom/bloom.sqlite")
        let other = BridgeOwnerToken.beside(databasePath: "/x/Bloom Dev/bloom.sqlite")

        #expect(one.path == "/x/Bloom/bridge-owner-token")
        #expect(one.path != other.path)
    }
}

@Suite("Admitting the owner")
struct BridgeOwnerAdmissionTests {
    @Test("an admitted token resolves to the owner, in no session and no workspace")
    func admits() {
        let registry = BridgeRegistry()

        registry.admit(ownerToken: "abc")

        let identity = registry.identity(forToken: "abc")
        #expect(identity?.role == .owner)
        #expect(identity?.workspaceID == nil)
        #expect(identity?.sessionID == nil)
    }

    @Test("admitting a new one retires the last, so regenerating really does revoke")
    func replaces() {
        let registry = BridgeRegistry()
        registry.admit(ownerToken: "old")

        registry.admit(ownerToken: "new")

        #expect(registry.identity(forToken: "old") == nil)
        #expect(registry.identity(forToken: "new")?.role == .owner)
    }

    /// `liveSessions` is what the config sweep asks, and an owner token in there would look like a
    /// session whose config file has gone missing, every launch, for ever.
    @Test("the owner's token is not a live session")
    func notASession() {
        let registry = BridgeRegistry()
        registry.admit(ownerToken: "abc")

        #expect(registry.liveSessions.isEmpty)
    }

    @Test("a session token still says which workspace, and is not the owner")
    func sessionsAreUnaffected() {
        let registry = BridgeRegistry()
        let token = registry.mint(
            sessionID: SessionID(rawValue: "s1"),
            workspaceID: WorkspaceID(rawValue: "w1"),
            role: .parent
        )
        registry.admit(ownerToken: "abc")

        #expect(registry.identity(forToken: token)?.role == .parent)
        #expect(registry.identity(forToken: token)?.workspaceID == WorkspaceID(rawValue: "w1"))
    }
}

@Suite("What the owner copies out of Settings")
struct BridgeOwnerCommandTests {
    private func attachment(
        shim: String = "/Applications/Bloom.app/Contents/MacOS/bloom-bridge",
        socket: String = "/tmp/bloom-bridge-abc.sock",
        token: String = "deadbeef"
    ) -> BridgeAttachment {
        BridgeAttachment(shimPath: shim, socketPath: socket, token: token, role: .owner)
    }

    @Test("it is one command, at user scope, naming the shim and the three variables")
    func shape() {
        let command = BridgeRegistration.ownerAddCommand(attachment())

        #expect(command.hasPrefix("claude mcp add --scope user "))
        #expect(command.contains(BridgeRegistration.ownerServerName))
        #expect(command.contains("-e 'BLOOM_BRIDGE_SOCKET=/tmp/bloom-bridge-abc.sock'"))
        #expect(command.contains("-e 'BLOOM_BRIDGE_TOKEN=deadbeef'"))
        #expect(command.contains("-e 'BLOOM_BRIDGE_ROLE=owner'"))
        #expect(command.hasSuffix("-- '/Applications/Bloom.app/Contents/MacOS/bloom-bridge'"))
    }

    @Test("Codex receives the same owner connection")
    func codexShape() {
        let command = BridgeRegistration.ownerCodexAddCommand(attachment())

        #expect(command.hasPrefix("codex mcp add \(BridgeRegistration.ownerServerName) "))
        #expect(command.contains("--env 'BLOOM_BRIDGE_SOCKET=/tmp/bloom-bridge-abc.sock'"))
        #expect(command.contains("--env 'BLOOM_BRIDGE_TOKEN=deadbeef'"))
        #expect(command.contains("--env 'BLOOM_BRIDGE_ROLE=owner'"))
        #expect(command.hasSuffix("-- '/Applications/Bloom.app/Contents/MacOS/bloom-bridge'"))
    }

    /// The name the owner registers under cannot be the one Bloom's own `--mcp-config` uses: that
    /// file is additive over the user's configuration, so a shared name would put two entries
    /// called the same thing in one client, one of them holding the owner's token.
    @Test("the standalone server is not named the same as the per session one")
    func distinctName() {
        #expect(BridgeRegistration.ownerServerName != BridgeRegistration.serverName)
    }

    /// The name is derived per copy of the app rather than fixed, and that is a defect fixed
    /// rather than a preference. `claude mcp add` replaces an existing entry of the same name
    /// without saying so, and `--scope user` is one file for the whole machine, so a constant name
    /// meant Bloom Dev's command silently evicted the owner's real registration. The table is
    /// `Store.databaseDirectoryName`, so a shared name now implies a shared database.
    @Test("each copy of Bloom registers under a name of its own")
    func namePerInstance() {
        #expect(
            BridgeRegistration.ownerServerName(forBundleIdentifier: Store.primaryBundleIdentifier)
                == "bloom"
        )
        #expect(
            BridgeRegistration.ownerServerName(forBundleIdentifier: Store.devBundleIdentifier)
                == "bloom-dev"
        )
        #expect(
            BridgeRegistration.ownerServerName(forBundleIdentifier: "be.spatie.bloom.beta")
                == "bloom-be-spatie-bloom-beta"
        )
        #expect(BridgeRegistration.ownerServerName(forBundleIdentifier: nil) == "bloom-unbundled")
    }

    @Test("a name is lower case, hyphenated, and never empty")
    func slugs() {
        #expect(BridgeRegistration.slugified("Bloom Dev") == "bloom-dev")
        #expect(BridgeRegistration.slugified("  Bloom (caf\u{e9} 2) ") == "bloom-caf-2")
        #expect(BridgeRegistration.slugified("...") == "")
        // Nothing survives the slug, so the fallback answers instead of handing `claude mcp add`
        // an empty name and letting it read the shim path as one.
        #expect(BridgeRegistration.ownerServerName(forBundleIdentifier: nil).isEmpty == false)
    }

    @Test("a path with a space in it survives the shell")
    func quotesPaths() {
        let command = BridgeRegistration.ownerAddCommand(
            attachment(shim: "/Users/me/Applications/Bloom Dev.app/Contents/MacOS/bloom-bridge")
        )

        #expect(command.hasSuffix(
            "-- '/Users/me/Applications/Bloom Dev.app/Contents/MacOS/bloom-bridge'"
        ))
    }

    @Test("a quote in a value cannot close the string early")
    func quotesQuotes() {
        #expect(BridgeRegistration.shellQuoted("it's") == #"'it'\''s'"#)
    }
}
