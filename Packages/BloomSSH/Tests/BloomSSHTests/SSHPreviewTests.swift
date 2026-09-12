import Foundation
import Testing
import BloomClient
@testable import BloomSSH

struct SSHPreviewTests {
    @Test(arguments: [0, -1, 65_536])
    func refusesInvalidPortsBeforeConnecting(port: Int) async throws {
        let configuration = try SSHConfiguration(host: "127.0.0.1", username: "test")
        await #expect(throws: ConnectionFailure.self) {
            try await SSHPreviewTunnel.open(configuration: configuration, privateKey: SSHIdentity.generate(), fingerprint: "SHA256:test", remotePort: port)
        }
    }

    @Test func requiresVerifiedHostTrust() async throws {
        let configuration = try SSHConfiguration(host: "127.0.0.1", username: "test")
        await #expect(throws: ConnectionFailure.self) {
            try await SSHPreviewTunnel.open(configuration: configuration, privateKey: SSHIdentity.generate(), fingerprint: "", remotePort: 80)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOOM_SSH_PREVIEW_TEST_PORT"] != nil), .timeLimit(.minutes(2)))
    func realPreviewForwardsResponseAndRevokesListenerOnClose() async throws {
        let environment = ProcessInfo.processInfo.environment
        let key = try Data(contentsOf: URL(fileURLWithPath: try #require(environment["BLOOM_SSH_TEST_KEY_PATH"])))
        let configuration = try SSHConfiguration(host: try #require(environment["BLOOM_SSH_TEST_HOST"]), username: try #require(environment["BLOOM_SSH_TEST_USER"]))
        let port = try #require(environment["BLOOM_SSH_PREVIEW_TEST_PORT"].flatMap(Int.init))
        let fingerprint = try #require(environment["BLOOM_SSH_TEST_FINGERPRINT"])
        await #expect(throws: ConnectionFailure.self) {
            try await SSHPreviewTunnel.open(configuration: configuration, privateKey: key, fingerprint: "SHA256:invalid", remotePort: port)
        }
        let tunnel = try await SSHPreviewTunnel.open(configuration: configuration, privateKey: key, fingerprint: fingerprint, remotePort: port)
        #expect(tunnel.localURL.host == "127.0.0.1")
        var request = URLRequest(url: tunnel.localURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data.count > 1_000)
            #expect(String(decoding: data, as: UTF8.self).contains("<title>"))
            await tunnel.close()
            await #expect(throws: (any Error).self) { try await URLSession.shared.data(for: request) }
        } catch { await tunnel.close(); throw error }
    }
}
