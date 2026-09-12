import Foundation
import Testing
@testable import BloomCore

struct SessionWireCompatibilityTests {
    // The session from the v14 transcript vector, before interactionMode existed.
    private let legacySession = #"{"agentKind":"claudeCode","contextTokens":0,"costUSD":0,"createdAt":0,"effort":"medium","id":"session-example","inputTokens":0,"lastReadSeq":0,"model":"example-model","outputTokens":0,"permissionMode":"bypassPermissions","sortOrder":0,"state":"idle","title":"Chat","updatedAt":0,"workspaceID":"workspace-example"}"#

    @Test func oldSessionReplyRemainsReadable() throws {
        let session = try JSONDecoder().decode(Session.self, from: Data(legacySession.utf8))
        #expect(session.id == SessionID("session-example"))
        #expect(session.workspaceID == WorkspaceID("workspace-example"))
        #expect(session.interactionMode == .build)
        #expect(session.permissionMode == .bypassPermissions)
        #expect(session.state == .idle)
        #expect(session.createdAt == Date(timeIntervalSinceReferenceDate: 0))
        let encoded = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: encoded) == session)
    }

    @Test func plannedSessionDecodingHonoursBackendInvariant() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(legacySession.utf8)) as? [String: Any])
        object["interactionMode"] = "plan"
        object["agentKind"] = "codex"
        let planned = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(planned.interactionMode == .plan)
        object["agentKind"] = "claudeCode"
        let normalised = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(normalised.interactionMode == .build)
    }

    @Test func oldComposerControlsRemainReadable() throws {
        let payload = #"{"agentKind":"codex","codexContextWindow":0,"effort":"medium","hasWorktree":true,"isFastMode":false,"model":"example-model","outputStyle":"default","permissionMode":"auto"}"#
        let controls = try JSONDecoder().decode(ComposerControls.self, from: Data(payload.utf8))
        #expect(controls.interactionMode == .build)
        #expect(controls.agentKind == .codex)
        #expect(controls.permissionMode == .auto)
    }
}
