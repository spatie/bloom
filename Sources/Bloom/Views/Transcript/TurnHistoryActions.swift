import SwiftUI
import BloomCore

struct TurnHistoryActions: View {
    var transcript: TranscriptModel
    var endingAt: Int
    @State private var isOpen = false

    private var checkpoint: TurnCheckpoint? {
        transcript.history.checkpoints.first { $0.endSeq == endingAt && $0.after != nil }
    }

    var body: some View {
        if let checkpoint {
            Button { isOpen = true } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Review the file changes during this turn")
            .accessibilityLabel("Review turn changes")
            .sheet(isPresented: $isOpen) {
                TurnSnapshotView(transcript: transcript, checkpoint: checkpoint)
            }
        }
    }
}

struct TurnSnapshotView: View {
    var transcript: TranscriptModel
    var checkpoint: TurnCheckpoint
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var patch: String?
    @State private var failure: String?
    @State private var paths: [String] = []
    @State private var selectedPath = ""
    @State private var showsLargeDiff = false
    @State private var confirmsRewind = false

    init(transcript: TranscriptModel, checkpoint: TurnCheckpoint, initialPath: String = "") {
        self.transcript = transcript
        self.checkpoint = checkpoint
        _selectedPath = State(initialValue: initialPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("Changes During This Turn").font(Typo.label)
                Spacer()
                if !paths.isEmpty {
                    Picker("File", selection: $selectedPath) {
                        Text("All files").tag("")
                        ForEach(paths, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 380)
                }
                if let patch { CopyButton(text: patch, title: "Copy patch") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Includes changes made by other conversations or terminal commands during the same period.")
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            if let failure {
                Text(failure).textSelection(.enabled)
            } else if let patch {
                if patch.isEmpty {
                    Text("No file changes during this turn.")
                } else if patch.utf8.count > 200_000 && !showsLargeDiff {
                    Text("This diff is large. Choose a file above or show the full patch.")
                    Button("Show Full Patch") { showsLargeDiff = true }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(patch).font(Typo.codeSmall).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView("Loading the saved diff")
            }
            Spacer(minLength: 0)
            if checkpoint.providerTurnID != nil, transcript.session.agentKind == .codex {
                Button("Edit From Here") { confirmsRewind = true }
                    .disabled(transcript.isRunning || transcript.history.isRewinding)
                    .help("Rewind to before this turn and return its prompt to the composer")
            }
        }
        .padding(Metrics.gutter)
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 640)
        .task(id: selectedPath) { await loadPatch() }
        .alert("Edit from before this turn?", isPresented: $confirmsRewind) {
            Button("Cancel", role: .cancel) {}
            Button("Rewind and Keep Files") { rewind(restoringFiles: false) }
            Button("Rewind and Restore Files", role: .destructive) { rewind(restoringFiles: true) }
        } message: {
            Text("The agent's later conversation will be removed. The original prompt and attachments return to your draft. Restoring files also replaces later file changes and staging. Stop terminal commands before restoring files.")
        }
    }

    private func loadPatch() async {
        guard let store = app.store else { return }
        let path = selectedPath
        patch = nil
        failure = nil
        showsLargeDiff = false
        do {
            let loaded = try await transcript.history.diff(
                checkpoint, store: store, cwd: transcript.cwd, path: path.isEmpty ? nil : path
            )
            guard !Task.isCancelled else { return }
            if paths.isEmpty {
                let files = try await transcript.history.files(checkpoint, cwd: transcript.cwd)
                guard !Task.isCancelled else { return }
                paths = files.map(\.path).sorted()
            }
            patch = loaded
        } catch { if !Task.isCancelled { failure = "Could not load the saved diff: \(error)" } }
    }

    private func rewind(restoringFiles: Bool) {
        Task { @MainActor in
            await transcript.history.rewind(checkpoint, restoringFiles: restoringFiles, transcript: transcript, app: app)
            if transcript.history.failure == nil { dismiss() }
        }
    }
}
