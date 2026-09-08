import SwiftUI
import UniformTypeIdentifiers
import BloomCore

/// The normal transcript rows and editor, with every action routed to the owning server.
/// Remote paths never enter a local WorkspaceModel or a local attachment preview.
struct RemoteConversationView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var showsFilePicker = false
    @State private var expanded: Set<Int64> = []
    @State private var caret = 0
    @State private var focused = false
    @State private var editorHeight = ComposerTextEditor.lineHeight
    @State private var bubbleWidth = TranscriptBubbleWidth()

    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.defaultChoice
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.defaultChoice

    private var canSend: Bool {
        model.isConnected && !model.isPerformingCommand
            && !model.isUploading && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let workspace = model.selectedWorkspace {
                HStack(spacing: 8) {
                    Label(workspace.branch, systemImage: "arrow.triangle.branch")
                    Spacer()
                    Label(model.serverName, systemImage: "server.rack")
                }
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, TranscriptLayout.inset).padding(.vertical, 10)
                Divider()
            }
            if let error = model.error {
                HStack {
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if !model.isConnected { Button("Reconnect") { Task { await model.connect() } } }
                }
                .font(Typo.caption).padding().background(Palette.surfaceSunken)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        TranscriptRowView(
                            row: row,
                            home: TranscriptHome(worktree: model.selectedWorkspace?.path ?? "", remoteWorkspaceID: model.selectedWorkspace?.id),
                            isExpanded: expanded.contains(row.id),
                            projectName: model.catalogue?.repositories.first { $0.id == model.selectedWorkspace?.repoID }?.name,
                            onToggle: {
                                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                            },
                            onAnswer: answer
                        )
                    }
                    if !model.streamingText.isEmpty { ProseRowView(text: model.streamingText) }
                }
                .padding(.vertical, TranscriptLayout.inset)
            }
            .defaultScrollAnchor(.bottom)
            .environment(\.transcriptBubbleWidth, bubbleWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                bubbleWidth.cap = max(240, min(640, width * 0.8))
            }
            if let error = model.queueError, !model.queuedPrompts.isEmpty { Text(error).font(Typo.caption).foregroundStyle(Palette.textSecondary).padding(8) }
            ForEach(model.queuedPrompts) { prompt in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Queued").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        Text(prompt.text).lineLimit(3)
                    }
                    Spacer()
                    Button("Remove queued message", systemImage: "xmark") { Task { await model.cancelQueued(prompt.id) } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(10).background(Palette.surfaceSunken).padding(.horizontal, TranscriptLayout.inset)
            }
            composer
        }
        .background(Palette.windowBackground)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
        .environment(\.markdownLinkActions, TranscriptLinkActions(
            identity: .workspace(model.selectedWorkspace?.id, pane: "remote"),
            open: { url, _ in Task { await model.preview(url) } },
            items: { _ in [TranscriptLinkItem(title: "Open Preview", target: .browserTab)] },
            openFile: { model.openFile($0); app.isInspectorVisible = true }
        ))
        .onChange(of: model.selectedSessionID) { _, _ in expanded = [] }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                let sources = try result.get().map(AttachmentSource.file)
                Task { await model.upload(sources) }
            } catch { model.error = error.localizedDescription }
        }
    }

    private var rows: [TranscriptRow] {
        return TranscriptModel.rows(from: model.messages).map { original in
            var row = original
            if row.kind == .permissionAsk, let ask = PermissionAsk.decode(payload: row.payload) {
                row.permissionDecision = model.permissionDecisions[ask.requestID]
            }
            return row
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ComposerEditor(
                text: $model.draft, caret: $caret, isFocused: $focused,
                height: min(180, editorHeight), onContentHeightChange: { editorHeight = $0 },
                onKey: { key in
                    if key == .returnKey || key == .commandReturn {
                        if canSend { Task { await model.send() } }
                        return true
                    }
                    return false
                },
                onAttach: { sources, _ in Task { await model.upload(sources) }; return true },
                onAttachmentFailure: { model.error = $0 },
                onOpenAttachment: { model.openFile($0); app.isInspectorVisible = true },
                placeholder: "Ask to make changes"
            )
            HStack(spacing: 10) {
                Button("Attach File", systemImage: "paperclip") { showsFilePicker = true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!model.isConnected || model.isUploading)
                if let session = model.selectedSession {
                    Text(session.model).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                if model.isBusy || model.isUploading { ProgressView().controlSize(.small) }
                Spacer()
                if model.isBusy {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                ComposerSendButton(canSend: canSend) { Task { await model.send() } }
            }
        }
        .padding(12)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner).stroke(Palette.border, lineWidth: 1))
        .padding(TranscriptLayout.inset)
    }

    private func answer(_ requestID: String, _ decision: PermissionDecision) {
        guard let ask = model.questions.first(where: { $0.requestID == requestID }) else { return }
        let response: ServerAnswer
        switch decision {
        case .allow(let scope):
            switch scope {
            case .once: response = .allowOnce
            case .session: response = .allowSession
            case .project: response = .allowProject
            }
        case .deny: response = .deny
        case .answer(let value): response = .question(input: value)
        }
        Task { await model.answer(ask, decision: response) }
    }
}
