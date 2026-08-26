import SwiftUI
import BloomCore

/// An archived workspace, open for reading.
///
/// **Why this exists at all.** Archiving removed the worktree and took the workspace out of
/// `AppModel.workspaces`, and nothing anywhere could put it back once Edit > Undo had expired.
/// Everything the workspace ever said was still in the database, keyed by its id, and the branch
/// was usually still on disk. None of it was reachable: no menu item, no double click, no context
/// menu item, and search excluded archived workspaces outright. A day-old archive took its whole
/// history out of the app.
///
/// **Why reading and resuming are two screens' worth of one screen, rather than one button.** They
/// are not the same act and they do not have the same failure. Reading the transcript costs
/// nothing and can never fail: the rows are in SQLite and the worktree was never involved.
/// Rebuilding the worktree needs a branch, and a branch can have been deleted here, on the remote,
/// or on both, which is exactly what happens to a workspace whose pull request was merged. A
/// single Restore button would therefore have worked for some rows and failed with a git error on
/// others, and the row it fails on is the one somebody most wants to look at. So this screen is
/// always available and always complete, and Restore is an offer on top of it that says in advance
/// whether it can be taken.
///
/// **What is deliberately not here.** No composer, because there is nowhere to send a prompt. No
/// inspector and no terminal, because there is no directory for either to point at; `RootView`
/// hides the inspector for this selection for the same reason it hides it on Home. No unread
/// clearing and no `onAppear` work either: this is a record, and reading a record should not write
/// to anything.
struct ArchivedWorkspaceView: View {
    @Bindable var model: WorkspaceModel

    @Environment(AppModel.self) private var app

    /// Where the branch still is, or nil while that is being worked out. Asking involves a fetch,
    /// so it is asked once per workspace rather than per redraw.
    @State private var source: RestoreSource?
    @State private var isLocating = true

    /// The same two settings the live conversation is drawn with, scoped to the same subtree, so a
    /// transcript does not change size when it is read from here instead of from there.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard
    @AppStorage(ChatFont.defaultsKey) private var chatFont = ChatFont.standard

    private var workspace: Workspace { model.workspace }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Hairline()
            if model.sessions.count > 1 {
                sessions
                Hairline()
            }
            TranscriptView(transcript: model.activeTranscript)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.fontScale, textSize.scale)
                .environment(\.chatFont, chatFont)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
        // Sessions and their transcripts are built here rather than in a body, for the reason
        // `WorkspaceModel.transcript(for:)` spells out. Nothing else `onAppear` normally does is
        // run: there is no worktree to diff and no unread flag worth clearing.
        .task(id: workspace.id) { await model.reloadSessions() }
        .task(id: workspace.id) { await locateBranch() }
    }

    // MARK: - The banner

    private var banner: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
                Image(systemName: "archivebox")
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(workspace.name)
                        .font(Typo.title)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)

                    Text(subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: Metrics.spacingWide)

                controls
            }

            standing
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let repo = model.repo { parts.append(repo.name) }
        parts.append(workspace.branch)
        if let archivedAt = workspace.archivedAt {
            parts.append(
                "archived " + archivedAt.formatted(
                    .relative(presentation: .named, unitsStyle: .wide)
                )
            )
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var controls: some View {
        HStack(spacing: Metrics.spacing) {
            Button("Copy Branch Name") { Clipboard.copy(workspace.branch) }

            // The title does not change while it is running. The spinner beside it already says
            // the work is under way, and swapping the words as well moved the button's width
            // under the pointer to say a second time what was already being said.
            Button("Restore Workspace") {
                Task { await app.restore(workspace) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentFill)
            .disabled(isRestoring || isLocating || source?.canRebuild != true)
            .help(restoreHelp)

            // In the row rather than in an overlay offset out of it. Pushed `Metrics.gutter` past
            // the controls' trailing edge it landed in a banner whose own trailing padding is
            // exactly that, so it sat flush against the pane edge or was clipped by it.
            if isRestoring || isLocating {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var isRestoring: Bool { app.restoring.contains(workspace.id) }

    private var restoreHelp: String {
        guard let source else { return "Looking for the branch" }
        return source.explanation(branch: workspace.branch)
    }

    /// The one sentence that says whether this workspace can be worked in again, and why not when
    /// it cannot. It is on screen before Restore is pressed rather than in the alert afterwards,
    /// which is the difference between a button that explains itself and one that fails.
    @ViewBuilder
    private var standing: some View {
        HStack(alignment: .top, spacing: Metrics.spacingWide) {
            Image(systemName: symbol)
                .font(Typo.caption)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            Text(sentence)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    private var sentence: String {
        guard let source else {
            return "The worktree was removed when this was archived. Looking for the branch it was on."
        }
        return "The worktree was removed when this was archived. "
            + source.explanation(branch: workspace.branch)
    }

    private var symbol: String {
        guard let source else { return "clock" }
        return source.canRebuild ? "arrow.uturn.backward.circle" : "text.book.closed"
    }

    private var tone: Color {
        guard let source else { return Palette.textTertiary }
        return source.canRebuild ? Palette.accent : Palette.warning
    }

    // MARK: - Sessions

    /// Only when there is more than one, because a picker offering one choice is furniture. The
    /// live workspace draws a tab strip here; this is a reader, and a reader gets a menu.
    private var sessions: some View {
        HStack(spacing: Metrics.spacingWide) {
            Picker("Session", selection: sessionBinding) {
                ForEach(model.sessions) { session in
                    Text(session.title).tag(session.id as SessionID?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingSmall)
        .background(Palette.surface)
    }

    /// Written through a binding of its own rather than `$model.activeSessionID`, so it is clear
    /// that setting it is what prepares the transcript. See `WorkspaceModel.activeSessionID`.
    private var sessionBinding: Binding<SessionID?> {
        Binding(
            get: { model.activeSessionID },
            set: { model.activeSessionID = $0 }
        )
    }

    // MARK: - Work

    private func locateBranch() async {
        isLocating = true
        source = await app.restoreSource(for: workspace)
        isLocating = false
    }
}
