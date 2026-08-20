import SwiftUI
import AppKit
import BloomCore

/// The sheet that starts a workspace.
///
/// It is the composer, not a form that happens to contain a text box.
///
/// Creating a workspace is writing the first message of a conversation. The thing you actually do
/// is describe a task, and everything else on the sheet is a qualifier on that sentence: which
/// project, which base, which model, how hard to think, what it may do without asking. So the
/// surface is the same surface as every other message in the app, with the same controls in the
/// same places: `ComposerPrompt` with `ComposerFooterView` under it, exactly as at the bottom of
/// the centre column. The form this replaced put the task in the fourth row of five, gave the
/// model and the effort no representation at all, and could not take an attachment.
///
/// What it gains by being the composer, rather than by anything written here: a screenshot can be
/// dropped, pasted or picked into the first message, `@` offers the repository's files, `/` offers
/// its commands, and the model, effort, permission mode and fast mode are chosen with the controls
/// you already know, then carried onto the session that gets made so the first turn runs with them.
struct CreateWorkspaceSheet: View {
    /// Which project to start in. The sidebar passes the repo whose `+` was clicked, otherwise
    /// the repo of whatever is selected. Either way the project arrives decided, so the control
    /// for it never asks a question: it reports, and opens only if you want to change your mind.
    var initialRepo: Repo?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var repoID: String?
    @State private var prompt = ""
    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight

    /// The model, effort, permission mode and fast mode this workspace's first turn will run with.
    /// Resolved from the same precedence chain a new session would use, so the sheet opens showing
    /// what would have happened anyway rather than a second set of defaults.
    @State private var controls = ComposerControls()

    @State private var mode: WorkspaceStartMode = .chat
    @State private var baseBranch = ""
    @State private var branches: [String] = []
    @State private var branchPrefix: String?
    @State private var isLoading = false

    /// Whether a model will be asked to name this workspace, which decides what the sheet may
    /// honestly promise about the branch. Both halves are settled off the main actor in `load`,
    /// because one of them looks for a binary on the PATH.
    @State private var isNamingAvailable = false

    /// Which bucket of `PromptAttachmentStore` this draft is filling, and the name of the staging
    /// directory its files are copied into. A fresh one per draft, so the second workspace fired
    /// off with "Create more" cannot pick up the first one's screenshots.
    @State private var draftID = PromptAttachments.newShortID()

    /// What was created a moment ago, shown in place of the branch hint so that firing off three
    /// workspaces in a row is not three identical sheets with no sign anything happened.
    @State private var lastCreated: String?

    /// Kept between openings on purpose. Somebody who works in threes will work in threes again
    /// tomorrow, and a toggle that reset every time would have to be found every time.
    @AppStorage("create.more") private var createMore = false

    /// Wider than the form was. The composer's footer carries four pickers, a paperclip and the
    /// create button, and this is the width at which that row draws in full rather than dropping
    /// its words to `ViewThatFits`.
    private static let width: CGFloat = 620
    /// What the writing area opens at. Five lines, because the question is "what do you want to
    /// work on" and a one-line box answers it with "something short".
    private static let minEditorLines: CGFloat = 5

    private var repo: Repo? { app.repos.first { $0.id == repoID } }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text is required, where in a conversation an attachment alone is enough to send. The
    /// difference is deliberate: a turn with nothing but a screenshot is a sentence, but a
    /// workspace with nothing but a screenshot has no name, no branch and nothing for the namer to
    /// read, and `Git.slug` would call it `workspace`.
    private var canCreate: Bool {
        repo != nil && !trimmedPrompt.isEmpty && !app.isCreatingWorkspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            if app.repos.isEmpty {
                noProjects
                    .padding(Metrics.gutter)
            } else {
                composer
            }
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .task { await load() }
        .onChange(of: repoID) { _, _ in
            Task { await load() }
        }
        // The confirmation stands until there is something new to say, which is the moment the
        // next task starts being written. No timer, so it cannot vanish mid sentence.
        .onChange(of: prompt) { _, _ in lastCreated = nil }
        // The draft's chips and the files behind them belong to a sheet that is going away.
        .onDisappear(perform: discardDraft)
    }

    // MARK: - The bar above the box

    /// Where the two choices that are not about the next turn live: which project, and which
    /// branch it is cut from. They sit above the box rather than in the footer because they are
    /// about the workspace, and the footer is about the turn.
    private var header: some View {
        HStack(spacing: Metrics.spacingSmall) {
            projectControl

            if repo != nil {
                baseBranchControl
            }

            Spacer(minLength: 0)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading branches")
            }

            overflowMenu
        }
        .padding(.horizontal, Metrics.spacing)
        .padding(.vertical, Metrics.spacingSmall)
    }

    /// The project, with its mark on it. A `Menu` rather than a `Picker`, which is what finally
    /// gets the tile into this control: a picker on macOS is an `NSPopUpButton` whose items draw a
    /// title and an `NSImage`, so a `Label` with a SwiftUI icon had the icon silently dropped.
    @ViewBuilder
    private var projectControl: some View {
        let label = ComposerControlLabel(
            text: repo?.name ?? "Choose a project",
            tint: Palette.textPrimary,
            showsMenuIndicator: app.repos.count > 1
        ) {
            RepoIcon(repo: repo, size: Metrics.repoIconSmall)
        }

        // One project is not a choice. It still says which project, because a sheet that cut a
        // worktree without naming the repository would be asking for trust it has not earned.
        if app.repos.count > 1 {
            Menu {
                // An inline `Picker` inside the menu, not a `Picker` in place of it. The tile on
                // the control above still needs a `Menu`, for the reason written just above; the
                // tick beside the project you are already in is the platform's to draw, and a
                // `Button` whose label carries a checkmark symbol never got one. See
                // `ComposerOptionMenu`.
                //
                // Each row carries the project's own mark as well, which an item in an `NSMenu`
                // has room for: a title, an image and a state marker are three separate slots and
                // they coexist. What the image slot will not take is a SwiftUI view, so the mark
                // arrives as a bitmap of the same `RepoIcon` the chip and the sidebar draw. See
                // `RepoIconImage`.
                //
                // No heading over them. The rows are project names wearing their own badges and
                // the control that opened the menu is showing one of them, so "Project" written
                // above would be a word to read past. `labelsHidden` takes the heading off the
                // picker without taking its name away from VoiceOver.
                Picker("Project", selection: Binding(
                    get: { repoID ?? "" },
                    set: { repoID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(app.repos) { candidate in
                        Label {
                            Text(candidate.name)
                        } icon: {
                            if let mark = RepoIconImage.of(candidate) {
                                // `.original`, because the tile is the project's colour and a
                                // template image in a menu is painted flat in the label colour.
                                Image(nsImage: mark).renderingMode(.original)
                            }
                        }
                        .tag(candidate.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the project")
            .accessibilityLabel("Project")
            .accessibilityValue(repo?.name ?? "")
        } else {
            label
        }
    }

    /// The branch the worktree is cut from. Visible rather than filed under the overflow menu,
    /// because it is the one setting here whose wrong value is expensive: work started from a
    /// stale base is discovered at merge time.
    private var baseBranchControl: some View {
        Menu {
            Picker("Start from", selection: $baseBranch) {
                ForEach(branchOptions, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ComposerControlLabel(
                systemImage: "arrow.triangle.branch",
                text: "from \(baseBranch.isEmpty ? (repo?.defaultBranch ?? "") : baseBranch)",
                showsMenuIndicator: true
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(branchOptions.isEmpty)
        .help("Cut the worktree from this branch")
        .accessibilityLabel("Start from")
        .accessibilityValue(baseBranch)
    }

    /// Everything real but rarely changed. Conductor puts the same class of thing behind the same
    /// glyph, and for the same reason: a control nobody touches on nineteen creations out of twenty
    /// should not be taking room from the one thing they came here to write.
    private var overflowMenu: some View {
        Menu {
            // The picker's own title is the section heading, so "Opens with" is still written
            // above the two rows and the one in force is ticked.
            Picker("Opens with", selection: $mode) {
                ForEach(WorkspaceStartMode.allCases) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.inline)

            Section {
                Text("Worktree in \(WorkspaceManager.workspacesRoot.path)")
            }
        } label: {
            ComposerControlLabel(systemImage: "ellipsis", text: nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More options")
    }

    // MARK: - The box

    private var composer: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("What do you want to work on?")
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)

            ComposerPrompt(
                text: $prompt,
                caret: $caret,
                isFocused: $isFocused,
                mentionRoot: repo?.path ?? NSHomeDirectory(),
                attachmentRoot: stagingDirectory,
                attachmentKey: draftID,
                placeholder: mode == .chat
                    ? "Describe the task, @mention files, run /commands"
                    : "Describe what you are about to do, so the branch has a name",
                editorHeight: editorHeight,
                onContentHeightChange: { contentHeight = $0 },
                onKey: handle(key:),
                onOpenAttachment: open(attachment:)
            ) { onAttach in
                ComposerFooterView(
                    controls: controls,
                    onChange: { controls = $0 },
                    canSend: canCreate,
                    intent: .create,
                    onAttach: onAttach,
                    onSend: create,
                    // A terminal workspace opens a shell and never starts an agent, so the model,
                    // the effort, the permission mode, fast mode and the paperclip have nothing to
                    // act on. They were drawn anyway, which made the sheet offer five settings that
                    // the workspace it was about to create would ignore.
                    showsAgentControls: mode == .chat
                )
            }

            statusRow
        }
        .padding(Metrics.gutter)
    }

    /// Grows with what is written, from five lines, and stops where the editor starts scrolling.
    private var editorHeight: CGFloat {
        max(contentHeight, ComposerTextEditor.lineHeight * Self.minEditorLines)
    }

    private var statusRow: some View {
        HStack(spacing: Metrics.spacingWide) {
            // The one thing in the overflow menu whose effect is not visible anywhere else on the
            // sheet, said out loud while it is on. The default needs no chip: chat is what the box
            // above already looks like.
            if mode == .terminal {
                Chip(text: "Opens a terminal", systemImage: "apple.terminal")
            }

            hint

            Spacer(minLength: 0)

            // More useful here than it is in Conductor, because running several agents at once is
            // what this app is for: three workspaces on one repository is the core motion, and a
            // sheet that closed between them made it three trips to the sidebar.
            Toggle("Create more", isOn: $createMore)
                .toggleStyle(.checkbox)
                .font(Typo.caption)
                .help("Keep this sheet open after creating, ready for the next one")

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// What the sheet is allowed to promise about the name and the branch.
    ///
    /// It used to say "named from your prompt", which stopped being true when workspaces started
    /// naming themselves: a chat workspace opens under a plant codename and a model rewrites both
    /// the name and the branch a few seconds later. The mechanical slug is still the answer when
    /// nothing is going to be asked, and it is the only one worth printing: when a model is going
    /// to answer, this says nothing at all. Naming is something to watch happen in the sidebar,
    /// where it happens, rather than a sentence to read about beforehand, and the slug cannot be
    /// shown in its place because a preview that is about to be replaced is a lie with a
    /// monospaced font.
    @ViewBuilder
    private var hint: some View {
        if let lastCreated {
            Label("Started \(lastCreated)", systemImage: "checkmark.circle")
                .font(Typo.caption)
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
        } else if willBeNamedByModel {
            // Deliberately nothing. See above.
            EmptyView()
        } else if trimmedPrompt.isEmpty {
            Text("The branch is named from what you write")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        } else {
            Chip(text: branchPreview, systemImage: "arrow.triangle.branch", monospaced: true)
                .lineLimit(1)
        }
    }

    private var noProjects: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Add a git repository before starting a workspace.")
        } actions: {
            Button("Choose a folder", systemImage: "folder", action: addProject)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Derived

    private var stagingDirectory: String {
        AttachmentStaging.directory(draftID: draftID)
    }

    private var branchOptions: [String] {
        guard let repo else { return branches }
        if branches.isEmpty { return [repo.defaultBranch] }
        return branches
    }

    /// The same question `AppModel` will ask a moment from now, so the hint and what happens cannot
    /// disagree. See `WorkspaceNaming.shouldName` for what each condition rules out.
    ///
    /// An empty box is asked about as though something had been written. `shouldName` answers no
    /// to an empty prompt, which is right for it and wrong here: Create is disabled without a task,
    /// so an empty box means "not written yet" rather than "there will be nothing to name from",
    /// and a hint that changed its story the moment you started typing would be the worse of the
    /// two answers.
    private var willBeNamedByModel: Bool {
        WorkspaceNaming.shouldName(
            userSuppliedName: nil,
            prompt: trimmedPrompt.isEmpty ? "a task" : trimmedPrompt,
            isChatWorkspace: mode == .chat,
            isEnabled: WorkspaceNamingPreferences().isEnabled,
            isAgentAvailable: isNamingAvailable
        )
    }

    /// Mirrors `WorkspaceManager.createWorkspace`, minus the uniquing suffix which depends on
    /// branches that could appear between now and Create. Only shown when no model is going to
    /// rewrite it, because a preview that is about to be replaced is a lie with a monospaced font.
    private var branchPreview: String {
        let slug = Git.slug(from: trimmedPrompt)
        guard let prefix = branchPrefix, !prefix.isEmpty else { return slug }
        return "\(prefix)/\(slug)"
    }

    // MARK: - Keys

    /// Whatever `ComposerPrompt` did not claim for a completion menu it has open.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .returnKey, .commandReturn:
            create()
            return true
        case .escape:
            dismiss()
            return true
        case .up, .down, .tab:
            return false
        }
    }

    // MARK: - Actions

    private func load() async {
        if repoID == nil {
            repoID = initialRepo?.id
                ?? app.selectedWorkspace.flatMap { app.repo(for: $0) }?.id
                ?? app.repos.first?.id
        }
        guard let repo else { return }

        isFocused = true
        isLoading = true
        defer { isLoading = false }

        let path = repo.path
        var appDefaults = AppDefaults()
        if let store = app.store {
            appDefaults = await AppDefaults.load(from: store)
        }

        // One hop off the main actor for all three: a branch listing, a settings file chain and a
        // PATH lookup, none of which belongs on the actor drawing the sheet.
        let loaded = await Task.detached(priority: .userInitiated) {
            let names = (try? await Git.branches(of: path)) ?? []
            let settings = SettingsLoader.load(repo: path)
            return (names, settings, WorkspaceNamer.isAvailable)
        }.value

        branches = loaded.0
        branchPrefix = loaded.1.branchPrefix
        isNamingAvailable = loaded.2
        controls = ComposerControls(
            defaults: ComposerDefaults.resolve(repo: loaded.1, app: appDefaults),
            isFastMode: appDefaults.fastMode
        )

        if !branches.contains(baseBranch) {
            baseBranch = branches.contains(repo.defaultBranch)
                ? repo.defaultBranch
                : (branches.first ?? repo.defaultBranch)
        }
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }

    /// A chip in the sheet has no review tab to open into, so it opens where a file opens when
    /// nothing in the app owns it.
    private func open(attachment: PromptAttachment) {
        NSWorkspace.shared.open(attachment.url(in: stagingDirectory))
    }

    private func create() {
        guard let repo, canCreate else { return }

        let text = trimmedPrompt
        let base = baseBranch.isEmpty ? repo.defaultBranch : baseBranch
        let chosen = mode
        let chosenControls = controls

        // A file can be moved or deleted between being attached and Create being pressed, and
        // naming a path that is not there only teaches the agent that Bloom lies about paths.
        let directory = stagingDirectory
        let handedOver = draftID
        let ready = PromptAttachmentStore.shared.attachments(for: handedOver).filter {
            FileManager.default.fileExists(atPath: $0.url(in: directory).path)
        }
        let staged = StagedAttachments(directory: directory, attachments: ready)
        // The chips go now; the files stay until the worktree has taken them.
        PromptAttachmentStore.shared.clear(sessionID: handedOver)
        // Rotated here rather than in `resetDraft`, and on both paths. Dismissing the sheet
        // discards whatever draft it is holding, and without this that would be the draft whose
        // files are at this moment on their way into a worktree.
        draftID = PromptAttachments.newShortID()

        if createMore {
            resetDraft()
        } else {
            dismiss()
        }

        Task {
            let workspace = await app.createWorkspace(
                in: repo,
                prompt: text,
                baseBranch: base,
                opensWith: chosen,
                controls: chosenControls,
                staged: staged
            )
            // Whatever survived is in the worktree now, and whatever did not was never going to be.
            AttachmentStaging.discard(draftID: handedOver)
            lastCreated = workspace?.name
        }
    }

    /// What "Create more" clears, and what it keeps.
    ///
    /// The task goes, because it has been sent and a second workspace on the same sentence is
    /// never what anybody wanted. Everything else stays: the project, the base branch, what it
    /// opens with and every choice in the footer are answers about this batch of work, and asking
    /// for them again three times in a row is what would make the toggle not worth having.
    private func resetDraft() {
        prompt = ""
        caret = 0
        contentHeight = ComposerTextEditor.lineHeight
        isFocused = true
    }

    private func discardDraft() {
        let id = draftID
        PromptAttachmentStore.shared.clear(sessionID: id)
        Task.detached(priority: .utility) {
            AttachmentStaging.discard(draftID: id)
        }
    }
}
