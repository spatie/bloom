import Foundation
import Testing
@testable import BloomClient

@Suite struct BrowserReadinessTests {
    private func receipt(_ changes: [String: JSONValue] = [:]) throws -> Data {
        var values: [String: JSONValue] = [
            "ready": .bool(true), "uid": .number(1001), "hostOnly": .bool(true),
            "agentVersion": .string("0.37.1"), "chromeVersion": .string("153.0.8010.36"),
            "executable": .string("/opt/bloom-browser/bin/agent-browser"),
            "agentBrowser": .string("/opt/bloom-browser/releases/pinned/agent-browser"),
            "chrome": .string("/opt/bloom-browser/releases/pinned/chrome-linux64/chrome"),
            "verifiedAt": .number(1_800_000_000),
            "sandbox": .object(["namespace": .bool(true), "pidNamespace": .bool(true),
                                "networkNamespace": .bool(true), "seccomp": .bool(true)]),
            "debugging": .object(["loopbackOnly": .bool(true)]),
        ]
        values.merge(changes) { _, new in new }
        return try JSONEncoder().encode(JSONValue.object(values))
    }

    @Test func readyMeansProtectedHostInstallationWithReportedSandbox() throws {
        let readiness = ServerBrowserReadiness.inspect(try receipt(), accountID: 1001) { $0.hasPrefix("/opt/bloom-browser/") }
        #expect(readiness.status == .ready)
        #expect(readiness.hostOnly)
        #expect(readiness.sandbox?.verified == true)
        #expect(readiness.agentVersion == "0.37.1")
    }

    @Test func staleAccountMissingExecutableAndPublicDebuggingAreNotReady() throws {
        #expect(ServerBrowserReadiness.inspect(try receipt(), accountID: 1002) { _ in true }.status == .attention)
        #expect(ServerBrowserReadiness.inspect(try receipt(), accountID: 1001) { _ in false }.status == .attention)
        for changes: [String: JSONValue] in [
            ["debugging": .object(["loopbackOnly": .bool(false)])],
            ["sandbox": .object(["namespace": .bool(false), "pidNamespace": .bool(true), "networkNamespace": .bool(true), "seccomp": .bool(true)])],
            ["chrome": .string("/opt/bloom-browser/releases/../../tmp/chrome")],
            ["agentVersion": .string("unexpected output containing private data")],
        ] {
            #expect(ServerBrowserReadiness.inspect(try receipt(changes), accountID: 1001) { _ in true }.status == .attention)
        }
    }

    @Test func olderDiagnosticsWithoutBrowserStillDecode() throws {
        let report = ServerDiagnostics(checkedAt: Date(), hostname: "server", operatingSystem: "Linux", account: "bloom", checks: [])
        let data = try JSONEncoder().encode(report)
        #expect(!String(decoding: data, as: UTF8.self).contains("browser"))
        #expect(try JSONDecoder().decode(ServerDiagnostics.self, from: data).browser == nil)
    }
}
