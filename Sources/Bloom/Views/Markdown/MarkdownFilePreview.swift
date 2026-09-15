import SwiftUI
import BloomCore

/// Reads independently of Edit mode so opening a preview cannot reload an active editor.
struct MarkdownFilePreview: View {
    let path: String
    let revision: Int
    var onClose: () -> Void

    @State private var document: MarkdownFileDocument?
    @State private var problem: String?
    private let session = FileEditSession.shared

    private struct Request: Equatable {
        var path: String
        var revision: Int
        var draft: String?
    }

    private var request: Request {
        let draft = session.draft(for: path)
        return Request(path: path, revision: revision, draft: draft?.isDirty == true ? draft?.text : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(action: onClose) {
                    Label("Close preview", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Close Markdown preview")
            }
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.barHeight)
            .background(Palette.surfaceSunken)
            Hairline()
            Group {
                if let problem {
                    EmptyStateView(glyph: "doc", title: "Cannot preview this file", message: problem)
                } else if let document {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                            MarkdownView(document.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if document.isTruncated {
                                Text("Showing the first \(MarkdownFileDocument.lineLimit.formatted()) lines")
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .padding(InspectorLayout.inset)
                    }
                    .defaultScrollAnchor(.topLeading)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    LoadingView("Reading Markdown")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.surface)
        .task(id: request) { await load(request) }
    }

    private func load(_ request: Request) async {
        let result = await Task.detached(priority: .userInitiated) {
            do {
                let document = try MarkdownFileDocument.read(path: request.path, draft: request.draft)
                _ = MarkdownPrime.blocks(of: document.text)
                return Result<MarkdownFileDocument, Error>.success(document)
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(value):
            document = value
            problem = nil
        case let .failure(error):
            document = nil
            problem = error.localizedDescription
        }
    }
}
