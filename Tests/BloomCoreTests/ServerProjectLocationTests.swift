import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory)
struct ServerProjectLocationTests {
    @Test func serverContextAndInspectionUseTheSameRepositoryDirectory() async throws {
        let store = try makeTestStore("project-location")
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, installedAgents: { _ in [] })
        let expected = URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("repositories").path
        let context = await runtime.respond(to: ServerRequest(.creation(.projectContext)))
        let inspection = await runtime.respond(to: ServerRequest(.creation(.inspectProject("example"))))
        await runtime.shutdown()
        guard case .creation(.projectContext(let values)) = context.result,
              case .creation(.inspection(let inspected)) = inspection.result else {
            Issue.record("The server could not prepare its project location")
            return
        }
        #expect(values.location == expected)
        #expect(inspected.facts.path == expected + "/example")
    }

    @Test func serverImportsStayWithServerDataEvenAfterAddingAnExternalRepository() {
        let preferences = DirectoryPreferences()
        let location = preferences.projectLocation(projectPaths: ["/home/bloom/Developer/old-project"],
            home: "/home/bloom", fallbackLocation: "/home/bloom/bloom/data/repositories")
        #expect(location == "/home/bloom/bloom/data/repositories")
    }

    @Test func explicitProjectDirectoryStillTakesPrecedence() {
        var preferences = DirectoryPreferences()
        preferences.projects = "~/projects"
        let location = preferences.projectLocation(projectPaths: [], home: "/home/bloom",
            fallbackLocation: "/home/bloom/bloom/data/repositories")
        #expect(location == "/home/bloom/projects")
    }

    @Test func localProjectsKeepTheirExistingLocationAndFirstUseDefault() {
        let preferences = DirectoryPreferences()
        #expect(preferences.projectLocation(projectPaths: ["/Users/person/code/app"], home: "/Users/person") == "/Users/person/code")
        #expect(preferences.projectLocation(projectPaths: [], home: "/Users/person") == "/Users/person/Developer")
    }
}
