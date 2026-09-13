import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Exercises the model and real controls with a disposable repository. The shared probe
/// harness prohibits activation; these windows are never ordered on screen or sent input.
@MainActor
enum ChangesReviewProbe {
    static func run(directory: String, check: (Bool, String) -> Void) async {
        let root = directory + "/history"
        let app = AppModel()
        let model = WorkspaceModel(
            workspace: Workspace(repoID: .new(), name: "Commit review", branch: "work", path: root, baseBranch: "main"),
            app: app
        )
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            func git(_ arguments: [String]) async throws {
                try await Shell.check("git", ["-c", "commit.gpgsign=false", "-c", "user.name=Review Agent",
                                              "-c", "user.email=review@example.test"] + arguments, cwd: root)
            }
            func write(_ text: String) throws {
                try text.write(toFile: root + "/Source.swift", atomically: true, encoding: .utf8)
            }
            try await git(["init", "-b", "main"])
            try write("let value = 0\n")
            try await git(["add", "."])
            try await git(["commit", "-m", "Baseline"])
            try await git(["checkout", "-b", "work"])
            try write("let value = 1\n")
            try await git(["add", "."])
            try await git(["commit", "-m", "Add the first implementation"])
            try write("let value = 1\nlet enabled = true\n")
            try await git(["add", "."])
            try await git(["commit", "-m", "Enable the new behaviour"])
            try write("let value = 2\nlet enabled = true\n")
            try await git(["add", "."])
            try write("let value = 3\nlet enabled = true\n")
            try "Review notes\n".write(toFile: root + "/notes.md", atomically: true, encoding: .utf8)
            await model.refreshChanges()
            check(model.branchCommits.commits.count == 2, "history did not load both commits")
            guard let newest = model.branchCommits.commits.first, let oldest = model.branchCommits.commits.last else { return }

            model.setDiffScope(.uncommitted)
            await Task.yield()
            await model.refreshChanges()
            check(model.changedFiles.count == 3, "staging groups lost a row")
            check(model.reviewFiles.count == 3, "review order dropped a duplicate path")
            let tab = CenterTabStore.shared.showReview(path: "Source.swift", workspaceID: model.workspace.id)
            CenterTabStore.shared.setShowsAllFiles(false, for: tab)
            let host = NSHostingView(rootView: Fixture(model: model))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            await settle(window)
            save(host, at: directory + "/changes-default-tab.png")
            for layer in [ChangeLayer.staged, .unstaged] {
                model.selectedChangeLayer = layer
                model.selectedFilePath = "Source.swift"
                FileReview.open(path: "Source.swift", in: model)
                check(model.selectedChangedFile(path: "Source.swift")?.layer == layer, "selection lost its staging layer")
                await settle(window)
                let text = texts(in: host).joined(separator: "\n")
                check(text.contains(layer == .staged ? "let value = 2" : "let value = 3"), "selected layer did not render its patch")
                save(host, at: directory + "/changes-\(layer.rawValue).png")
            }
            CenterTabStore.shared.setShowsAllFiles(true, for: tab)
            for layer in [ChangeLayer.staged, .unstaged] {
                model.selectedChangeLayer = layer
                FileReview.open(path: "Source.swift", in: model)
                await settle(window)
                check(model.selectedChangeLayer == layer, "all-files navigation lost its staging layer")
            }
            save(host, at: directory + "/changes-all-sections.png")
            CenterTabStore.shared.setShowsAllFiles(false, for: tab)
            model.inspectorTab = .history
            check(model.diffScope == .commit(newest), "History did not select the newest commit")
            model.setDiffScope(.commit(oldest))
            await Task.yield()
            await model.refreshChanges()
            FileReview.open(path: "Source.swift", in: model)
            SourceEditorState.file(root + "/Source.swift").prefersEditing = true
            await settle(window)
            let oldText = texts(in: host).joined(separator: "\n")
            check(oldText.contains("let value = 1"), "historical patch did not render")
            check(!oldText.contains("let value = 3"), "historical view opened today's edit buffer")
            save(host, at: directory + "/changes-commit.png")
            model.inspectorTab = .changes
            check(model.diffScope == .uncommitted, "Changes did not restore the previous scope")
            await model.refreshChanges()
            await settle(window)
            save(host, at: directory + "/changes-return-from-history.png")
            model.inspectorTab = .history
            check(model.diffScope == .commit(oldest), "History did not remember the selected commit")
            await model.refreshChanges()
            model.selectedFilePath = "Source.swift"
            try await git(["add", "."])
            try await git(["commit", "-m", "Another agent commit"])
            await model.refreshChanges(.quiet)
            check(model.branchCommits.commits.count == 3, "quiet refresh did not discover an agent commit")
            check(model.diffScope == .commit(oldest), "new commit moved the historical selection")
            check(model.selectedFilePath == "Source.swift", "new commit moved the file selection")

            // Switching comparisons twice must not let the first asynchronous answer overwrite
            // the final selection or leave old files under the new comparison heading.
            model.setDiffScope(.commit(newest))
            model.setDiffScope(.uncommitted)
            await Task.yield()
            await model.refreshChanges()
            check(model.diffScope == .uncommitted && model.changedFiles.isEmpty, "a superseded refresh overwrote the scope")

            SourceEditorState.file(root + "/Source.swift").prefersEditing = false
            model.setDiffScope(.all)
            await Task.yield()
            await model.refreshChanges()
            window.setContentSize(CGSize(width: 780, height: 600))
            await settle(window)
            save(host, at: directory + "/changes-narrow.png")
            window.appearance = NSAppearance(named: .aqua)
            host.rootView = Fixture(model: model, scheme: .light)
            await settle(window)
            save(host, at: directory + "/changes-light.png")
            if let latest = model.branchCommits.commits.first {
                model.setDiffScope(.commit(latest))
                await Task.yield()
                await model.refreshChanges()
                try await git(["commit", "--amend", "-m", "Amended agent commit"])
                await model.refreshChanges(.quiet)
                check(model.diffScope == .all, "amended commit did not fall back")
                check(model.historyNotice != nil, "amended commit fallback was not explained")
            }
            check(!window.isVisible && !window.isKeyWindow, "probe activated a window")
            window.contentView = nil
        } catch {
            check(false, "changes review probe failed: \(error)")
        }
        withExtendedLifetime(app) {}
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func texts(in view: NSView) -> [String] {
        (view as? NSTextView).map { [$0.string] } ?? view.subviews.flatMap { texts(in: $0) }
    }

    private static func save(_ host: NSView, at path: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private struct Fixture: View {
        let model: WorkspaceModel
        var scheme: ColorScheme = .dark
        var body: some View {
            HStack(spacing: 0) {
                InspectorView(model: model).frame(width: 340)
                Hairline(axis: .vertical)
                if let tab = CenterTabStore.shared.review(for: model.workspace.id) {
                    ReviewPaneView(model: model, tab: tab)
                }
            }
            .environment(\.colorScheme, scheme)
            .background(Palette.surface)
        }
    }
}
#endif
