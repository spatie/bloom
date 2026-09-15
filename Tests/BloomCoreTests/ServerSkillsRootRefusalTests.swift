import Foundation
import Testing
@testable import BloomCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Linux CI runs ordinary service fixtures as its service account, then invokes this filtered
/// regression as root. The production guard must reject before creating even the storage folder.
@Suite struct ServerSkillsRootRefusalTests {
    @Test(.enabled(if: geteuid() == 0))
    func refusesRootBeforeCreatingStorageOrAgentDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-root-refusal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSkillsService(directory: root.appendingPathComponent("skills").path, home: root.path)
        do {
            _ = try await service.handle(.init(action: .inspect))
            Issue.record("Root must not manage service-account skills.")
        } catch {
            #expect(error.localizedDescription == "Skills must be managed by the Bloom service account, never root.")
        }
        do {
            _ = try ServerSkillsService.containerEnvironment(directory: root.appendingPathComponent("skills").path, home: root.path)
            Issue.record("Root must not prepare service-account skill mounts.")
        } catch {
            #expect(error.localizedDescription == "Skill directories must belong to the Bloom service account.")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
