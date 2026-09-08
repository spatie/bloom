import AppKit
import BloomCore

/// Exercises real runner event ingestion while another workspace is selected. It only writes
/// synthetic messages to an explicitly requested, disposable probe database.
@MainActor
enum SwitchBackgroundProbe {
    static func run(order: [WorkspaceID]) async -> JSONValue {
        guard ProbeHarness.isPresent("--switch-background-updates") else { return .null }
        guard Bundle.main.bundleIdentifier?.hasPrefix("be.spatie.bloom.typography-") == true,
              ProcessInfo.processInfo.environment["BLOOM_DB_PATH"] != nil,
              order.count >= 2, let app = ProbeHarness.appModel, let store = app.store,
              let workspace = app.existingModel(for: order[0]),
              let session = workspace.activeSession,
              let transcript = workspace.existingTranscript(for: session.id),
              let other = app.existingModel(for: order[1])?.activeTranscript else {
            return .object(["passed": .bool(false), "failures": .strings(["isolated background fixture unavailable"])])
        }
        var failures: [String] = []
        app.selection = .workspace(order[1])
        try? await Task.sleep(for: .milliseconds(200))
        let otherCount = other.rows.count
        _ = transcript.presentationFolds()
        _ = transcript.pinnedQuestion(atOrBefore: Int.max)
        do {
            let prompt = "Verify background conversation updates"
            _ = try await store.appendNext(sessionID: session.id, kind: .user,
                payload: Data("{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(prompt)\"}]}}".utf8))
            let toolIDs = (0..<3).map { _ in "switch-background-\(UUID().uuidString)" }
            for toolID in toolIDs {
                _ = try await store.appendNext(sessionID: session.id, kind: .toolUse,
                    payload: Data("{\"name\":\"Read\",\"input\":{\"file_path\":\"fixture.txt\"}}".utf8), refID: toolID)
                await transcript.acceptForProbe(.toolUse(AgentToolUse(id: toolID, name: "Read", input: .object([:]))))
            }
            if transcript.pinnedQuestion(atOrBefore: Int.max)?.summary != prompt {
                failures.append("background user message was missing from the question index")
            }
            let before = transcript.presentationFolds()
            let rowCount = transcript.rows.count
            let revision = transcript.presentationRevision
            for toolID in toolIDs {
                _ = try await store.appendNext(sessionID: session.id, kind: .toolResult,
                    payload: Data("{\"content\":\"Read completed\",\"is_error\":false}".utf8), refID: toolID)
                await transcript.acceptForProbe(.toolResult(AgentToolResult(toolUseID: toolID, text: "Read completed")))
            }
            if transcript.rows.count != rowCount { failures.append("tool result appended a row instead of updating its call") }
            if transcript.presentationRevision <= revision { failures.append("background tool result did not invalidate presentation") }
            if transcript.presentationFolds() == before { failures.append("background tool completion left stale folds") }
            if app.selection != .workspace(order[1]) || other.rows.count != otherCount {
                failures.append("background update affected the selected conversation")
            }
            await transcript.acceptForProbe(.streamDelta(.text("A reply arriving in the background")))
            try? await Task.sleep(for: .milliseconds(80))
            app.selection = .workspace(order[0])
            try? await Task.sleep(for: .milliseconds(300))
            if transcript.streamingText != "A reply arriving in the background" {
                failures.append("switching back lost the in-progress reply")
            }
            _ = try await store.appendNext(sessionID: session.id, kind: .assistantText,
                payload: Data("{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Background reply complete\"}]}}".utf8))
            await transcript.acceptForProbe(.assistantText(AgentTextBlock(text: "Background reply complete")))
            if transcript.rows.last?.kind != .assistantText || !transcript.streamingText.isEmpty {
                failures.append("the saved reply did not replace the streaming reply")
            }
        } catch { failures.append(error.localizedDescription) }
        return .object(["passed": .bool(failures.isEmpty), "failures": .strings(failures)])
    }
}
