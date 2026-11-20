import AppKit
import BloomCore

#if DEBUG
/// Lists every hosting view in the window with its depth, counted the way AppKit's layout pass
/// recurses, so a crash report's stack depth can be matched to a view.
///
///     Bloom --hostdepth-probe /tmp/hostdepth.json [--hostdepth-workspace <id>] [--window-hidden]
@MainActor
enum HostDepthProbe {
    private static let harness = ProbeHarness(subject: "hostdepth")

    static var isRequested: Bool { harness.isRequested }

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        let (window, content) = await harness.window()
        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        harness.markStarted()
        var report: [String: JSONValue] = [:]
        app.selection = .home
        try? await Task.sleep(for: .seconds(2))
        report["home"] = .array(hosts(under: content.superview ?? content))
        if let id = ProbeHarness.value(for: "--hostdepth-workspace").map(WorkspaceID.init) {
            app.selection = .workspace(id)
            try? await Task.sleep(for: .seconds(4))
            report["workspace"] = .array(hosts(under: content.superview ?? content))
            AppModel.probeSelectedModel?.activeTranscript?.probeSend("probe")
            try? await Task.sleep(for: .seconds(3))
            report["running"] = .array(hosts(under: content.superview ?? content))
            AppModel.probeSelectedModel?.activeTranscript?.probeSettle()
        }
        _ = window
        harness.write(.object(report))
        exit(0)
    }

    /// The frame view is depth 1, as the outermost `_layoutSubtreeWithOldSize:` in a stack.
    private static func hosts(under root: NSView) -> [JSONValue] {
        var found: [JSONValue] = []
        func walk(_ view: NSView, _ depth: Int, _ path: [String]) {
            let name = String(describing: type(of: view))
            let chain = path + [name]
            if name.contains("Hosting") {
                found.append(.string("\(depth) \(chain.suffix(6).joined(separator: " > "))"))
            }
            for child in view.subviews { walk(child, depth + 1, chain) }
        }
        walk(root, 1, [])
        return found
    }
}
#endif
