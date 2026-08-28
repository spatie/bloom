import AVFoundation
import AVKit
import AppKit
import BloomCore
import QuickLookUI
import SwiftUI

/// Media the agent deliberately placed in the conversation.
///
/// This is content, not an expanded tool detail. It uses the same readable measure and inset as
/// assistant prose, stays out of action folds, and leaves the ordinary tool row behind only when
/// the bridge confirmed the file was safe to show.
struct MediaShowRowView: View {
    var request: MediaShowRequest
    var home: TranscriptHome

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            if !request.caption.isEmpty {
                Text(request.caption)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .proseLeading()
                    .textSelection(.enabled)
            }

            if let media = WorkspaceMedia.resolve(path: request.path, in: home.worktree) {
                mediaView(media)

                HStack(spacing: Metrics.spacingWide) {
                    Label(media.relativePath, systemImage: media.kind == .image ? "photo" : "film")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(media.relativePath)

                    Spacer(minLength: Metrics.spacing)

                    Button("Quick Look", systemImage: "eye") {
                        MediaQuickLookController.shared.show(media.url)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Open in Quick Look")

                    Button("Save As", systemImage: "square.and.arrow.down") {
                        save(media.url)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Save a copy")
                }
            } else {
                Label("This media file is no longer available", systemImage: "doc.questionmark")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(TranscriptLayout.block)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
            }
        }
        .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.block)
    }

    @ViewBuilder
    private func mediaView(_ media: WorkspaceMedia) -> some View {
        Group {
            switch media.kind {
            case .image:
                AttachmentPreview(
                    url: media.url,
                    maxWidth: TranscriptLayout.proseMeasure,
                    maxHeight: 520
                )
            case .video:
                InlineVideoView(url: media.url)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        // An inset pure-neutral outline keeps pale and transparent media legible on both themes
        // without adding a point to the measured row.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
    }

    private func save(_ source: URL) {
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = source.lastPathComponent
            panel.canCreateDirectories = true
            guard await panel.present() == .OK, let destination = panel.url else { return }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// A native AVKit player that never autoplays. Its aspect ratio comes from the video track rather
/// than from a fixed 16:9 box, so portrait screen recordings do not arrive letterboxed as a wide
/// empty card.
private struct InlineVideoView: View {
    var url: URL

    @State private var player: AVPlayer?
    @State private var aspectRatio = 16.0 / 9.0

    var body: some View {
        NativeVideoPlayer(player: player)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: TranscriptLayout.proseMeasure)
            .background(Color.black)
            .task(id: url) { await prepare() }
            .onDisappear { player?.pause() }
            .accessibilityLabel("Video: \(url.lastPathComponent)")
    }

    private func prepare() async {
        player?.pause()
        player = AVPlayer(url: url)

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return }
        let transformed = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width > 0, height > 0 else { return }
        aspectRatio = width / height
    }
}

/// AppKit's player view is stable when the transcript measures an offscreen row. The SwiftUI
/// wrapper currently aborts while its generic metadata is created on macOS 27, which made a chat
/// containing a video crash Bloom again on every launch.
private struct NativeVideoPlayer: NSViewRepresentable {
    var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}

private final class MediaQuickLookController: NSObject, @MainActor QLPreviewPanelDataSource {
    @MainActor
    static let shared = MediaQuickLookController()

    private var url: URL?

    @MainActor
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
