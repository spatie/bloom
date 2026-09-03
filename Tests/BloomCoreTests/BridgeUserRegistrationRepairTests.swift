import Foundation
import Testing
@testable import BloomCore

/// The owner moved Bloom from `~/Applications` to `/Applications` and every agent started from his
/// own terminal reported a bridge that was down, at a path that no longer existed. These are the
/// six cases that decide whether the entry may be put back: the ones that must be repaired, and
/// the four that must be left exactly as they are.
///
/// **No test here opens a real home directory.** The rule is a pure function over bytes and over a
/// closure answering whether a path names an executable, so every path below is a fiction and
/// `~/.claude.json` is never read, let alone written.
@Suite("BridgeUserRegistrationRepair")
struct BridgeUserRegistrationRepairTests {
    private let moved = "/Applications/Bloom.app/Contents/MacOS/bloom-bridge"
    private let gone = "/Users/freek/Applications/Bloom.app/Contents/MacOS/bloom-bridge"

    private var attachment: BridgeAttachment {
        BridgeAttachment(
            shimPath: moved,
            socketPath: "/tmp/bloom-bridge-abc123.sock",
            token: "0123456789abcdef",
            role: .owner
        )
    }

    private func entry(
        command: String,
        socket: String? = nil,
        token: String? = nil,
        role: String = "owner"
    ) -> [String: Any] {
        [
            "type": "stdio",
            "command": command,
            "args": [String](),
            "env": [
                BridgeProtocol.socketVariable: socket ?? attachment.socketPath,
                BridgeProtocol.tokenVariable: token ?? attachment.token,
                BridgeProtocol.roleVariable: role,
            ],
        ]
    }

    /// A config with the owner's real neighbours in it, so a repair has something to preserve.
    private func config(_ servers: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "numStartups": 412,
            "oauthAccount": ["emailAddress": "technical@spatie.be"],
            "projects": ["/Users/freek/dev/code/bloom": ["allowedTools": [String]()]],
            "mcpServers": servers,
        ])
    }

    /// Nothing on disk exists unless a test says so, which is the state a moved bundle leaves.
    private func decide(
        _ data: Data?,
        serverNamed name: String = "bloom",
        present: Set<String> = []
    ) -> BridgeUserRegistrationRepair.Repair {
        BridgeUserRegistrationRepair.decide(
            userConfig: data,
            serverNamed: name,
            matching: attachment,
            shimExists: { present.contains($0) }
        )
    }

    private func command(in data: Data, serverNamed name: String) throws -> String? {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = root?["mcpServers"] as? [String: Any]
        return (servers?[name] as? [String: Any])?["command"] as? String
    }

    @Test("An entry already on this bundle's shim is left alone")
    func correctEntry() throws {
        // The common case, and the one that must never write: rewriting somebody's ~/.claude.json
        // on every launch to change nothing is not acceptable.
        let data = try config(["bloom": entry(command: moved)])
        #expect(decide(data, present: [moved]) == .leaveAlone(.alreadyCorrect))
    }

    @Test("Our entry pointing at a bundle that has gone is re-pointed at this one")
    func repairsTheMove() throws {
        let data = try config(["bloom": entry(command: gone)])
        guard case .rewrite(let rewritten, let from, let to) = decide(data, present: [moved]) else {
            Issue.record("a stale entry of ours should be repaired")
            return
        }
        #expect(from == gone)
        #expect(to == moved)
        let repointed = try command(in: rewritten, serverNamed: "bloom")
        #expect(repointed == moved)
    }

    @Test("The repair changes one string and carries the rest of the file through")
    func keepsEverythingElse() throws {
        // The file holds a live OAuth token and every project the CLI has been run in. A repair
        // that dropped any of that would be far worse than the bug it fixes.
        let data = try config([
            "bloom": entry(command: gone),
            "figma": ["command": "/opt/homebrew/bin/figma-mcp"],
        ])
        guard case .rewrite(let rewritten, _, _) = decide(data, present: [moved]) else {
            Issue.record("a stale entry of ours should be repaired")
            return
        }
        let root = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        #expect(root["numStartups"] as? Int == 412)
        #expect((root["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "technical@spatie.be")
        #expect((root["projects"] as? [String: Any])?.count == 1)
        let neighbour = try command(in: rewritten, serverNamed: "figma")
        #expect(neighbour == "/opt/homebrew/bin/figma-mcp")
        // The rest of the entry survives too: `claude mcp add` writes these and the repair is not
        // entitled to an opinion about them.
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let ours = try #require(servers["bloom"] as? [String: Any])
        #expect(ours["type"] as? String == "stdio")
        #expect((ours["env"] as? [String: Any])?[BridgeProtocol.tokenVariable] as? String == attachment.token)
    }

    @Test("An entry naming another app is not ours to move, whatever it is called")
    func somebodyElsesEntry() throws {
        // Under our own name, but with neither the socket nor the token this instance mints. The
        // pair is the whole proof of authorship: nothing else can produce it.
        let strangeSocket = try config(["bloom": entry(command: gone, socket: "/tmp/bloom-bridge-other.sock")])
        let strangeToken = try config(["bloom": entry(command: gone, token: "deadbeef")])
        let noEnvironment = try config(["bloom": ["command": gone]])
        // Ours by socket and token, but the command names something that is not a shim, which is
        // where a wrapper script somebody wrote would land.
        let wrapper = try config(["bloom": entry(command: "/Users/freek/bin/bridge-wrapper")])
        #expect(decide(strangeSocket) == .leaveAlone(.notOurs))
        #expect(decide(strangeToken) == .leaveAlone(.notOurs))
        #expect(decide(noEnvironment) == .leaveAlone(.notOurs))
        #expect(decide(wrapper) == .leaveAlone(.notOurs))
    }

    @Test("An entry pointing at a shim that is still there is a working arrangement, not a move")
    func deliberateCrossWire() throws {
        // The shim is a relay that takes its socket and its token out of the environment, so Bloom
        // Dev's binary driving this instance's socket works, and somebody may have wired it that
        // way on purpose. "Stale" means the path names nothing, and only that is repaired.
        let elsewhere = "/Users/freek/Applications/Bloom Dev.app/Contents/MacOS/bloom-bridge"
        let data = try config(["bloom": entry(command: elsewhere)])
        #expect(decide(data, present: [moved, elsewhere]) == .leaveAlone(.shimStillThere))
    }

    @Test("The release copy does not touch the dev copy's entry, and the dev copy cannot take ours")
    func theThreeIdentities() throws {
        // Two separate defences, and the test checks both. The name is derived per copy through
        // `Store.databaseDirectoryName`, so the three identities in Tools/guard.sh are not looking
        // at the same entry at all; and underneath that, the socket and token pair belongs to one
        // database, so a copy that somehow did look at the other's entry could not claim it.
        let devShim = "/Users/freek/Applications/Bloom Dev.app/Contents/MacOS/bloom-bridge"
        let dev: [String: Any] = [
            "command": devShim,
            "env": [
                BridgeProtocol.socketVariable: "/tmp/bloom-bridge-def456.sock",
                BridgeProtocol.tokenVariable: "fedcba9876543210",
                BridgeProtocol.roleVariable: "owner",
            ],
        ]
        let data = try config(["bloom": entry(command: gone), "bloom-dev": dev])
        guard case .rewrite(let rewritten, _, _) = decide(data, present: []) else {
            Issue.record("the release copy's own entry should still be repaired")
            return
        }
        let ours = try command(in: rewritten, serverNamed: "bloom")
        let theirs = try command(in: rewritten, serverNamed: "bloom-dev")
        #expect(ours == moved)
        #expect(theirs == devShim)

        // The dev copy, with its own socket, token and shim, looking at the release copy's entry:
        // both are stale, and it still may not move one it cannot prove it wrote.
        let devAttachment = BridgeAttachment(
            shimPath: devShim,
            socketPath: "/tmp/bloom-bridge-def456.sock",
            token: "fedcba9876543210",
            role: .owner
        )
        let refused = BridgeUserRegistrationRepair.decide(
            userConfig: data,
            serverNamed: "bloom",
            matching: devAttachment,
            shimExists: { _ in false }
        )
        #expect(refused == .leaveAlone(.notOurs))
    }

    @Test("A missing file, an empty one, and no table at all are all left alone")
    func nothingToRepair() throws {
        let emptyTable = try config([:])
        let somebodyElse = try config(["figma": entry(command: gone)])
        #expect(decide(nil) == .leaveAlone(.unreadable))
        #expect(decide(Data()) == .leaveAlone(.unreadable))
        #expect(decide(Data("{}".utf8)) == .leaveAlone(.absent))
        #expect(decide(emptyTable) == .leaveAlone(.absent))
        #expect(decide(somebodyElse) == .leaveAlone(.absent))
    }

    @Test("JSON this app did not expect is somebody else's file, and is not rewritten")
    func malformed() {
        // Half written by another process, a JSON array, a document whose `mcpServers` is not a
        // table. None of these is a crash and none of them is a truncated file afterwards.
        #expect(decide(Data(#"{"mcpServers": {"bloom":"#.utf8)) == .leaveAlone(.malformed))
        #expect(decide(Data("not json at all".utf8)) == .leaveAlone(.malformed))
        #expect(decide(Data("[1, 2, 3]".utf8)) == .leaveAlone(.malformed))
        #expect(decide(Data(#"{"mcpServers": "none"}"#.utf8)) == .leaveAlone(.absent))
        #expect(decide(Data(#"{"mcpServers": {"bloom": "none"}}"#.utf8)) == .leaveAlone(.absent))
    }

    @Test("The written file is atomic, keeps its mode, and is only touched on a real difference")
    func writesThroughToDisk() throws {
        // A fixture in a scratch directory, never the owner's own file. What is being checked is
        // the half `decide` cannot answer: that a repair lands, that a correct entry leaves the
        // bytes alone, and that 0600 survives a file holding an OAuth token.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloom-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("claude.json").path

        try config(["bloom": entry(command: gone)]).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let repaired = BridgeUserRegistrationRepair.repairIfStale(
            path: path,
            serverNamed: "bloom",
            matching: attachment,
            shimExists: { _ in false }
        )
        #expect(repaired == .repaired(from: gone, to: moved))
        let written = try #require(FileManager.default.contents(atPath: path))
        let repointed = try command(in: written, serverNamed: "bloom")
        #expect(repointed == moved)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // Asked again, it finds its own work and writes nothing.
        let again = BridgeUserRegistrationRepair.repairIfStale(
            path: path,
            serverNamed: "bloom",
            matching: attachment,
            shimExists: { _ in false }
        )
        #expect(again == .unchanged(.alreadyCorrect))
        #expect(FileManager.default.contents(atPath: path) == written)
    }

    @Test("A file that is not there is not created")
    func absentFileIsNotWritten() {
        let path = NSTemporaryDirectory() + "/bloom-repair-\(UUID().uuidString)/claude.json"
        let outcome = BridgeUserRegistrationRepair.repairIfStale(
            path: path,
            serverNamed: "bloom",
            matching: attachment,
            shimExists: { _ in false }
        )
        #expect(outcome == .unchanged(.unreadable))
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
