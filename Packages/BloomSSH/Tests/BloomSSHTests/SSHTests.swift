import Foundation
import Testing
import BloomClient
@testable import BloomSSH

struct SSHTests {
    @Test func defaultPathsMatchTheDedicatedServerHome() throws {
        let configuration = try SSHConfiguration(host: "example.com", username: "bloom")
        #expect(configuration.executable == "/home/bloom/bloom/server/current/bin/bloom-server")
        #expect(configuration.dataDirectory == "/home/bloom/bloom/data")
        #expect(configuration.command == "'/home/bloom/bloom/server/current/bin/bloom-server' connect --data-dir '/home/bloom/bloom/data'")
    }
    @Test func validatesAddressAndQuotesRemotePaths() throws {
        let configuration = try SSHConfiguration(host: "  EXAMPLE.com  ", username: "bloom", executable: "/opt/Bloom's Server", dataDirectory: "/var/lib/bloom")
        #expect(configuration.host == "example.com")
        #expect(configuration.identity == "ssh://bloom@example.com/var/lib/bloom")
        #expect(configuration.command == "'/opt/Bloom'\\''s Server' connect --data-dir '/var/lib/bloom'")
        #expect(throws: (any Error).self) { try SSHConfiguration(host: "https://example.com", username: "bloom") }
        #expect(throws: (any Error).self) { try SSHConfiguration(host: "example.com", port: 0, username: "bloom") }
        #expect(throws: (any Error).self) { try SSHConfiguration(host: "example.com", username: "bloom", executable: "bad\ncommand") }
    }
    @Test func generatesStablePublicIdentityAndFingerprint() throws {
        let key = SSHIdentity.generate()
        #expect(key.count == 32)
        let publicKey = try SSHIdentity.publicKey(key)
        #expect(publicKey.hasPrefix("ssh-ed25519 "))
        #expect(try SSHIdentity.publicKey(key) == publicKey)
        #expect(try SSHIdentity.fingerprint(publicKey: publicKey).hasPrefix("SHA256:"))
        #expect(try SSHIdentity.fingerprint(publicKey: publicKey + " comment") == SSHIdentity.fingerprint(publicKey: publicKey))
        #expect(throws: (any Error).self) { try SSHIdentity.publicKey(Data([1, 2])) }
    }
    @Test func unreachableServerHasAnActionableFailure() async throws {
        let connection = SSHConnection(configuration: try SSHConfiguration(host: "127.0.0.1", port: 1, username: "bloom"), privateKey: SSHIdentity.generate(), fingerprint: nil)
        let error = await #expect(throws: ConnectionFailure.self) { try await connection.exchange(Data(), timeout: .seconds(1)) }
        #expect(error?.localizedDescription.contains("Check the address, port, network and server firewall") == true)
        await connection.close()
    }

    @Test func closedConnectionCannotSend() async throws {
        let connection = SSHConnection(configuration: try SSHConfiguration(host: "127.0.0.1", username: "bloom"), privateKey: SSHIdentity.generate(), fingerprint: nil)
        await connection.close()
        await #expect(throws: CancellationError.self) { try await connection.request(.call("hello")) }
    }

    /// Opt-in real SSH verification uses a dedicated device key outside the checkout. It sends
    /// only read-only protocol envelopes; no agent is started and no workspace is modified.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOOM_SSH_TEST_HOST"] != nil))
    func realSSHRequiresTrustRefusesChangedKeysAndRelaysRequests() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["BLOOM_SSH_TEST_KEY_PATH"])
        let url = URL(fileURLWithPath: path)
        let key: Data
        if FileManager.default.fileExists(atPath: path) { key = try Data(contentsOf: url) } else {
            key = SSHIdentity.generate()
            try key.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        try (SSHIdentity.publicKey(key) + " bloom-ios-transport-test\n").write(to: url.appendingPathExtension("pub"), atomically: true, encoding: .utf8)
        let configuration = try SSHConfiguration(host: try #require(environment["BLOOM_SSH_TEST_HOST"]), username: try #require(environment["BLOOM_SSH_TEST_USER"]), executable: try #require(environment["BLOOM_SSH_TEST_EXECUTABLE"]), dataDirectory: try #require(environment["BLOOM_SSH_TEST_DATA_DIR"]))
        let wireVersion = environment["BLOOM_SSH_TEST_WIRE_VERSION"].flatMap(Int.init) ?? BloomWire.version
        let body = Data("{\"version\":\(wireVersion),\"id\":\"\(UUID())\",\"operation\":{\"hello\":{}}}".utf8)
        let unknown = SSHConnection(configuration: configuration, privateKey: key, fingerprint: nil)
        let trust = await #expect(throws: SSHHostTrustRequired.self) { try await unknown.exchange(body, timeout: .seconds(20)) }
        let fingerprint = try #require(trust?.fingerprint)
        if let expected = environment["BLOOM_SSH_TEST_FINGERPRINT"] { #expect(fingerprint == expected) }
        let changed = SSHConnection(configuration: configuration, privateKey: key, fingerprint: "SHA256:invalid")
        await #expect(throws: ConnectionFailure.self) { try await changed.exchange(body, timeout: .seconds(20)) }
        let trusted = SSHConnection(configuration: configuration, privateKey: key, fingerprint: fingerprint)
        let response = try await trusted.exchange(body, timeout: .seconds(20))
        let json = try JSONDecoder().decode(JSONValue.self, from: response)
        #expect(json["result"]?["hello"]?["name"]?.stringValue != nil)
    }
}

struct SSHWorkspaceIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOOM_SSH_WORKSPACE_TEST_ROOT"] != nil), .timeLimit(.minutes(3)))
    func createsWorkspaceAndReceivesAgentReplyThroughMobileService() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try #require(environment["BLOOM_SSH_WORKSPACE_TEST_ROOT"])
        let key = try Data(contentsOf: URL(fileURLWithPath: try #require(environment["BLOOM_SSH_TEST_KEY_PATH"])))
        let configuration = try SSHConfiguration(host: try #require(environment["BLOOM_SSH_TEST_HOST"]), username: try #require(environment["BLOOM_SSH_TEST_USER"]), executable: try #require(environment["BLOOM_SSH_TEST_EXECUTABLE"]), dataDirectory: root + "/data")
        let fingerprint = try #require(environment["BLOOM_SSH_TEST_FINGERPRINT"])
        let connection = SSHConnection(configuration: configuration, privateKey: key, fingerprint: fingerprint)
        let inspection = try await connection.request(.call("creation", ["_0": .object(["inspectProject": .object(["_0": .string(root + "/repository")])])]))
        let facts = try #require(inspection["creation"]?["_0"]?["inspection"]?["_0"]?["facts"])
        _ = try await connection.request(.call("creation", ["_0": .object(["startProject": .object(["typed": .string(root + "/repository"), "expected": facts])])]))
        let service = RemoteWorkspaceService(client: connection)
        let project = try #require(try await service.catalogue().repositories.first)
        let name = "iOS SSH " + UUID().uuidString.prefix(8)
        let command = try await service.workspaceCommand(project: project, name: name, prompt: "Reply exactly BLOOM_IOS_SSH_OK. Do not use tools or change files.")
        _ = try await connection.request(command)
        let catalogue = try await service.catalogue()
        let workspace = try #require(catalogue.workspaces.first { $0.name == name })
        let session = try #require(catalogue.sessions.first { $0.workspaceID == workspace.id })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        var completed = false
        while clock.now < deadline {
            let transcript = try await service.transcript(sessionID: session.id, after: 0)
            if !transcript.isBusy, transcript.messages.contains(where: { $0.kind == "assistantText" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "BLOOM_IOS_SSH_OK" }) {
                completed = true; break
            }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(completed)
        await connection.close()
    }
}
