import SwiftUI
import BloomCore

/// What Bloom offers instead of refusing a folder that is not a git repository.
///
/// Two answers, not one. Conductor's version of this dialog assumes a GitHub repository is what
/// you want, and for Bloom that is simply not true: worktrees, agents, diffs and merging back into
/// the base branch all work on a repository that exists nowhere but this Mac. Only pull requests
/// and checks need a remote. So the local answer is offered first, it is the default, it needs no
/// account and no network, and the GitHub answer is a deliberate second choice rather than the
/// only one on the table. A default that cannot publish anything is also the safe one to leave
/// under the Return key.
///
/// The dialog is a choice, not a form. The owner and the name only exist once GitHub has been
/// picked, so the local path is two sentences and a button.
struct ProjectSetupSheet: View {
    let request: ProjectSetup.Request
    /// Called with the folder once it is a repository Bloom can add, and with nil when the user
    /// backed out or left it in a state that is not a project.
    let onFinish: (String?) -> Void

    private enum Choice: Equatable {
        case local
        case gitHub
    }

    private enum Phase: Equatable {
        case choosing
        case working(RepositoryStartStep)
        case failed(RepositoryStartFailure)
        /// The user stopped it part way through. See `RepositoryStartAbandonment`.
        case stopped(RepositoryStartAbandonment)
        case finished(RepositoryStartOutcome)
    }

    @State private var choice: Choice
    @State private var owners: [GitHubOwner] = []
    @State private var owner = ""
    @State private var name = ""
    @State private var availability: NameAvailability = .idle
    @State private var access: GitHubAvailability.State = .unknown
    @State private var phase: Phase = .choosing
    @State private var signIn: GitHubSignIn.Request?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isShowingExcluded = false
    @State private var availabilityCheck: Task<Void, Never>?
    @State private var isLoadingOwners = false
    /// The run in flight, held so it can be stopped.
    ///
    /// Without it this sheet had no way out at all. The footer's only button in the working phase
    /// was a Cancel that did nothing and was disabled, so a step that never came back left the app
    /// with a modal sheet nobody could dismiss and no answer but killing the process. It happened:
    /// `git commit` sat waiting on a signing helper's approval that was never shown.
    @State private var startTask: Task<Void, Never>?
    /// Whether the step now running has been going longer than `RepositoryStartStep.patience`.
    @State private var isStepSlow = false
    /// True while the folder is being put back after a stop.
    @State private var isStopping = false

    /// A network call per keystroke is the lazy version of this. Long enough that typing a name
    /// costs one request rather than one per character, short enough that the answer arrives while
    /// the user is still looking at the field.
    private static let availabilityDelay = Duration.milliseconds(450)
    private static let width: CGFloat = 560
    /// Enough to see what is being kept out without the list becoming the dialog.
    private static let excludedShown = 8

    init(request: ProjectSetup.Request, onFinish: @escaping (String?) -> Void) {
        self.request = request
        self.onFinish = onFinish
        // Local unless a capture run asked for the other half. See `ProjectSetup.capturedChoice`
        // for why that exists at all.
        _choice = State(initialValue: ProjectSetup.capturedChoice == "github" ? .gitHub : .local)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            // Deliberately not a ScrollView. One takes every point it is offered, so a dialog with
            // two paragraphs in it stood 420 points tall with 200 of them empty. The content is
            // bounded instead: the file list is capped and the GitHub half only exists once it
            // has been chosen, so the sheet is as tall as what is in it.
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                switch phase {
                case .choosing: offer
                case .working(let step): working(step)
                case .failed(let failure): failed(failure)
                case .stopped(let left): stopped(left)
                case .finished(let outcome): finished(outcome)
                }
            }
            .padding(Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)

            Hairline()
            footer
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .task { await probeGitHub() }
        .onAppear { name = GitHubRepositoryName.suggestion(from: request.folderName) }
        .onDisappear {
            availabilityCheck?.cancel()
            // Not a stop: the sheet is only taken off screen by a path that has already finished
            // with the run. What this covers is the window closing under it, and a run left
            // pumping git into a dialog that is gone is worse than one that ends.
            startTask?.cancel()
        }
        .sheet(item: $signIn) { pending in
            GitHubSignInSheet(request: pending) { connected in
                signIn = nil
                if connected { Task { await probeGitHub() } }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Image(systemName: "folder.badge.questionmark")
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(title)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text(request.path)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
    }

    private var title: String {
        switch phase {
        case .choosing: "\(request.folderName) is not a git repository"
        case .working: "Setting up \(request.folderName)"
        case .failed(let failure): failure.title
        case .stopped: "Stopped setting up \(request.folderName)"
        case .finished: "\(request.folderName) is ready"
        }
    }

    // MARK: - The offer

    @ViewBuilder
    private var offer: some View {
        Text(
            "Bloom runs every agent in a git worktree, so a project has to be a repository. "
                + "Bloom can make this folder one."
        )
        .font(Typo.body)
        .foregroundStyle(Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        if let problem = request.identityProblem {
            Callout(text: problem, symbol: "exclamationmark.triangle.fill", tone: .warning)
        }

        firstCommit

        VStack(spacing: Metrics.spacing) {
            option(
                .local,
                title: "Here on this Mac",
                caption: "git init and a first commit, and nothing else. No account, no network. "
                    + "Worktrees, agents, diffs and merging all work on this."
            )
            option(
                .gitHub,
                title: "And a private repository on GitHub",
                caption: "The same, then a private repository, origin, and a first push. "
                    + "Needed only for pull requests and checks."
            )
        }

        if choice == .gitHub { gitHub }
    }

    private func option(_ value: Choice, title: String, caption: String) -> some View {
        Button {
            choice = value
            if value == .gitHub { scheduleAvailabilityCheck() }
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacingWide) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .font(Typo.body)
                    .foregroundStyle(choice == value ? Palette.controlAccent : Palette.textTertiary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(title)
                        .font(Typo.labelEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                    Text(caption)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(Metrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                choice == value ? Palette.selected : Palette.surfaceSunken,
                in: RoundedRectangle(cornerRadius: Metrics.corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .strokeBorder(
                        choice == value ? Palette.controlAccent : Palette.border,
                        lineWidth: Metrics.outline
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == value ? [.isSelected, .isButton] : .isButton)
    }

    /// What the first commit will contain, before anything is committed and long before anything
    /// is pushed. The counts come from a walk of the folder, and the wording carries the
    /// uncertainty rather than hiding it.
    @ViewBuilder
    private var firstCommit: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            LabeledLine(label: "First commit", value: request.contents.summary)

            if !request.contents.excluded.isEmpty {
                Button {
                    isShowingExcluded.toggle()
                } label: {
                    HStack(spacing: Metrics.spacingSmall) {
                        Image(systemName: isShowingExcluded ? "chevron.down" : "chevron.right")
                            .font(Typo.micro)
                        Text(request.contents.excludedSummary ?? "")
                            .font(Typo.caption)
                    }
                    .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                // The three things `RepoHeaderRow.disclosure` gives its own chevron and this one
                // had none of: the state as a value rather than only in the glyph's direction, a
                // tooltip, and the turn as movement that Reduce Motion drops.
                .animation(reduceMotion ? nil : Motion.pane, value: isShowingExcluded)
                .accessibilityValue(isShowingExcluded ? "Expanded" : "Collapsed")
                .help(isShowingExcluded ? "Hide what is left out" : "Show what is left out")

                if isShowingExcluded {
                    VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                        ForEach(request.contents.excluded.prefix(Self.excludedShown)) { item in
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
                        if request.contents.excluded.count > Self.excludedShown {
                            Text("and \(request.contents.excluded.count - Self.excludedShown) more")
                                .font(Typo.codeTiny)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .padding(.leading, Metrics.inset)
                }
            }

            if request.contents.isEmpty == false && request.contents.hasGitignore == false {
                Text("There is no .gitignore here, so everything else in the folder goes in.")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    // MARK: - The GitHub half

    @ViewBuilder
    private var gitHub: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            switch access {
            case .ready:
                ownerAndName
            case .unknown:
                HStack(spacing: Metrics.spacingWide) {
                    ProgressView().controlSize(.small)
                    Text("Checking the GitHub CLI")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            case .notInstalled, .signedOut:
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    Text(access == .notInstalled
                        ? "Creating a repository needs the gh command, and it is not installed."
                        : "Creating a repository needs GitHub access.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(access == .notInstalled ? "Install the GitHub CLI" : "Connect GitHub") {
                        signIn = GitHubSignIn.Request(access: access, directory: request.path)
                    }
                    .controlSize(.small)
                }
            }

            if !request.contents.oversizeFiles.isEmpty {
                Callout(
                    text: "GitHub refuses any file over 100 MB, and this folder has "
                        + "\(request.contents.oversizeFiles.count). The push will fail: "
                        + request.contents.oversizeFiles.prefix(3).joined(separator: ", "),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .negative
                )
            } else if request.contents.isLargeUpload {
                Callout(
                    text: "That is a lot to upload, and all of it becomes a repository on GitHub. "
                        + "Worth a look before you press.",
                    symbol: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        )
    }

    private var ownerAndName: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            HStack(spacing: Metrics.spacingWide) {
                Picker("Owner", selection: $owner) {
                    ForEach(owners) { candidate in
                        Text(candidate.login).tag(candidate.login)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .disabled(owners.isEmpty)
                .onChange(of: owner) { _, _ in scheduleAvailabilityCheck() }

                Text("/")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)

                TextField("Repository name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in scheduleAvailabilityCheck() }

                if isLoadingOwners {
                    ProgressView().controlSize(.small)
                }
            }

            // What will be created, spelled out, before it is. Conductor gets this part right and
            // it is worth keeping: a repository is not something to discover the name of
            // afterwards.
            if let problem = GitHubRepositoryName.problem(with: trimmedName) {
                Label(problem.sentence, systemImage: "exclamationmark.circle.fill")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Metrics.spacingWide) {
                    Text("Will create \(owner)/\(trimmedName), private.")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textSecondary)
                    availabilityLine
                }
            }
        }
    }

    @ViewBuilder
    private var availabilityLine: some View {
        switch availability {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .available:
            Label("available", systemImage: "checkmark.circle.fill")
                .font(Typo.micro)
                .foregroundStyle(Palette.positive)
        case .taken:
            Label("already taken", systemImage: "xmark.circle.fill")
                .font(Typo.micro)
                .foregroundStyle(Palette.negative)
        case .unknown(let why):
            // Never rendered as "available". A check that failed knows nothing, and it does not
            // stop the button either: pressing it is what settles the question, and gh says so
            // plainly when the name is gone.
            Label(why, systemImage: "questionmark.circle")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: - Running, failing, finishing

    private func working(_ step: RepositoryStartStep) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                ForEach(RepositoryStartStep.steps(for: destination), id: \.self) { candidate in
                    HStack(spacing: Metrics.spacingWide) {
                        // Hidden rather than labelled, and the row speaks for itself below. Three
                        // marks, none of them labelled and none of them hidden, is three
                        // unnamed images in a list, which is what this was: the same file gets it
                        // right twice already, at the radio button and the destination picker.
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
                            .foregroundStyle(candidate == step ? Palette.textPrimary : Palette.textSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(candidate.label)
                    .accessibilityValue(
                        candidate < step ? "Done" : candidate == step ? "Running" : "Not started"
                    )
                }
            }

            // A step that has stopped looks exactly like a step that is working, and the spinner
            // says nothing either way. After `patience` it stops being a spinner and starts being
            // a sentence, which names the command and the likeliest reason it is stuck.
            if isStepSlow {
                Callout(text: step.slowNotice, symbol: "clock.badge.exclamationmark", tone: .warning)
            }

            if isStopping {
                HStack(spacing: Metrics.spacingWide) {
                    ProgressView().controlSize(.small)
                    Text("Stopping, and putting the folder back")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        // Keyed on the step, so the clock restarts each time the sequence moves on and a slow
        // commit does not leave the warning standing over a push that has only just begun.
        .task(id: step) {
            isStepSlow = false
            try? await Task.sleep(for: step.patience)
            guard !Task.isCancelled else { return }
            isStepSlow = true
        }
    }

    /// What is on disk after a stop, and nothing about why it was stopped: the user did that and
    /// knows. See `RepositoryStartAbandonment`.
    private func stopped(_ left: RepositoryStartAbandonment) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Text("What the folder is now")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textPrimary)
            Text(left.state)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    /// A failure names the step, quotes what git or gh said, and then says what the folder is now.
    /// The last part is the one that matters: five things happen in order and the user has to know
    /// which of them already did.
    private func failed(_ failure: RepositoryStartFailure) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Callout(text: failure.message, symbol: "exclamationmark.triangle.fill", tone: .negative)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("What the folder is now")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text(failure.state)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        }
    }

    private func finished(_ outcome: RepositoryStartOutcome) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            LabeledLine(
                label: "Branch",
                value: "\(outcome.branch), \(outcome.committedFiles.formatted()) "
                    + (outcome.committedFiles == 1 ? "file committed" : "files committed")
            )
            if let page = outcome.page {
                LabeledLine(label: "GitHub", value: page)
            }
            if !outcome.excluded.isEmpty {
                LabeledLine(
                    label: "Kept out",
                    value: outcome.excluded.map(\.path).joined(separator: ", ")
                        + ". They are in .gitignore, and still on disk."
                )
            }
            if outcome.commitWasUnsigned {
                Callout(
                    text: "Your git is set to sign commits and the signing failed, so the first "
                        + "commit was made without a signature.",
                    symbol: "signature",
                    tone: .warning
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Metrics.spacingWide) {
            Spacer(minLength: 0)

            switch phase {
            case .choosing:
                Button("Cancel", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.controlAccent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)

            case .working:
                // Enabled, and carrying Escape, which is the whole fix. It was a disabled Cancel
                // that did nothing, and there was no other way out of the sheet.
                Button("Stop", role: .cancel) { stop() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isStopping)

            case .stopped(let left):
                if left.isUsableProject {
                    Button("Add the project anyway") { onFinish(request.path) }
                }
                Button("Close", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Try again") { phase = .choosing }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.controlAccent)
                    .keyboardShortcut(.defaultAction)

            case .failed(let failure):
                if failure.isUsableProject {
                    // The half that worked still stands. The folder is a repository with a commit
                    // in it, so it is a project Bloom can run, and refusing to add it over a
                    // GitHub failure would throw away work that succeeded.
                    Button("Add the project anyway") { onFinish(request.path) }
                }
                if failure.step >= .createRemoteRepository {
                    // The local half stands, so going back is a way to change the name after
                    // GitHub said it was taken. Running again skips whatever already worked: the
                    // commit is detected, and so is an origin that was already added.
                    Button("Back") { phase = .choosing }
                }
                Button("Close", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Try again") { start(resuming: failure.completed) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.controlAccent)
                    .keyboardShortcut(.defaultAction)

            case .finished(let outcome):
                if let page = outcome.page {
                    Button("Open on GitHub") { GitHubBridge.open(page) }
                }
                Button("Add project") { onFinish(request.path) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.controlAccent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
    }

    private var primaryTitle: String {
        choice == .local ? "Create Repository" : "Create and Push"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var destination: RepositoryDestination {
        choice == .local
            ? .local
            : .gitHub(owner: owner, name: trimmedName, isPrivate: true)
    }

    private var canStart: Bool {
        guard request.identityProblem == nil else { return false }
        guard choice == .gitHub else { return true }
        guard access == .ready, !owner.isEmpty else { return false }
        guard GitHubRepositoryName.isValid(trimmedName) else { return false }
        // A check that is still running or that failed does not hold the button. Only a name
        // GitHub has said is taken does.
        return !availability.blocksCreation
    }

    // MARK: - Work

    private func probeGitHub() async {
        access = await GitHubAvailability.shared.check()
        guard access == .ready else { return }
        guard owners.isEmpty else { return }

        isLoadingOwners = true
        defer { isLoadingOwners = false }
        guard let found = try? await GitHub.owners(), !found.isEmpty else { return }
        owners = found
        if owner.isEmpty { owner = found[0].login }
        if choice == .gitHub { scheduleAvailabilityCheck() }
    }

    /// Debounced, and the one in flight is cancelled before another starts. Without both, typing a
    /// twelve character name is twelve requests whose answers arrive in whatever order the network
    /// felt like, and the last one to land wins.
    private func scheduleAvailabilityCheck() {
        availabilityCheck?.cancel()

        let candidate = trimmedName
        let account = owner
        guard choice == .gitHub, access == .ready, !account.isEmpty,
              GitHubRepositoryName.isValid(candidate) else {
            availability = .idle
            return
        }

        availability = .checking
        availabilityCheck = Task {
            try? await Task.sleep(for: Self.availabilityDelay)
            guard !Task.isCancelled else { return }
            let answer = await GitHub.repositoryAvailability(owner: account, name: candidate)
            guard !Task.isCancelled else { return }
            // The field may have moved on while the request was out.
            guard candidate == trimmedName, account == owner else { return }
            availability = answer
        }
    }

    private func start(resuming completed: Set<RepositoryStartStep> = []) {
        let target = destination
        isStepSlow = false
        phase = .working(RepositoryStartStep.steps(for: target).first ?? .initialise)

        startTask?.cancel()
        startTask = Task {
            do {
                let outcome = try await RepositoryStarter.start(
                    at: request.path,
                    destination: target,
                    completed: completed
                ) { step in
                    phase = .working(step)
                }
                // A stopped run's git is killed mid command, so it comes back here as a failure a
                // moment after `stop` has already worked out what the folder is. Whichever of the
                // two writes second wins, so the cancelled one writes nothing.
                guard !Task.isCancelled else { return }
                // Nothing worth reporting means nothing worth a second click. A plain local
                // repository with no exclusions is finished the moment it is finished.
                if target.isGitHub || !outcome.excluded.isEmpty || outcome.commitWasUnsigned {
                    phase = .finished(outcome)
                } else {
                    onFinish(request.path)
                }
            } catch let failure as RepositoryStartFailure {
                guard !Task.isCancelled else { return }
                phase = .failed(failure)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(RepositoryStartFailure(
                    step: .initialise,
                    // Not `readableMessage`, which is the argv and the exit status for a
                    // `ShellError`. Nothing reaches here today, because the typed catch above
                    // takes every path that exists, but this is the modal it would leak into.
                    message: RepositoryStarter.sentence(from: error),
                    completed: completed,
                    destination: target
                ))
            }
        }
    }

    /// Abandons the run, and puts the folder back to something honest.
    ///
    /// Cancelling reaches the subprocess: `Shell.run` terminates the command it is waiting on, so
    /// the hung `git commit` really does go away rather than being orphaned. What is left behind
    /// is then worked out and, where Bloom made it, undone. See `RepositoryStarter.abandon`.
    private func stop() {
        startTask?.cancel()
        startTask = nil
        isStopping = true
        Task {
            let left = await RepositoryStarter.abandon(at: request.path)
            isStopping = false
            isStepSlow = false
            phase = .stopped(left)
        }
    }
}

// MARK: - Small parts

/// A label and a value on one line, wrapping under the label rather than beside it.
private struct LabeledLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Text(label)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
