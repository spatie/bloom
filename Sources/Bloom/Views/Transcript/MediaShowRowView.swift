import AVFoundation
import AVKit
import AppKit
import BloomCore
import SwiftUI

/// Media the agent deliberately placed in the conversation.
///
/// This is content, not an expanded tool detail. It uses the same readable measure and inset as
/// assistant prose, stays out of action folds, and leaves the ordinary tool row behind only when
/// the bridge confirmed the file was safe to show.
struct MediaShowRowView: View {
    enum Source {
        case workspace
        case codexImageView
    }

    var request: MediaShowRequest
    var home: TranscriptHome
    var source: Source = .workspace

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

            if let media = resolvedMedia {
                mediaView(media)

                HStack(spacing: Metrics.spacing) {
                    Label(media.relativePath, systemImage: media.kind == .image ? "photo" : "film")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(media.relativePath)

                    Menu {
                        Button("Open") { NSWorkspace.shared.open(media.url) }
                        Button("Download") { save(media.url) }
                    } label: {
                        Label("More for \(media.url.lastPathComponent)", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Open or download this file")

                    Spacer(minLength: 0)
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

    private var resolvedMedia: WorkspaceMedia? {
        switch source {
        case .workspace:
            WorkspaceMedia.resolve(path: request.path, in: home.worktree)
        case .codexImageView:
            WorkspaceMedia.resolveImageView(path: request.path, in: home.worktree)
        }
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
                .background(HoverQuickLook(url: media.url))
                .help("Hover and press Space for Quick Look")
                .accessibilityAction(named: "Quick Look") {
                    HoverQuickLookController.shared.show(media.url)
                }
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
            guard source.resolvingSymlinksInPath().standardizedFileURL
                != destination.resolvingSymlinksInPath().standardizedFileURL else { return }

            do {
                // Prepare the whole copy before replacing an existing destination. A failed
                // copy must not delete the file the save panel asked permission to replace.
                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".bloom-download-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
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
