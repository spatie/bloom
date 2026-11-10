import AppKit
import BloomCore
import Observation
import SwiftUI

/// Offscreen photographs of the real settings controls and table, including changing the same
/// open table's measure. No bootstrap, windows ordered on screen, input events or display capture.
/// Run the isolated app with --snapshot <directory> --chat-width.
@MainActor
enum ChatWidthSnapshots {
    @Observable final class Choice {
        var width = ChatWidth.comfortable
        var limitsProse = true
        var streaming = false
        var measures: ChatWidth.Measures { width.measures(limitsProse: limitsProse) }
    }

    static func render(to output: String) async {
        guard Bundle.main.bundleIdentifier != "be.spatie.bloom" else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let app = AppModel()
        let choice = Choice()
        let controller = TranscriptTableController()
        let size = CGSize(width: 1440, height: 1000)
        let host = NSHostingView(rootView: TranscriptFixture(app: app, choice: choice, controller: controller)
            .frame(width: size.width, height: size.height).background(Palette.surface))
        let transcriptWindow = window(host: host, size: size)
        await settle(host)
        controller.arrived()
        controller.scroll(to: .row(4), anchor: .top)
        await settle(host)
        var placements: [Placement] = []
        for width in ChatWidth.allCases {
            choice.width = width
            choice.limitsProse = true
            await settle(host)
            write(host, to: "\(output)/chat-\(width.rawValue).png")
            record(controller, state: width.rawValue, into: &placements)
        }
        choice.limitsProse = false
        await settle(host)
        write(host, to: "\(output)/chat-full-uncapped.png")
        record(controller, state: "full-uncapped", into: &placements)
        choice.limitsProse = true
        await settle(host)
        write(host, to: "\(output)/chat-full-restored.png")
        record(controller, state: "full-restored", into: &placements)
        for width in [ChatWidth.wide, .comfortable] {
            choice.width = width
            await settle(host)
            write(host, to: "\(output)/chat-\(width.rawValue)-return.png")
            record(controller, state: "\(width.rawValue)-return", into: &placements)
        }
        choice.streaming = true
        choice.limitsProse = true
        choice.width = .comfortable
        await settle(host)
        controller.scroll(to: .row(4), anchor: .top)
        await settle(host)
        for width in ChatWidth.allCases {
            choice.width = width
            await settle(host)
            write(host, to: "\(output)/chat-\(width.rawValue)-streaming.png")
            record(controller, state: "\(width.rawValue)-streaming", into: &placements)
        }
        for width in [ChatWidth.wide, .comfortable] {
            choice.width = width
            await settle(host)
            write(host, to: "\(output)/chat-\(width.rawValue)-streaming-return.png")
            record(controller, state: "\(width.rawValue)-streaming-return", into: &placements)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(placements).write(to: URL(filePath: "\(output)/scroll-positions.json"))
        } catch {
            FileHandle.standardError.write(Data("Could not record capture positions: \(error)\n".utf8))
        }
        transcriptWindow.contentView = nil

        for width in ChatWidth.allCases {
            choice.width = width
            choice.limitsProse = true
            let settingsSize = CGSize(width: 720, height: 300)
            let settings = NSHostingView(rootView: SettingsFixture(choice: choice)
                .frame(width: settingsSize.width, height: settingsSize.height).background(Palette.windowBackground))
            let settingsWindow = window(host: settings, size: settingsSize)
            await settle(settings)
            write(settings, to: "\(output)/settings-\(width.rawValue).png")
            settingsWindow.contentView = nil
        }
        choice.width = .full
        choice.limitsProse = false
        let settingsSize = CGSize(width: 720, height: 300)
        let settings = NSHostingView(rootView: SettingsFixture(choice: choice)
            .frame(width: settingsSize.width, height: settingsSize.height).background(Palette.windowBackground))
        let settingsWindow = window(host: settings, size: settingsSize)
        await settle(settings)
        write(settings, to: "\(output)/settings-full-uncapped.png")
        settingsWindow.contentView = nil

        for width in ChatWidth.allCases {
            let hoverSize = CGSize(width: 1440, height: 540)
            let hover = NSHostingView(rootView: TimestampFixture(width: width)
                .frame(width: hoverSize.width, height: hoverSize.height).background(Palette.surface))
            let hoverWindow = window(host: hover, size: hoverSize)
            await settle(hover)
            write(hover, to: "\(output)/timestamp-\(width.rawValue).png")
            hoverWindow.contentView = nil
        }
    }

    private struct Placement: Encodable {
        let state: String
        let topRow: Int
        let responseFiveDelta: Double
        let offset: Double
    }

    private static func record(_ controller: TranscriptTableController, state: String, into placements: inout [Placement]) {
        guard let scroll = controller.scrollView, let table = scroll.documentView as? NSTableView else { return }
        let visible = scroll.contentView.documentVisibleRect
        placements.append(Placement(
            state: state, topRow: table.row(at: NSPoint(x: 0, y: visible.minY + 1)),
            responseFiveDelta: table.rect(ofRow: 4).minY - visible.minY, offset: visible.minY
        ))
    }

    private static func window(host: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        return window
    }

    private static func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private static func write(_ host: NSView, to path: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        if host.isFlipped {
            context.cgContext.translateBy(x: 0, y: host.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        host.layer?.render(in: context.cgContext)
        context.flushGraphics()
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            print(path)
        } catch {
            FileHandle.standardError.write(Data("Could not write \(path): \(error)\n".utf8))
        }
    }

    private struct SettingsFixture: View {
        @Bindable var choice: Choice
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings / Appearance").font(Typo.title).padding(20)
                Form {
                    Section("Conversation") {
                        ChatWidthControls(choice: $choice.width, limitsProse: $choice.limitsProse)
                    }
                }
                .settingsForm()
            }
        }
    }

    private struct TimestampFixture: View {
        let width: ChatWidth
        private let code = "```swift\nlet measures = ChatWidth.full.measures()\nprint(measures.conversation)\n```"
        private let table = "| Component | Status | Details |\n| --- | --- | --- |\n| Transcript | Ready | Tables can use the complete conversation column |"

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(width.title), timestamp on hover").font(Typo.title).padding(16)
                ProseRowView(text: code, copyText: code, sentAt: Date(timeIntervalSince1970: 1_794_302_400), previewsHover: true)
                ProseRowView(text: table, copyText: table, sentAt: Date(timeIntervalSince1970: 1_794_302_400), previewsHover: true)
                Spacer()
            }
            .environment(\.chatMeasures, width.measures())
            .frame(maxWidth: width.measures().conversation)
            .frame(maxWidth: .infinity)
        }
    }

    private struct TranscriptFixture: View {
        let app: AppModel
        let choice: Choice
        let controller: TranscriptTableController
        @State private var hover = TranscriptHoverHost()
        @State private var bubbles = TranscriptBubbleWidth()
        @State private var selection = TranscriptConversationSelection()

        private static let sample = """
        ## A more useful reading column

        The release summary should stay easy to read on a large display. Paragraphs keep their \
        own measure while the table and code below have room for longer names, useful context \
        and complete command output. Changing the width reflows this open conversation while \
        keeping the reader's place in the same part of the answer.

        | Component | Change | Result | Details |
        | --- | --- | --- | --- |
        | Transcript table | Preserve the visible row during reflow | Ready for review | Open conversations adopt the new width immediately |
        | Markdown renderer | Keep paragraphs readable and give structured blocks more room | Ready for review | Tables and code use the selected column |

        ```swift
        let measures = ChatWidth.wide.measures(limitsProse: true)
        let conversation = measures.conversation // Tables and code can use the whole column.
        let paragraph = measures.prose           // Paragraphs keep an independent reading measure.
        ```
        """

        private var entries: [TranscriptTableEntry] {
            (0..<12).map { index in
                TranscriptTableEntry(id: .row(index), contentKey: TranscriptContentKey { $0.combine(index); $0.combine(choice.streaming) },
                                     shape: .answer, content: {
                    AnyView(VStack(alignment: .leading, spacing: 8) {
                        Text("Response \(index + 1)").font(Typo.caption).padding(.horizontal, TranscriptLayout.inset)
                        ProseRowView(text: Self.sample, isStreaming: choice.streaming)
                        Text("Command output").font(Typo.caption).padding(.horizontal, TranscriptLayout.inset)
                        DetailCodeBlock(text: "Build complete!\nTranscriptTable.swift    reflowed    visible rows retained    column follows the selected chat width\nMarkdownView.swift       rendered    paragraphs capped         tables and code use the full column")
                            .padding(.horizontal, TranscriptLayout.inset)
                    }.padding(.vertical, 16))
                })
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(choice.width.title)\(choice.limitsProse ? "" : ", paragraph cap off")")
                    .font(Typo.title).padding(16)
                TranscriptTable(entries: entries, session: SessionID("chat-width-snapshot"), controller: controller,
                    heightMemory: nil, scale: ChatTextSize.defaultChoice.scale,
                    rowEnvironment: TranscriptRowEnvironment(
                        app: app, hoverHost: hover, bubbleWidth: bubbles, conversation: selection,
                        linkActions: TranscriptLinkActions(), table: controller,
                        fontScale: ChatTextSize.defaultChoice.scale, chatFont: .standard,
                        lineHeight: .defaultChoice, chatMeasures: choice.measures, reduceMotion: true
                    ), onGeometryChange: { _ in }, onSettled: {}, onLiveScrollChange: { _ in })
            }
            .environment(app)
        }
    }
}
