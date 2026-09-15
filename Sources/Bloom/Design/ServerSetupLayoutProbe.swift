#if DEBUG
import AppKit
import BloomCore
import SwiftUI

/// Whether the setup wizard's Installation and "Setup stopped" pages fit the window, measured
/// rather than guessed.
///
/// Written when the owner's screenshots showed the optional extras below the fold and a failure
/// clipping the install stages mid row. `ServerSetupProbe` photographs these pages too, but only
/// against a real server and through a window the window server composites. This draws the real
/// `ServerSetupView` at its own 840 by 700 in a window that is never ordered in, reports how far
/// each scroll view's content runs past its viewport, and writes a PNG per page. Nothing reaches
/// the display, the Keychain or a server.
///
///     BLOOM_DB_PATH=/tmp/probe.sqlite .build/debug/Bloom --server-setup-layout-probe /tmp/layout
@MainActor
enum ServerSetupLayoutProbe {
    private static let flag = "--server-setup-layout-probe"
    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    static func runAndExit() -> Never {
        Snapshot.refuseWithoutDatabase(flag: flag)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task {
            do {
                try await run()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(flag): \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    private struct Page {
        let name: String
        let check: String
        var failure: ServerSetupFailure?
    }

    private static func check(warnings: String = "[]", swap: String) -> String {
        """
        {"platform":"Ubuntu 26.04", "architecture":"x86_64", "privilege":"root", "existing":false,
        "blockers":[], "warnings":\(warnings), "executable":"/home/bloom/bloom/server/current/bin/bloom-server",
        "dataDirectory":"/home/bloom/bloom/data", "serviceUser":"bloom", "serviceHome":"/home/bloom"\(swap)}
        """
    }

    private static let memoryWarning = """
        [{"code":"limited_memory","message":"This server has 1 GB of memory. Agents and builds may be slow or stop."}]
        """

    private static var pages: [Page] {
        let offered = check(swap: #", "activeSwapBytes":0, "configuredSwap":false"#)
        return [
            Page(name: "installation-page", check: offered),
            Page(name: "installation-memory-warning-active-swap",
                 check: check(warnings: memoryWarning, swap: #", "activeSwapBytes":2147483648, "configuredSwap":true"#)),
            Page(name: "installation-configured-swap", check: check(swap: #", "activeSwapBytes":0, "configuredSwap":true"#)),
            Page(name: "installation-unknown-swap", check: check(swap: "")),
            Page(name: "setup-stopped-long-failure", check: offered, failure: .installation(
                code: "maintenance_unsupported",
                message: "This server package does not support supervised maintenance. Choose a newly built Bloom Server package, "
                    + "or build one from this checkout, and try the installation again from the beginning.",
                recovery: "Inspect the managed maintenance service as an administrator. Finish or recover pending updates before retrying setup.",
                details: "maintenance protocol 0", command: "ssh", exitStatus: 1)),
        ]
    }

    private static func run() async throws {
        guard let output = ProbeHarness.value(for: flag) else { throw ServerFailure("Name a directory to write into.") }
        let directory = URL(fileURLWithPath: output)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-layout-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data().write(to: scratch.appendingPathComponent("install-bloom-server.py"))
        defer { try? FileManager.default.removeItem(at: scratch) }

        var fits = true
        for page in pages {
            let preferences = UserDefaults(suiteName: "be.spatie.bloom.layout-probe.\(UUID())")!
            let json = page.check
            let model = ServerSetupModel(server: ServerWindowModel(preferences: preferences), resources: scratch,
                supportDirectory: scratch, resumeExisting: false,
                inspectConnection: { _, _ in try JSONDecoder().decode(ServerInstallCheck.self, from: Data(json.utf8)) })
            model.beginSetup(); model.host = "root@203.0.113.10"; model.label = "Bloom Server"
            await model.inspect()
            guard model.phase == .readyToInstall else { throw ServerFailure("\(page.name) did not reach Installation.") }
            if let failure = page.failure {
                model.showFailureForLayoutProbe(failure, events: [
                    ServerInstallEvent(event: "progress", step: "upload-package", message: "Server package upload complete."),
                    ServerInstallEvent(event: "progress", step: "verify", message: "Verifying the uploaded package"),
                ])
            }

            let size = CGSize(width: 840, height: 700)
            let host = NSHostingView(rootView: ServerSetupView(model: model, showAdvanced: {})
                .environment(\.colorScheme, .light).background(Palette.windowBackground))
            host.wantsLayer = true
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()

            let overflow = scrollViews(in: host).map { scroll in
                (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
            }
            let worst = overflow.max() ?? 0
            if worst > 0.5 { fits = false }
            try render(host, to: directory.appendingPathComponent(page.name + ".png"))
            print("\(page.name): scroll overflow \(overflow.map { String(format: "%.1f", $0) }) visible=\(window.isVisible)")
            model.cancel()
        }
        print(fits ? "every page fits" : "a page scrolls")
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    /// Twice the points, so the PNG can be read the way the owner's screenshots are.
    private static func render(_ host: NSView, to url: URL) throws {
        host.displayIfNeeded()
        let bounds = host.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = host.layer
        else { throw ServerFailure("The page could not be drawn.") }
        bitmap.size = bounds.size
        context.cgContext.scaleBy(x: 2, y: 2)
        if host.isFlipped {
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context.cgContext)
        context.flushGraphics()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ServerFailure("The page could not be encoded.") }
        try png.write(to: url)
    }
}
#endif
