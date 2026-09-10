import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite struct ServerCredentialImportTests {
    @Test func environmentCannotSelectAnotherAccountOrEnableDebugOutput() throws {
        let source = ["HOME": "/fixture", "PATH": "/usr/bin:/bin", "GH_TOKEN": "fake-secret", "GITHUB_TOKEN": "fake-secret", "GH_ENTERPRISE_TOKEN": "fake-secret", "GITHUB_ENTERPRISE_TOKEN": "fake-secret", "GH_DEBUG": "api", "DEBUG": "1", "NODE_OPTIONS": "injected", "GH_CONFIG_DIR": "/fixture/gh"]
        let result = try ServerCredentialImport.localEnvironment(source)
        #expect(result["GH_CONFIG_DIR"] == "/fixture/gh")
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG", "DEBUG", "NODE_OPTIONS"] { #expect(result[key] == nil) }
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImport.localEnvironment(["GH_CONFIG_DIR": "relative"]) }
    }

    @Test func transportAndCodexDoNotDependOnGitHubConfiguration() throws {
        let fixture = try ImportDirectory()
        let source = ["HOME": fixture.url.path, "CODEX_HOME": fixture.url.path,
                      "GH_CONFIG_DIR": "relative", "XDG_CONFIG_HOME": "invalid", "GH_TOKEN": "fake-override"]
        let transport = ServerCredentialImport.transportEnvironment(source)
        #expect(transport["HOME"] == fixture.url.path)
        #expect(transport["GH_CONFIG_DIR"] == nil)
        #expect(transport["XDG_CONFIG_HOME"] == nil)
        #expect(transport["GH_TOKEN"] == nil)
        #expect(ServerCredentialImport.codexHome(environment: source)?.path == fixture.url.path)
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImport.localEnvironment(source) }
    }

    @Test func preflightRefusalNeverReadsTheCredential() async throws {
        let reads = ImportCounter()
        await #expect(throws: ServerCredentialImport.Failure.self) {
            try await ServerCredentialImport.withPreflight({ .init(status: "existingAuth") }) {
                reads.increment()
                return .init(verified: true, message: "fixture", removalGuidance: "fixture")
            }
        }
        #expect(reads.count == 0)
        _ = try await ServerCredentialImport.withPreflight({ .init(status: "ready") }) {
            reads.increment()
            return .init(verified: false, message: "fixture", removalGuidance: "fixture")
        }
        #expect(reads.count == 1)
    }

    @Test func repliesMustMatchTheTransferPhase() throws {
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImport.checkRemote(.init(status: "ready"), phase: "import") }
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImport.checkRemote(.init(status: "verified"), phase: "check") }
        try ServerCredentialImport.checkRemote(.init(status: "cacheAccepted"), phase: "import")
    }

    @Test func onlySupportedFileCachesCanBeTransferred() throws {
        #expect(ServerCredentialImportFiles.validCodexCache(Data(#"{"OPENAI_API_KEY":"fake-fixture-key"}"#.utf8)))
        #expect(ServerCredentialImportFiles.validCodexCache(Data(#"{"tokens":{"access_token":"a","refresh_token":"r","id_token":"i"}}"#.utf8)))
        #expect(!ServerCredentialImportFiles.validCodexCache(Data(#"{"tokens":{"access_token":"a"}}"#.utf8)))
        #expect(!ServerCredentialImportFiles.validCodexCache(Data(#"{"OPENAI_API_KEY":"fake","arbitrary":"payload"}"#.utf8)))
        #expect(!ServerCredentialImportFiles.validCodexCache(Data(repeating: 65, count: 131073)))
    }

    @Test(arguments: ["keyring", "auto", "ephemeral"])
    func staleFileIsRefusedWhenAnotherStoreIsConfigured(_ storage: String) throws {
        let fixture = try ImportDirectory()
        try Data("cli_auth_credentials_store = \"\(storage)\"\n".utf8).write(to: fixture.url.appendingPathComponent("config.toml"))
        let folder = try ServerCredentialImportFiles.Folder(fixture.url)
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImportFiles.checkCodexStorage(folder) }
    }

    @Test func heldFolderDoesNotFollowReplacementAndLeafLinksAreRefused() throws {
        let fixture = try ImportDirectory()
        let original = fixture.url.appendingPathComponent("original")
        let replacement = fixture.url.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("original-fake-cache".utf8).write(to: original.appendingPathComponent("auth.json"))
        try Data("different-fake-cache".utf8).write(to: replacement.appendingPathComponent("auth.json"))
        let held = try ServerCredentialImportFiles.Folder(original)
        try FileManager.default.moveItem(at: original, to: fixture.url.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)
        #expect(try held.read("auth.json", limit: 100) == Data("original-fake-cache".utf8))
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImportFiles.Folder(original) }
        try FileManager.default.createSymbolicLink(at: replacement.appendingPathComponent("link"), withDestinationURL: replacement.appendingPathComponent("auth.json"))
        #expect(throws: ServerCredentialImport.Failure.self) { try ServerCredentialImportFiles.read(replacement.appendingPathComponent("link"), limit: 100) }
        #expect(throws: ServerCredentialImport.Failure.self) { try held.read("auth.json", limit: 2) }
    }

    @Test func privateCaptureHidesSecretsFromDescriptionsAndDiscardsStderr() async throws {
        let result = try await ServerCredentialImportProcess.run("/bin/sh", ["-c", "printf fake-stdout; printf fake-stderr >&2"], environment: [:])
        #expect(result.output == Data("fake-stdout".utf8))
        #expect(!String(describing: result).contains("fake-"))
        #expect(!String(reflecting: result).contains("fake-"))
        #expect(Mirror(reflecting: result).children.isEmpty)
        let merged = try await ServerCredentialImportProcess.run("/bin/sh", ["-c", "printf fake-stderr >&2"], environment: [:], captureStderr: true)
        #expect(merged.output == Data("fake-stderr".utf8))
    }

    @Test func workingDirectoryIsAppliedWithoutAShellChangeDirectory() async throws {
        let fixture = try ImportDirectory()
        let result = try await ServerCredentialImportProcess.run("/bin/pwd", [], environment: [:], workingDirectory: fixture.url.path)
        #expect(String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == fixture.url.path)
    }

    @Test func timeoutStopsBackpressuredInputAndOutputLimitsStayPrivate() async {
        let start = ContinuousClock.now
        do {
            _ = try await ServerCredentialImportProcess.run("/bin/sh", ["-c", "sleep 30"], environment: ["PATH": "/usr/bin:/bin"], input: Data(repeating: 65, count: 131072), timeout: 0.15)
            Issue.record("Expected the non-reading process to time out")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(!String(reflecting: error).contains(String(repeating: "A", count: 20)))
        }
        #expect(start.duration(to: .now) < .seconds(3))
        await #expect(throws: ServerCredentialImport.Failure.self) {
            try await ServerCredentialImportProcess.run("/bin/sh", ["-c", "printf fake-secret-output"], environment: [:], limit: 3)
        }
        let early = try? await ServerCredentialImportProcess.run("/usr/bin/true", [], environment: [:], input: Data(repeating: 65, count: 131072))
        #expect(early?.status == 0)
    }

    @Test func cancellationKillsTheProcessGroupWithoutWaitingForPipeEOF() async throws {
        let fixture = try ImportDirectory()
        let marker = fixture.url.appendingPathComponent("ready")
        let task = Task {
            try await ServerCredentialImportProcess.run("/bin/sh", ["-c", "touch \"$1\"; sleep 30", "fixture", marker.path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(2))
    }
}

private final class ImportCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

final class ImportDirectory {
    let url: URL
    init() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-import-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        url = try #require(ServerCredentialImportFiles.canonicalDirectory(created))
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
