import AppKit
import BloomCore
import SwiftUI

/// An interactive fixture using the production viewport and controls. Available only in an
/// isolated app, so checking layout never opens a workspace or talks to an agent.
@MainActor
enum BrowserViewportDemo {
    static var isRequested: Bool { CommandLine.arguments.contains("--browser-viewport-demo") }
    private static var window: NSWindow?

    static func schedule() {
        guard Bundle.main.bundleIdentifier == "be.spatie.bloom.dev" else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            let session = BrowserSession(url: "")
            session.viewport.isEnabled = true
            session.webView.loadHTMLString(page, baseURL: nil)
            let demo = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            demo.title = "[DEV] Responsive preview"
            demo.isReleasedWhenClosed = false
            demo.contentView = NSHostingView(rootView: BrowserViewportDemoView(session: session))
            demo.center()
            demo.orderFrontRegardless()
            window = demo
            if let index = CommandLine.arguments.firstIndex(of: "--viewport-checks"),
               CommandLine.arguments.indices.contains(index + 1) {
                await check(session, window: demo, output: CommandLine.arguments[index + 1])
            }
        }
    }

    private static func check(_ session: BrowserSession, window: NSWindow, output: String) async {
        var results: [[String: Any]] = []
        do {
            for _ in 0..<100 where session.webView.isLoading {
                try await Task.sleep(for: .milliseconds(100))
            }
            _ = try await session.webView.evaluateJavaScript("document.querySelector('input').value = 'Kept across resizing'")
            for (width, height, fit) in [(390, 844, true), (1440, 900, true), (768, 1024, true), (844, 390, true), (1440, 900, false)] {
                session.viewport.resize(width: width, height: height)
                session.viewport.fitsPane = fit
                try await Task.sleep(for: .milliseconds(450))
                window.contentView?.layoutSubtreeIfNeeded()
                let actual = try await session.webView.evaluateJavaScript(
                    "[innerWidth, innerHeight, document.querySelector('input').value, matchMedia('(min-width: 1000px)').matches]"
                ) as? [Any] ?? []
                results.append([
                    "requested": [width, height], "fit": fit, "actual": actual,
                    "passed": (actual.first as? Int == width) && (actual.dropFirst().first as? Int == height)
                        && (actual.dropFirst(2).first as? String == "Kept across resizing")
                        && (actual.last as? Bool == (width >= 1000)),
                ])
            }
            session.viewport.isEnabled = false
            try await Task.sleep(for: .milliseconds(450))
            let normal = try await session.webView.evaluateJavaScript("[innerWidth, innerHeight]") as? [Int] ?? []
            results.append(["normal": normal, "passed": normal.first == 1000])
            session.viewport.isEnabled = true
            session.viewport.fitsPane = true
            session.viewport.select(.phone)
            try await Task.sleep(for: .milliseconds(450))
            let restored = try await session.webView.evaluateJavaScript("[innerWidth, innerHeight]") as? [Int] ?? []
            results.append(["restored": restored, "passed": restored == [390, 844]])
        } catch {
            results.append(["passed": false, "error": error.localizedDescription])
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output))
        } catch {
            FileHandle.standardError.write(Data("Viewport checks could not be written: \(error)\n".utf8))
        }
    }

    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    * { box-sizing: border-box } body { margin: 0; color: #24392f; background: #f5f3ec;
    font: 16px -apple-system, sans-serif } header { padding: 24px 28px; border-bottom: 1px solid #d9ded3;
    display: flex; justify-content: space-between; align-items: center } header b { font-size: 22px }
    nav { display: flex; gap: 28px } main { padding: 42px 28px; max-width: 1240px; margin: auto }
    .eyebrow { text-transform: uppercase; letter-spacing: 2px; font-size: 11px; color: #60786a }
    h1 { font: 54px Georgia, serif; line-height: 1.05; letter-spacing: -2px; max-width: 620px; margin: 18px 0 }
    .intro { max-width: 510px; line-height: 1.65; color: #607065 }
    .grid { display: grid; grid-template-columns: 1fr; gap: 18px; margin-top: 32px }
    article { border: 1px solid #d9ded3; border-radius: 12px; padding: 26px; background: #fffcf5 }
    .number { color: #7c8d72; font: 38px Georgia, serif } h2 { font-size: 18px; margin-top: 22px }
    article p { font-size: 14px; line-height: 1.6; color: #607065 }
    input { font: inherit; padding: 12px; border: 1px solid #b7c5b2; border-radius: 6px; max-width: 100%; width: 350px }
    label { display: block; margin: 32px 0 10px; font-size: 13px }
    .wide { display: none } @media(min-width: 600px) { .grid { grid-template-columns: repeat(2, 1fr) } }
    @media(min-width: 1000px) { .grid { grid-template-columns: repeat(3, 1fr) } h1 { font-size: 72px }
    .wide { display: inline } } @media(max-width: 599px) { nav { display: none } }
    </style></head><body>
    <header><b>Fieldwork.</b><nav><span>Work</span><span>Studio</span><span>Contact</span></nav></header>
    <main><div class="eyebrow">Independent design studio <span class="wide"> / Desktop layout</span></div>
    <h1>Good things.<br>Thoughtfully made.</h1><p class="intro">A small studio for useful ideas, considered details,
    and websites that feel at home on every screen.</p>
    <div class="grid"><article><div class="number">01</div><h2>A clear starting point</h2>
    <p>Give your ideas room to grow. Find the structure that makes everything feel simple.</p></article>
    <article><div class="number">02</div><h2>Details that matter</h2><p>From the first impression to the smallest
    interaction, make every part feel considered.</p></article><article><div class="number">03</div>
    <h2>Room for every screen</h2><p>Try the presets above or drag the page edges. This grid responds to its real viewport.</p></article></div>
    <label for="note">Your notes stay here while you resize</label><input id="note" placeholder="Try typing something…">
    </main></body></html>
    """
}

private struct BrowserViewportDemoView: View {
    @Bindable var session: BrowserSession
    @State private var address = "Responsive preview example"
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbarView(
                toolbar: BrowserToolbar(), address: $address, addressFocus: $addressFocused,
                isRingVisible: addressFocused, viewport: $session.viewport
            )
            Hairline()
            BrowserViewportView(session: session)
        }
        .background(Palette.surface)
    }
}
