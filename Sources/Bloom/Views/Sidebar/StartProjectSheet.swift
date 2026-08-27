import SwiftUI
import BloomCore

/// One door into the project list: a field, a block that says what will happen, and a button named
/// after it.
///
/// It replaces a two item menu. The `+` beside Projects used to ask New Project or Add Project
/// Folder before the person had typed anything, and the owner's objection was that both answers
/// end in the same place. They do, and the target decides the verb: a git repository is added, an
/// empty folder or a name that is not taken is created, a folder with work in it and no repository
/// is tracked. Nothing here asks which button was pressed.
///
/// **Every decision it draws is `ProjectTargetVerdict` in the core.** How one typed line is read,
/// which of the two rule sets judges it, what the block says, whether the button can be pressed
/// and what it is called: all of them are pure functions with tests, because the sheet is the one
/// place in the app where a wrong answer writes to somebody's disk.
///
/// **No GitHub half.** `ProjectSetupSheet` offers to publish a folder it has just turned into a
/// repository, and this sheet does not, in either of the two cases where it makes one. For a brand
/// new project the argument is the one the sheet this replaced was built on: publishing an empty
/// repository claims a name in somebody's account for a thing that may not exist next week, and
/// `RepositoryStarter.abandon` will not delete one once it does. **For Start Tracking that
/// argument does not hold**, a folder with sixty files in it is exactly the sort of thing somebody
/// might want published, and it is deliberately left out all the same: a publish flow here is its
/// own piece of work, with an owner picker, an availability check and a sign in sheet, and it does
/// not belong in the change that removed a menu. Publishing an existing project is still
/// `ProjectSetupSheet`'s, reached from the file panel.
struct StartProjectSheet: View {
    /// Called with the project once there is one, and with nil when the person backed out.
    let onFinish: (StartedProject?) -> Void

    @Environment(AppModel.self) private var app

    private enum Phase: Equatable {
        case naming
        case working(RepositoryStartStep)
        case failed(NewProjectFailure)
    }

    /// The line, exactly as typed. A name, or a path, and Bloom reads which.
    @State private var typed = ""
    @State private var facts = NewProjectFacts()
    /// What the folder holds, once the walk that counts it has come back. Only ever asked of a
    /// folder that is about to be tracked, because it is a walk of somebody's whole project.
    @State private var contents: FolderContents?
    @State private var phase: Phase = .naming
    /// Where a bare name goes: the folder the owner's projects already live in. Settled once, when
    /// the sheet appears, so it cannot move while somebody is typing.
    @State private var defaultLocation = ""
    @State private var projectsThere = 0
    /// What the first commit's branch will be. Read from git rather than asserted, because a
    /// machine with `init.defaultBranch` set gets its own answer. See `NewProjectStarter`.
    @State private var branch = "main"
    /// Set when git on this Mac has no name or address configured, in which case no commit can be
    /// made and the button is held before anything is written rather than half way through it.
    @State private var identityProblem: String?
    @State private var createTask: Task<Void, Never>?
    @State private var isStepSlow = false
    @FocusState private var isFieldFocused: Bool

    private static let width: CGFloat = 560
    /// Long enough that typing a name costs one walk of the file system rather than one per
    /// character, short enough that the block answers while the eye is still on it.
    private static let inspectionDelay = Duration.milliseconds(150)
    /// The block is always there and never collapses, so the field above it and the button below
    /// it do not move as the target changes under the keyboard. It grows for a long refusal: the
    /// nine that are left run to 232 characters and every one of them is worth reading in full,
    /// which is the whole argument for a sheet rather than an editable row in the sidebar.
    private static let blockMinHeight: CGFloat = 74
    /// Enough to see what is being kept out of the first commit without the list becoming the
    /// sheet. The same cap `ProjectSetupSheet` uses.
    private static let excludedShown = 8

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private var verdict: ProjectTargetVerdict { ProjectTargetVerdict.of(facts) }

    private var hasTyped: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The block, from the core: the instruction before anything is typed, and the verdict after.
    private var consequence: ProjectConsequence {
        guard hasTyped else {
            return .opening(location: defaultLocation, projectsThere: projectsThere, home: home)
        }
        return .of(verdict, path: facts.path, home: home, branch: branch, contents: contents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            // Not a ScrollView, for the reason `ProjectSetupSheet` gives: one takes every point it
            // is offered, and this sheet is as tall as the three things in it.
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                switch phase {
                case .naming: form
                case .working(let step): working(step)
                case .failed(let failure): failed(failure)
                }
            }
            .padding(Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)

            Hairline()
            footer
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .onAppear {
            if defaultLocation.isEmpty {
                let paths = app.repos.map(\.path)
                defaultLocation = NewProjectPlan.suggestedLocation(projectPaths: paths, home: home)
                projectsThere = NewProjectPlan.projectsIn(defaultLocation, projectPaths: paths)
            }
            isFieldFocused = true
        }
        .task {
            branch = await NewProjectStarter.plannedBranch()
            identityProblem = await RepositoryStarter.identityProblem(at: home)
        }
        // Re-asked after a pause rather than on every keystroke: this walks up the tree looking
        // for a `.git`, reads a directory and, for a folder with something in it, asks the same
        // question of every child. Cheap once and rude sixty times.
        .task(id: Draft(typed: typed, location: defaultLocation)) {
            try? await Task.sleep(for: Self.inspectionDelay)
            guard !Task.isCancelled else { return }
            let line = typed
            let location = defaultLocation
            let found = await Task.detached {
                NewProjectStarter.inspect(typed: line, defaultLocation: location)
            }.value
            guard !Task.isCancelled else { return }
            facts = found
        }
        // The counts under a Start Tracking verdict, which are a walk of the whole folder and so
        // are asked only once the target has settled on one. Keyed on the path rather than on the
        // line, so correcting a typo further up the path does not walk `node_modules` twice.
        .task(id: pathToScan) {
            contents = nil
            guard let path = pathToScan else { return }
            let found = await Task.detached { RepositoryStarter.scan(path) }.value
            guard !Task.isCancelled else { return }
            contents = found
        }
        .onDisappear {
            // Not a stop: the sheet only leaves the screen by a path that has finished with the
            // run. What this covers is the window closing under it.
            createTask?.cancel()
        }
    }

    /// What the inspection is keyed on. The line and where a bare name would go, because the
    /// second of those is settled after the first layout pass and a target resolved against an
    /// empty location is not the one the person typed.
    private struct Draft: Equatable {
        var typed: String
        var location: String
    }

    /// The folder whose contents are worth counting, and nil for every other verdict.
    private var pathToScan: String? {
        guard case .track = verdict, !facts.path.isEmpty else { return nil }
        return facts.path
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Image(systemName: "folder.badge.plus")
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(title)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("a folder on this Mac, and a project in the sidebar")
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
    }

    private var title: String {
        switch phase {
        case .naming: "Start a project"
        case .working: "Setting up \(folderName)"
        case .failed(let failure): failure.title
        }
    }

    private var folderName: String {
        let name = (facts.path as NSString).lastPathComponent
        return name.isEmpty ? "the project" : name
    }

    // MARK: - The one question

    @ViewBuilder
    private var form: some View {
        HStack(spacing: Metrics.spacingWide) {
            // One control, and it takes whatever the person has: a word, a path pasted out of a
            // terminal, or the answer to the file panel next to it. The two fields this replaces,
            // Name and Location, were the same split as the menu one level further down.
            TextField("Name it, or point at a folder", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(Typo.code)
                .focused($isFieldFocused)
                .onSubmit(start)
            Button("Choose\u{2026}", action: chooseFolder)
        }

        // Only where a commit is about to be made. Adding a repository writes nothing, so an
        // unconfigured git is none of its business and saying so there would be a warning about
        // something that is not going to happen.
        if let identityProblem, verdict.makesACommit {
            Callout(text: identityProblem, symbol: "exclamationmark.triangle.fill", tone: .warning)
        }

        block
    }

    /// What will happen, said in the same place whatever the answer is.
    ///
    /// One block rather than a hint line, a first commit box and a refusal that each appear and
    /// disappear: the target changes under the keyboard, and a sheet whose middle grows and
    /// shrinks by a paragraph per keystroke is one nobody reads.
    private var block: some View {
        let said = consequence
        return HStack(alignment: .top, spacing: Metrics.spacingWide) {
            Image(systemName: symbol(for: said.tone))
                .font(Typo.caption)
                .foregroundStyle(ink(for: said.tone))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                if let lead = said.lead {
                    Text(lead)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Text(said.detail)
                    .font(Typo.caption)
                    .foregroundStyle(
                        said.tone == .waiting ? Palette.textTertiary : Palette.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if !said.excluded.isEmpty { excluded(said.excluded) }

                if let alternative = said.alternative {
                    // The offer `FolderRefusal.alternative` has always returned and nothing has
                    // ever drawn. One field is the first place it fits, because taking it is one
                    // write into the control the person is already looking at.
                    Button("Use \(NewProjectPlan.display(alternative, home: home))") {
                        typed = NewProjectPlan.display(alternative, home: home)
                    }
                    .controlSize(.small)
                    .padding(.top, Metrics.spacingTight)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, minHeight: Self.blockMinHeight, alignment: .topLeading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(said.tone == .refusal ? Palette.negative.opacity(0.35) : .clear)
        )
    }

    /// Drawn open rather than behind a chevron, which is where `ProjectSetupSheet` keeps it. It is
    /// the one thing on this sheet worth reading before pressing: a folder with a `.env` in it is
    /// exactly the case that goes wrong quietly.
    private func excluded(_ paths: [ExcludedPath]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            ForEach(paths.prefix(Self.excludedShown)) { item in
                HStack(spacing: Metrics.spacingSmall) {
                    Image(systemName: item.reason == .sensitive
                        ? "key.fill" : "folder.badge.gearshape")
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textTertiary)
                    Text(item.path)
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if paths.count > Self.excludedShown {
                Text("and \(paths.count - Self.excludedShown) more")
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.top, Metrics.spacingTight)
    }

    private func symbol(for tone: ProjectConsequenceTone) -> String {
        switch tone {
        case .waiting: "folder"
        case .going: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .refusal: "exclamationmark.circle.fill"
        }
    }

    private func ink(for tone: ProjectConsequenceTone) -> Color {
        switch tone {
        case .waiting: Palette.textTertiary
        case .going: Palette.accent
        case .caution: Palette.warning
        case .refusal: Palette.negative
        }
    }

    // MARK: - Running and failing

    private func working(_ step: RepositoryStartStep) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                ForEach(RepositoryStartStep.steps(for: .local), id: \.self) { candidate in
                    HStack(spacing: Metrics.spacingWide) {
                        if candidate < step {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.positive)
                                .accessibilityHidden(true)
                        } else if candidate == step {
                            ProgressView().controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(Palette.textTertiary)
                                .accessibilityHidden(true)
                        }
                        Text(candidate.label)
                            .font(Typo.label)
                            .foregroundStyle(
                                candidate == step ? Palette.textPrimary : Palette.textSecondary
                            )
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(candidate.label)
                    .accessibilityValue(
                        candidate < step ? "Done" : candidate == step ? "Running" : "Not started"
                    )
                }
            }

            // A step that has stopped looks exactly like a step that is working. After `patience`
            // the spinner stops being a spinner and starts being a sentence. `git commit` waiting
            // on a signing helper's approval is the one that happens.
            if isStepSlow {
                Callout(text: step.slowNotice, symbol: "clock.badge.exclamationmark", tone: .warning)
            }
        }
        .task(id: step) {
            isStepSlow = false
            try? await Task.sleep(for: step.patience)
            guard !Task.isCancelled else { return }
            isStepSlow = true
        }
    }

    private func failed(_ failure: NewProjectFailure) -> some View {
        Callout(text: failure.message, symbol: "exclamationmark.triangle.fill", tone: .negative)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Metrics.spacingWide) {
            // The one branch the unification introduces, said before it is taken: creating a
            // project ends in the New Workspace sheet and adding one ends in the sidebar. Four
            // words, drawn only where they are true.
            if phase == .naming, verdict.opensAWorkspace {
                Text("then a new workspace")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }

            Spacer(minLength: 0)

            switch phase {
            case .naming:
                Button("Cancel", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                // Named after the verdict, so a verb that is not what will happen can never be
                // pressed. It keeps its title while disabled, because a button that goes blank
                // reads as Bloom not having understood the target rather than as it refusing one.
                Button(verdict.buttonTitle, action: start)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)

            case .working:
                // Enabled, and carrying Escape. A disabled Cancel over a step that has hung is a
                // sheet with no way out, which is the bug the neighbouring sheet was left with
                // when `git commit` sat waiting on a signing helper.
                Button("Stop", role: .cancel, action: stop)
                    .keyboardShortcut(.cancelAction)

            case .failed:
                Button("Close", role: .cancel, action: discardAndClose)
                    .keyboardShortcut(.cancelAction)
                Button("Try again") { phase = .naming }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentFill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
    }

    private var canStart: Bool {
        guard hasTyped, verdict.isAllowed else { return false }
        return identityProblem == nil || !verdict.makesACommit
    }

    // MARK: - Work

    private func chooseFolder() {
        // The deepest part of what is typed that really exists, so the panel opens beside the
        // folder being named rather than at whatever it was last shown.
        let opening = facts.targetExists
            ? facts.path
            : (facts.nearestExistingAncestor.isEmpty
                ? defaultLocation
                : facts.nearestExistingAncestor)
        Task {
            guard let chosen = await ProjectFolderPicker.chooseTarget(startingAt: opening)
            else { return }
            typed = NewProjectPlan.display(chosen, home: home)
        }
    }

    /// The button, whichever verb it is wearing.
    private func start() {
        // Asked again here, from what is typed at this instant. The block is a beat behind the
        // keyboard on purpose, and Return is faster than that beat: without this, typing a name
        // and pressing Return in one movement pressed a button that was still looking at the empty
        // field. It is a handful of stats, once, on a key press.
        let current = NewProjectStarter.inspect(typed: typed, defaultLocation: defaultLocation)
        facts = current
        let decided = ProjectTargetVerdict.of(current)
        guard decided.isAllowed, !current.path.isEmpty else { return }
        guard identityProblem == nil || !decided.makesACommit else { return }

        // Nothing is written for a repository that is already one, so there is no run to watch and
        // no failure to report: the project simply appears in the sidebar.
        if case .add(let root) = decided {
            onFinish(StartedProject(path: root, opensWorkspace: false))
            return
        }

        let target = current.path
        let opensWorkspace = decided.opensAWorkspace
        isStepSlow = false
        phase = .working(.initialise)

        createTask?.cancel()
        createTask = Task {
            do {
                // The same call for all three of the verbs that write. Creating a project, using
                // an empty folder and tracking one with work in it differ by whether the folder
                // has to be made and by what ends up in the first commit, and `NewProjectStarter`
                // is `RepositoryStarter` with the `mkdir` in front of it either way.
                let creation = try await NewProjectStarter.create(at: target) { step in
                    phase = .working(step)
                }
                guard !Task.isCancelled else { return }
                onFinish(StartedProject(path: creation.path, opensWorkspace: opensWorkspace))
            } catch let failure as NewProjectFailure {
                guard !Task.isCancelled else { return }
                phase = .failed(failure)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(NewProjectFailure(
                    title: "Could not start the project",
                    message: RepositoryStarter.sentence(from: error),
                    folderWasCreated: false
                ))
            }
        }
    }

    /// Stopping reaches the subprocess: `Shell.run` terminates the command it is waiting on, so a
    /// hung `git commit` really does go away. What Bloom made is then taken back off the disk, and
    /// what it did not make is left exactly where it was. See `NewProjectStarter.discard`, which
    /// is the rule that keeps a folder somebody else's files are in.
    private func stop() {
        createTask?.cancel()
        createTask = nil
        let target = facts.path
        Task {
            await NewProjectStarter.discard(at: target, folderWasCreated: !facts.targetExists)
            onFinish(nil)
        }
    }

    private func discardAndClose() {
        guard case .failed(let failure) = phase else {
            onFinish(nil)
            return
        }
        let target = facts.path
        Task {
            await NewProjectStarter.discard(
                at: target, folderWasCreated: failure.folderWasCreated
            )
            onFinish(nil)
        }
    }
}

/// What the sheet ended with.
///
/// Two facts rather than one, because the window does two different things with them: every
/// project it hands back goes into the sidebar, and only one that Bloom made goes straight on to
/// its first workspace. See `ProjectTargetVerdict.opensAWorkspace` for why that difference is
/// right, and the footer for where it is said out loud.
struct StartedProject: Equatable {
    var path: String
    var opensWorkspace: Bool
}
