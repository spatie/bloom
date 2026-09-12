import Foundation
import Testing
@testable import BloomClient

struct WorkspaceNoteTests {
    @Test func unknownServerNoteNeverAllowsWritingOverIt() {
        #expect(!WorkspaceNote.needsSave(stored: nil, typed: "A local draft"))
        #expect(!WorkspaceNote.needsSave(stored: nil, typed: ""))
        #expect(WorkspaceNote.needsSave(stored: "", typed: "A new note"))
        #expect(!WorkspaceNote.needsSave(stored: "", typed: " \n"))
        #expect(WorkspaceNote.needsSave(stored: "Existing note", typed: "Edited note"))
    }

    @Test func missingNotePayloadIsAnErrorRatherThanAnEmptyNote() async throws {
        let service = RemoteWorkspaceService(client: NotesReplyClient(reply: .object(["accepted": .object([:])])))
        await #expect(throws: ConnectionFailure.self) { try await service.notes(workspaceID: .init("workspace")) }
        let empty = RemoteWorkspaceService(client: NotesReplyClient(reply: .object(["text": .object(["_0": .string("")])])))
        #expect(try await empty.notes(workspaceID: .init("workspace")) == "")
    }

    @Test func noteIsNotSavedWithoutAnExplicitAcknowledgement() async throws {
        let service = RemoteWorkspaceService(client: NotesReplyClient(reply: .object(["text": .object(["_0": .string("")])])))
        await #expect(throws: ConnectionFailure.self) { try await service.saveNotes("Keep this draft", workspaceID: .init("workspace")) }
        let accepted = RemoteWorkspaceService(client: NotesReplyClient(reply: .object(["accepted": .object([:])])))
        try await accepted.saveNotes("Saved", workspaceID: .init("workspace"))
    }
}

private struct NotesReplyClient: RemoteRequesting {
    let reply: JSONValue
    func request(_ command: RemoteCommand) async throws -> JSONValue { reply }
}
