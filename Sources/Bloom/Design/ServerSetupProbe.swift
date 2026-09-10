#if DEBUG
import AppKit
import ScreenCaptureKit
import BloomCore
import SwiftUI

/// A real installation through the production wizard model and view, rendered in an inactive
/// window. The operator supplies an isolated server and its independently verified host key.
@MainActor
enum ServerSetupProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--server-setup-probe") }
    private struct Configuration: Decodable {
        let host: String
        let identityFile: String
        let resources: String
        let support: String
        let output: String
        let expectedFingerprint: String
        let install: Bool
        let githubSignIn: Bool?
        let inspect: Bool?
    }

    static func runAndExit() -> Never {
        Snapshot.refuseWithoutDatabase(flag: "--server-setup-probe")
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    private static func run() async {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--server-setup-probe"), index + 1 < CommandLine.arguments.count else {
                throw ServerFailure("Supply the public probe configuration file.")
            }
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            let output = URL(fileURLWithPath: configuration.output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let preferences = UserDefaults(suiteName: "be.spatie.bloom.wizard-probe.\(UUID())")!
            let app = AppModel()
            let server = ServerWindowModel(preferences: preferences)
            if configuration.inspect == false {
                server.host = "bloom@existing-server"; server.executable = "/opt/bloom/server"
                server.remoteDirectory = "/var/lib/bloom"; server.identityFile = "/tmp/fixture-key"
                server.knownHostsFile = "/tmp/fixture-known-hosts"
                try await verifyAuthenticationIsolation(server)
            }
            let model = ServerSetupModel(server: server, resources: URL(fileURLWithPath: configuration.resources), supportDirectory: URL(fileURLWithPath: configuration.support), resumeExisting: false)
            model.host = configuration.host; model.identityFile = configuration.identityFile; model.label = "New Ubuntu server"
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.title = "Bloom server setup verification"
            window.contentView = NSHostingView(rootView: ServerSetupView(model: model, showAdvanced: {}).environment(\.colorScheme, .light).background(Palette.windowBackground))
            window.orderBack(nil)
            var count = 0
            func capture(_ phase: String, targetWindow: NSWindow? = nil) async throws {
                let window = targetWindow ?? window
                window.contentView?.layoutSubtreeIfNeeded()
                let content = try await SCShareableContent.currentProcess
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw ServerFailure("The wizard's own window is unavailable for capture.")
                }
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let settings = SCStreamConfiguration()
                settings.width = Int(window.frame.width * 2)
                settings.height = Int(window.frame.height * 2)
                settings.showsCursor = false
                settings.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ServerFailure("The wizard capture could not be encoded.") }
                count += 1
                try data.write(to: output.appendingPathComponent(String(format: "%02d-%@.png", count, phase)))
            }
            try await Task.sleep(for: .milliseconds(300))
            guard model.phase == .introduction else { throw ServerFailure("Adding a server must introduce the feature first.") }
            try await capture("introduction")
            model.beginSetup()
            if configuration.inspect == false {
                let address = model.host, label = model.label, key = model.identityFile
                model.showIntroduction()
                guard model.phase == .introduction, model.host == address, model.label == label, model.identityFile == key else {
                    throw ServerFailure("Returning to the introduction lost the entered server details.")
                }
                model.beginSetup()
            }
            try await Task.sleep(for: .milliseconds(200))
            try await capture("server-details")
            if configuration.inspect != false { await model.inspect() }
            try await capture("server-check")
            if model.phase == .trust {
                guard model.fingerprint == configuration.expectedFingerprint else { throw ServerFailure("The wizard host fingerprint does not match the independently verified key.") }
                try await capture("verify-host")
                await model.trustHost()
            }
            try await capture("preflight")
            if configuration.install, model.phase == .readyToInstall, model.check?.blockers.isEmpty == true {
                let operation = Task { await model.install() }
                var progressCount = -1
                while !operation.isCancelled {
                    try await Task.sleep(for: .milliseconds(500))
                    if model.progress.count != progressCount {
                        progressCount = model.progress.count
                        try await capture("installation")
                    }
                    if !model.isBusy { break }
                }
                await operation.value
                try await capture("accounts")
                if model.phase == .accounts, let root = window.contentView,
                   let scroll = accountScroll(in: root), let document = scroll.documentView {
                    let original = scroll.contentView.bounds.origin
                    let end = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(200))
                    try await capture("account-details")
                    scroll.contentView.scroll(to: original)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if configuration.githubSignIn == true, let launch = model.accountTerminal(.github) {
                    let login = LoginTerminalSession(launch: launch, label: "GitHub on the new server") { _ in }
                    let loginWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
                    loginWindow.isReleasedWhenClosed = false
                    loginWindow.title = "Bloom GitHub sign-in verification"
                    loginWindow.appearance = NSAppearance(named: .aqua)
                    loginWindow.contentView = NSHostingView(rootView: ServerSetupLoginView(session: login, close: {}).environment(\.colorScheme, .light).background(Palette.windowBackground))
                    loginWindow.orderBack(nil)
                    login.start()
                    try await Task.sleep(for: .seconds(2))
                    login.terminal.send(txt: "\r")
                    try await Task.sleep(for: .seconds(2))
                    login.terminal.send(txt: "\r")
                    try await Task.sleep(for: .seconds(3))
                    try await capture("github-device-sign-in", targetWindow: loginWindow)
                    let terminal = login.terminal.getTerminal()
                    var text = "", row = terminal.buffer.totalLinesTrimmed
                    while let line = terminal.getScrollInvariantLine(row: row) {
                        text += line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) + "\n"
                        row += 1
                    }
                    if let range = text.range(of: "[A-Z0-9]{4}-[A-Z0-9]{4}", options: .regularExpression) {
                        try String(text[range]).write(to: output.appendingPathComponent("github-device-code.txt"), atomically: true, encoding: .utf8)
                    }
                    for _ in 0..<600 where login.isRunning { try await Task.sleep(for: .seconds(1)) }
                    try await capture("github-sign-in-result", targetWindow: loginWindow)
                    login.stop(); loginWindow.close()
                    await model.refreshAccounts()
                    try await capture("accounts-after-sign-in")
                }
                if model.canConnect { await model.connect(); try await capture("connected") }
            }
            if configuration.inspect == false {
                guard model.phase == .address else { throw ServerFailure("Adding a server must start with a fresh address form.") }
                window.contentView = NSHostingView(rootView: SidebarStatusBar(filter: .constant(.all)).environment(app).environment(\.colorScheme, .light).background(Palette.windowBackground))
                window.setContentSize(NSSize(width: 280, height: 40))
                try await Task.sleep(for: .milliseconds(200))
                try await capture("sidebar-footer")
            }
            let report: [String: Any] = ["phase": String(describing: model.phase), "error": model.failure?.message ?? "", "captures": count,
                                       "connected": server.isConnected, "progress": model.progress, "windowWasShown": window.isVisible]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
            model.cancel()
            await server.disconnect()
            window.close()
            exit(model.failure == nil ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func accountScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = accountScroll(in: child) { return scroll }
        }
        return nil
    }

    private static func verifyAuthenticationIsolation(_ server: ServerWindowModel) async throws {
        let original = server.connectionProfile
        let endpoint = server.endpoint
        guard let candidate = ServerConnectionProfile(values: ["usesHTTPS": "true", "httpsAddress": "https://example.invalid"]) else {
            throw ServerFailure("The authentication test fixture is invalid.")
        }
        let cancelled = await server.connect(to: candidate, authenticate: { _ in throw CancellationError() })
        guard !cancelled, server.connectionProfile == original, server.endpoint == endpoint else {
            throw ServerFailure("Cancelled sign-in changed the active server.")
        }
        let stale = await server.connect(to: candidate, authenticate: { _ in await server.disconnect() })
        guard !stale, server.connectionProfile == original, server.endpoint == endpoint else {
            throw ServerFailure("A stale sign-in changed the active server.")
        }
        server.error = nil
    }
}
#endif
