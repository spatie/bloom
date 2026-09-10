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
                server.remoteDirectory = "/home/bloom/bloom/data"; server.identityFile = "/tmp/fixture-key"
                server.knownHostsFile = "/tmp/fixture-known-hosts"
                try await verifyAuthenticationIsolation(server)
            }
            let model = ServerSetupModel(server: server, resources: URL(fileURLWithPath: configuration.resources), supportDirectory: URL(fileURLWithPath: configuration.support), resumeExisting: false)
            model.host = configuration.host; model.identityFile = configuration.identityFile; model.label = "New Ubuntu server"
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
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
            if configuration.inspect != false, model.canReviewInstallation {
                guard model.phase == .address else { throw ServerFailure("Check results must stay on the address page.") }
                model.reviewInstallation()
                try await capture("confirm-installation")
            }
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
                let checked = ServerSetupModel(server: server, resources: URL(fileURLWithPath: configuration.resources),
                    supportDirectory: URL(fileURLWithPath: configuration.support), resumeExisting: false,
                    inspectConnection: { connection, _ in
                        if connection.host == "root@unreachable.example" { throw ServerSetupFailure(code: .unreachable) }
                        let blockers = connection.host == "root@blocked.example"
                            ? "[{\"code\":\"service_account_exists\",\"message\":\"The Unix account 'bloom' already exists, but there is no matching managed Bloom installation. Setup will not take over its files or permissions.\"}]" : "[]"
                        return try JSONDecoder().decode(ServerInstallCheck.self, from: Data("""
                        {"platform":"Ubuntu 24.04", "architecture":"x86_64", "privilege":"root", "existing":false,
                        "blockers":\(blockers), "warnings":[], "executable":"/home/bloom/bloom/server/current/bin/bloom-server",
                        "dataDirectory":"/home/bloom/bloom/data", "serviceUser":"bloom"}
                        """.utf8))
                    })
                checked.beginSetup(); checked.host = "root@preview.example"; checked.label = "Development"
                window.contentView = NSHostingView(rootView: ServerSetupView(model: checked, showAdvanced: {}).environment(\.colorScheme, .light).background(Palette.windowBackground))
                await checked.inspect()
                guard checked.phase == .address, checked.canReviewInstallation else { throw ServerFailure("Successful checks left the edit page.") }
                await checked.install()
                guard checked.phase == .address, checked.progress.isEmpty else { throw ServerFailure("Installation bypassed the review step.") }
                try await Task.sleep(for: .milliseconds(200))
                try await capture("inline-checks-fixture")
                checked.reviewInstallation()
                guard checked.phase == .readyToInstall else { throw ServerFailure("Installation review is unavailable.") }
                try await Task.sleep(for: .milliseconds(200))
                try await capture("installation-review-fixture")
                await checked.goBack()
                guard checked.check != nil, checked.canReviewInstallation else { throw ServerFailure("Back discarded unchanged check results.") }
                checked.identityFile = "/tmp/changed-key"
                guard checked.check == nil, !checked.canReviewInstallation else { throw ServerFailure("Changing the key kept stale check results.") }
                checked.identityFile = ""; checked.host = "root@blocked.example"
                await checked.inspect(); checked.reviewInstallation()
                guard checked.phase == .address, !checked.canReviewInstallation, checked.diagnosticReport.contains("service_account_exists") else { throw ServerFailure("Blocked checks allowed installation review.") }
                try await Task.sleep(for: .milliseconds(200))
                try await capture("blocked-checks-fixture")
                checked.host = "root@unreachable.example"
                await checked.inspect()
                guard checked.failure != nil, !checked.isBusy else { throw ServerFailure("A failed connection did not allow correction.") }
                try await Task.sleep(for: .milliseconds(200))
                try await capture("failed-connection-fixture")
                await checked.goBack()
                guard checked.phase == .address, checked.failure == nil else { throw ServerFailure("Back did not recover from a failed check.") }
                checked.host = "root@preview.example"
                guard checked.failure == nil, checked.phase == .address else { throw ServerFailure("Editing the address did not clear its old failure.") }
                await checked.inspect()
                guard checked.canReviewInstallation else { throw ServerFailure("Retry after an address correction failed.") }
                await checked.goBack()
                guard checked.phase == .introduction, checked.host == "root@preview.example" else { throw ServerFailure("Back lost the address at the introduction.") }
                checked.beginSetup(); checked.host = ""
                try await Task.sleep(for: .milliseconds(200))
                try await capture("empty-address-form")
                checked.cancel()
                let live = ServerSetupModel(server: server, resources: URL(fileURLWithPath: configuration.resources),
                    supportDirectory: URL(fileURLWithPath: configuration.support), resumeExisting: false,
                    inspectConnection: { _, _ in
                        try JSONDecoder().decode(ServerInstallCheck.self, from: Data("""
                        {"platform":"Ubuntu 26.04", "architecture":"x86_64", "privilege":"root", "existing":false,
                        "blockers":[], "warnings":[], "executable":"/home/bloom/bloom/server/current/bin/bloom-server",
                        "dataDirectory":"/home/bloom/bloom/data", "serviceUser":"bloom"}
                        """.utf8))
                    }, installConnection: { _, _, _, _, progress in
                        for (step, message) in [("upload-package", "Server package uploaded (64 MB)."), ("verify", "SHA-256 checksum verified."), ("dependencies", "Preparing development tools") ] {
                            await progress(ServerInstallEvent(event: "progress", step: step, message: message))
                        }
                        for line in ["$ apt-get install git tmux gh nodejs npm", "Reading package lists... Done", "Building dependency tree... Done", "nodejs : Conflicts: npm", "E: Unable to correct problems, you have held broken packages."] {
                            await progress(ServerInstallEvent(event: "output", step: "dependencies", message: line))
                        }
                        try await Task.sleep(for: .seconds(2))
                        throw ServerSetupFailure.installation(code: "command_failed", message: "Development tools could not be installed.",
                            recovery: "The installed NodeSource package already includes npm. Use its npm instead of installing Ubuntu’s separate npm package.",
                            details: "nodejs : Conflicts: npm", command: "apt-get install git tmux gh nodejs npm", exitStatus: 100)
                    })
                live.beginSetup(); live.host = "root@preview.example"; live.label = "Development"; live.installsBrowserTools = false
                await live.inspect(); live.reviewInstallation()
                window.contentView = NSHostingView(rootView: ServerSetupView(model: live, showAdvanced: {}).environment(\.colorScheme, .light).background(Palette.windowBackground))
                let installation = Task { await live.install() }
                for _ in 0..<100 where (!live.isBusy || live.activity.lines.count < 5) { try await Task.sleep(for: .milliseconds(20)) }
                try await capture("live-installation-fixture")
                await installation.value
                guard live.failure?.exitStatus == 100, live.activity.output.contains("Conflicts: npm"),
                      live.diagnosticReport.contains("Exit status: 100"), live.diagnosticReport.contains("Server output:") else {
                    throw ServerFailure("The copyable failure report lost command status or live output.")
                }
                try await Task.sleep(for: .milliseconds(200))
                try await capture("exact-failure-fixture")
                await live.goBack()
                let stoppedInstallation = Task { await live.install() }
                for _ in 0..<100 where (!live.isBusy || live.activity.lines.count < 5) { try await Task.sleep(for: .milliseconds(20)) }
                await live.stopSetup()
                await stoppedInstallation.value
                guard live.failure?.code == .cancelled, live.phase == .installing, !live.activity.lines.isEmpty, !live.isBusy else {
                    throw ServerFailure("Stopping setup discarded its diagnostic output or left the action busy.")
                }
                try await capture("stopped-with-output-fixture")
                live.cancel()
                try await ServerCredentialImportProbe.verify(window: window) { phase in try await capture(phase) }
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
