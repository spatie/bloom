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
/// **Why there is a second button, and only sometimes.** A branch that is gone from this Mac and
/// from the remote leaves Restore permanently greyed out, and that used to be the end of the
/// workspace: the conversation was readable and nothing could be done with it. It can be carried
/// on, though. Both backends Bloom runs resolve a conversation by its own id rather than by the
/// directory it was had in, so a new worktree cut somewhere else can pick the same conversation
/// up with the agent's memory of it intact. Carry On does exactly that and nothing more: this
/// archive is not unarchived, not written to and not moved, a new workspace appears beside it,
/// and the turn that opens it says which archive it came from. The rule for when it is offered is
/// `CarryOnGate` in the core. See `ArchivedCarryOn` for what does and does not come across.
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

    /// Whether this conversation can be carried on in a new worktree, worked out from the branch
    /// above and from the chat the picker is on. Nil until both are known.
    @State private var carryOn: CarryOnDecision?

    /// The same three settings the live conversation is drawn with, scoped to the same subtree,
    /// so a transcript does not change size or line height when it is read from here instead of
    /// from there.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.standard

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
                .environment(\.chatFont, ChatFont(rawValue: chatFontID))
                .environment(\.chatLineHeight, lineHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
        // Sessions and their transcripts are built here rather than in a body, for the reason
        // `WorkspaceModel.transcript(for:)` spells out. Nothing else `onAppear` normally does is
        // run: there is no worktree to diff and no unread flag worth clearing.
        .task(id: workspace.id) { await model.reloadSessions() }
        .task(id: workspace.id) { await locateBranch() }
        // Keyed on the chat as well as the branch, because the offer depends on the chat having a
        // thread to resume and the picker above can move to one that has not. `canRebuild` is in
        // the key rather than the whole source so the answer is worked out once, when the fetch
        // lands, rather than again for a source that changed from one rebuildable value to
        // another.
        .task(id: carryOnKey) { await decideCarryOn() }
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

            // Two words, because this row already holds "Copy Branch Name" and a banner is not a
            // place to spend the width twice. What it does is in `.help` and, at more length, in
            // the sentence under the row.
            if let plan = carryOn?.plan {
                Button("Carry On") {
                    Task { await app.carryOn(workspace, plan: plan) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.controlAccent)
                .disabled(isCarryingOn)
                .help(carryOnHelp(plan))
            } else {
                // The title does not change while it is running. The spinner beside it already
                // says the work is under way, and swapping the words as well moved the button's
                // width under the pointer to say a second time what was already being said.
                Button("Restore Workspace") {
                    Task { await app.restore(workspace) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.controlAccent)
                .disabled(isRestoring || isLocating || source?.canRebuild != true)
                .help(restoreHelp)
            }

            // In the row rather than in an overlay offset out of it. Pushed `Metrics.gutter` past
            // the controls' trailing edge it landed in a banner whose own trailing padding is
            // exactly that, so it sat flush against the pane edge or was clipped by it.
            if isRestoring || isCarryingOn || isLocating {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var isRestoring: Bool { app.restoring.contains(workspace.id) }

    private var isCarryingOn: Bool { app.carryingOn.contains(workspace.id) }

    private func carryOnHelp(_ plan: CarryOnPlan) -> String {
        "Cuts a new worktree from \(plan.baseBranch), on \(plan.branch), and picks this "
            + "conversation up there with the agent's memory of it intact. This archive is left "
            + "as it is."
    }

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
        var text = "The worktree was removed when this was archived. "
            + source.explanation(branch: workspace.branch)
        // Appended rather than folded into the explanation above, because the two answer
        // different questions: that one is about the branch, this one is about what is still on
        // offer, and the offer depends on a chat having a thread to resume.
        if let plan = carryOn?.plan, let repo = model.repo {
            text += " " + ArchivedCarryOn.standing(
                project: repo.name, baseBranch: plan.baseBranch
            )
        }
        return text
    }

    private var symbol: String {
        guard let source else { return "clock" }
        if source.canRebuild { return "arrow.uturn.backward.circle" }
        // A carried conversation is a way forward rather than a dead end, so the row it is on
        // does not wear the icon for one.
        return carryOn?.isOffered == true ? "arrow.forward.circle" : "text.book.closed"
    }

    private var tone: Color {
        guard let source else { return Palette.textTertiary }
        if source.canRebuild { return Palette.accent }
        return carryOn?.isOffered == true ? Palette.accent : Palette.warning
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

    /// What the `.task` above is keyed on. See it for why these three and not the whole state.
    private var carryOnKey: CarryOnKey {
        CarryOnKey(
            workspace: workspace.id,
            session: model.activeSessionID,
            canRebuild: source?.canRebuild
        )
    }

    private struct CarryOnKey: Equatable {
        var workspace: WorkspaceID
        var session: SessionID?
        var canRebuild: Bool?
    }

    private func decideCarryOn() async {
        // Nothing to decide until the branch has been looked for. Left nil rather than refused,
        // so the row keeps showing Restore, disabled, exactly as it does while the fetch runs.
        guard source != nil else {
            carryOn = nil
            return
        }
        carryOn = await app.carryOnDecision(
            for: workspace, session: model.activeSession, source: source
        )
    }
}
