import AppKit
import SwiftUI
import BloomCore

/// What the welcome window draws.
///
/// Two steps, and the sequence is `OnboardingFlow` in the core rather than a boolean here,
/// because which screen follows which and whether back is offered is the only part of a wizard
/// that can be wrong and a decision taken inside a view is a decision nothing can test. The
/// greeting is `WelcomeGreeting`; everything below is the second step.
///
/// Three bands, in the register the About window established: the brand's plinth with the water
/// moving in it, the reading ground under a hairline, and a chrome strip at the foot with the
/// buttons in it. Nothing here is a new surface and nothing here is a new colour; the only thing
/// this window adds to the app's vocabulary is the line down the left of the checks, and that line
/// is carrying information rather than decorating the column. See `soundingLine`.
struct WelcomeView: View {
    let inspection: SetupInspection
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow: OnboardingFlow
    /// The row whose fix is open. One at a time: two open commands is a wall of code where there
    /// should be a next step.
    @State private var expanded: SetupTool?
    @State private var copied: SetupTool?
    /// The login running inside this window, and which row asked for it.
    @State private var login: (tool: SetupTool, session: GitHubLoginSession)?

    init(inspection: SetupInspection, start: OnboardingStep, onFinish: @escaping () -> Void) {
        self.inspection = inspection
        self.onFinish = onFinish
        _flow = State(initialValue: OnboardingFlow(step: start))
    }

    /// Wide enough for `npm install -g @anthropic-ai/claude-code` to sit on one line in the mono
    /// face, which is the longest command this window can ever show, and no wider. A command that
    /// wrapped would be a command somebody copies wrong by hand.
    private static let width: CGFloat = 520
    private static let markSize: CGFloat = 64
    /// The gutter the glyphs and the sounding line share.
    private static let gutter: CGFloat = 26

    private var report: SetupReport { inspection.shown }

    var body: some View {
        Group {
            switch flow.step {
            case .greeting:
                WelcomeGreeting(
                    isFirstVisit: flow.isFirstVisit(to: .greeting),
                    onContinue: { move { flow.advance() } }
                )
            case .checks:
                checksStep
            }
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .onAppear {
            inspection.revealsInstantly = reduceMotion
            // Started here rather than on the checks step, so four subprocesses are already
            // running while somebody reads the greeting and nobody ever waits for them. The
            // model holds the ROWS back until the checks are on screen; see `presentChecks`.
            inspection.start()
        }
        .onDisappear {
            login?.session.stop()
            inspection.cancel()
        }
    }

    /// One move through the sequence, drawn as a crossfade.
    ///
    /// Opacity and nothing else. Two screens sliding past each other would be a slideshow, and
    /// what is wanted is the plinth growing into the window and shrinking back out of it, which
    /// is what a crossfade between a full bleed plinth and a band at the top already reads as.
    private func move(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : Motion.pane) { change() }
    }

    private var checksStep: some View {
        VStack(spacing: 0) {
            plinth
            hairline
            body(report)
            hairline
            footer
        }
        .transition(reduceMotion ? .identity : .opacity)
        .onAppear { inspection.presentChecks() }
        .onDisappear { inspection.dismissChecks() }
    }

    private var hairline: some View {
        Rectangle().fill(Palette.border).frame(height: Metrics.hairline)
    }

    // MARK: - The plinth

    /// The greeting's plinth, compressed into a band. Same gradient, same water, same wordmark
    /// face, and the mark read out of the running bundle rather than shipped again.
    ///
    /// The line about worktrees and agents is not repeated here. It is the greeting's line, it has
    /// just been read, and a window that says the same sentence on two screens running is a window
    /// that was not designed as two screens. What is left is the mark and the name, which is what
    /// makes this band read as the screen before it, pushed up out of the way.
    private var plinth: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.markSize, height: Self.markSize)
                .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
                .accessibilityHidden(true)

            Text(verbatim: "Welcome to Bloom")
                .font(.system(size: 26, weight: .light, design: .serif))
                .tracking(-0.6)
                .foregroundStyle(Brand.foam)
                .padding(.top, Metrics.spacingWide + Metrics.spacingSmall)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .padding(.horizontal, Metrics.pane)
        .background {
            ZStack {
                Brand.depth
                BrandWater()
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - The reading ground

    private func body(_ report: SetupReport) -> some View {
        VStack(alignment: .leading, spacing: Metrics.pane - Metrics.spacingSmall) {
            verdict(report)
            checks(report)
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The headline and the sentence, which change once as the last row settles.
    ///
    /// Keyed on the verdict and crossfaded rather than simply re-rendered, so "Looking around"
    /// becomes "You are all set" as one movement. That transition is the window's one orchestrated
    /// moment and it is where the whole thing either reads as a welcome or reads as a form.
    private func verdict(_ report: SetupReport) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(report.headline)
                .font(.system(size: 19, weight: .medium, design: .serif))
                .foregroundStyle(Palette.textPrimary)

            Text(report.sentence)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(report.verdict)
        .transition(reduceMotion ? .identity : .opacity)
        .animation(reduceMotion ? nil : Motion.arrival, value: report.verdict)
    }

    private func checks(_ report: SetupReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(report.checks.enumerated()), id: \.element.id) { position, check in
                row(check, in: report, isLast: position == report.checks.count - 1)
            }
        }
    }

    // MARK: - One check

    private func row(_ check: SetupCheck, in report: SetupReport, isLast: Bool) -> some View {
        let severity = report.severity(for: check.tool)
        // A row that is in the way shows its command without being asked, and a row that is only
        // a note keeps it behind the button. That is proportional rather than uniform: the thing
        // stopping you gets the whole answer on the first frame, and the thing that costs you
        // nothing does not put a wall of shell in front of somebody who was fine.
        let isOpen = expanded == check.tool || severity == .problem

        return HStack(alignment: .top, spacing: Metrics.spacingWide + Metrics.spacingTight) {
            soundingLine(check, severity: severity, isLast: isLast)

            VStack(alignment: .leading, spacing: Metrics.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
                    Text(check.tool.title)
                        .font(Typo.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)

                    Spacer(minLength: Metrics.spacingWide)

                    status(check, in: report, severity: severity)
                }

                // The login is the row while it is up, and it is drawn from `login` rather than
                // from the outcome, which is what stops it being yanked away.
                //
                // The bug this fixes: a login exiting starts a fresh probe, a fresh probe puts
                // every row back to pending, and pending failed the settled test below, so the
                // terminal was torn out of the window on the frame the command finished. If the
                // login had failed, the reason it failed went with it. A second later the rows
                // settled, the row still said not signed in, and the same dead terminal came back
                // by itself with a header still claiming to be running it. Nothing here waits for
                // the probe now: the terminal stays where it is, with its output, until somebody
                // presses the way out of it.
                if let running = login, running.tool == check.tool {
                    loginTerminal(check, session: running.session)
                } else if severity != .ok, check.outcome.isSettled {
                    Text(check.tool.purpose)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let fix = check.fix {
                        fixStrip(check, fix: fix, severity: severity, isOpen: isOpen)
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : Metrics.gutter + Metrics.spacingSmall)
        }
        .contentShape(.rect)
    }

    /// The status on the right of a row's first line.
    ///
    /// One line, always, and never a sentence: an account, a version, or the shortest true words
    /// for the state. The account comes out of `AgentCatalog`, which has already decided what may
    /// be shown from a file holding a live token.
    private func status(_ check: SetupCheck, in report: SetupReport, severity: SetupSeverity) -> some View {
        Group {
            switch check.outcome {
            case .pending:
                Text("Checking")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
            case .ready(let detail):
                // The one place in the column that is monospaced, because it is the one place
                // holding something the machine said: a version, or the account a CLI is signed
                // in as. Every other cell here is English, and English set in mono reads as data
                // rather than as a state, which is what "Not signed in" used to look like.
                Text(detail ?? "Ready")
                    .font(detail == nil ? Typo.label : Typo.code)
                    .foregroundStyle(Palette.textTertiary)
            case .needsSignIn:
                Text(stateWord("Not signed in", in: report, severity: severity))
                    .font(Typo.label)
                    .foregroundStyle(severity == .problem ? Palette.warning : Palette.textTertiary)
            case .missing:
                Text(stateWord("Not installed", in: report, severity: severity))
                    .font(Typo.label)
                    .foregroundStyle(severity == .problem ? Palette.warning : Palette.textTertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// What a tool that is not set up is called on the right of its row.
    ///
    /// "Optional" first, and on both of the two ways a tool can be not set up rather than only on
    /// the missing one. The fact worth reading first about a tool Bloom does not need is not that
    /// it is absent, it is that its absence does not matter, and a GitHub CLI that was installed
    /// but signed out used to be the one optional state that never said so.
    ///
    /// Only once the list has finished settling, which is a guard rather than a nicety. A missing
    /// agent is a note while the OTHER agent row is still being looked at, so a machine with
    /// neither Claude Code nor Codex called Claude Code optional for the frame between the two
    /// rows being revealed. Nothing is called optional until the column knows.
    private func stateWord(_ state: String, in report: SetupReport, severity: SetupSeverity) -> String {
        severity == .note && report.isSettled ? "Optional, \(state.lowercased())" : state
    }

    // MARK: - The sounding line

    /// The glyph, and the hairline running down from it to the next row.
    ///
    /// The line is the one thing this window invents, and it is not a decoration: it is the
    /// column being read. It is drawn in the accent as far as the checks have settled and in the
    /// border colour below that, so a glance at the left edge says how far down the list Bloom has
    /// got without anybody reading a word. That is why the rows are revealed in order rather than
    /// in the order four subprocesses happen to exit: the line only means something if it descends.
    private func soundingLine(_ check: SetupCheck, severity: SetupSeverity, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            glyph(check, severity: severity)
                // The glyph's own size and no more, so the hairline under it is the longer of the
                // two and the column reads as a line with marks on it rather than as marks with
                // ticks between them.
                .frame(width: Self.gutter, height: 17)

            if !isLast {
                Rectangle()
                    .fill(check.outcome.isSettled ? Palette.accent.opacity(0.35) : Palette.border)
                    .frame(width: Metrics.hairline)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: Self.gutter, alignment: .top)
        // Top, not centre. Without the alignment the last row, which has no hairline under it,
        // centred its glyph in the whole row and sat visibly lower than the three above it.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func glyph(_ check: SetupCheck, severity: SetupSeverity) -> some View {
        switch check.outcome {
        case .pending:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.accent)
                .font(.system(size: 15))
                // Only the arrival, and only in scale. A tick that spun or bounced would be
                // announcing itself on a window whose whole argument is that nothing is wrong.
                .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
        // A lock rather than the dotted ring the missing rows carry, and the whole reason this
        // case is drawn separately. Signed out and not installed are different problems with
        // different commands behind them, and they used to share one glyph and one colour, so an
        // optional tool that was merely signed out and an optional tool that was not there at all
        // were the same mark in the same grey. A lock says the thing is here and closed.
        case .needsSignIn:
            Image(systemName: severity == .problem ? "lock.circle.fill" : "lock.circle")
                .foregroundStyle(severity == .problem ? Palette.warning : Palette.textTertiary)
                .font(.system(size: 15))
                .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
        case .missing:
            // Filled is the rule for a row that is in the way, on this case and on the one above,
            // so weight carries the severity down the column and shape carries the state.
            Image(systemName: severity == .problem ? "exclamationmark.circle.fill" : "circle.dotted")
                .foregroundStyle(severity == .problem ? Palette.warning : Palette.textTertiary)
                .font(.system(size: 15))
                .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
        }
    }

    // MARK: - The fix

    /// What to do about a row, in the smallest honest form.
    ///
    /// Two shapes, and which one appears is decided by the command rather than by taste. A command
    /// that asks questions back runs here, in a real pty, because that is the only way the CLI's
    /// own one-time code is legible and the only way somebody can answer it where they are already
    /// looking. A command that does not ask anything is shown verbatim with a copy button and a
    /// Check again, because Bloom cannot install Homebrew packages on somebody's behalf and
    /// pretending otherwise would be worse than the extra step.
    @ViewBuilder
    private func fixStrip(
        _ check: SetupCheck,
        fix: SetupFix,
        severity: SetupSeverity,
        isOpen: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            HStack(spacing: Metrics.inset) {
                if fix.isInteractive {
                    Button(fix.summary) { startLogin(check, fix: fix) }
                        .controlSize(.small)
                } else if severity == .problem {
                    // The command is already below, so there is nothing left for a button to
                    // reveal. What is left is the sentence naming what the command does, which
                    // is worth more as a label than as a control that does nothing new.
                    Text(fix.summary)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    // Not `fix.summary`, which is the imperative for the command itself.
                    // Nothing is installed by pressing this: it reveals the line to run, and a
                    // button reading "Install the GitHub CLI" that produced a shell command was
                    // the same failure "Check my Mac" was flagged for.
                    Button(isOpen ? "Hide the install command" : "Show the install command") {
                        withAnimation(reduceMotion ? nil : Motion.pane) {
                            expanded = isOpen ? nil : check.tool
                        }
                    }
                    .controlSize(.small)
                }

                if let url = fix.url {
                    // The app's teal rather than the system accent, which is what a bare `Link`
                    // draws and what would have put a blue word three inches from the teal one in
                    // the footer. See `linkButton()`, which fixes the same thing for controls.
                    Link("Instructions", destination: url)
                        .font(Typo.label)
                        .foregroundStyle(Palette.link)
                }

                Spacer(minLength: 0)
            }

            if isOpen, let command = fix.command {
                commandLine(check, command: command)
            }
        }
    }

    /// The command, in the mono face, with the one button that matters beside it.
    private func commandLine(_ check: SetupCheck, command: String) -> some View {
        HStack(spacing: Metrics.spacingWide) {
            Text(command)
                .font(Typo.code)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Metrics.spacing)

            Button(copied == check.tool ? "Copied" : "Copy") {
                Clipboard.copy(command)
                copied = check.tool
                Task {
                    try? await Task.sleep(for: Clipboard.flashDuration)
                    if copied == check.tool { copied = nil }
                }
            }
            .buttonStyle(.plain)
            .font(Typo.label)
            .foregroundStyle(Palette.link)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner).strokeBorder(Palette.border)
        )
        .transition(reduceMotion ? .identity : .opacity)
    }

    /// The login, running here. Nothing reads what scrolls past: the CLI is talking to the person
    /// in front of it, and the one-time code on screen is its output, never Bloom's to store, log
    /// or copy. See `GitHubSignInSheet`, which is where this pattern is argued out at length.
    private func loginTerminal(_ check: SetupCheck, session: GitHubLoginSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.spacingWide) {
                // Present tense only while it is true. This used to say "Running gh auth login"
                // over a terminal whose command had exited minutes ago, which is the window
                // lying about the one thing on it that was moving.
                Text(session.isRunning ? "Running \(session.label)" : "\(session.label) finished")
                    .font(Typo.code)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // A named way out, not a cross.
                //
                // The cross was the only control on this strip, and a cross reads as kill: the
                // one thing somebody who had wandered into a login and wanted out was least
                // likely to press. It is a back button, so it says so and points the way it goes.
                // Pressing it kills the child first and then drops the strip, in that order, so a
                // half finished `gh auth login` is never left waiting on a pty nobody can see.
                Button("Back to the checks", systemImage: "chevron.left") { stopLogin() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(Typo.label)
                    .foregroundStyle(Palette.link)
                    .help(session.isRunning ? "Stop this and go back to the list" : "Go back to the list")
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.barHeight)
            .background(Palette.surfaceSunken)

            Hairline()

            GitHubLoginTerminal(session: session)
                .frame(height: 220)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner).strokeBorder(Palette.border))
    }

    private func startLogin(_ check: SetupCheck, fix: SetupFix) {
        stopLogin()
        // The command as it is shown, split the way a shell would split it, so the string in the
        // copy button and the string that runs are the same string. `claude /login` is a program
        // and a slash command, `gh auth login` is a program and two words, and neither has an
        // argument that could hold a space.
        let parts = (fix.command ?? "").split(separator: " ").map(String.init)
        guard let executable = parts.first else { return }
        guard let session = GitHubLoginSession(
            executable: executable,
            arguments: Array(parts.dropFirst()),
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            onExit: { _ in
                // Whatever it exited with, ask the machine rather than the exit status. A CLI that
                // returns zero because the user pressed Escape at its first question has not
                // signed anybody in, and the probe is the only thing that actually knows.
                Task { @MainActor in
                    inspection.start()
                }
            }
        ) else { return }
        login = (check.tool, session)
    }

    private func stopLogin() {
        login?.session.stop()
        login = nil
    }

    // MARK: - The foot

    /// One primary button that always works, and one quiet way out beside it.
    ///
    /// The primary is never disabled and never waits for the settling: `inspection.truth` is what
    /// titles it, so a machine that has already answered can be left the instant its owner wants
    /// to leave, whatever the rows are still doing. Making somebody watch an animation they did
    /// not ask for is the trap this whole window is one step away from.
    private var footer: some View {
        HStack(spacing: Metrics.inset) {
            if let title = flow.backButtonTitle {
                // Bottom left, which is where a Mac setup assistant has put Go Back since there
                // were setup assistants. It is drawn quietly and it never carries the return key:
                // the one thing the keyboard does on this screen is the primary button, and a
                // wizard where Return walks backwards is a wizard nobody can get out of.
                //
                // It stops a running login on the way out rather than leaving it behind. Walking
                // off this step would otherwise leave a `gh auth login` waiting on a pty with
                // nothing on screen, which is the orphan `GitHubLoginSession.stop` exists to
                // prevent, and it would be waiting for an answer nobody could give it.
                Button(title, systemImage: "chevron.left") { move { stopLogin(); flow.goBack() } }
                    .buttonStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(Palette.link)
            }

            Spacer(minLength: Metrics.inset)

            // The two quiet controls are at opposite ends rather than side by side. Back and
            // Check again next to each other read as one pair of links and neither of them said
            // which way it went; back belongs with the way out, and Check again belongs with the
            // button it is the alternative to.
            if inspection.truth.verdict == .blocked {
                Button("Skip for now") { finish() }
                    .buttonStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(Palette.link)
            } else {
                Button("Check again") { inspection.start() }
                    .buttonStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(inspection.isRunning ? Palette.textTertiary : Palette.link)
                    .disabled(inspection.isRunning)
            }

            Button(inspection.truth.primaryButtonTitle) {
                if inspection.truth.verdict == .blocked {
                    inspection.start()
                } else {
                    finish()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            // Bloom's own fill rather than whatever the user picked in Appearance, which is what
            // every other prominent button in the app already does. A system blue button two
            // inches under a teal wordmark is the one place this window could have looked like
            // somebody else's.
            .tint(Palette.accentFill)
            .controlSize(.large)
        }
        .padding(.horizontal, Metrics.pane)
        .padding(.vertical, Metrics.inset + Metrics.spacingSmall)
        .background(Palette.surfaceSunken)
    }

    private func finish() {
        stopLogin()
        WelcomeLaunch.recordCompletion()
        onFinish()
    }
}
