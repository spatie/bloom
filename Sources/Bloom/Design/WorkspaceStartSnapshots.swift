import AppKit
import BloomCore
import ScreenCaptureKit
import SwiftUI

#if DEBUG
/// Captures the actual workspace_start lifecycle with local CLI fixtures in its own background panel.
@MainActor
enum WorkspaceStartSnapshots {
    static var isRequested: Bool { CommandLine.arguments.contains("--workspace-start-snapshots") }

    static func runAndExit() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "be.spatie.bloom.terminal-start-capture",
              let output = ProbeHarness.value(for: "--workspace-start-snapshots"),
              let fixtures = environment["BLOOM_CAPTURE_FIXTURES"],
              environment["PATH"]?.hasPrefix(fixtures + "/bin:") == true,
              environment["ZDOTDIR"] == fixtures + "/shell",
              environment["BLOOM_LOGIN_SHELL_PATH"] == "0",
              environment["BLOOM_DB_PATH"] == output + "/bloom.sqlite",
              ["claude", "codex"].allSatisfy({ agent in
                  (try? String(contentsOfFile: fixtures + "/bin/" + agent, encoding: .utf8))?
                      .contains("Local CLI capture fixture") == true
              })
        else { exit(1) }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {
            do {
                try await render(in: URL(fileURLWithPath: output))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Workspace start snapshots: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func render(in directory: URL) async throws {
        let app = AppModel()
        await app.bootstrap()
        guard let store = app.store else { throw AppNotReady.stillStartingUp }
        let scenario = directory.lastPathComponent
        let usesDefault = scenario.contains("default")
        try await store.setSetting(AppDefaults.Key.terminalChat, usesDefault || scenario.contains("override") ? "1" : "0")
        let handlers = app.bridgeToolbox().handlers
        guard let start = handlers.first(where: { $0.tool.name == "workspace_start" }) else {
            throw AppNotReady.stillStartingUp
        }
        let repo = directory.appending(path: "terminal-start-fixture").path
        _ = try await WorkspaceManager(store: store).addRepository(at: repo)
        var arguments: [String: JSONValue] = [
            "project": .string(repo), "project_checkout": .bool(true),
            "name": .string("Terminal start evidence"),
            "agent": .string(scenario.contains("codex") ? "codex" : "claudeCode"),
            "prompt": .string("Inspect 'quoted' input.\nKeep this opening task as one argument."),
        ]
        if !usesDefault { arguments["terminal_chat"] = .bool(!scenario.contains("chat")) }
        let host = NSHostingView(rootView: RootView().environment(app)
            .environment(\.colorScheme, .light).transaction { $0.disablesAnimations = true })
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                             styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Workspace start capture"
        window.isFloatingPanel = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        let repetitions = scenario.contains("reuse") ? 2 : 1
        for index in 0..<repetitions {
            if index > 0 {
                arguments["prompt"] = .string("Reused checkout opening task.\nStill delivered as a CLI argument.")
            }
            let result = await start.call(MCPRequest(
                id: .number(Double(index)), method: "workspace_start", params: .object(arguments)
            ), as: .owner, store: store)
            guard !result.isError, let answer = JSONValue.parse(result.text),
                  let id = answer["workspace_id"]?.stringValue else {
                throw NSError(domain: "WorkspaceStartSnapshots", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: result.text])
            }
            app.selection = .workspace(WorkspaceID(id))
            try Data(result.text.utf8).write(to: directory.appending(path: "result-\(index).json"))
        }
        try JSONEncoder().encode(JSONValue.object(arguments)).write(to: directory.appending(path: "request.json"))
        window.layoutIfNeeded()
        // cacheDisplay omits the terminal's native content. A nonactivating panel ordered behind
        // the owner's windows gives WindowServer a surface without taking focus.
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(2))
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration
        )
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appending(path: "workspace.png"))
        print(directory.appending(path: "workspace.png").path)
    }
}
#endif
