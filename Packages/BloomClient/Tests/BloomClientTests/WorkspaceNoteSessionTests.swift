import Foundation
import Testing
@testable import BloomClient

@MainActor
@Suite("Durable workspace note editing")
struct WorkspaceNoteSessionTests {
    private let workspace = WorkspaceID("workspace")
    private enum Failure: Error { case offline }

    @Test("Closing offline and reopening restores the typed note and its known baseline")
    func offlineDraftSurvivesReopening() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let note = try store.session(scope: "server-A", workspaceID: workspace)
        await note.load { "previous note" }
        let fail: WorkspaceNoteSession.Write = { _ in throw Failure.offline }
        note.edit("draft for tomorrow", using: fail)
        note.save(using: fail)
        await note.waitForSave()
        #expect(note.saveError != nil)
        let reopened = try WorkspaceNoteDraftStore(file: location).session(scope: "server-A", workspaceID: workspace)
        #expect(reopened.text == "draft for tomorrow")
        #expect(reopened.baseline == "previous note")
        #expect(reopened.canEdit)
    }

    @Test("The device draft is on disk before the first server write begins")
    func persistBeforeSending() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let note = try store.session(scope: "server-A", workspaceID: workspace)
        await note.load { "before" }
        var persisted = false
        let write: WorkspaceNoteSession.Write = { text in
            let disk = try WorkspaceNoteDraftStore(file: location).session(scope: "server-A", workspaceID: workspace)
            persisted = disk.text == text && disk.baseline == "before"
        }
        note.edit("after", using: write); note.save(using: write)
        await note.waitForSave()
        #expect(persisted)
        #expect(!note.hasChanges)
        let reopened = try WorkspaceNoteDraftStore(file: location).session(scope: "server-A", workspaceID: workspace)
        #expect(reopened.text.isEmpty)
        #expect(!reopened.canEdit)
    }

    @Test("Typing and repeated flushes during a save produce serial writes of the latest text")
    func coalescesConcurrentFlushes() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let note = try store.session(scope: "server-A", workspaceID: workspace)
        let same = try store.session(scope: "server-A", workspaceID: workspace)
        #expect(note === same)
        await note.load { "original" }
        let writer = HeldNoteWrite()
        let write: WorkspaceNoteSession.Write = { try await writer.write($0) }
        note.edit("first", using: write); note.save(using: write)
        await writer.waitUntilStarted()
        same.edit("latest", using: write); same.save(using: write); note.save(using: write)
        let disk = try WorkspaceNoteDraftStore(file: location).session(scope: "server-A", workspaceID: workspace)
        #expect(disk.text == "latest")
        writer.release()
        await note.waitForSave()
        #expect(writer.values == ["first", "latest"])
        #expect(writer.maximumConcurrent == 1)
        #expect(note.text == "latest")
        #expect(note.baseline == "latest")
        #expect(!note.hasChanges)
    }

    @Test("A late cancelled load cannot replace a successful save or newer typing")
    func staleLoadCannotReplaceSave() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let note = try store.session(scope: "server-A", workspaceID: workspace)
        await note.load { "original" }
        let read = HeldNoteRead()
        let loading = Task { await note.load { await read.read() } }
        await read.waitUntilStarted()
        note.edit("new text", using: { _ in })
        note.save(using: { _ in })
        await note.waitForSave()
        read.release("stale text")
        await loading.value
        #expect(note.text == "new text")
        #expect(note.baseline == "new text")
    }

    @Test("A cancelled load releases its spinner and permits a fresh read")
    func cancelledLoadCanRetry() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let note = try store.session(scope: "server-A", workspaceID: workspace)
        let read = HeldNoteRead()
        let loading = Task { await note.load { await read.read() } }
        await read.waitUntilStarted()
        loading.cancel()
        read.release("late response")
        await loading.value
        #expect(!note.isLoading)
        #expect(note.text.isEmpty)
        await note.load { "fresh response" }
        #expect(note.text == "fresh response")
    }

    @Test("Identical workspace IDs on different servers cannot share a draft")
    func scopeIsolation() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let first = try store.session(scope: "server-A", workspaceID: workspace)
        let second = try store.session(scope: "server-B", workspaceID: workspace)
        await first.load { "A" }; await second.load { "B" }
        first.importLegacyDraft("draft A")
        second.importLegacyDraft("draft B")
        #expect(first.text == "draft A")
        #expect(second.text == "draft B")
        let reopened = WorkspaceNoteDraftStore(file: location)
        let reopenedFirst = try reopened.session(scope: "server-A", workspaceID: workspace)
        let reopenedSecond = try reopened.session(scope: "server-B", workspaceID: workspace)
        #expect(reopenedFirst.text == "draft A")
        #expect(reopenedSecond.text == "draft B")
    }

    @Test("An unreadable device draft blocks network writes and does not replace its file")
    func failedPersistenceBlocksWrite() async throws {
        let location = temporaryFile(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = WorkspaceNoteDraftStore(file: location)
        let note = try store.session(scope: "server-A", workspaceID: workspace)
        await note.load { "baseline" }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("damaged draft storage".utf8).write(to: location)
        var sent = false
        let write: WorkspaceNoteSession.Write = { _ in sent = true }
        note.edit("unsaved text", using: write); note.save(using: write)
        await note.waitForSave()
        #expect(!sent)
        #expect(note.draftError != nil)
        #expect(note.text == "unsaved text")
        #expect(try String(contentsOf: location, encoding: .utf8) == "damaged draft storage")
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BloomNoteTests-" + UUID().uuidString).appendingPathComponent("drafts.json")
    }
}

@MainActor
private final class HeldNoteWrite {
    private(set) var values: [String] = []
    private(set) var maximumConcurrent = 0
    private var concurrent = 0
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func write(_ text: String) async throws {
        values.append(text); concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        if values.count == 1 {
            await withCheckedContinuation { held = $0; started?.resume(); started = nil }
        }
    }
    func waitUntilStarted() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { held?.resume(); held = nil }
}

@MainActor
private final class HeldNoteRead {
    private var held: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read() async -> String {
        await withCheckedContinuation { held = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(_ text: String) { held?.resume(returning: text); held = nil }
}
