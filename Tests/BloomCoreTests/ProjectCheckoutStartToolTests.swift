import Foundation
import Testing
@testable import BloomCore

/// `workspace_start` with `project_checkout`: the owner's client asking for work in the project's
/// own folder. The app's two halves are stubs, as in `WorkspaceStartToolTests`, so what is pinned
/// is which of them the tool reached for, and what it refused before reaching either.
@Suite("workspace_start in the project checkout", .tags(.persistence), .scratchDirectory)
struct ProjectCheckoutStartToolTests {
    private final class Recorder: @unchecked Sendable {
        var starts: [(order: AgentWorkspaceOrder, origin: WorkspaceOrigin)] = []
        var chats: [(workspace: WorkspaceID, order: ChatCreateOrder)] = []
        /// What `start` does instead of answering, when a test needs it to fail.
        var startFails: (@Sendable (WorkspaceOrigin) async throws -> Void)?
        /// Awaited inside `addChat` before it answers, to hold a chat mid-creation.
        var whileAddingChat: (@Sendable () async -> Void)?
        /// Where the app would put the chat, so a repeat can find it again. Optional because a
        /// test that never adds a chat has nothing to give it.
        let store: Store?

        init(store: Store? = nil) {
            self.store = store
        }

        func tool() -> WorkspaceStartTool {
            WorkspaceStartTool(
                preferences: WorkspaceStartPreferences(
                    defaults: UserDefaults(suiteName: "ProjectCheckoutStartToolTests.\(UUID().uuidString)")!
                ),
                start: { [self] order, _, _, origin in
                    starts.append((order, origin))
                    try await startFails?(origin)
                    return StartedWorkspaceSummary(
                        workspaceID: WorkspaceID(rawValue: "w-checkout"), name: "Project checkout",
                        branch: "main", path: "/tmp/limbo"
                    )
                },
                addChat: { [self] workspaceID, order in
                    chats.append((workspaceID, order))
                    await whileAddingChat?()
                    // The chat the app's own door creates, as a row: a repeat is only answered from
                    // a chat that is still there.
                    let chatID = try? await store?.upsert(
                        Session(workspaceID: workspaceID, title: "Chat \(chats.count + 1)")
                    ).id
                    return .created(BridgeChatSummary(
                        chatID: chatID ?? SessionID(rawValue: "s-new"), title: "Chat 2", agent: .claudeCode,
                        model: "opus", effort: "high", permissionMode: .auto, interactionMode: .build,
                        workspaceID: workspaceID, workspace: "Project checkout"
                    ))
                }
            )
        }
    }

    private func store(withCheckout: Bool) async throws -> (Store, Repo, Workspace?) {
        let store = try makeTestStore("checkout-start")
        let repo = try await store.upsert(Repo(name: "limbo", path: "/tmp/limbo", defaultBranch: "main"))
        guard withCheckout else { return (store, repo, nil) }
        let checkout = try await store.upsert(Workspace(
            repoID: repo.id, name: "Project checkout", branch: "main", path: repo.path,
            baseBranch: "main", kind: .projectCheckout
        ))
        return (store, repo, checkout)
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_start", params: .object(arguments))
    }

    private let asking: [String: JSONValue] = [
        "project": .string("limbo"),
        "prompt": .string("Tidy the invoice export"),
        "project_checkout": .bool(true),
    ]

    @Test("the owner with no project checkout yet gets one made")
    func ownerCreates() async throws {
        let (store, _, _) = try await store(withCheckout: false)
        let recorder = Recorder()

        let result = await recorder.tool().call(request(asking), as: .owner, store: store)

        #expect(!result.isError)
        #expect(recorder.starts.first?.order.source == .projectCheckout)
        #expect(recorder.starts.first?.order.source.kind == .projectCheckout)
        #expect(recorder.chats.isEmpty)
    }

    @Test("the owner with a live project checkout gets a chat in it, not a second workspace")
    func ownerAddsAChat() async throws {
        let (store, _, checkout) = try await store(withCheckout: true)
        let recorder = Recorder()

        let result = await recorder.tool().call(request(asking), as: .owner, store: store)

        #expect(!result.isError)
        #expect(result.text.contains("chat_added"))
        #expect(recorder.starts.isEmpty)
        #expect(recorder.chats.first?.workspace == checkout?.id)
        #expect(recorder.chats.first?.order.message == "Tidy the invoice export")
    }

    @Test("a repeat of the same call adds no second chat")
    func repeatIsDeduplicated() async throws {
        let (store, _, _) = try await store(withCheckout: true)
        let recorder = Recorder(store: store)
        let tool = recorder.tool()

        _ = await tool.call(request(asking), as: .owner, store: store)
        let again = await tool.call(request(asking), as: .owner, store: store)

        #expect(!again.isError)
        #expect(again.text.contains("already_started"))
        #expect(recorder.chats.count == 1)
    }

    @Test("two identical calls at once add one chat, and the second is told it already started")
    func concurrentRepeatsAddOneChat() async throws {
        let (store, _, _) = try await store(withCheckout: true)
        let recorder = Recorder(store: store)
        // Yields rather than a wait on the other call: they give a tool without the queue the
        // chance to let the second call read the key before the first one writes it, which is the
        // race, while a tool with the queue passes whatever the scheduling.
        recorder.whileAddingChat = { for _ in 0..<200 { await Task.yield() } }
        let tool = recorder.tool()

        async let first = tool.call(request(asking), as: .owner, store: store)
        async let second = tool.call(request(asking), as: .owner, store: store)
        let answers = await [first, second]

        #expect(recorder.chats.count == 1)
        #expect(answers.filter { $0.text.contains("chat_added") }.count == 1)
        #expect(answers.filter { $0.text.contains("already_started") }.count == 1)
    }

    @Test("a create that lost to its own retry adds no chat to the checkout that retry made")
    func takenByItselfAddsNoChat() async throws {
        let (store, repo, _) = try await store(withCheckout: false)
        let recorder = Recorder(store: store)
        recorder.startFails = { origin in
            let mine = try await store.upsert(Workspace(
                repoID: repo.id, name: "Project checkout", branch: "main", path: repo.path,
                baseBranch: "main", origin: origin, kind: .projectCheckout
            ))
            throw ProjectCheckoutTaken(existing: mine)
        }

        let result = await recorder.tool().call(request(asking), as: .owner, store: store)

        #expect(result.text.contains("already_started"))
        #expect(recorder.chats.isEmpty)
    }

    @Test("a create that lost to somebody else's checkout adds its chat there")
    func takenByAnotherAddsAChat() async throws {
        let (store, repo, _) = try await store(withCheckout: false)
        let recorder = Recorder(store: store)
        recorder.startFails = { _ in
            let theirs = try await store.upsert(Workspace(
                repoID: repo.id, name: "Project checkout", branch: "main", path: repo.path,
                baseBranch: "main", origin: .ownerClient(spawnToolUseID: "another-call"), kind: .projectCheckout
            ))
            throw ProjectCheckoutTaken(existing: theirs)
        }

        let result = await recorder.tool().call(request(asking), as: .owner, store: store)

        #expect(result.text.contains("chat_added"))
        #expect(recorder.chats.count == 1)
    }

    @Test("a repeat after the checkout was archived and made again starts the prompt in the new one")
    func repeatKeyDiesWithItsCheckout() async throws {
        let (store, repo, first) = try await store(withCheckout: true)
        let recorder = Recorder(store: store)
        let tool = recorder.tool()
        _ = await tool.call(request(asking), as: .owner, store: store)
        let archived = try #require(first)
        try await store.update(workspaceID: archived.id) { $0.archive() }
        let second = try await store.upsert(Workspace(
            repoID: repo.id, name: "Project checkout", branch: "main", path: repo.path,
            baseBranch: "main", kind: .projectCheckout
        ))

        let again = await tool.call(request(asking), as: .owner, store: store)

        #expect(again.text.contains("chat_added"))
        #expect(recorder.chats.map(\.workspace) == [archived.id, second.id])
    }

    @Test("a workspace agent is refused before anything is started or added")
    func workspaceAgentRefused() async throws {
        let (store, repo, _) = try await store(withCheckout: true)
        let caller = try await store.upsert(Workspace(
            repoID: repo.id, name: "caller", branch: "feature", path: "/tmp/limbo-feature",
            baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: caller.id, title: "Chat"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(asking),
            as: BridgeIdentity(sessionID: session.id, workspaceID: caller.id, role: .workspace),
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("only the owner's client"))
        #expect(recorder.starts.isEmpty)
        #expect(recorder.chats.isEmpty)
    }
}
