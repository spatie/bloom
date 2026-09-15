import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerStorageServiceTests {
    private func service(_ commands: StorageCommands, files: @escaping ServerStorageDocker.ValidateFiles = {}) -> ServerStorageService {
        let docker = ServerStorageDocker(configuration: ServerStorageDockerTests.configuration,
            run: { args, env, timeout, limit in try await commands.run(args, env, timeout, limit) }, validateFiles: files)
        return ServerStorageService(directory: "/data", docker: docker, disk: { _ in (100, 40) })
    }

    @Test func snapshotKeepsDiskCapacityWhenDockerIsMissing() async {
        let commands = StorageCommands()
        let result = await service(commands, files: { throw ServerStorageDocker.Failure.missing }).inspect()
        #expect(result.totalBytes == 100)
        #expect(result.freeBytes == 40)
        #expect(result.dockerState == .unavailable)
        #expect(result.usage.isEmpty)
        #expect(await commands.calls.isEmpty)
    }

    @Test func cleanupOnlyUsesExplicitPruneCommandsAndReportsEngineReclaimedLabels() async throws {
        let commands = StorageCommands()
        let result = try await service(commands).clean([.buildCache, .unusedImages])
        #expect(!result.interrupted)
        #expect(result.outcomes.map(\.status) == [.completed, .completed])
        #expect(result.outcomes.map(\.reclaimedLabel) == ["1.2GB", "300MB"])
        #expect(result.report?.dockerState == .ready)
        let prunes = await commands.calls.filter { $0.contains("prune") }
        #expect(prunes == [
            ["--host", "unix:///run/user/995/docker.sock", "builder", "prune", "--all", "--force"],
            ["--host", "unix:///run/user/995/docker.sock", "image", "prune", "--all", "--force"],
        ])
        #expect(await commands.calls.allSatisfy { !$0.contains("volume") && !$0.contains("container") && !$0.contains("system") || $0.contains("df") })
    }

    @Test func partialFailureRetainsCompletedCategoryAndDoesNotClaimNoChanges() async throws {
        let commands = StorageCommands(failsImages: true)
        let result = try await service(commands).clean([.buildCache, .unusedImages])
        #expect(result.interrupted)
        #expect(result.outcomes.map(\.status) == [.completed, .uncertain])
        #expect(result.outcomes[0].reclaimedLabel == "1.2GB")
        #expect(result.outcomes[1].reclaimedLabel == nil)
        #expect(!result.outcomes[1].message.contains("do-not-disclose"))
        #expect(result.outcomes[1].message.contains("already have completed"))
        #expect(result.report == nil)
    }

    @Test func invalidSelectionsNeverStartCommands() async {
        let commands = StorageCommands()
        let storage = service(commands)
        await #expect(throws: ServerFailure.self) { try await storage.clean([]) }
        await #expect(throws: ServerFailure.self) { try await storage.clean([.buildCache, .buildCache]) }
        #expect(await commands.calls.isEmpty)
    }

    @Test func unsafeDaemonIsAFailureBeforeAnyPrune() async throws {
        let commands = StorageCommands()
        let result = try await service(commands, files: { throw ServerStorageDocker.Failure.unsafe }).clean([.unusedImages])
        #expect(result.outcomes.map(\.status) == [.failed])
        #expect(result.interrupted)
        #expect(await commands.calls.isEmpty)
    }

    @Test func cancellationRetainsUncertaintyAndConcurrentCleanupIsRefused() async throws {
        let commands = StorageCommands(pausesPrune: true)
        let storage = service(commands)
        let first = Task { try await storage.clean([.buildCache, .unusedImages]) }
        await commands.waitForPrune()
        await #expect(throws: ServerFailure.self) { try await storage.clean([.unusedImages]) }
        first.cancel()
        let result = try await first.value
        #expect(result.interrupted)
        #expect(result.outcomes.map(\.status) == [.uncertain])
        #expect(result.outcomes[0].message.contains("may have removed"))
        #expect(result.report == nil)
        #expect(await commands.calls.filter { $0.contains("prune") }.count == 1)
    }
}

private actor StorageCommands {
    var calls: [[String]] = []
    let failsImages: Bool
    let pausesPrune: Bool
    private var enteredPrune = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(failsImages: Bool = false, pausesPrune: Bool = false) {
        self.failsImages = failsImages; self.pausesPrune = pausesPrune
    }

    func waitForPrune() async {
        if enteredPrune { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func run(_ args: [String], _ environment: [String: String], _ timeout: TimeInterval, _ limit: Int) async throws -> ServerStorageDocker.Output {
        calls.append(args)
        #expect(environment == ServerStorageDockerTests.configuration.environment)
        #expect(timeout <= 120)
        #expect(limit <= 262_144)
        if args == ["context", "show"] { return .init(status: 0, text: "rootless") }
        if args.first == "context" { return .init(status: 0, text: #""unix:///run/user/995/docker.sock""#) }
        #expect(args.prefix(2) == ["--host", "unix:///run/user/995/docker.sock"])
        if args.contains("info") { return .init(status: 0, text: #"{"root":"/home/bloom/bloom/docker/data","security":["name=rootless"]}"#) }
        if args.contains("df") { return .init(status: 0, text: ServerStorageDockerTests.usage) }
        if args.contains("prune") {
            enteredPrune = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            if pausesPrune { try await Task.sleep(for: .seconds(60)) }
            if args.contains("image"), failsImages { return .init(status: 1, text: "Deleted some images\ntoken=do-not-disclose\nDaemon connection ended") }
            return .init(status: 0, text: "Total reclaimed space: " + (args.contains("builder") ? "1.2GB" : "300MB") + "\n")
        }
        Issue.record("Unexpected storage command")
        return .init(status: 1, text: "")
    }
}
