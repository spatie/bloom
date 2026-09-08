import Foundation
import Testing
@testable import BloomCore

@Suite("RemoteMessageIdentity")
@MainActor
struct RemoteMessageIdentityTests {
    @Test func overlappingDatabaseRowsNeverSharePresentationIDs() {
        let first = RemoteMessageIdentity()
        let second = RemoteMessageIdentity()
        let message = Message(id: 42, sessionID: .new(), seq: 8, kind: .assistantText, payload: Data("remote".utf8))
        let rendered = first.presentation(message)
        #expect(rendered.id < 0)
        #expect(rendered.id != second.presentation(message).id)
        #expect(rendered == first.presentation(message))
        #expect(rendered.seq == message.seq)
        #expect(rendered.sessionID == message.sessionID)
        #expect(rendered.payload == message.payload)
        first.reset()
        #expect(first.presentation(message).id != rendered.id)
    }
}
