import AppKit
import SwiftUI

struct SidebarMaterial: NSViewRepresentable {
    var tint: Color
    var opacity: Double

    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        let overlay = NSView(frame: view.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let colour = tint.opacity(opacity).resolve(in: environment)
        view.subviews.first?.layer?.backgroundColor = NSColor(
            srgbRed: CGFloat(colour.red), green: CGFloat(colour.green), blue: CGFloat(colour.blue),
            alpha: CGFloat(colour.opacity)
        ).cgColor
    }
}
