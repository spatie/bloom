import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory)
struct ServerStorageProtocolTests {
    @Test func storageReadsHaveNoMutationScopeAndCleanupIsJournalledOnce() async throws {
        #expect(!ServerOperation.storage.mutates)
        #expect(ServerOperation.storage.workspaceMutation == nil)
        let operation = ServerOperation.cleanupStorage(targets: [.buildCache])
        #expect(operation.mutates)
        #expect(operation.workspaceMutation == nil)
        let store = try makeTestStore("storage-protocol")
        let probe = StorageProtocolDocker()
        let docker = ServerStorageDocker(configuration: .init(home: "/home/bloom", uid: 1000, supported: true),
            run: { arguments, _, _, _ in await probe.run(arguments) }, validateFiles: {})
        let service = ServerStorageService(directory: "/fixture", docker: docker, disk: { _ in (total: 1024, free: 512) })
        let runtime = ServerRuntime(store: store, installedAgents: { _ in [] }, workspaceAdmissions: ServerWorkspaceAdmissions(), storageService: service)
        let read = ServerRequest(.storage)
        guard case .storage(let report) = await runtime.respond(to: read).result else { Issue.record("Expected a storage report"); return }
        #expect(report.freeBytes == 512)
        #expect(try await store.setting("server.command.\(read.id.uuidString)") == nil)
        #expect(await probe.prunes == 0)
        let cleanup = ServerRequest(operation)
        let first = await runtime.respond(to: cleanup)
        let retry = await runtime.respond(to: cleanup)
        guard case .storageCleanup(let result) = first.result, case .storageCleanup(let replay) = retry.result else {
            Issue.record("Expected cleanup outcomes"); return
        }
        #expect(!result.needsAttention)
        #expect(result == replay)
        #expect(await probe.prunes == 1)
        await runtime.shutdown()
    }

    @Test func storageWireAcceptsOnlyExplicitCleanupCategories() throws {
        let request = ServerRequest(.cleanupStorage(targets: [.buildCache, .unusedImages]))
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ServerRequest.self, from: data) == request)
        let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "unusedImages", with: "volumes")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ServerRequest.self, from: Data(invalid.utf8)) }
    }
}

private actor StorageProtocolDocker {
    var prunes = 0
    func run(_ arguments: [String]) -> ServerStorageDocker.Output {
        let text: String
        if arguments == ["context", "show"] { text = "rootless" } else if arguments.starts(with: ["context", "inspect"]) { text = #""unix:///run/user/1000/docker.sock""# } else if arguments.contains("info") { text = #"{"root":"/home/bloom/bloom/docker/data","security":["name=rootless"]}"# } else if arguments.contains("prune") { prunes += 1; text = "Total reclaimed space: 12MB" } else {
            text = ["Images", "Containers", "Local Volumes", "Build Cache"].map {
                #"{"Type":""# + $0 + #"","TotalCount":"1","Active":"0","Size":"12MB","Reclaimable":"12MB"}"#
            }.joined(separator: "\n")
        }
        return .init(status: 0, text: text)
    }
}
