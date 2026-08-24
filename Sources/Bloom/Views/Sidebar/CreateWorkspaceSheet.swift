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

    /// Whether the sheet opens with the pull request box already up. The File menu's "New
    /// Workspace from Pull Request…" is the only caller that sets it, and it exists because the
    /// pull request route was two levels inside the "Start from" menu and so invisible to anybody
    /// who had not already been told it was there.
    ///
    /// It raises the box for a number or a URL rather than the list of open ones, because that is
    /// the half a menu item can actually put in front of somebody: the list is a network call that
    /// has not landed when the sheet opens, and it cannot offer a closed pull request, somebody
    /// else's, or the hundred and first of a busy repository. The list is still one click away in
    /// the "Start from" control the sheet opens with.
    var startsOnPullRequest = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var repoID: RepoID?
    @State private var prompt = ""
    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight

    /// The model, effort, permission mode and fast mode this workspace's first turn will run with.
    /// Resolved from the same precedence chain a new session would use, so the sheet opens showing
    /// what would have happened anyway rather than a second set of defaults.
    @State private var controls = ComposerControls()

    @State private var baseBranch = ""
    @State private var branches: [String] = []

    /// The pull request or branch this workspace opens on, or nil for the route Bloom has always
    /// had: a new branch cut from `baseBranch`. Choosing one takes over the name, the branch and,
    /// for a pull request, the base the diff is measured against. See `WorkspaceCheckout`.
    @State private var checkout: WorkspaceCheckout?
    @State private var checkoutOptions = WorkspaceCheckoutOptions()
    @State private var isLoadingCheckouts = false
    /// A pull request number or URL typed into the sheet, for the ones the list does not offer:
    /// somebody else's, a closed one, or one of the two hundred a busy repository has open.
    @State private var reference = ""
    @State private var isEnteringReference = false
    @FocusState private var isReferenceFocused: Bool
    @State private var referenceProblem: String?
    @State private var isResolvingReference = false
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

    /// Wider than the form was, and on the compact rung of the footer's ladder since the second
    /// button arrived.
    ///
    /// 620 used to be the width at which that row drew in full. "Just a terminal" took the full
    /// row from 528 points to 691, against the 572 this frame leaves inside its padding, so
    /// `ViewThatFits` drops to glyph-only pickers here and the sheet has read that way since.
    /// Measured rather than argued: the words do come back at 740, but only by collapsing the
    /// spacer between the pickers and the buttons to nothing, which reads as one crowded run of
    /// controls rather than as two groups. Glyphs with their tooltips is the better of the two, so
    /// this stays where it is. Do not raise it to "fix" the labels without looking at the row that
    /// produces.
    private static let width: CGFloat = 620
    /// What the writing area opens at. Five lines, because the question is "what do you want to
    /// work on" and a one-line box answers it with "something short".
    private static let minEditorLines: CGFloat = 5

    private var repo: Repo? { app.repos.first { $0.id == repoID } }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the task says without the files named in it.
    ///
    /// An attachment is a word in the sentence now, so the whole draft is what the agent gets and
    /// this is what everything else reads: the name, the branch, the model that writes the name,
    /// and the question of whether anything has been written at all.
    private var spokenPrompt: String {
        AttachmentDraft.withoutAttachments(prompt, paths: attachedPaths)
    }

    private var attachedPaths: [String] {
        PromptAttachmentStore.shared.attachments(for: draftID).map(\.path)
    }

    /// Whether Create may be pressed. Words are required, where in a conversation an attachment
    /// alone is enough to send: a turn with nothing but a screenshot is a sentence, but a chat
    /// workspace with nothing but a screenshot has no name, no branch and nothing for the namer
    /// to read, and `Git.slug` would call it `workspace`.
    ///
    /// The rule is `WorkspaceStartPlan.canStart`, in the core, because it decides which routes
    /// exist and a decision taken here is a decision nothing can test. This one was also wrong:
    /// it disabled every route on an empty box, including the one route that needs no sentence
    /// at all.
    private var canCreate: Bool {
        WorkspaceStartPlan.canStart(
            hasProject: repo != nil,
            prompt: spokenPrompt,
            hasCheckout: checkout != nil,
            isChatWorkspace: true,
            isBusy: app.isCreatingWorkspace
        )
    }

    /// Whether "Just a terminal" may be pressed. The same rule, asked about the other route, and
    /// the difference between the two answers on an empty box is the feature.
    private var canOpenTerminal: Bool {
        WorkspaceStartPlan.canStart(
            hasProject: repo != nil,
            prompt: spokenPrompt,
            hasCheckout: checkout != nil,
            isChatWorkspace: false,
            isBusy: app.isCreatingWorkspace
        )
    }

    /// What the second button in the footer is.
    ///
    /// A button rather than a checkbox, and beside Create rather than in the overflow menu it used
    /// to be a picker in. "Opens with: Terminal" was two clicks inside an ellipsis, had to be found
    /// before Create was pressed and read after it, and still refused to create anything until a
    /// sentence had been written for an agent that was never going to be started. A second button
    /// is one gesture, says what it does, and is the only control on the sheet that a completely
    /// empty box does not disable.
    private var terminalAction: ComposerSecondaryAction {
        ComposerSecondaryAction(
            title: "Just a terminal",
            systemImage: "apple.terminal",
            help: "Cut the worktree and open a shell in it. No chat, and nothing to describe.",
            isEnabled: canOpenTerminal,
            action: { create(opensWith: .terminal) }
        )
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
        // One task keyed on the project, not a task plus an onChange: the pair ran `load` twice on
        // every open (the first pass writes `repoID`, which fired the onChange), and a load left
        // in flight when the project changed could land another project's branches on this one's
        // sheet. `.task(id:)` cancels the stale load; `load` checks before writing.
        .task(id: repoID) { await load() }
        // The keyboard goes to the pull request box rather than to the task, when the sheet was
        // opened to open a pull request. `load` puts it in the task unconditionally, so this has
        // to come after it rather than beside it.
        .task {
            guard startsOnPullRequest else { return }
            isEnteringReference = true
            isReferenceFocused = true
        }
        // A second task, and a second trip, because listing pull requests is a network call and
        // the composer has to be typeable before it lands. The sheet opens on the branch route
        // either way; the picker fills in behind it.
        .task(id: repoID) { await loadCheckouts() }
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
                sourceControl
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
                    get: { repoID ?? RepoID("") },
                    set: { repoID = $0.rawValue.isEmpty ? nil : $0 }
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

    /// Where the work comes from: a new branch cut from a base, an open pull request, or a branch
    /// that already exists.
    ///
    /// One control rather than three, and it stays where the base branch picker was, because the
    /// three are answers to the same question and only ever one of them is in force. Visible
    /// rather than filed under the overflow menu for the reason the base branch always was: it is
    /// the setting here whose wrong value is expensive.
    private var sourceControl: some View {
        Menu {
            Picker("Start from", selection: Binding(
                get: { checkout == nil ? baseBranch : "" },
                set: { branch in
                    guard !branch.isEmpty else { return }
                    checkout = nil
                    baseBranch = branch
                }
            )) {
                ForEach(branchOptions, id: \.self) { branch in
                    Text("New branch from \(branch)").tag(branch)
                }
            }
            .pickerStyle(.inline)

            Section("Review a pull request") {
                ForEach(checkoutOptions.pullRequests) { request in
                    Button {
                        choose(.pullRequest(request))
                    } label: {
                        Text(pullRequestLabel(request))
                    }
                }
                if let sentence = pullRequestUnavailable {
                    Text(sentence)
                }
                Button("Pull request by number or URL…") {
                    referenceProblem = nil
                    isEnteringReference = true
                }
            }

            if !checkoutOptions.branches.isEmpty {
                Section("Open an existing branch") {
                    ForEach(checkoutOptions.branches) { branch in
                        Button(branch.isLocal ? branch.name : "\(branch.name) (remote)") {
                            choose(.branch(branch))
                        }
                    }
                }
            }
        } label: {
            ComposerControlLabel(
                systemImage: sourceGlyph,
                text: sourceLabel,
                showsMenuIndicator: true
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cut a new branch, or open a pull request or an existing branch")
        .accessibilityLabel("Start from")
        .accessibilityValue(sourceLabel)
    }

    private var sourceGlyph: String {
        switch checkout {
        case .pullRequest: "arrow.triangle.pull"
        case .branch, .none: "arrow.triangle.branch"
        }
    }

    private var sourceLabel: String {
        switch checkout {
        case .pullRequest(let request): "PR #\(request.number)"
        case .branch(let branch): "on \(branch.name)"
        case .none: "from \(baseBranch.isEmpty ? (repo?.defaultBranch ?? "") : baseBranch)"
        }
    }

    private func pullRequestLabel(_ request: PullRequestListing) -> String {
        let title = request.title.count > 52
            ? String(request.title.prefix(52)) + "…"
            : request.title
        return "#\(request.number) \(title)" + (request.isDraft ? " (draft)" : "")
    }

    /// Why the pull request section is empty, when it is. The three reasons need different
    /// sentences: gh missing is installed, gh signed out is signed in, and a repository with
    /// nothing open is not a problem at all.
    private var pullRequestUnavailable: String? {
        guard checkoutOptions.pullRequests.isEmpty else { return nil }
        if isLoadingCheckouts { return "Loading…" }
        switch checkoutOptions.access {
        case .notInstalled: return "Install the GitHub CLI to list pull requests"
        case .signedOut: return "Sign in with gh to list pull requests"
        case .ready: return checkoutOptions.failure ?? "No open pull requests"
        }
    }

    /// The box for a pull request the list does not offer. Shown only when it is asked for, so the
    /// ordinary case is still one control and a text box.
    private var referenceField: some View {
        HStack(spacing: Metrics.spacingSmall) {
            TextField("Pull request number or URL", text: $reference)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)
                .focused($isReferenceFocused)
                .onSubmit { resolveReference() }
                .disabled(isResolvingReference)

            if isResolvingReference {
                ProgressView().controlSize(.small)
            } else {
                Button("Open", action: resolveReference)
                    .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Cancel", role: .cancel) {
                isEnteringReference = false
                reference = ""
                referenceProblem = nil
            }
            .buttonStyle(.plain)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
        }
    }

    /// Everything real but rarely changed. Conductor puts the same class of thing behind the same
    /// glyph, and for the same reason: a control nobody touches on nineteen creations out of twenty
    /// should not be taking room from the one thing they came here to write.
    private var overflowMenu: some View {
        Menu {
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
            if isEnteringReference {
                referenceField
            }

            if let referenceProblem {
                Text(referenceProblem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
            }

            Text(heading)
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)

            ComposerPrompt(
                text: $prompt,
                caret: $caret,
                isFocused: $isFocused,
                mentionRoot: repo?.path ?? NSHomeDirectory(),
                attachmentRoot: stagingDirectory,
                attachmentKey: draftID,
                placeholder: "Describe the task, @mention files, run /commands",
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
                    // The repository, because the worktree this sheet is about to cut does not
                    // exist yet and a style the project defines is already in the repository.
                    project: repo?.path,
                    onAttach: onAttach,
                    onSend: { create(opensWith: .chat) },
                    // Beside Create, because it is the other way to finish this sheet. See
                    // `terminalAction`.
                    secondary: terminalAction
                )
            }

            statusRow
        }
        .padding(Metrics.gutter)
    }

    /// What the box is asking for. A review workspace is opened to read something, so the task is
    /// genuinely optional there and the question says so rather than demanding a sentence the
    /// button no longer requires.
    private var heading: String {
        switch checkout {
        case .pullRequest(let request): "What should happen to #\(request.number)?"
        case .branch(let branch): "What should happen on \(branch.name)?"
        case .none: "What do you want to work on?"
        }
    }

    /// Grows with what is written, from five lines, and stops where the editor starts scrolling.
    private var editorHeight: CGFloat {
        max(contentHeight, ComposerTextEditor.lineHeight * Self.minEditorLines)
    }

    private var statusRow: some View {
        HStack(spacing: Metrics.spacingWide) {
            hint

            Spacer(minLength: 0)

            // More useful here than it is in Conductor, because running several agents at once is
            // what this app is for: three workspaces on one repository is the core motion, and a
            // sheet that closed between them made it three trips to the sidebar.
            Toggle("Create more", isOn: $createMore)
                .toggleStyle(.checkbox)
                // Untinted it follows the system accent, which on a Mac set to anything but Blue
                // is another app's colour in Bloom's sheet.
                .tint(Palette.accentFill)
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
        if let checkout {
            // The checkout says everything the branch preview would have: what is being opened,
            // what the diff will be measured against, and the one sentence a merged or closed
            // pull request deserves before it is opened and found to be empty.
            HStack(spacing: Metrics.spacingSmall) {
                Chip(
                    text: "\(checkout.preferredLocalBranch) → \(checkout.baseBranch(default: repo?.defaultBranch ?? "main"))",
                    systemImage: "arrow.triangle.pull",
                    monospaced: true
                )
                .lineLimit(1)

                if let sentence = checkoutNote {
                    Text(sentence)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        } else if let lastCreated {
            Label("Started \(lastCreated)", systemImage: "checkmark.circle")
                .font(Typo.caption)
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
        } else if willBeNamedByModel {
            // Deliberately nothing. See above.
            EmptyView()
        } else if spokenPrompt.isEmpty {
            Text("The branch is named from what you write")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        } else {
            Chip(text: branchPreview, systemImage: "arrow.triangle.branch", monospaced: true)
                .lineLimit(1)
        }
    }

    /// What is worth saying about the chosen checkout beyond its branch: that it has already been
    /// merged or closed, or that a workspace on that branch is already open. Neither stops the
    /// create, because both are things somebody does on purpose.
    private var checkoutNote: String? {
        guard let checkout else { return nil }
        if let sentence = WorkspaceCheckoutPlan.warning(for: checkout) { return sentence }
        if let held = WorkspaceCheckoutPlan.workspaceHolding(
            branch: checkout.preferredLocalBranch, among: app.workspaces
        ) {
            return "Already open in \(held.name)"
        }
        return nil
    }

    private var noProjects: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Add a git repository before starting a workspace.")
        } actions: {
            Button("Choose a folder", systemImage: "folder", action: addProject)
                .buttonStyle(.borderedProminent)
                // Tinted explicitly, like every other prominent button in the app: untinted it
                // follows the system accent, which on a Mac set to Graphite is grey glass. See
                // `EmptyStateView`, which says the same over the same button.
                .tint(Palette.accentFill)
        }
    }

    // MARK: - Derived

    private var stagingDirectory: String {
        AttachmentStaging.directory(draftID: draftID)
    }

    private var branchOptions: [String] {
        guard let repo else { return branches }
        return WorkspaceStartContext.branchOptions(branches: branches, defaultBranch: repo.defaultBranch)
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
            prompt: spokenPrompt.isEmpty ? "a task" : spokenPrompt,
            isChatWorkspace: true,
            isEnabled: WorkspaceNamingPreferences().isEnabled,
            isAgentAvailable: isNamingAvailable
        )
    }

    /// The same function `WorkspaceManager.cut` derives the real branch from, minus the uniquing
    /// suffix, which depends on branches that could appear between now and Create. Only shown when
    /// no model is going to rewrite it, because a preview that is about to be replaced is a lie
    /// with a monospaced font.
    private var branchPreview: String {
        Git.branchStem(prompt: spokenPrompt, prefix: branchPrefix)
    }

    // MARK: - Keys

    /// Whatever `ComposerPrompt` did not claim for a completion menu it has open.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .returnKey, .commandReturn:
            create(opensWith: .chat)
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
            // Writing `repoID` restarts this task for the resolved project, so the listing below
            // runs once per project rather than once on open and again on the change.
            repoID = initialRepo?.id
                ?? app.selectedWorkspace.flatMap { app.repo(for: $0) }?.id
                ?? app.repos.first?.id
            return
        }
        guard let repo else { return }

        isFocused = true
        isLoading = true

        let path = repo.path
        var appDefaults = AppDefaults()
        if let store = app.store {
            appDefaults = await AppDefaults.load(from: store)
        }

        // The gathering and both branch decisions live in the core, where the suite can reach
        // them, and where the subprocess rule wants them: this sheet was the last view on the
        // allow-list in `Tools/house-rules.sh` for calling `Git` itself.
        let context = await WorkspaceStartContext.load(repoPath: path)

        // Cancelled means the project changed under this load, and these are the other
        // project's branches. The task running for the new project owns the sheet now,
        // spinner included.
        guard !Task.isCancelled else { return }
        isLoading = false

        branches = context.branches
        branchPrefix = context.settings.branchPrefix
        isNamingAvailable = context.isNamingAvailable
        controls = ComposerControls(
            defaults: ComposerDefaults.resolve(repo: context.settings, app: appDefaults),
            isFastMode: appDefaults.fastMode,
            outputStyle: appDefaults.outputStyle
        )

        baseBranch = WorkspaceStartContext.resolvedBaseBranch(
            current: baseBranch,
            branches: branches,
            defaultBranch: repo.defaultBranch
        )
    }

    /// Takes a pull request or a branch as the source, and closes anything the choice answers.
    private func choose(_ chosen: WorkspaceCheckout) {
        checkout = chosen
        isEnteringReference = false
        referenceProblem = nil
        reference = ""
        isFocused = true
    }

    /// Resolves what was typed into the box. Everything but the drawing is in the core: the
    /// parsing, the repository check and the gh call are `WorkspaceCheckoutResolver`.
    private func resolveReference() {
        guard let repo, !isResolvingReference else { return }
        let text = reference
        let path = repo.path
        isResolvingReference = true
        referenceProblem = nil
        Task {
            let resolution = await WorkspaceCheckoutResolver.resolve(text, repoPath: path)
            isResolvingReference = false
            switch resolution {
            case .checkout(let resolved): choose(resolved)
            case .failure(let sentence): referenceProblem = sentence
            }
        }
    }

    /// The pull requests and branches this project can be opened on.
    ///
    /// Runs after `load`, and reads the branch list it wrote, so the local half of the branch
    /// section costs no second `git` call. Branches already checked out in a live workspace are
    /// left out: git refuses to have one branch in two worktrees, so offering them would be
    /// offering a create that cannot succeed.
    private func loadCheckouts() async {
        guard let repo else { return }
        isLoadingCheckouts = true
        let taken = Set(app.workspaces.filter { $0.state == .active }.map(\.branch))
        let options = await WorkspaceCheckoutOptions.load(
            repoPath: repo.path,
            defaultBranch: repo.defaultBranch,
            localBranches: branches,
            takenBranches: taken
        )
        guard !Task.isCancelled else { return }
        isLoadingCheckouts = false
        checkoutOptions = options
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }

    /// A chip in the sheet has no review tab to open into, so it opens where a file opens when
    /// nothing in the app owns it.
    private func open(attachment: PromptAttachment) {
        NSWorkspace.shared.open(attachment.url(in: stagingDirectory))
    }

    /// Cuts the worktree, on whichever of the two routes was pressed.
    ///
    /// One function for both, because everything below the first line is the same work: the same
    /// attachments, the same staging, the same "Create more", the same funnel. Only the layout the
    /// workspace opens on differs, and it is one argument. See `AppModel.createWorkspace`, which
    /// is the one way a workspace is started whoever is asking.
    private func create(opensWith chosen: WorkspaceStartMode) {
        guard let repo, chosen == .chat ? canCreate : canOpenTerminal else { return }

        let text = trimmedPrompt
        let base = baseBranch.isEmpty ? repo.defaultBranch : baseBranch
        let source = checkout
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
                staged: staged,
                checkout: source
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
        // The checkout goes with the task. Everything else on the sheet is a setting for this
        // batch of work; the pull request that was just opened is not, and a second workspace on
        // the same pull request is never what anybody meant by "Create more".
        checkout = nil
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
