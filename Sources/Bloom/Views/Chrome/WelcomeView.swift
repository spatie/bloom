import AppKit
import SwiftUI
import BloomCore

/// What the welcome window draws.
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
    /// The row whose fix is open. One at a time: two open commands is a wall of code where there
    /// should be a next step.
    @State private var expanded: SetupTool?
    @State private var copied: SetupTool?
    /// The login running inside this window, and which row asked for it.
    @State private var login: (tool: SetupTool, session: GitHubLoginSession)?

    /// Wide enough for `npm install -g @anthropic-ai/claude-code` to sit on one line in the mono
    /// face, which is the longest command this window can ever show, and no wider. A command that
    /// wrapped would be a command somebody copies wrong by hand.
    private static let width: CGFloat = 520
    private static let markSize: CGFloat = 64
    /// The gutter the glyphs and the sounding line share.
    private static let gutter: CGFloat = 26

    private var report: SetupReport { inspection.shown }

    var body: some View {
        VStack(spacing: 0) {
            plinth
            hairline
            body(report)
            hairline
            footer
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .onAppear {
            inspection.revealsInstantly = reduceMotion
            inspection.start()
        }
        .onDisappear {
            login?.session.stop()
            inspection.cancel()
        }
    }

    private var hairline: some View {
        Rectangle().fill(Palette.border).frame(height: Metrics.hairline)
    }

    // MARK: - The plinth

    /// The About window's plinth at this window's scale. Same gradient, same water, same wordmark
    /// face, and the mark read out of the running bundle rather than shipped again.
    private var plinth: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.markSize, height: Self.markSize)
                .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
                .accessibilityHidden(true)

            Text(verbatim: "Welcome to Bloom")
                .font(.system(size: 30, weight: .light, design: .serif))
                .tracking(-0.6)
                .foregroundStyle(Brand.foam)
                .padding(.top, Metrics.spacingWide + Metrics.spacingSmall)

            Text("A worktree, an agent and a branch for every task you describe")
                .font(Typo.codeTiny)
                .foregroundStyle(Brand.mistDim)
                .multilineTextAlignment(.center)
                .padding(.top, Metrics.spacing)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
        .padding(.bottom, 24)
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
                .font(Typo.label)
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

                    status(check, severity: severity)
                }

                // The sentence only appears on a row that has something to say. A tick with a
                // paragraph under it explaining what git is for would be four paragraphs on the
                // machine where nothing is wrong, which is most machines.
                if severity != .ok, check.outcome.isSettled {
                    Text(check.tool.purpose)
                        .font(Typo.caption)
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
    private func status(_ check: SetupCheck, severity: SetupSeverity) -> some View {
        Group {
            switch check.outcome {
            case .pending:
                Text("Checking")
                    .foregroundStyle(Palette.textTertiary)
            case .ready(let detail):
                Text(detail ?? "Ready")
                    .foregroundStyle(Palette.textTertiary)
            case .needsSignIn:
                Text("Not signed in")
                    .foregroundStyle(severity == .problem ? Palette.warning : Palette.textTertiary)
            case .missing:
                Text(severity == .ok ? "Not installed" : optionalWord(check, severity: severity))
                    .foregroundStyle(severity == .problem ? Palette.warning : Palette.textTertiary)
            }
        }
        .font(Typo.codeSmall)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// What a missing tool is called on the right of its row. "Optional" rather than "Not
    /// installed" for the ones Bloom does not need, because the fact worth reading first is not
    /// that it is absent, it is that its absence does not matter.
    private func optionalWord(_ check: SetupCheck, severity: SetupSeverity) -> String {
        severity == .note ? "Optional, not installed" : "Not installed"
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
        case .needsSignIn, .missing:
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
        if let running = login, running.tool == check.tool {
            loginTerminal(check, session: running.session)
        } else {
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
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                    } else {
                        Button(isOpen ? "Hide the command" : fix.summary) {
                            withAnimation(reduceMotion ? nil : Motion.pane) {
                                expanded = isOpen ? nil : check.tool
                            }
                        }
                        .controlSize(.small)
                    }

                    if let url = fix.url {
                        // The app's teal rather than the system accent, which is what a bare
                        // `Link` draws and what would have put a blue word three inches from the
                        // teal one in the footer. See `linkButton()`, which fixes the same thing
                        // for controls.
                        Link("Instructions", destination: url)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.link)
                    }

                    Spacer(minLength: 0)
                }

                if isOpen, let command = fix.command {
                    commandLine(check, command: command)
                }
            }
        }
    }

    /// The command, in the mono face, with the one button that matters beside it.
    private func commandLine(_ check: SetupCheck, command: String) -> some View {
        HStack(spacing: Metrics.spacingWide) {
            Text(command)
                .font(Typo.codeSmall)
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
            .font(Typo.caption)
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
                Text("Running \(session.label)")
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("Stop", systemImage: "xmark") { stopLogin() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .help("Stop and close")
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
            if inspection.truth.verdict == .blocked {
                Button("Skip for now") { finish() }
                    .buttonStyle(.plain)
                    .font(Typo.label)
                    .foregroundStyle(Palette.link)
            } else {
                Button("Check again") { inspection.start() }
                    .buttonStyle(.plain)
                    .font(Typo.label)
                    .foregroundStyle(inspection.isRunning ? Palette.textTertiary : Palette.link)
                    .disabled(inspection.isRunning)
            }

            Spacer(minLength: Metrics.inset)

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
