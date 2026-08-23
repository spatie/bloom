import Foundation
import Testing
@testable import BloomCore

/// Hiding a project from the bridge, and the four ways the call can be wrong.
@Suite("project_hide and project_unhide", .tags(.persistence), .scratchDirectory)
struct ProjectHideToolTests {
    private func request(_ tool: String, _ project: String?) -> MCPRequest {
        MCPRequest(
            id: .number(1),
            method: tool,
            params: project.map { .object(["project": .string($0)]) } ?? .object([:])
        )
    }

    private func seed(_ store: Store) async throws -> (Repo, Repo) {
        let flare = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", sortOrder: 0))
        let bloom = try await store.upsert(Repo(name: "bloom", path: "/tmp/bloom", sortOrder: 1))
        return (flare, bloom)
    }

    /// A workspace agent has one project and cannot act in another, so naming one is not something
    /// it has any use for. The owner's client has no workspace and has to name one out loud.
    @Test("only the owner sees either of them")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [ProjectHideTool(), ProjectUnhideTool()])

        #expect(toolbox.tools(for: .parent).isEmpty)
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).map(\.name) == ["project_hide", "project_unhide"])
        #expect(BridgeToolbox.standard.tools(for: .owner).map(\.name)
            .contains(["project_hide", "project_unhide"].first!))
    }

    /// `selfApproved` is for tools an agent must be able to call with nobody watching. These two
    /// are the owner's own, and the owner is sitting there to answer the ask.
    @Test("neither is answered by Bloom on the owner's behalf")
    func notSelfApproved() {
        #expect(!BridgeToolApproval.isSelfApproved(
            toolName: BridgeToolApproval.toolPrefix + "project_hide"
        ))
        #expect(!BridgeToolApproval.isSelfApproved(
            toolName: BridgeToolApproval.toolPrefix + "project_unhide"
        ))
    }

    @Test("hiding a project stores it, and says what is left showing")
    func hides() async throws {
        let store = try makeTestStore("hide")
        let (flare, _) = try await seed(store)

        let result = await ProjectHideTool()
            .call(request("project_hide", "flare"), as: .owner, store: store)

        #expect(!result.isError)
        #expect(result.text.contains("\"state\" : \"hidden\""))
        #expect(result.text.contains("1 project is still showing"))
        #expect(try await store.repo(id: flare.id)?.hidden == true)
    }

    /// The refusal a model actually needs: nothing was destroyed, so a second call is not a
    /// mistake and must not read as one.
    @Test("hiding a hidden project changes nothing and is not an error")
    func hidingTwice() async throws {
        let store = try makeTestStore("hide-twice")
        _ = try await seed(store)
        let tool = ProjectHideTool()

        _ = await tool.call(request("project_hide", "flare"), as: .owner, store: store)
        let again = await tool.call(request("project_hide", "flare"), as: .owner, store: store)

        #expect(!again.isError)
        #expect(again.text.contains("\"state\" : \"already_hidden\""))
        #expect(again.text.contains("Nothing changed."))
    }

    @Test("unhiding puts it back, and is not an error for a project that was showing")
    func unhides() async throws {
        let store = try makeTestStore("unhide")
        let (flare, _) = try await seed(store)
        _ = await ProjectHideTool()
            .call(request("project_hide", "/tmp/flare"), as: .owner, store: store)

        let back = await ProjectUnhideTool()
            .call(request("project_unhide", "flare"), as: .owner, store: store)

        #expect(!back.isError)
        #expect(back.text.contains("\"state\" : \"showing\""))
        #expect(try await store.repo(id: flare.id)?.hidden == false)

        let again = await ProjectUnhideTool()
            .call(request("project_unhide", "flare"), as: .owner, store: store)
        #expect(!again.isError)
        #expect(again.text.contains("\"state\" : \"already_showing\""))
    }

    /// An agent that empties the owner's sidebar and answers "done" has told them nothing they
    /// could act on.
    @Test("hiding the last showing project says how to get one back")
    func hidingEverything() async throws {
        let store = try makeTestStore("hide-all")
        _ = try await seed(store)
        let tool = ProjectHideTool()

        _ = await tool.call(request("project_hide", "flare"), as: .owner, store: store)
        let last = await tool.call(request("project_hide", "bloom"), as: .owner, store: store)

        #expect(!last.isError)
        #expect(last.text.contains("No projects are left showing"))
        #expect(last.text.contains("project_unhide"))
    }

    @Test("a call with no project named says how to find one")
    func needsAProject() async throws {
        let store = try makeTestStore("hide-noargs")
        _ = try await seed(store)

        let result = await ProjectHideTool()
            .call(request("project_hide", nil), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("project_hide needs the project"))
        #expect(result.text.contains("project_list"))
    }

    /// Told only "no such project", a client guesses, and every guess is another call.
    @Test("an unknown name names what Bloom does have and says retrying will not help")
    func unknownProject() async throws {
        let store = try makeTestStore("hide-unknown")
        _ = try await seed(store)

        let result = await ProjectHideTool()
            .call(request("project_hide", "flair"), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("'flare'"))
        #expect(result.text.contains("Retrying with the same name will fail the same way"))
        // The refusal is about hiding, not about starting a workspace, which is what makes
        // `BridgeProjectLookup.refusal` the wrong sentence to reuse here.
        #expect(!result.text.contains("workspace"))
    }

    @Test("two projects with one name are refused rather than guessed between")
    func ambiguousProject() async throws {
        let store = try makeTestStore("hide-ambiguous")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/one/flare"))
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/two/flare"))

        let result = await ProjectHideTool()
            .call(request("project_hide", "flare"), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("/tmp/one/flare"))
        #expect(result.text.contains("/tmp/two/flare"))
        let stored = try await store.repos()
        #expect(stored.allSatisfy { !$0.hidden })
    }

    @Test("with nothing registered it says so rather than listing nothing")
    func nothingRegistered() async throws {
        let store = try makeTestStore("hide-empty")

        let result = await ProjectUnhideTool()
            .call(request("project_unhide", "flare"), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("Bloom has no projects"))
        #expect(result.text.contains("project_add"))
    }

    /// A client that could not see a hidden project would name it, be refused, and add it again as
    /// a duplicate. So they are all listed, each saying which it is.
    @Test("project_list reports hidden state, and says what hidden means")
    func listingReportsHidden() async throws {
        let store = try makeTestStore("hide-listing")
        _ = try await seed(store)
        _ = await ProjectHideTool()
            .call(request("project_hide", "flare"), as: .owner, store: store)

        let listing = await ProjectListTool().call(
            MCPRequest(id: .number(1), method: "project_list", params: nil),
            as: .owner,
            store: store
        )

        #expect(!listing.isError)
        #expect(listing.text.contains("\"hidden\" : true"))
        #expect(listing.text.contains("\"hidden\" : false"))
        #expect(listing.text.contains("\"hidden_projects\" : 1"))
        #expect(listing.text.contains("project_unhide"))
    }
}
