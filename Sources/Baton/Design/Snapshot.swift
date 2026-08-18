import SwiftUI
import AppKit
import BatonCore

/// Renders the app's own views to PNG files and exits.
///
/// This exists because screen recording is not always permitted, and a UI cannot be judged from
/// its source. `ImageRenderer` draws a SwiftUI view straight to a bitmap in process, with no
/// window and no screen capture, so the interface can be looked at from a terminal.
///
/// Two limits worth knowing. An `NSViewRepresentable` (the sidebar material, the terminal) does
/// not draw here, so those areas come out empty. And nothing asynchronous runs, so every scene
/// has to be handed state that is already loaded.
///
///     Baton --snapshot /tmp/shots
@MainActor
enum Snapshot {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--snapshot")
    }

    private static var directory: String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else {
            return NSTemporaryDirectory() + "baton-shots"
        }
        return arguments[index + 1]
    }

    /// Blocks the main thread on purpose. This runs before any scene exists, and the process is
    /// going to exit at the end of it either way.
    static func runAndExit() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await render()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        exit(0)
    }


    // MARK: - Window capture

    /// Captures the real window, rather than re-rendering views.
    ///
    /// `ImageRenderer` cannot draw a `List`, a `SettingsLink` or an `NSViewRepresentable`: it
    /// paints SwiftUI's yellow "unsupported" placeholder instead, which is useless for judging a
    /// sidebar built on `List`. Asking the window's own view hierarchy to draw itself into a
    /// bitmap goes through the real AppKit rendering path, so materials, toolbars and lists all
    /// come out as the user sees them, and it needs no screen recording permission.
    ///
    ///     Baton --snapshot-window /tmp/shots/window.png
    static var isWindowCaptureRequested: Bool {
        CommandLine.arguments.contains("--snapshot-window")
    }

    private static var windowCapturePath: String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-window"), index + 1 < arguments.count else {
            return NSTemporaryDirectory() + "baton-window.png"
        }
        return arguments[index + 1]
    }

    /// Waits for the window to exist and settle, captures it, then exits.
    static func scheduleWindowCapture() {
        Task { @MainActor in
            let path = windowCapturePath
            // Long enough for the first layout pass and any `.task` that populates the sidebar.
            try? await Task.sleep(for: .seconds(3))

            // Optionally open a workspace first, so the screen that matters (transcript, composer,
            // inspector) can be captured rather than only the home screen.
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--select"), index + 1 < arguments.count {
                NotificationCenter.default.post(
                    name: .batonOpenWorkspace, object: arguments[index + 1]
                )
                try? await Task.sleep(for: .seconds(3))
            }

            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let content = window.contentView else {
                FileHandle.standardError.write(Data("no window to capture\n".utf8))
                exit(1)
            }

            let bounds = content.bounds
            guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
                FileHandle.standardError.write(Data("could not allocate a bitmap\n".utf8))
                exit(1)
            }

            // `cacheDisplay` walks the view hierarchy and asks each view to draw. That misses
            // anything whose content lives in a layer rather than in `draw(_:)`, which on macOS
            // includes the NSTableView behind a SwiftUI `List`: the sidebar came out blank.
            // Rendering the layer tree instead captures what is actually composited on screen.
            if let layer = content.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
                // A CALayer's geometry has its origin at the top left, the opposite of the
                // AppKit view it backs, so the context has to be flipped before it is rendered.
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: bounds.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
                context.flushGraphics()
            } else {
                content.cacheDisplay(in: bounds, to: rep)
            }

            guard let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("could not encode the bitmap\n".utf8))
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: path))
            print(path)
            exit(0)
        }
    }

    private static func render() async {
        let output = directory
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        let model = await seededModel()

        let scenes: [(String, AnyView, CGSize)] = [
            ("sidebar", AnyView(SidebarView().frame(width: 260, height: 620)), CGSize(width: 260, height: 620)),
            ("home", AnyView(HomeView().frame(width: 900, height: 620)), CGSize(width: 900, height: 620)),
            ("components", AnyView(ComponentGallery().frame(width: 640, height: 700)), CGSize(width: 640, height: 700)),
        ]

        for appearanceName in ["light", "dark"] {
            let appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)!
            NSApp?.appearance = appearance

            for (name, view, size) in scenes {
                // Semantic NSColors resolve against whatever appearance is current while drawing,
                // so the whole render has to happen inside this block.
                var rendered: Data?
                appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(
                    content: view
                        .environment(model)
                        .environment(\.colorScheme, appearanceName == "dark" ? .dark : .light)
                        .frame(width: size.width, height: size.height)
                        .background(Palette.windowBackground)
                )
                renderer.scale = 2

                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff) {
                    rendered = bitmap.representation(using: .png, properties: [:])
                }
                }

                guard let png = rendered else {
                    FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                    continue
                }
                let path = "\(output)/\(name)-\(appearanceName).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print(path)
            }
        }
    }

    /// A model holding enough to make the views show something. The database path is overridden
    /// through the environment, so this can never touch the user's real workspaces.
    private static func seededModel() async -> AppModel {
        let model = AppModel()
        await model.bootstrap()
        return model
    }
}

/// Every shared control on one page, which is the fastest way to see whether the design system
/// is coherent rather than checking one screen at a time.
private struct ComponentGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Text") {
                Text("Title, semibold body").font(Typo.title)
                Text("Body, the default reading size").font(Typo.body)
                Text("Label, one step down").font(Typo.label).foregroundStyle(Palette.textSecondary)
                Text("Caption, for metadata").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                Text("let code = \"monospaced\"").font(Typo.code)
            }

            group("Chips and stats") {
                HStack(spacing: 6) {
                    Chip(text: "Read", systemImage: "doc.text")
                    Chip(text: "Ticket.php", monospaced: true)
                    Chip(text: "opus", systemImage: "sparkle", tint: Palette.accent)
                    DiffStatLabel(additions: 118, deletions: 4)
                    DiffStatLabel(additions: 2_800, deletions: 608)
                }
            }

            group("Rows") {
                VStack(spacing: 2) {
                    galleryRow("Selected row", selected: true, hovered: false)
                    galleryRow("Hovered row", selected: false, hovered: true)
                    galleryRow("Plain row", selected: false, hovered: false)
                }
            }

            group("Buttons") {
                HStack(spacing: 8) {
                    Button("Primary") {}.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Secondary") {}.buttonStyle(.bordered).controlSize(.large)
                    Button("Borderless") {}.buttonStyle(.borderless)
                }
            }

            group("State") {
                HStack(spacing: 14) {
                    HStack(spacing: 5) { ActivityDot(isActive: true); Text("Running").font(Typo.label) }
                    HStack(spacing: 5) { ActivityDot(isActive: false); Text("Idle").font(Typo.label) }
                    Text("Positive").font(Typo.label).foregroundStyle(Palette.positive)
                    Text("Negative").font(Typo.label).foregroundStyle(Palette.negative)
                    Text("Warning").font(Typo.label).foregroundStyle(Palette.warning)
                }
            }

            group("Diff tints") {
                VStack(spacing: 0) {
                    Text("+    let added = true")
                        .font(Typo.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(Palette.diffAddBackground)
                    Text("-    let removed = false")
                        .font(Typo.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(Palette.diffDeleteBackground)
                }
            }

            Spacer()
        }
        .padding(20)
        .background(Palette.surface)
    }

    private func galleryRow(_ title: String, selected: Bool, hovered: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(Typo.caption)
            Text(title).font(Typo.body)
            Spacer()
            DiffStatLabel(additions: 12, deletions: 3)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .rowBackground(isSelected: selected, isHovered: hovered)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}
