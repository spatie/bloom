import SwiftUI
import BloomCore

/// Starting a project that is not a repository yet: a name, a place to put it, and a button.
///
/// The sheet beside this one, `ProjectSetupSheet`, is what happens to a folder that already
/// exists. This one is for the person who has an idea and nothing else, and it is the smaller of
/// the two on purpose: everything after the button press is `NewProjectStarter`, which is
/// `RepositoryStarter` with a `mkdir` in front of it. Only two things here cannot be worked out,
/// and they are the two fields. Everything else is stated rather than asked.
///
/// **Every decision it draws is in `NewProjectPlan`.** Where the location field opens, what the
/// line under it says, whether Create Project can be pressed and what the refusal reads like: all
/// four are pure functions with tests, because the first of them reads the owner's own disk layout
/// and a location default is exactly the kind of thing that looks right on the machine it was
/// written on.
///
/// **No GitHub half, and that is the one thing it deliberately does less of than its neighbour.**
/// Publishing an empty repository claims a name in somebody's account for a thing that may not
/// exist next week, and `RepositoryStarter.abandon` will not delete one once it does. Publishing
/// belongs on a project that has something in it, and the machinery for it is already written.
struct NewProjectSheet: View {
    /// Called with the folder once it is a repository Bloom can add, and with nil when the person
    /// backed out.
    let onFinish: (String?) -> Void

    @Environment(AppModel.self) private var app

    private enum Phase: Equatable {
        case naming
        case working(RepositoryStartStep)
        case failed(NewProjectFailure)
    }

    @State private var name = ""
    @State private var location = ""
    @State private var facts = NewProjectFacts()
    @State private var phase: Phase = .naming
    /// What the first commit's branch will be. Read from git rather than asserted, because a
    /// machine with `init.defaultBranch` set gets its own answer. See `NewProjectStarter`.
    @State private var branch = "main"
    /// Set when git on this Mac has no name or address configured, in which case no commit can be
    /// made and the button is held before anything is written rather than half way through it.
    @State private var identityProblem: String?
    @State private var createTask: Task<Void, Never>?
    @State private var isStepSlow = false
    @FocusState private var isNameFocused: Bool

    private static let width: CGFloat = 560
    /// Long enough that typing a name costs one walk of the file system rather than one per
    /// character, short enough that the line under the field answers while the eye is still on it.
    private static let inspectionDelay = Duration.milliseconds(150)

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private var verdict: NewProjectVerdict { NewProjectVerdict.of(facts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            // Not a ScrollView, for the reason `ProjectSetupSheet` gives: one takes every point it
            // is offered, and this sheet is as tall as the four things in it.
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
            if location.isEmpty {
                location = NewProjectPlan.display(
                    NewProjectPlan.suggestedLocation(projectPaths: app.repos.map(\.path), home: home),
                    home: home
                )
            }
            isNameFocused = true
        }
        .task {
            branch = await NewProjectStarter.plannedBranch()
            identityProblem = await RepositoryStarter.identityProblem(at: home)
        }
        // Re-asked after a pause rather than on every keystroke: this walks up the tree looking
        // for a `.git` and reads a directory, which is cheap once and rude sixty times.
        .task(id: Draft(name: name, location: location)) {
            try? await Task.sleep(for: Self.inspectionDelay)
            guard !Task.isCancelled else { return }
            let typedName = name
            let typedLocation = location
            let found = await Task.detached {
                NewProjectStarter.inspect(name: typedName, location: typedLocation)
            }.value
            guard !Task.isCancelled else { return }
            facts = found
        }
        .onDisappear {
            // Not a stop: the sheet only leaves the screen by a path that has finished with the
            // run. What this covers is the window closing under it.
            createTask?.cancel()
        }
    }

    /// What the inspection is keyed on. The two fields together, so a change to either re-asks and
    /// neither cancels the other's answer.
    private struct Draft: Equatable {
        var name: String
        var location: String
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
                Text("a folder, a repository in it, and a project in the sidebar")
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
        case .naming: "New project"
        case .working: "Creating \(NewProjectPlan.folderName(from: name))"
        case .failed(let failure): failure.title
        }
    }

    // MARK: - The two questions

    @ViewBuilder
    private var form: some View {
        Text(
            "Bloom makes the folder, turns it into a git repository and adds it. "
                + "Nothing leaves this Mac."
        )
        .font(Typo.body)
        .foregroundStyle(Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        if let identityProblem {
            Callout(text: identityProblem, symbol: "exclamationmark.triangle.fill", tone: .warning)
        }

        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Text("Name")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)
        }

        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Text("Location")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: Metrics.spacingWide) {
                TextField("Location", text: $location)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.code)
                    .onSubmit(create)
                Button("Choose\u{2026}", action: chooseLocation)
            }
            hint
        }

        firstCommit
    }

    /// The line under the location field: the whole path, and then what Bloom will do to it.
    ///
    /// It is the only thing on this sheet that is about to be written to disk, and it is the one
    /// thing a sentence typed into a chat can never show. Silent while the name field is still
    /// empty, because telling somebody to give the project a name before they have typed a letter
    /// is scolding them for reading the label.
    @ViewBuilder
    private var hint: some View {
        if NewProjectPlan.folderName(from: name).isEmpty {
            // Held open, so the sheet does not jump the moment the first character lands.
            Text(" ").font(Typo.micro)
        } else {
            let line = verdict.hint(path: facts.path, home: home)
            switch verdict {
            case .create, .adopt:
                Text(line)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .refuse:
                Label(line, systemImage: "exclamationmark.circle.fill")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the first commit holds, said before it is made. The whole content of it is that Bloom
    /// wrote none of it: a language-guessed `.gitignore` or a generated README is a guess that is
    /// wrong for ever in a history nobody rewrites, and the agent about to start is a better
    /// scaffolder than a menu because it explains itself in a diff.
    private var firstCommit: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Text("First commit")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(
                "Empty, on \(branch). Bloom writes no files of its own: no README, no .gitignore. "
                    + "The first thing in the history will be something you or an agent put there."
            )
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
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
            Spacer(minLength: 0)

            switch phase {
            case .naming:
                Button("Cancel", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Create Project", action: create)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)

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

    private var canCreate: Bool {
        identityProblem == nil && verdict.allowsCreation
    }

    // MARK: - Work

    private func chooseLocation() {
        Task {
            guard let chosen = await ProjectFolderPicker.chooseLocation(
                startingAt: facts.path.isEmpty ? nil : (facts.path as NSString).deletingLastPathComponent
            ) else { return }
            location = NewProjectPlan.display(chosen, home: home)
        }
    }

    private func create() {
        guard identityProblem == nil else { return }
        // Asked again here, from what is typed at this instant. The line under the field is a
        // beat behind the keyboard on purpose, and Return is faster than that beat: without this,
        // typing a name and pressing Return in one movement pressed a button that was still
        // looking at the empty field. It is a handful of stats, once, on a key press.
        let current = NewProjectStarter.inspect(name: name, location: location)
        facts = current
        guard NewProjectVerdict.of(current).allowsCreation, !current.path.isEmpty else { return }

        let target = current.path
        isStepSlow = false
        phase = .working(.initialise)

        createTask?.cancel()
        createTask = Task {
            do {
                let creation = try await NewProjectStarter.create(at: target) { step in
                    phase = .working(step)
                }
                guard !Task.isCancelled else { return }
                onFinish(creation.path)
            } catch let failure as NewProjectFailure {
                guard !Task.isCancelled else { return }
                phase = .failed(failure)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(NewProjectFailure(
                    title: "Could not create the project",
                    message: RepositoryStarter.sentence(from: error),
                    folderWasCreated: false
                ))
            }
        }
    }

    /// Stopping reaches the subprocess: `Shell.run` terminates the command it is waiting on, so a
    /// hung `git commit` really does go away. What Bloom made is then taken back off the disk, and
    /// what it did not make is left exactly where it was. See `NewProjectStarter.discard`.
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
