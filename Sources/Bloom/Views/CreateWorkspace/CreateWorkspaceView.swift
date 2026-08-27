import SwiftUI
import AppKit
import BloomCore

/// What is inside the window that starts a workspace. The window itself, and why it is one, is
/// `CreateWorkspaceWindow`.
///
/// It is the composer, not a form that happens to contain a text box.
///
/// Creating a workspace is writing the first message of a conversation. The thing you actually do
/// is describe a task, and everything else here is a qualifier on that sentence: which project,
/// which base, which model, how hard to think, what it may do without asking. So the surface is
/// the same surface as every other message in the app, with the same controls in the same places:
/// `ComposerPrompt` with `ComposerFooterView` under it, exactly as at the bottom of the centre
/// column. The form this replaced put the task in the fourth row of five, gave the model and the
/// effort no representation at all, and could not take an attachment.
///
/// What it gains by being the composer, rather than by anything written here: a screenshot can be
/// dropped, pasted or picked into the first message, `@` offers the repository's files, `/` offers
/// its commands, and the model, effort, permission mode and fast mode are chosen with the controls
/// you already know, then carried onto the session that gets made so the first turn runs with them.
///
/// Still a plain `View` with a `dismiss` in it, which is the whole reason moving it out of a sheet
/// cost this file so little: `DismissAction` closes the window it is in exactly as it dismissed
/// the sheet it was in, so every route that ended the sheet ends the window.
struct CreateWorkspaceView: View {
    /// Which project to start in. The sidebar passes the repo whose `+` was clicked, otherwise
    /// the repo of whatever is selected. Either way the project arrives decided, so the control
    /// for it never asks a question: it reports, and opens only if you want to change your mind.
    var initialRepo: Repo?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var repoID: RepoID?
    @State private var prompt = ""
    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight

    /// The model, effort, permission mode and fast mode this workspace's first turn will run with.
    /// Resolved from the same precedence chain a new session would use, so the window opens showing
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
    /// A pull request number or URL typed into the window, for the ones the list does not offer:
    /// somebody else's, a closed one, or one of the two hundred a busy repository has open.
    @State private var reference = ""
    @State private var isEnteringReference = false
    @FocusState private var isReferenceFocused: Bool
    @State private var referenceProblem: String?
    /// Why the row that was just picked cannot be opened, or nil. See `BranchHolder.refusal`.
    ///
    /// Its own state rather than `referenceProblem` because the two are answers to different
    /// questions and are cleared at different moments: one is about a number typed into a box,
    /// this is about a branch something else already has. Drawn in the same place, which is the
    /// full width line under the composer, because a path is unreadable anywhere narrower.
    @State private var heldProblem: String?
    @State private var isResolvingReference = false
    @State private var branchPrefix: String?
    /// Whether this project runs anything after the worktree is cut, so the footer can say so.
    /// Read with the branches, from the same settings the rest of this window is built from.
    @State private var hasSetupScript = false
    @State private var isLoading = false

    /// Whether a model will be asked to name this workspace, which decides what the window may
    /// honestly promise about the branch. Both halves are settled off the main actor in `load`,
    /// because one of them looks for a binary on the PATH.
    @State private var isNamingAvailable = false

    /// Which bucket of `PromptAttachmentStore` this draft is filling, and the name of the staging
    /// directory its files are copied into. A fresh one per draft, so a window opened again cannot
    /// pick up the previous draft's screenshots.
    @State private var draftID = PromptAttachments.newShortID()

    /// Which of the three things this window is being used for, and the last answer, kept.
    ///
    /// Read through `WorkspaceStartMode.remembered` rather than by giving `@AppStorage` a default,
    /// so the fresh-install answer and the reason for it live in the core beside the tests instead
    /// of in a property wrapper's second argument. Global rather than per project, and why, is on
    /// `WorkspaceStartMode.rememberedKey`.
    @AppStorage(WorkspaceStartMode.rememberedKey) private var rememberedMode: String?

    /// What the name field holds in the two modes that run no agent. Separate from `prompt`
    /// rather than sharing it, which is what lets a draft survive a person changing their mind
    /// twice: the box keeps its sentence while the field is on screen and the field keeps its name
    /// while the box is. See `WorkspaceStartPlan.carriedName`.
    @State private var typedName = ""
    @FocusState private var isNameFocused: Bool

    /// Wider than the form was. The composer's footer carries four pickers, a paperclip and the
    /// create button, and this is the width at which that row draws in full rather than dropping
    /// its words to `ViewThatFits`.
    ///
    /// It stopped being true for four days and is true again. Measured: the full row is 528 points
    /// against the 572 this frame leaves inside its padding, and "Just a terminal" beside Create
    /// took it to 691, which put every picker on the glyph-only rung at once. Choosing the mode
    /// above the box rather than the route beside Create is what hands those labels back, and it
    /// is not a happy accident: a control that says which of three things you are doing does not
    /// belong in the row that qualifies the turn. Do not put a second button back here.
    ///
    /// **And then a fifth control arrived and took the words again.** The row carries fast mode
    /// now as well as the model, the effort, the output style and the permission mode, and 620
    /// put every one of them back on the glyph-only rung: a window asking what you want to work on
    /// while showing five unlabelled symbols is a window that tells you nothing about what it is
    /// about to do. The number below is what the same row needs with its words on.
    private static let width: CGFloat = 700
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

    /// Which mode the window is in, and the one place the stored string is turned back into it.
    private var mode: WorkspaceStartMode {
        WorkspaceStartMode.remembered(raw: rememberedMode)
    }

    /// What the create button is about to be given as the task.
    ///
    /// In chat mode it is the sentence, attachments and all. In the modes with no agent it is the
    /// name field, because that is what `AppModel.startWorkspace` derives such a workspace's name
    /// and branch from, and an empty one is what claims a sea. One property rather than a branch
    /// at each call site, so the button, its enabled state and the hint under the box cannot end
    /// up asking about different text.
    private var task: String {
        mode.runsAnAgent ? spokenPrompt : typedName
    }

    /// Whether Create may be pressed. Words are required for a chat, and for nothing else.
    ///
    /// The rule is `WorkspaceStartPlan.canStart`, in the core, because it decides which routes
    /// exist and a decision taken here is a decision nothing can test.
    ///
    /// One button now, asked one question. It used to be this and a second copy asking the same
    /// question about the other route, which is what let both be live at once: the sheet offered
    /// two ways to finish and only one of them used what had been typed. The mode answers it
    /// first, so there is nothing left to disagree about.
    private var canCreate: Bool {
        WorkspaceStartPlan.canStart(
            hasProject: repo != nil,
            prompt: task,
            hasCheckout: checkout != nil,
            isChatWorkspace: mode.runsAnAgent,
            isBusy: app.isCreatingWorkspace
        )
    }

    /// Whether the name field is worth showing.
    ///
    /// A checkout arrives with a name, a branch and a base already chosen by whoever opened the
    /// pull request, and `WorkspaceStartRequest` takes that name over anything derived here. So a
    /// name field beside a chosen pull request would be a box that changes nothing, which is worse
    /// than no box: it is a box that lies. The checkout's own chip under the box says what the
    /// workspace will be called instead.
    /// One line saying what pressing Create actually does.
    ///
    /// The sheet asked for a task and a branch and never said what it would make, so somebody
    /// meeting Bloom read "New workspace" and had to infer that a workspace is a worktree on disk.
    /// It names the two things that happen and nothing else: the checkout, and the setup script
    /// where the project has one. No worktree jargon, because a person who knows the word does not
    /// need the sentence and a person who does not is not helped by it.
    private var consequence: some View {
        Text(hasSetupScript
            ? "Creates a separate copy of the project on this Mac, on its own branch, and runs this project's setup script in it."
            : "Creates a separate copy of the project on this Mac, on its own branch.")
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.gutter)
    }

    private var offersName: Bool { checkout == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            if app.repos.isEmpty {
                noProjects
                    .padding(Metrics.gutter)
            } else {
                composer
                consequence
            }
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        // One task keyed on the project, not a task plus an onChange: the pair ran `load` twice on
        // every open (the first pass writes `repoID`, which fired the onChange), and a load left
        // in flight when the project changed could land another project's branches on this one's
        // window. `.task(id:)` cancels the stale load; `load` checks before writing.
        .task(id: repoID) { await load() }
        // The keyboard goes to the pull request box rather than to the task, when the window was
        // opened to open a pull request. `load` puts it in the task unconditionally, so this has
        // to come after it rather than beside it.
        //
        // One flag, read at the only two moments there are: here, for a window that has just been
        // built, and below, for one that was already open when the menu item was pressed. It is
        // consumed by whichever gets there, so the box is raised once. See
        // `CreateWorkspaceOpening`.
        .task {
            guard CreateWorkspaceOpening.shared.consumePullRequestAsk() else { return }
            raisePullRequestBox()
        }
        // The already-open case. No `initial`, deliberately: a window built with the flag already
        // set sees no change and is served by the task above, which runs after `load` and so keeps
        // the keyboard the task would otherwise have taken back.
        .onChange(of: CreateWorkspaceOpening.shared.wantsPullRequest) { _, _ in
            guard CreateWorkspaceOpening.shared.consumePullRequestAsk() else { return }
            raisePullRequestBox()
        }
        // A second task, and a second trip, because listing pull requests is a network call and
        // the composer has to be typeable before it lands. The window opens on the branch route
        // either way; the picker fills in behind it.
        .task(id: repoID) { await loadCheckouts() }
        // The draft's chips and the files behind them belong to a window that is going away.
        .onDisappear(perform: discardDraft)
    }

    // MARK: - The bar above the box

    /// Where the two choices that are not about the next turn live: which project, and which
    /// branch it is cut from. They sit above the box rather than in the footer because they are
    /// about the workspace, and the footer is about the turn.
    private var header: some View {
        HStack(spacing: Metrics.spacingSmall) {
            // **"New workspace" used to be the first thing in this row, and the title bar says it
            // now.** It was put here because a sheet that opened on a segmented control read as a
            // fragment of a window rather than as a window, and every other sheet in the app opens
            // with a `Typo.heading` title at the top left. This is a window, with the title in the
            // bar where a window's title goes, so the same words in bold thirty points underneath
            // are the stutter the argument was made against.
            //
            // What the band is now is the sentence that was already after the title: "in bloom,
            // from main", the two choices that are about the workspace rather than about the turn.
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
        }
        // The same padding as `ProjectSetupSheet`'s header, which is the app's other header
        // sitting above a hairline: `gutter` across, `inset` down.
        //
        // It was `spacing` across and `spacingSmall` down, six points and four, and both were the
        // numbers for what this strip used to be: a row of 28 point control plates, which carry
        // their own air and are drawn as plates rather than read as words. A 15 point bold title
        // has neither, so four points put it into the sheet's rounded corner, which is what was
        // reported as the top of the sheet sticking to the title. Ten points of air above and
        // below leave the row optically centred in its band and clear of the corner.
        //
        // Only the vertical was ever wrong. The title already stood on 12 points, because it
        // carried six of its own on top of the strip's six, and it still does. What the strip
        // gains across is a trailing margin that matches: the row's trailing edge now keeps the
        // same 12 from the right edge that the title keeps from the left, where it kept six. Widening
        // this sheet from 620 to 700 spent nothing on either edge, so neither number had moved
        // since the strip held no title at all. What ends the row has changed since; the margin
        // has not.
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
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

        // One project is not a choice. It still says which project, because a window that cut a
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
    ///
    /// Everything it draws is `WorkspaceSourcePicker`, including the search field a `Menu` could
    /// not have held. What is left here is what the window owns: which project's lists these are,
    /// and what happens to the one that gets picked.
    private var sourceControl: some View {
        WorkspaceSourcePicker(
            offering: offering,
            checkout: checkout,
            baseBranch: baseBranch.isEmpty ? (repo?.defaultBranch ?? "") : baseBranch,
            unavailable: pullRequestUnavailable,
            onPick: pick(_:)
        )
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
                .onSubmit { resolveReference(reference) }
                .disabled(isResolvingReference)

            if isResolvingReference {
                ProgressView().controlSize(.small)
            } else {
                Button("Open") { resolveReference(reference) }
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

    // MARK: - The choice, and then the box

    private var composer: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            modePicker

            if isEnteringReference {
                referenceField
            }

            if let referenceProblem {
                Text(referenceProblem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
            }

            if let heldProblem {
                Text(heldProblem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A rung below the title in the band, which is what makes the band the anchor. Both
            // were `Typo.heading` for one build and the sheet had two things the same size
            // competing to be read first, which is most of what "janky" was: "New workspace" and
            // "What do you want to work on?" at fifteen bold, forty points apart. This is the
            // system's own heading style at reading size, which is what a section inside a titled
            // window is.
            Text(heading)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            switch mode {
            case .chat: chatBox
            // One box for both, because they ask the same question. What differs between a
            // terminal and a browser start is which tab the workspace lands on, and that is
            // settled after the window is gone. See `WorkspaceStartMode.pane`.
            case .terminal, .browser: nameBox
            }

            statusRow
        }
        .padding(Metrics.gutter)
    }

    /// Which of the three things this window is for.
    ///
    /// Above the question rather than beside Create, which is the whole of the change. A second
    /// button next to Create was two ways to finish where one of them silently repurposed the
    /// input, and it cost the footer's five labels to say so. A choice made before anything is
    /// typed cannot discard what was typed, because in the modes with no agent the box is not
    /// there.
    ///
    /// `Text` rather than `Label` in the rows. A segmented picker on macOS is an
    /// `NSSegmentedControl`, whose cells carry a title and an `NSImage`, so a SwiftUI icon inside
    /// one is silently dropped: the same trap `projectControl` documents for `NSPopUpButton`. The
    /// words are what carries this control anyway.
    private var modePicker: some View {
        // "Start with", not "Start workspace", which is what was asked for and would have said
        // the title's word back to it eight points underneath. The title names the thing; this
        // names the choice, and the segments finish the sentence: start with a chat with an
        // agent, with a terminal, or with a browser.
        //
        // The label is drawn by the picker rather than by a `Text` beside it, so AppKit places it
        // and VoiceOver gets the association for nothing. `labelsHidden` used to be here, which
        // is what left the control floating with no introduction.
        Picker("Start with", selection: modeBinding) {
            ForEach(WorkspaceStartMode.allCases) { candidate in
                Text(candidate.pickerLabel).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        // Tinted explicitly, like every other coloured control in this window: untinted a
        // segmented control paints its selected cell in the SYSTEM accent, which on a Mac set to
        // anything but Blue is another app's colour sitting in Bloom's own window. Measured on a
        // capture: bright system blue beside its teal Create button.
        .tint(Palette.accentFill)
        .help("Start a chat with an agent, or cut a worktree and open a shell or a browser in it")
    }

    /// Writing the choice down, and carrying the draft across with it.
    ///
    /// Both directions, because the window now opens on whichever was used last: somebody who was
    /// last in a terminal opens in one, and a sentence typed there has to survive the trip to chat
    /// exactly as a sentence typed in chat has to survive the trip the other way. Both rules are
    /// `WorkspaceStartPlan`'s. See `carriedName`. Terminal to browser crosses nothing, because
    /// both are showing the same field with the same name in it.
    private var modeBinding: Binding<WorkspaceStartMode> {
        Binding(
            get: { mode },
            set: { chosen in
                guard chosen != mode else { return }
                switch chosen {
                case .terminal, .browser:
                    typedName = WorkspaceStartPlan.carriedName(
                        prompt: spokenPrompt, currentName: typedName
                    )
                case .chat:
                    prompt = WorkspaceStartPlan.carriedPrompt(
                        name: typedName, currentPrompt: prompt
                    )
                    caret = (prompt as NSString).length
                }
                // Written before the focus is moved, because `focusTheBox` reads the mode back
                // out of it and would otherwise put the keyboard in the box that is leaving.
                rememberedMode = chosen.rawValue
                focusTheBox()
            }
        )
    }

    /// Chat mode, which is what this was before a second button was put in its footer.
    private var chatBox: some View {
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
        ) { actions in
            ComposerFooterView(
                controls: controls,
                onChange: { controls = $0 },
                canSend: canCreate,
                intent: .create,
                // The repository, because the worktree this window is about to cut does not
                // exist yet and a style the project defines is already in the repository.
                project: repo?.path,
                onAttach: actions.attach,
                // Written into the box, whatever the prompt's own two switches say. There is no
                // conversation here to send into and no strip to open a chat on, and the window is
                // not going to cut a worktree because a row was arrowed onto. `QuickPromptDelivery`
                // is the same fallback said once, for a surface that can do neither.
                onQuickPrompt: actions.insert,
                onSend: create
            )
        }
    }

    /// Terminal and browser mode: a name, and the button that cuts the worktree.
    ///
    /// Not the composer with its controls disabled. A model, a reasoning effort, an output style,
    /// a permission mode and a paperclip are all qualifiers on a turn, and there is no turn here,
    /// so the honest drawing of them is none of them. What is left is the one field that decides
    /// anything and the one button that finishes the window.
    ///
    /// **It is as tall as what is in it**, which it was not until somebody looked at the gap. See
    /// the note over `.composerBox` at the foot of this view.
    private var nameBox: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            if offersName {
                // "Optional", not "Named after a sea". The placeholder's job is to say the field
                // may be left alone; the line under it says what happens if it is.
                TextField("Optional", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.body)
                    .focused($isNameFocused)
                    .onSubmit(create)
                    .accessibilityLabel("Workspace name")
            }

            Text(startNote)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Files staged in chat mode and then left behind by a change of mind. There is no
            // paperclip here and no turn to put them in, so the only two honest answers were to
            // carry them or to say they are being dropped. They are carried, by
            // `AppModel.startWorkspace`, into the worktree the tab is about to stand beside, and
            // this is where that is said. Silence is what the two-button sheet did, and it deleted
            // them.
            if let sentence = attachmentNote {
                Label(sentence, systemImage: "paperclip")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Metrics.spacing) {
                Spacer(minLength: 0)
                // Beside Create rather than in the row below it. The two things that end this
                // window were stacked vertically, which is not a shape a Mac dialogue has: the pair is
                // one decision and reads as one row, with the default action rightmost.
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // The same button the composer's footer ends with, in the same corner of the same
                // box, doing the same job. One way to finish the window in every mode, and Return
                // presses it in every one.
                ComposerSendButton(intent: .create, canSend: canCreate, onSend: create)
            }
        }
        // **No fixed height here any more, and that is a rule traded rather than dropped.**
        //
        // This card used to be padded out to the chat box's height so that Create landed on the
        // same point in both modes. What it bought was reported by the owner as a large blank gap:
        // a name field, one line of caption, and then some forty points of nothing above the
        // buttons. It was worse than that number, because the padding tracked `editorHeight`, so a
        // fifteen line draft in chat mode and then a click on Terminal made a card with a field at
        // the top and two hundred points of air under it.
        //
        // The half of the rule worth keeping still holds for free: the mode is chosen with the
        // segmented control, that control and everything above it sit above this card, and the
        // container's top edge does not move, so nothing under the pointer moves when the card
        // resizes. What does move is the button row inside the card and the bottom edge below it,
        // by about the height of the gap. Air that is always there against a button that settles
        // forty points higher on a click nobody is aiming below: the air was the thing being
        // looked at.
        //
        // The card, and deliberately not its focus ring. `composerBox` draws one because the text
        // view inside it has none of its own; a `.roundedBorder` field brings its own, so passing
        // focus through here drew two rings, one inside the other, which reads as a mistake rather
        // than as emphasis. Measured on a capture. The field's own ring is the correct one.
        .composerBox(isFocused: .constant(false))
    }

    /// What a mode with no agent says about the files that came with the draft, or nothing when
    /// there are none.
    ///
    /// One read of `PromptAttachmentStore` rather than two. It was asked whether the list was
    /// empty and then asked again for its count, and both go through a shared store and build an
    /// array, on a property that is read on every pass of the body.
    private var attachmentNote: String? {
        let count = attachedPaths.count
        guard count > 0 else { return nil }
        return count == 1
            ? "The file you attached is copied into the worktree."
            : "The \(count) files you attached are copied into the worktree."
    }

    /// What a mode with no agent says about itself. The sentences and the choice between them are
    /// `WorkspaceStartPlan`'s, where a test holds them to not naming a sea.
    private var startNote: String {
        WorkspaceStartPlan.startNote(mode: mode, hasCheckout: !offersName, name: typedName)
    }

    /// What the box is asking for. A review workspace is opened to read something, so the task is
    /// genuinely optional there and the question says so rather than demanding a sentence the
    /// button no longer requires.
    private var heading: String {
        guard mode.runsAnAgent else {
            // The noun the segmented control was clicked with, in lower case. Stated again here it
            // would be a second list of the same words, and the heading would go on saying
            // "terminal" the day a third one was added, which is exactly what it did.
            let opened = mode.label.lowercased()
            switch checkout {
            case .pullRequest(let request): return "Open #\(request.number) in a \(opened)"
            case .branch(let branch): return "Open \(branch.name) in a \(opened)"
            // Not "Name this workspace". The band above it already says "New workspace", and the
            // two together read as a stutter. It is the field's label rather than an instruction,
            // which is what "Give it a name" was: the caption under the field is already one, and
            // two in four points of each other is one too many.
            case .none: return "Workspace name"
            }
        }
        switch checkout {
        case .pullRequest(let request): return "What should happen to #\(request.number)?"
        case .branch(let branch): return "What should happen on \(branch.name)?"
        case .none: return "What do you want to work on?"
        }
    }

    /// Grows with what is written, from five lines, and stops where the editor starts scrolling.
    private var editorHeight: CGFloat {
        max(contentHeight, ComposerTextEditor.lineHeight * Self.minEditorLines)
    }

    /// What the window is willing to promise, under the box. Cancel used to stand at its trailing
    /// end, which put the window's two terminal actions one above the other; it is beside Create
    /// now.
    private var statusRow: some View {
        HStack(spacing: Metrics.spacingWide) {
            hint

            Spacer(minLength: 0)
        }
    }

    /// What the window is allowed to promise about the name and the branch.
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
        } else if willBeNamedByModel {
            // Deliberately nothing. See above.
            EmptyView()
        } else if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only chat mode has anything to say here, and only when no model is going to write
            // the name. The other modes have said it already: the line under the name field says
            // Bloom will name it, and the branch follows the name. A second sentence eight points
            // lower saying the same thing again was the third place this window explained a
            // mechanism nobody had asked about, and the mechanism is the part that was wrong.
            if mode.runsAnAgent {
                Text("The branch is named from what you write")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        } else {
            Chip(text: branchPreview, systemImage: "arrow.triangle.branch", monospaced: true)
                .lineLimit(1)
        }
    }

    /// What is worth saying about the chosen checkout beyond its branch: that it has already been
    /// merged or closed, or that something has taken its branch since.
    ///
    /// Merged and closed do not stop the create, because reading the code of something that landed
    /// last week is a real reason to open one. A held branch does, and not here: `offer` refuses it
    /// before it can be chosen and `WorkspaceManager.open` refuses it again before git is asked.
    /// This is the third mechanism and the only one that is only a note, because the branch it
    /// catches is one taken in the seconds between the picker loading and Create being pressed.
    private var checkoutNote: String? {
        guard let checkout else { return nil }
        if let sentence = WorkspaceCheckoutPlan.warning(for: checkout) { return sentence }
        return holder(of: checkout)?.note
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

    /// The three lists the picker ranks, as one value.
    ///
    /// The base branches are this window's own listing rather than `checkoutOptions.branches`. The
    /// two are different questions: what may be cut from includes the default branch and every
    /// head a pull request speaks for, and what may be opened does not. See
    /// `WorkspaceCheckoutPlan.offeredBranches`.
    private var offering: WorkspaceSourceOffering {
        WorkspaceSourceOffering(
            pullRequests: checkoutOptions.pullRequests,
            branches: checkoutOptions.branches,
            baseBranches: branchOptions
        )
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
            isChatWorkspace: mode.runsAnAgent,
            isEnabled: WorkspaceNamingPreferences().isEnabled,
            isAgentAvailable: isNamingAvailable
        )
    }

    /// The same function `WorkspaceManager.cut` derives the real branch from, minus the uniquing
    /// suffix, which depends on branches that could appear between now and Create. Only shown when
    /// no model is going to rewrite it, because a preview that is about to be replaced is a lie
    /// with a monospaced font.
    private var branchPreview: String {
        Git.branchStem(prompt: task, prefix: branchPrefix)
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
            // Writing `repoID` restarts this task for the resolved project, so the listing below
            // runs once per project rather than once on open and again on the change.
            repoID = initialRepo?.id
                ?? app.selectedWorkspace.flatMap { app.repo(for: $0) }?.id
                ?? app.repos.first?.id
            return
        }
        guard let repo else { return }

        // A refusal is about a branch of the project that was on screen when the row was picked,
        // so it goes with the project. Left standing, it would name a folder in a repository the
        // window is no longer looking at.
        heldProblem = nil

        // Whichever box the remembered mode has put on screen. The window no longer always opens
        // on the writing box, so focusing it unconditionally would put the caret in a view that
        // is not there.
        focusTheBox()
        isLoading = true

        let path = repo.path
        var appDefaults = AppDefaults()
        if let store = app.store {
            appDefaults = await AppDefaults.load(from: store)
        }

        // The gathering and both branch decisions live in the core, where the suite can reach
        // them, and where the subprocess rule wants them: this view was the last one on the
        // allow-list in `Tools/house-rules.sh` for calling `Git` itself.
        let context = await WorkspaceStartContext.load(repoPath: path)

        // Cancelled means the project changed under this load, and these are the other
        // project's branches. The task running for the new project owns the window now,
        // spinner included.
        guard !Task.isCancelled else { return }
        isLoading = false

        branches = context.branches
        branchPrefix = context.settings.branchPrefix
        hasSetupScript = !(context.settings.setupScript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// What a row in the source picker means here.
    ///
    /// The two that mean opening something both go through `offer`, which is where the one row
    /// that is not a choice about this window at all is dealt with: a branch something already
    /// holds. Git refuses one branch in two worktrees, so "open it" cannot mean a second
    /// workspace. Such a row used to be missing from the list entirely, which answered the
    /// question by pretending the branch was not there.
    private func pick(_ source: WorkspaceSource) {
        heldProblem = nil
        switch source {
        case .newBranch(let ref):
            checkout = nil
            baseBranch = ref
            focusTheBox()
        case .existingBranch(let branch):
            offer(.branch(branch))
        case .pullRequest(.listed(let request)):
            offer(.pullRequest(request))
        case .pullRequest(.typed(_, let text)):
            // A number or a URL, which nothing knows anything about until gh is asked. The box
            // comes up carrying it so the wait, and any sentence about the wrong repository, have
            // somewhere to be read.
            reference = text
            referenceProblem = nil
            isEnteringReference = true
            resolveReference(text)
        }
    }

    /// Takes the checkout on unless something already has its branch.
    ///
    /// **The gate that stops a create that cannot succeed.** Git allows one worktree per branch,
    /// and until this existed the only thing that knew about the other worktrees on this Mac was
    /// git itself: pull request #362's head was held by a Conductor worktree, the row looked free,
    /// and the refusal arrived as `gh pr checkout`'s stderr in a dialogue. The branch half of the
    /// picker had always greyed such a row and the pull request half never had, which is why the
    /// question is asked here, over the checkout, rather than per case.
    ///
    /// A branch one of Bloom's own workspaces holds is not a refusal at all: the window has nothing
    /// left to ask and goes there, which is what it has always done. Anything else is named with
    /// its path, because that is the folder to go and close, and the sentence says what can be had
    /// instead. See `BranchHolder.refusal`.
    private func offer(_ chosen: WorkspaceCheckout) {
        guard let holder = holder(of: chosen) else {
            choose(chosen)
            return
        }
        let branch = WorkspaceCheckoutPlan.localBranch(for: chosen, taken: Set(branches))
        if holder.isBloomWorkspace, let repo, let held = WorkspaceCheckoutPlan.workspaceHolding(
            branch: branch, in: repo.id, among: app.workspaces
        ) {
            app.selection = .workspace(held.id)
            dismiss()
            return
        }
        heldProblem = holder.refusal(branch: branch)
    }

    /// What already holds the branch this checkout would land on, when something does.
    ///
    /// The branch is `localBranch` rather than the head verbatim, because that is the name
    /// `WorkspaceManager.open` will pass to git: a fork's `patch-1` is opened as
    /// `<owner>-patch-1`, so asking about `patch-1` would refuse a checkout git would have allowed.
    private func holder(of chosen: WorkspaceCheckout) -> BranchHolder? {
        checkoutOptions.holders[
            WorkspaceCheckoutPlan.localBranch(for: chosen, taken: Set(branches))
        ]
    }

    /// Takes a pull request or a branch as the source, and closes anything the choice answers.
    private func choose(_ chosen: WorkspaceCheckout) {
        checkout = chosen
        isEnteringReference = false
        referenceProblem = nil
        heldProblem = nil
        reference = ""
        focusTheBox()
    }

    /// Raises the box for a pull request number or URL, and puts the keyboard in it.
    private func raisePullRequestBox() {
        isEnteringReference = true
        isReferenceFocused = true
    }

    /// Puts the keyboard in whichever box this mode is showing.
    private func focusTheBox() {
        isFocused = mode.runsAnAgent
        isNameFocused = !mode.runsAnAgent && offersName
    }

    /// Resolves what was typed into the box. Everything but the drawing is in the core: the
    /// parsing, the repository check and the gh call are `WorkspaceCheckoutResolver`.
    ///
    /// The text is passed in rather than read back off `reference`, because the picker's typed row
    /// writes it and calls this in the same breath.
    private func resolveReference(_ text: String) {
        guard let repo, !isResolvingReference else { return }
        let path = repo.path
        isResolvingReference = true
        referenceProblem = nil
        Task {
            let resolution = await WorkspaceCheckoutResolver.resolve(text, repoPath: path)
            isResolvingReference = false
            switch resolution {
            case .checkout(let resolved): offer(resolved)
            case .failure(let sentence): referenceProblem = sentence
            }
        }
    }

    /// The pull requests and branches this project can be opened on.
    ///
    /// It reads its own branch listing rather than the one `load` writes into `branches`. The two
    /// run in separate tasks, so this one used to see an empty list every time and offer every
    /// branch as though it lived only on the remote. See `WorkspaceCheckoutOptions.load`.
    ///
    /// Branches already checked out somewhere are listed with a note saying so, and selecting one
    /// goes to the workspace that has it when it is one of Bloom's. They used to be left out,
    /// because git refuses one branch in two worktrees and offering one is offering a create that
    /// cannot succeed. That is true of the create and wrong about the list: the branch being looked
    /// for is very often the one that is already open. See `WorkspaceCheckoutPlan.offeredBranches`.
    ///
    /// "Somewhere" is asked of git rather than of the database, so a worktree Conductor cut, or one
    /// cut by hand, is as visible as one of Bloom's own. See `BranchHolder`.
    private func loadCheckouts() async {
        guard let repo else { return }
        isLoadingCheckouts = true
        let options = await WorkspaceCheckoutOptions.load(
            repoPath: repo.path,
            repoID: repo.id,
            defaultBranch: repo.defaultBranch,
            // Every workspace the app is holding, filtered to this project's live ones inside
            // `BranchHolder.names` rather than here, because a filter written in a view is a
            // filter nothing can test. It got the project half wrong once already: a branch name
            // is not unique across repositories, and an unfiltered list labelled this project's
            // `develop` as held by a workspace in another project.
            workspaces: app.workspaces
        )
        guard !Task.isCancelled else { return }
        isLoadingCheckouts = false
        checkoutOptions = options
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }

    /// A chip in this window has no review tab to open into, so it opens where a file opens when
    /// nothing in the app owns it.
    private func open(attachment: PromptAttachment) {
        NSWorkspace.shared.open(attachment.url(in: stagingDirectory))
    }

    /// Cuts the worktree, on whichever mode the window is in.
    ///
    /// One function, one button, one guard, because there is now one way to finish this window.
    /// Everything below the first two lines is the same work whichever mode asked for it: the same
    /// attachments, the same staging, the same funnel. See `AppModel.createWorkspace`, which is
    /// the one way a workspace is started whoever is asking.
    ///
    /// `task` is the sentence in chat mode and the name field in the other two, and both arrive at
    /// `startWorkspace` as `prompt` because that is what it derives a name and a branch from. What
    /// separates them is `opensWith`, which decides whether an opening turn is ever sent and which
    /// tab the workspace is first shown on.
    private func create() {
        guard let repo, canCreate else { return }

        let chosen = mode
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Still rotated, even though creating now always dismisses. `dismiss` runs `onDisappear`,
        // which discards whatever draft the window is holding, and without this that would be the
        // draft whose files are at this moment on their way into a worktree.
        draftID = PromptAttachments.newShortID()

        dismiss()

        // The window this one is not attached to. Creating selects the new workspace in the main
        // window, and this window can be sitting in front of it, beside it, or open with the main
        // window closed altogether, in which case nothing at all would show what pressing Create
        // just did. `openWindow` on the main scene brings it forward when it is open and opens it
        // when it is not. It was free while this was a sheet, because a sheet cannot exist without
        // the window it is attached to.
        openWindow(id: BloomApp.mainWindowID)

        Task {
            await app.createWorkspace(
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
        }
    }

    private func discardDraft() {
        let id = draftID
        PromptAttachmentStore.shared.clear(sessionID: id)
        Task.detached(priority: .utility) {
            AttachmentStaging.discard(draftID: id)
        }
    }
}
