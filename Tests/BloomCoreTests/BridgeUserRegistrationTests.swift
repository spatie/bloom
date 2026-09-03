import Foundation
import Testing
@testable import BloomCore

@Suite("BridgeUserRegistration")
struct BridgeUserRegistrationTests {
    private let attachment = BridgeAttachment(
        shimPath: "/Applications/Bloom.app/Contents/MacOS/bloom-bridge",
        socketPath: "/tmp/bloom-bridge-abc123.sock",
        token: "0123456789abcdef",
        role: .owner
    )

    private func config(_ servers: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers])
    }

    private func entry(
        command: String? = nil,
        socket: String? = nil,
        token: String? = nil,
        role: String = "owner"
    ) -> [String: Any] {
        [
            "type": "stdio",
            "command": command ?? attachment.shimPath,
            "args": [String](),
            "env": [
                BridgeProtocol.socketVariable: socket ?? attachment.socketPath,
                BridgeProtocol.tokenVariable: token ?? attachment.token,
                BridgeProtocol.roleVariable: role,
            ],
        ]
    }

    private func state(_ data: Data?) -> BridgeUserRegistration.State {
        BridgeUserRegistration.state(userConfig: data, serverNamed: "bloom", matching: attachment)
    }

    @Test("An entry naming this Bloom, this socket and this token is the offer already taken")
    func registered() throws {
        let data = try config(["bloom": entry()])
        #expect(state(data) == .registered)
    }

    @Test("The role is not compared, because an entry that disagrees about it still works")
    func ignoresTheRole() throws {
        // It travels in the attachment for diagnostics only and the server resolves the real one
        // from the token, so re-offering the command over it would be the check inventing a
        // problem. See `BridgeProtocol.roleVariable`.
        let data = try config(["bloom": entry(role: "parent")])
        #expect(state(data) == .registered)
    }

    @Test("No table, an empty table, and somebody else's servers are all a straight no")
    func absent() throws {
        let empty = try config([:])
        let somebodyElse = try config(["figma": entry()])
        #expect(state(Data("{}".utf8)) == .notRegistered)
        #expect(state(empty) == .notRegistered)
        #expect(state(somebodyElse) == .notRegistered)
    }

    @Test("The name from before the rename does not count as this copy being registered")
    func theLegacyName() throws {
        // `bloom-owner-bridge` was one constant for every copy of Bloom at once, so an entry under
        // it may be pointing at a build that has gone. See `BridgeRegistration.ownerServerName`.
        let data = try config(["bloom-owner-bridge": entry()])
        #expect(state(data) == .notRegistered)
    }

    @Test("An entry wearing the name and pointing somewhere else is not registered")
    func stale() throws {
        // One case rather than three, because one paste fixes all of them: `claude mcp add`
        // replaces an entry of the same name.
        let elsewhere = try config(["bloom": entry(command: "/Volumes/Old/bloom-bridge")])
        let otherSocket = try config(["bloom": entry(socket: "/tmp/bloom-bridge-other.sock")])
        let otherToken = try config(["bloom": entry(token: "deadbeef")])
        let noEnvironment = try config(["bloom": ["command": attachment.shimPath]])
        #expect(state(elsewhere) == .notRegistered)
        #expect(state(otherSocket) == .notRegistered)
        #expect(state(otherToken) == .notRegistered)
        #expect(state(noEnvironment) == .notRegistered)
    }

    @Test("A token that has been regenerated leaves the entry behind, and it counts as not done")
    func regenerated() throws {
        // Regenerate revokes the old token the moment it is pressed, so what is in this file is a
        // server that will be refused at the handshake. That is exactly the state worth offering
        // the command over.
        let old = BridgeAttachment(
            shimPath: attachment.shimPath,
            socketPath: attachment.socketPath,
            token: "the-revoked-one",
            role: .owner
        )
        let data = try config(["bloom": entry(token: old.token)])
        let state = BridgeUserRegistration.state(
            userConfig: data,
            serverNamed: "bloom",
            matching: attachment
        )
        #expect(state == .notRegistered)
    }

    @Test("A file that cannot be read or parsed is unknown, which is offered rather than assumed")
    func unknown() {
        #expect(state(nil) == .unknown)
        #expect(state(Data()) == .unknown)
        #expect(state(Data("not json at all".utf8)) == .unknown)
        // Valid JSON that is not an object. Claude Code would never write it; the check still has
        // to answer rather than crash.
        #expect(state(Data("[1, 2, 3]".utf8)) == .unknown)
    }

    @Test("With no bridge to compare against, an entry of the right name is taken at face value")
    func noAttachment() throws {
        let data = try config(["bloom": entry()])
        let state = BridgeUserRegistration.state(
            userConfig: data,
            serverNamed: "bloom",
            matching: nil
        )
        #expect(state == .registered)
    }

    @Test("The name looked for is the one the command registers, per copy of Bloom")
    func namedPerCopy() throws {
        // The dev build's entry is not the owner build's, which is the whole reason the name is
        // derived. A window that looked for one name would tell Bloom Dev it was already set up.
        let dev = BridgeRegistration.ownerServerName(forBundleIdentifier: "be.spatie.bloom.dev")
        #expect(dev == "bloom-dev")
        let data = try config(["bloom": entry()])
        let state = BridgeUserRegistration.state(userConfig: data, serverNamed: dev, matching: attachment)
        #expect(state == .notRegistered)
    }

    @Test("The path read is Claude Code's own configuration file")
    func path() {
        #expect(BridgeUserRegistration.userConfigPath == "\(NSHomeDirectory())/.claude.json")
    }
}
