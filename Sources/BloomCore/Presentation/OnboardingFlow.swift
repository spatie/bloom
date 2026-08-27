import Foundation

/// The steps the welcome window walks through, and the rules for moving between them.
///
/// There are four, and the third one is not always there. The window used to be one screen that
/// opened straight onto four probes, which meant the first thing a new Bloom ever said to anybody
/// was a list of what their Mac might be missing. That reads as a form. A greeting first, then the
/// checks, is what turns the same two facts into a welcome, and it costs one press.
///
/// **The third step is an offer rather than a stage, and that is the whole reason `OnboardingFlow`
/// owns the sequence rather than this enum.** Bloom can be driven from the owner's own terminal by
/// running one `claude mcp add` command, and until it was offered here it lived in a settings pane
/// nobody browses. It is shown only when there is something to offer: this copy of Bloom has a
/// bridge, and the owner's user scope has not already been pointed at it. Somebody who ran the
/// command last week is not asked to run it again, and somebody who never wants it presses the
/// same button that ended the sequence before it existed.
public enum OnboardingStep: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    /// The mark, the name and one line saying what Bloom is. No information to act on.
    case greeting
    /// What this Mac already has, which is the window's other half.
    case checks
    /// The one command that couples the owner's own Claude Code to this Bloom. Optional, and
    /// omitted entirely when there is nothing to offer. See `OnboardingFlow.steps`.
    case commandLine
    /// The prompt anybody can send back to the people who build Bloom, which is the same sheet
    /// Help's Submit a Prompt raises and the same endpoint it posts to.
    ///
    /// Never left out, unlike the offer above it, because nothing about this Mac can make it
    /// empty: every build may send, the address is a constant, and there is no configuration to
    /// have already been done. So `isOptional` is false here and stays a statement about the
    /// list rather than about whether a reader has to do anything.
    case promptSubmission

    public var id: String { rawValue }

    /// Reading order. Which of these a given window actually walks is `OnboardingFlow.steps`,
    /// which is the same list with the optional step taken out when it has nothing to say.
    public static let order: [OnboardingStep] = [.greeting, .checks, .commandLine, .promptSubmission]

    /// True of a step the sequence may leave out. Nothing is lost by leaving it out: the offer is
    /// in Settings for the rest of the app's life, which is where somebody goes back for it.
    public var isOptional: Bool { self == .commandLine }

    /// What the button that opens this screen says, or nil for a screen nothing advances to.
    ///
    /// Named after the screen it opens rather than after the act of moving, which is why there is
    /// a table here at all: "Continue" would be true of every wizard ever shipped and would tell
    /// nobody what they are about to see.
    ///
    /// The checks entry said "Check my Mac", which named the object and left the act to the
    /// imagination, and on a screen that has just asked to look at somebody's machine the
    /// imagination fills that in badly: a hardware scan, a disk sweep, something rummaging. What
    /// it actually does is look down the PATH for four tools and ask two of them whether they are
    /// signed in, so the button names the screen it opens instead.
    ///
    /// The command line entry said "One more thing", and the words were about the position in the
    /// sequence rather than about the screen. The position moved: a screen after it makes a button
    /// promising to be the last one into a button that is not. It names the capability now, which
    /// is what the position wording was standing in for. Not "Connect your terminal", which is the
    /// same screen described as a job somebody has been given, and the one thing that step must
    /// not do is read as a job: Bloom works perfectly without it.
    ///
    /// The prompt entry is the sentence the screen leads with rather than the name of the sheet it
    /// ends at. "Submit a prompt" is what the button ON that screen says, because by then somebody
    /// has read what a prompt does here; arriving at a form nobody has been told the purpose of is
    /// how a menu item three menus deep goes unread in the first place.
    public var arrivalButtonTitle: String? {
        switch self {
        case .greeting: nil
        case .checks: "See what Bloom needs"
        case .commandLine: "Use Bloom from your terminal"
        case .promptSubmission: "Say what Bloom does next"
        }
    }
}

/// Where the window opens, how it moves, and which steps it has at all.
///
/// Two interesting rules. `firstStep` is where it opens: a first run gets the greeting, because
/// that is the whole reason the greeting exists and a warm second is what somebody who has just
/// double clicked a fresh app is owed. Every other way this window opens is somebody who has been
/// here before, so the Help menu and a later broken launch open on the checks; greeting them again
/// would be the app not remembering them. Back is still offered from there, so the greeting is
/// never a screen that has been taken away.
///
/// `steps` is which screens exist for this window at all, and it is a list rather than a constant
/// because the command line offer is only worth a screen when it has something to offer. Every
/// move walks that list, so a step that is not in it is not somewhere back can land either.
public struct OnboardingFlow: Sendable, Hashable {
    public private(set) var step: OnboardingStep
    /// Every step this window has shown, in the order it showed them. What makes back honest when
    /// the sequence did not start at the beginning.
    public private(set) var history: [OnboardingStep]
    /// Whether the optional command line step is part of this window's sequence. Answered by
    /// reading the owner's own configuration, which is a file on disk and therefore an answer that
    /// arrives after the window has opened. See `offerCommandLine`.
    public private(set) var offersCommandLine: Bool

    public init(step: OnboardingStep = .greeting, offersCommandLine: Bool = false) {
        self.step = step
        self.history = [step]
        self.offersCommandLine = offersCommandLine
    }

    /// Where a window opened by this trigger starts.
    public static func firstStep(trigger: OnboardingTrigger) -> OnboardingStep {
        switch trigger {
        case .firstRun: .greeting
        case .blocked, .none: .checks
        }
    }

    public static func opening(
        trigger: OnboardingTrigger,
        offersCommandLine: Bool = false
    ) -> OnboardingFlow {
        OnboardingFlow(step: firstStep(trigger: trigger), offersCommandLine: offersCommandLine)
    }

    /// The screens this window walks, in order.
    ///
    /// The step somebody is standing on is always in the list, whatever the offer says. Otherwise
    /// an answer arriving a moment late would take the screen out from under a reader, and the
    /// back control on it would point at a step the list no longer contains.
    public var steps: [OnboardingStep] {
        OnboardingStep.order.filter { !$0.isOptional || offersCommandLine || $0 == step }
    }

    /// Says whether the optional step is worth showing. Nothing else may change the sequence.
    public mutating func offerCommandLine(_ isOffered: Bool) {
        offersCommandLine = isOffered
    }

    private var position: Int { steps.firstIndex(of: step) ?? 0 }

    /// The step after this one, or nil at the end of the sequence. Nil is what says the primary
    /// button is the way out rather than the way on.
    public var next: OnboardingStep? {
        let walked = steps
        let after = (walked.firstIndex(of: step) ?? 0) + 1
        return after < walked.count ? walked[after] : nil
    }

    /// The step before this one, or nil at the start.
    ///
    /// Nil is what the view draws nothing for. A back control that is present and disabled on the
    /// first step is a promise of a screen that does not exist.
    public var back: OnboardingStep? {
        let before = position - 1
        return before >= 0 ? steps[before] : nil
    }

    public var canGoBack: Bool { back != nil }

    /// What the button that moves the sequence on says, or nil on a step that has no next.
    public var forwardButtonTitle: String? { next?.arrivalButtonTitle }

    /// What the control back to the previous step says.
    ///
    /// One word wherever it appears. It was a table naming the screen it returns to, which never
    /// held more than one entry and which said "Back" in it, and a table of one is a decision
    /// nobody took. What a back control needs to say is where it goes, and on a window this short
    /// where it goes is the screen you were just on.
    public var backButtonTitle: String? { canGoBack ? "Back" : nil }

    /// Moves on, if there is anywhere to move on to. Returns whether anything changed, so a view
    /// only animates a transition that happened.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let next else { return false }
        step = next
        history.append(next)
        return true
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let back else { return false }
        step = back
        history.append(back)
        return true
    }

    /// True the first time this window shows a step, which is the only time its entrance should
    /// play. Coming back to the greeting from the checks is a return, not an arrival, and
    /// replaying the whole opening sequence on a return is how a nice moment becomes a wait.
    public func isFirstVisit(to step: OnboardingStep) -> Bool {
        history.filter { $0 == step }.count <= 1
    }
}

// MARK: - The one button that is always on screen

/// What the welcome window's primary button says and does, on whichever step is up.
///
/// A decision rather than a drawing, and it is here because it is the one control the window
/// cannot get wrong twice: it is enabled on every step, it carries the return key, and what it
/// does changes with both the step and the machine. It was an `if` inside the footer, reading a
/// verdict, on a window that then grew a step the verdict says nothing about.
///
/// The rules, in the order they are asked:
///
/// - A blocked machine is offered another look rather than a closed door, and only on the screen
///   that is showing it what is wrong.
/// - A step with somewhere to go is a step whose button goes there.
/// - Otherwise the button leaves, which is what the last step's button always does. It is never
///   disabled and it never waits for a probe: a machine that has already answered can be left the
///   instant its owner wants to leave.
public struct OnboardingPrimary: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// Run the checks again, staying where we are.
        case checkAgain
        /// Show the next screen.
        case advance(OnboardingStep)
        /// Close the window and remember that this was finished.
        case finish
    }

    public let action: Action
    public let title: String

    /// The words on the button that ends the sequence.
    ///
    /// Named here rather than only in the verdict's table because the screen that ends the
    /// sequence is one no verdict has an opinion about.
    public static let finishTitle = "Start using Bloom"

    public init(step: OnboardingStep, verdict: SetupVerdict, next: OnboardingStep?) {
        // Blocked is asked about only on the screen carrying the column. A re-probe that turns
        // blocked while somebody is reading the offer would otherwise replace their way out with
        // a Check again for a list that is not in front of them.
        if step == .checks, verdict == .blocked {
            self.action = .checkAgain
            self.title = verdict.primaryButtonTitle
        } else if let next, let forward = next.arrivalButtonTitle {
            self.action = .advance(next)
            self.title = forward
        } else {
            self.action = .finish
            self.title = Self.finishTitle
        }
    }
}
