import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Runs notification callbacks and draws the welcome and tab controls in an isolated probe bundle.
@MainActor
enum AppChromeProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--app-chrome-probe") }

    static func runAndExit() -> Never {
        guard Bundle.main.bundleIdentifier != "be.spatie.bloom",
              ProcessInfo.processInfo.environment["BLOOM_DB_PATH"] != nil else { exit(1) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    private static func run() async {
        let availability = TextZoomAvailability.shared
        let oldSize = ChatTextSize.current
        var failures: [String] = []
        for size in ChatTextSize.allCases {
            ChatTextSize.current = size
            for _ in 0..<100 {
                NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: nil)
            }
            await Task.detached {
                for _ in 0..<100 {
                    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                }
            }.value
            try? await Task.sleep(for: .milliseconds(50))
            if availability.canZoomIn != (size.stepped(by: 1) != nil) { failures.append("zoom in: \(size)") }
            if availability.canZoomOut != (size.stepped(by: -1) != nil) { failures.append("zoom out: \(size)") }
            if availability.canResetSize != (size != .defaultChoice) { failures.append("reset: \(size)") }
        }
        ChatTextSize.current = oldSize
        await render(ChromeTabsFixture(), size: CGSize(width: 720, height: 96), name: "tabs")
        await render(WelcomeGreeting(isFirstVisit: false, continueTitle: "See what Bloom needs", onContinue: {}),
                     size: CGSize(width: 520, height: 424), name: "welcome-inactive")
        let result: [String: Any] = ["notifications": 1000, "checks": 15, "passed": failures.isEmpty, "failures": failures]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func render(_ content: some View, size: CGSize, name: String) async {
        let host = NSHostingController(rootView: content
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .inactive)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
            .background(Palette.sidebar))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.view.displayIfNeeded()
        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        if host.view.isFlipped {
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        host.view.layer?.render(in: context.cgContext)
        context.flushGraphics()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "/tmp/bloom-chrome-\(name).png"))
    }
}

private struct ChromeTabsFixture: View {
    var body: some View {
        VStack(spacing: 16) {
            ChromeTabsRow(busy: false)
            ChromeTabsRow(busy: true)
        }
        .padding(.horizontal, 8)
    }
}

private struct ChromeTabsRow: View {
    var busy: Bool
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            tab("Chat", icon: "bubble.left", active: true, busy: busy)
            tab("All changes", icon: "doc.text")
            TabStripSeparator()
            tab("Terminal", icon: "terminal")
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.barHeight)
    }

    private func tab(_ title: String, icon: String, active: Bool = false, busy: Bool = false) -> some View {
        TabItemView(title: title, icon: .symbol(icon), isActive: active, isRunning: busy,
                    isRenaming: false, editableTitle: title, canClose: true, closeTitle: "Close tab",
                    onSelect: {}, onStartRename: {}, onCommitRename: { _ in }, onCancelRename: {}, onClose: {},
                    namespace: namespace)
            .fixedSize(horizontal: true, vertical: false)
    }
}
#endif
