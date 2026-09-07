import AppKit
import BloomCore
import SwiftUI

/// Renders only its own offscreen controls, never the desktop or a real pull request.
@MainActor
enum MergeContrastProbe {
    private static let harness = ProbeHarness(subject: "merge-contrast")
    static var isRequested: Bool { harness.isRequested }
    static func schedule() { Task { @MainActor in await run() } }

    private static func run() async {
        _ = await harness.window()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(name: name, appearance: appearance, titlebar: false)
            await render(name: name, appearance: appearance, titlebar: true)
        }
        harness.write(.object(["rendered": .bool(true)]))
        exit(0)
    }

    private static func render(name: String, appearance: NSAppearance.Name, titlebar: Bool) async {
        let host = NSHostingView(rootView: MergeSplitButton(
            method: .merge, fill: Color(red: 0, green: 0.45, blue: 0.4),
            canMerge: true, choose: { _ in }, merge: {}
        ).padding(20).background(Color.white).environment(\.controlActiveState, .active))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 80)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: titlebar ? [.titled] : [], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        if titlebar {
            window.toolbar = NSToolbar(identifier: "merge-contrast")
            window.toolbarStyle = .unified
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = host
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
        } else {
            window.contentView = host
        }
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            harness.fail("no bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let path = harness.outputPath + ".\(name)\(titlebar ? "-titlebar" : "").png"
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
