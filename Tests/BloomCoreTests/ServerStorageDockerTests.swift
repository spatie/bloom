import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import BloomCore

@Suite struct ServerStorageDockerTests {
    static let configuration = ServerStorageDocker.Configuration(home: "/home/bloom", uid: 995, supported: true)
    static let usage = #"""
{"Type":"Images","TotalCount":"9","Active":"4","Size":"4.7GB","Reclaimable":"4.7GB (100%)"}
{"Type":"Containers","TotalCount":"7","Active":"7","Size":"31.1MB","Reclaimable":"0B (0%)"}
{"Type":"Local Volumes","TotalCount":"2","Active":"2","Size":"84MB","Reclaimable":"0B (0%)"}
{"Type":"Build Cache","TotalCount":"252","Active":"0","Size":"3.21GB","Reclaimable":"3.21GB"}
"""#

    @Test func keepsSharedImageAndCacheFiguresSeparate() throws {
        let rows = try ServerStorageDocker.parseUsage(Self.usage)
        #expect(rows.count == 4)
        #expect(rows[0].size == "4.7GB")
        #expect(rows[0].activeCount == 4)
        #expect(rows[0].reclaimable == nil)
        #expect(rows[1].reclaimable == nil)
        #expect(rows[2].reclaimable == nil)
        #expect(rows[3].reclaimable == "3.21GB")
    }

    @Test(arguments: ["", "not JSON", String(repeating: "a", count: 65_537)])
    func refusesInvalidOrOversizedUsage(_ text: String) {
        #expect(throws: ServerStorageDocker.Failure.self) { try ServerStorageDocker.parseUsage(text) }
    }

    @Test func refusesDuplicateRowsAndUntrustedLabels() {
        #expect(throws: ServerStorageDocker.Failure.self) { try ServerStorageDocker.parseUsage(Self.usage + "\n" + Self.usage) }
        #expect(throws: ServerStorageDocker.Failure.self) {
            try ServerStorageDocker.parseUsage(Self.usage.replacingOccurrences(of: "4.7GB", with: "$(touch /tmp/no)"))
        }
    }

    @Test func onlyAcceptsCompletedEngineReclaimedSummary() {
        #expect(ServerStorageDocker.reclaimed("Deleted Images:\nsha256:example\nTotal reclaimed space: 1.2GB\n") == "1.2GB")
        #expect(ServerStorageDocker.reclaimed("Deleted Images:\nsha256:example") == nil)
        #expect(ServerStorageDocker.reclaimed("Total reclaimed space: https://untrusted") == nil)
    }

    @Test(arguments: ["context", "endpoint", "rootful", "data"])
    func refusesOtherDaemonTargets(_ refusal: String) async throws {
        let docker = ServerStorageDocker(configuration: Self.configuration, run: { args, env, timeout, limit in
            #expect(env == Self.configuration.environment)
            #expect(env["DOCKER_HOST"] == nil)
            #expect(env["DOCKER_CONTEXT"] == nil)
            #expect(timeout <= 30)
            #expect(limit <= 65_536)
            if args == ["context", "show"] { return .init(status: 0, text: refusal == "context" ? "default" : "rootless") }
            if args.first == "context" { return .init(status: 0, text: refusal == "endpoint" ? #""unix:///var/run/docker.sock""# : #""unix:///run/user/995/docker.sock""#) }
            #expect(args.prefix(2) == ["--host", "unix:///run/user/995/docker.sock"])
            return .init(status: 0, text: refusal == "rootful" ? #"{"root":"/home/bloom/bloom/docker/data","security":["name=seccomp"]}"# :
                refusal == "data" ? #"{"root":"/var/lib/docker","security":["name=rootless"]}"# : #"{"root":"/home/bloom/bloom/docker/data","security":["name=rootless"]}"#)
        }, validateFiles: {})
        await #expect(throws: ServerStorageDocker.Failure.self) { try await docker.validate() }
    }

    @Test func unsupportedAndRootHostsNeverRunDocker() async {
        for configuration in [ServerStorageDocker.Configuration(home: "/home/bloom", uid: 995, supported: false),
                              ServerStorageDocker.Configuration(home: "/root", uid: 0, supported: true)] {
            let docker = ServerStorageDocker(configuration: configuration, run: { _, _, _, _ in
                Issue.record("Docker must not run for an unsupported host")
                return .init(status: 0, text: "")
            }, validateFiles: {})
            await #expect(throws: ServerStorageDocker.Failure.self) { try await docker.validate() }
        }
    }

    @Test func directoryAndSocketOwnershipChecksRejectLinksForeignOwnersAndPublicAccess() throws {
        let parent = try #require(ServerCredentialImportFiles.canonicalDirectory(URL(fileURLWithPath: "/tmp")))
        let root = parent.appendingPathComponent("storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self, "Private directory is accepted") { try ServerStorageDocker.ownedDirectory(root.path, uid: geteuid(), privateAccess: true) }
        #expect(throws: ServerStorageDocker.Failure.self) {
            try ServerStorageDocker.ownedDirectory(root.path, uid: geteuid() + 1, privateAccess: true)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: ServerStorageDocker.Failure.self) {
            try ServerStorageDocker.ownedDirectory(link.path, uid: geteuid(), privateAccess: true)
        }
        let socketPath = root.appendingPathComponent("engine.sock").path
        let socket = try UnixSocketListener(path: socketPath) { connection in connection.close() }
        defer { socket.stop() }
        #expect(throws: Never.self, "Private socket is accepted") { try ServerStorageDocker.ownedSocket(socketPath, uid: geteuid()) }
        #expect(throws: ServerStorageDocker.Failure.self) { try ServerStorageDocker.ownedSocket(socketPath, uid: geteuid() + 1) }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: socketPath)
        #expect(throws: ServerStorageDocker.Failure.self) { try ServerStorageDocker.ownedSocket(socketPath, uid: geteuid()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o710], ofItemAtPath: root.path)
        #expect(throws: Never.self, "Private parent permits Docker group traversal") { try ServerStorageDocker.ownedDirectory(root.path, uid: geteuid(), privateAccess: false) }
        #expect(throws: ServerStorageDocker.Failure.self) {
            try ServerStorageDocker.ownedDirectory(root.path, uid: geteuid(), privateAccess: true)
        }
    }

    @Test func unsafeFilesNeverReachDocker() async {
        let docker = ServerStorageDocker(configuration: Self.configuration, run: { _, _, _, _ in
            Issue.record("Unsafe filesystem must fail before Docker runs")
            return .init(status: 0, text: "")
        }, validateFiles: { throw ServerStorageDocker.Failure.unsafe })
        await #expect(throws: ServerStorageDocker.Failure.self) { try await docker.validate() }
    }
}
