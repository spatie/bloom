import Foundation
import Testing
@testable import BloomCore

@Suite("Showing workspace media inline", .scratchDirectory)
struct MediaShowToolTests {
    private var identity: BridgeIdentity {
        BridgeIdentity(sessionID: SessionID("s"), workspaceID: WorkspaceID("w"), role: .parent)
    }

    @Test("the tool hands a path and caption to its own workspace")
    func call() async throws {
        let store = try makeTestStore("media-show")
        let recorder = Recorder()
        let tool = MediaShowTool { order, workspaceID in
            await recorder.record(order, workspaceID: workspaceID)
            return .shown("shown")
        }
        let result = await tool.call(
            MCPRequest(
                id: .integer(1),
                method: tool.tool.name,
                params: .object([
                    "path": .string(" output/demo.mp4 "),
                    "caption": .string(" New interaction "),
                ])
            ),
            as: identity,
            store: store
        )

        #expect(!result.isError)
        #expect(
            await recorder.values == [
                Value(
                    order: MediaShowOrder(path: "output/demo.mp4", caption: "New interaction"),
                    workspaceID: WorkspaceID("w")
                ),
            ]
        )
    }

    @Test("only Bloom's own media tool becomes inline content")
    func requestIdentity() throws {
        let own = AgentToolUse(
            id: "1",
            name: "mcp__\(BridgeRegistration.serverName)__media_show",
            input: .object(["path": .string("shot.png"), "caption": .string("Result")])
        )
        let foreign = AgentToolUse(
            id: "2",
            name: "mcp__somewhere-else__media_show",
            input: .object(["path": .string("shot.png")])
        )

        let request = try #require(MediaShowRequest(use: own))
        #expect(request.path == "shot.png")
        #expect(request.caption == "Result")
        #expect(MediaShowRequest(use: foreign) == nil)
        #expect(MediaShowRow.isCall(own.raw) == false)
        #expect(
            MediaShowRow.isCall(
                Data("{\"name\":\"mcp__\(BridgeRegistration.serverName)__media_show\"}".utf8)
            )
        )
    }

    @Test("paths stay inside the workspace and resolve images and movies")
    func containment() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "bloom-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "bloom-outside-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data([0]).write(to: root.appending(path: "shot.png"))
        try Data([0]).write(to: root.appending(path: "demo.mp4"))
        try Data([0]).write(to: root.appending(path: "notes.txt"))
        try Data([0]).write(to: outside)

        #expect(WorkspaceMedia.resolve(path: "shot.png", in: root.path)?.kind == .image)
        #expect(WorkspaceMedia.resolve(path: "demo.mp4", in: root.path)?.kind == .video)
        #expect(WorkspaceMedia.resolve(path: "notes.txt", in: root.path) == nil)

        // A file inside the worktree is named by its path in it, and one outside by its own name:
        // the whole of a temp path says nothing a reader wants under a picture.
        #expect(WorkspaceMedia.resolve(path: "shot.png", in: root.path)?.relativePath == "shot.png")

        // Outside the worktree is shown, which is the rule that changed. A screenshot written to
        // a temporary folder is the ordinary case, and refusing it made the tool useless in
        // exactly the moment somebody says "show me that". See `WorkspaceMedia.resolve`.
        #expect(WorkspaceMedia.resolve(path: outside.path, in: root.path)?.kind == .image)
        #expect(WorkspaceMedia.resolve(path: outside.path, in: root.path)?.relativePath
            == outside.lastPathComponent)
        #expect(WorkspaceMedia.resolve(path: "../\(outside.lastPathComponent)", in: root.path)?.kind
            == .image)

        // What still bounds it: the file has to be there, and it has to be a picture or a film.
        #expect(WorkspaceMedia.resolve(path: "/no/such/shot.png", in: root.path) == nil)
        #expect(WorkspaceMedia.resolve(path: root.path, in: root.path) == nil)
        #expect(WorkspaceMedia.resolve(path: "", in: root.path) == nil)
        #expect(WorkspaceMedia.resolve(path: "shot.png", in: "") == nil)

        #expect(WorkspaceMedia.resolveImageView(path: outside.path, in: root.path)?.kind == .image)
    }

    @Test("a native Codex image view is recognised as visible media")
    func codexImageView() throws {
        let item = CodexItem.other(
            type: "imageView",
            id: "image-1",
            json: .object([
                "type": .string("imageView"),
                "id": .string("image-1"),
                "path": .string("/tmp/result.png"),
            ])
        )
        let use = AgentToolUse(
            id: "image-1",
            name: CodexTranslation.toolName(for: item),
            input: CodexTranslation.input(for: item)
        )

        #expect(CodexImageViewRequest(use: use)?.path == "/tmp/result.png")
        #expect(CodexImageViewRow.isCall(Data("{\"type\":\"imageView\"}".utf8)))
    }

    @Test("media presentation does not interrupt the agent with a permission question")
    func approval() {
        #expect(
            BridgeToolApproval.isSelfApproved(
                toolName: BridgeToolApproval.toolPrefix + MediaShowToolName.show
            )
        )
    }

    @Test("featured media separates the action groups around it")
    func foldBoundary() {
        let action: (Int) -> TranscriptFold.Fact = {
            TranscriptFold.Fact(seq: $0, kind: .toolUse)
        }
        let facts = [
            action(1), action(2), action(3),
            TranscriptFold.Fact(seq: 4, kind: .toolUse, featured: true),
            action(5), action(6), action(7),
        ]
        let folds = TranscriptFold.folds(in: facts)

        #expect(folds.all.map(\.rows).map { $0.map(\.seq) } == [[1, 2, 3], [5, 6, 7]])
    }

    private struct Value: Sendable, Equatable {
        var order: MediaShowOrder
        var workspaceID: WorkspaceID
    }

    private actor Recorder {
        var values: [Value] = []
        func record(_ order: MediaShowOrder, workspaceID: WorkspaceID) {
            values.append(Value(order: order, workspaceID: workspaceID))
        }
    }
}
