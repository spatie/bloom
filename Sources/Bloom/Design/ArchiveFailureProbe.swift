import AppKit
import BloomCore

/// Runs only in a disposable probe bundle. Its repository and unrecognised worktree are fresh
/// temporary folders, so the refusal path cannot remove a user's checkout or stop their agents.
@MainActor
enum ArchiveFailureProbe {
    private static let harness = ProbeHarness(subject: "archive-failure")
    static var isRequested: Bool { harness.isRequested }

    static func schedule() { Task { @MainActor in await run() } }

    private static func run() async {
        guard Bundle.main.bundleIdentifier?.hasPrefix("be.spatie.bloom.typography-") == true else {
            harness.fail("requires a disposable probe bundle")
        }
        _ = await harness.window()
        guard let app = AppModel.probeInstance, let store = app.store else {
            harness.fail("no app store")
        }
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bloom-archive-probe-\(UUID().uuidString)")
            let folder = root.appendingPathComponent("unrecognised-worktree")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let marker = folder.appendingPathComponent("keep.txt")
            try Data("keep this work".utf8).write(to: marker)
            let repo = Repo(name: "Archive refusal probe", path: root.path)
            let workspace = Workspace(
                repoID: repo.id, name: "Unrecognised checkout", branch: "probe",
                path: folder.path, baseBranch: "main"
            )
            try await store.upsert(repo)
            try await store.upsert(workspace)
            let session = Session(workspaceID: workspace.id, title: "Archive probe")
            try await store.upsert(session)
            await app.reload()
            app.selection = .workspace(workspace.id)
            try? await Task.sleep(for: .milliseconds(400))
            var failures: [String] = []
            guard let model = app.existingModel(for: workspace.id) else { harness.fail("no workspace model") }
            let transcript = model.transcript(for: session)
            transcript.draft = "Keep this draft"
            app.hideFromSidebar(workspace.id)
            await transcript.submit("Do not start a real agent")
            if transcript.draft != "Keep this draft" { failures.append("archive accepted a new prompt") }
            let pending = try await store.pendingDeliveries(sessionID: session.id)
            if !pending.isEmpty { failures.append("archive queued a new prompt") }
            app.restoreToSidebar(workspace)
            var observations = 0
            var lostSelection = 0
            var lostInspector = 0
            for _ in 0..<5 {
                await app.archive(workspace, deleteBranch: false, alwaysConfirm: true)
                guard let request = app.pendingArchive else { harness.fail("no refusal confirmation") }
                let archive = Task { await app.confirmArchive(request) }
                for _ in 0..<100 {
                    observations += 1
                    if app.selection != .workspace(workspace.id) { lostSelection += 1 }
                    if app.selectedWorkspace == nil { lostInspector += 1 }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                await archive.value
                if model.existingTranscript(for: session.id) !== transcript {
                    failures.append("refused archive discarded its transcript model")
                }
                if app.alert == nil { failures.append("failed archive did not explain its refusal") }
                app.alert = nil
            }
            if lostSelection > 0 { failures.append("failed archive changed the detail selection") }
            if lostInspector > 0 { failures.append("failed archive removed the inspector subject") }
            await app.archive(workspace, deleteBranch: false, alwaysConfirm: true)
            guard let request = app.pendingArchive else { harness.fail("no second refusal") }
            let navigation = Task { await app.confirmArchive(request) }
            while !app.isArchiving(workspace.id) { await Task.yield() }
            app.selection = .home
            await navigation.value
            if app.selection != .home { failures.append("refusal overrode newer navigation") }
            let saved = try await store.workspace(id: workspace.id)
            if saved?.state != .active { failures.append("refused workspace was archived") }
            if try Data(contentsOf: marker) != Data("keep this work".utf8) {
                failures.append("refused archive changed the folder")
            }
            harness.write(.object([
                "passed": .bool(failures.isEmpty), "failures": .strings(failures),
                "observations": .integer(observations), "lostSelection": .integer(lostSelection),
                "lostInspector": .integer(lostInspector), "fixture": .string(root.path),
            ]))
            exit(failures.isEmpty ? 0 : 1)
        } catch { harness.fail(error.localizedDescription) }
    }
}
