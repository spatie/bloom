import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Photographs real navigation and native alerts in an unshown, disposable app instance.
@MainActor
enum WorkspaceLinkSnapshots {
    static var isRequested: Bool { CommandLine.arguments.contains("--workspace-link-snapshots") }

    static func runAndExit() -> Never {
        guard Bundle.main.bundleIdentifier == "be.spatie.bloom.workspace-link-snapshots",
              let output = ProbeHarness.value(for: "--workspace-link-snapshots") else { exit(1) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: output)
        setenv("BLOOM_DB_PATH", directory.appending(path: "fixture.sqlite").path, 1)
        Task {
            do {
                try await render(in: directory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Workspace link snapshots: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func render(in directory: URL) async throws {
        let store = try Store(path: directory.appending(path: "fixture.sqlite").path)
        let repo = Repo(name: "Deep link examples", path: directory.appending(path: "repository").path)
        try await store.upsert(repo)
        let live = Workspace(id: WorkspaceID("live-example"), repoID: repo.id, name: "Live workspace",
                             branch: "main", path: repo.path, baseBranch: "main")
        var archive = Workspace(id: WorkspaceID("archived-example"), repoID: repo.id, name: "Archived workspace",
                                branch: "finished", path: directory.appending(path: "removed-worktree").path, baseBranch: "main")
        archive.archive()
        try await store.upsert(live)
        try await store.upsert(archive)
        for (workspace, chats) in [(live, ["First chat", "Requested chat"]), (archive, ["Summary", "Archived chat"])] {
            for (index, title) in chats.enumerated() {
                let session = Session(id: SessionID("\(workspace.id)-chat-\(index + 1)"), workspaceID: workspace.id,
                                      title: title, sortOrder: index)
                try await store.upsert(session)
                let text = "\(title) in \(workspace.name). This transcript is stored in the isolated screenshot database."
                let payload = try JSONEncoder().encode(JSONValue.object([
                    "type": .string("user"),
                    "message": .object([
                        "role": .string("user"),
                        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    ]),
                ]))
                _ = try await store.appendNext(sessionID: session.id, kind: .user, payload: payload)
            }
        }
        let app = AppModel()
        await app.bootstrap()
        app.selection = .home
        let host = NSHostingView(rootView: RootView().environment(app)
            .environment(\.colorScheme, .light)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        try save(host, to: directory.appending(path: "01-before-link.png"))
        let links = [
            ("02-live-workspace", "bloomdev://workspace/live-example"),
            ("03-requested-chat", "bloomdev://workspace/live-example?chat=live-example-chat-2"),
            ("04-archived-transcript", "bloomdev://workspace/archived-example?chat=archived-example-chat-2"),
            ("05-unknown-workspace", "bloomdev://workspace/missing-example"),
            ("06-foreign-chat", "bloomdev://workspace/live-example?chat=archived-example-chat-2"),
            ("06a-malformed-link", "bloomdev://workspace/"),
            ("06b-scheme-isolation", "bloom://workspace/live-example"),
        ]
        var states: [String: JSONValue] = [:]
        for (name, link) in links {
            app.alert = nil
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            try await Task.sleep(for: .milliseconds(150))
            await BloomDeepLink.open(URL(string: link)!, in: app)
            try await Task.sleep(for: .seconds(1))
            host.layoutSubtreeIfNeeded()
            try save(host, to: directory.appending(path: name + ".png"))
            if let sheet = window.attachedSheet, let content = sheet.contentView {
                sheet.layoutIfNeeded()
                content.layoutSubtreeIfNeeded()
                sheet.display()
                content.display()
                try saveLayer(content, to: directory.appending(path: name + "-alert.png"))
            }
            states[name] = .object([
                "url": .string(link), "selection": .string(String(describing: app.selection)),
                "chat": .string(app.selectedModel?.activeSessionID?.rawValue ?? ""),
                "alert": .string(app.alert?.message ?? ""),
            ])
        }
        app.alert = nil
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        try await Task.sleep(for: .milliseconds(150))
        let matches = try await WorkspaceEntityQuery().entities(matching: "archived-example")
        if let match = matches.first {
            await app.open(workspaceID: match.id)
            try await Task.sleep(for: .seconds(1))
            try save(host, to: directory.appending(path: "07-shortcuts-exact-id.png"))
        }
        states["shortcuts-exact-id"] = .array(matches.map { .string($0.id.rawValue) })
        await app.open(workspaceID: live.id, chatID: SessionID("live-example-chat-2"))
        let model = app.model(for: live)
        let tabs = WorkspaceTabsStore.shared
        let root = PaneContent.chat(SessionID("live-example-chat-1"))
        if let pane = tabs.split(tab: root, axis: .horizontal, showing: .chat(SessionID("live-example-chat-2"))) {
            tabs.select(root, in: model)
            tabs.focus(pane, in: root, of: model)
            try await Task.sleep(for: .seconds(1))
            try save(host, to: directory.appending(path: "08-split-before-link.png"))
            await BloomDeepLink.open(URL(string: "bloomdev://workspace/live-example?chat=live-example-chat-1")!, in: app)
            try await Task.sleep(for: .seconds(1))
            try save(host, to: directory.appending(path: "09-split-requested-chat.png"))
            states["split-chat"] = .string(model.activeSessionID?.rawValue ?? "")
        }
        try JSONEncoder().encode(JSONValue.object(states)).write(to: directory.appending(path: "navigation.json"))
        window.contentView = nil
    }

    private static func saveLayer(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        // AppKit's button hosting view fills its layer during the cache draw even when the
        // window is unshown. Prime it before rendering, or some alert controls remain blank.
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if view.isFlipped {
            context.cgContext.translateBy(x: 0, y: view.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        // A native sheet's material is transparent without a window-server backdrop. Draw its
        // real layer tree over the window background, under the sheet's own appearance.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.cgContext.fill(view.bounds)
        }
        view.layer?.render(in: context.cgContext)
        context.flushGraphics()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    private static func save(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        print(url.path)
    }
}
#endif
