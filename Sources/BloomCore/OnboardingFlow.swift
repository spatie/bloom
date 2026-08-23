import Foundation

/// The steps the welcome window walks through, and the rules for moving between them.
///
/// There are two, and the count is the argument. The window used to be one screen that opened
/// straight onto four probes, which meant the first thing a new Bloom ever said to anybody was a
/// list of what their Mac might be missing. That reads as a form. A greeting first, then the
/// checks, is what turns the same two facts into a welcome, and it costs one press.
///
/// It stops at two on purpose. A tour is a tax on somebody who has already installed the app, and
/// the moment there is a third step the second one starts being read as progress rather than as
/// the end. `next` returning nil from `.checks` is what says the sequence is over and the primary
/// button is the way out rather than the way on.
///
/// Here rather than in the view because which step follows which, and whether back is offered, is
/// the only part of the sequence that can be wrong. See `Tests/BloomCoreTests/OnboardingFlowTests`.
public enum OnboardingStep: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    /// The mark, the name and one line saying what Bloom is. No information to act on.
    case greeting
    /// What this Mac already has, which is the window's other half.
    case checks

    public var id: String { rawValue }

    /// Reading order, and the order `next` and `back` walk.
    public static let order: [OnboardingStep] = [.greeting, .checks]

    private var position: Int { Self.order.firstIndex(of: self) ?? 0 }

    /// The step after this one, or nil at the end of the sequence.
    public var next: OnboardingStep? {
        let after = position + 1
        return after < Self.order.count ? Self.order[after] : nil
    }

    /// The step before this one, or nil at the start.
    ///
    /// Nil is what the view draws nothing for. A back control that is present and disabled on the
    /// first step is a promise of a screen that does not exist.
    public var back: OnboardingStep? {
        let before = position - 1
        return before >= 0 ? Self.order[before] : nil
    }

    public var canGoBack: Bool { back != nil }

    /// True when this step is the one whose primary button leaves the window rather than
    /// advancing it. The checks step owns the verdict, so it owns the way out.
    public var isLast: Bool { next == nil }

    /// What the button that moves the sequence on says, or nil on the step that has no next.
    ///
    /// One phrase, in the imperative, naming what the next screen is rather than naming the act
    /// of moving. "Continue" would be true of every wizard ever shipped and would tell nobody
    /// what they are about to see.
    public var forwardButtonTitle: String? {
        switch self {
        case .greeting: "Check my Mac"
        case .checks: nil
        }
    }

    /// What the control back to the previous step says. Named after the screen it returns to, for
    /// the same reason `forwardButtonTitle` is.
    public var backButtonTitle: String? {
        switch back {
        case .greeting: "Back"
        case .checks, nil: nil
        }
    }
}

/// Where the window opens, and how it moves.
///
/// The one interesting rule is `firstStep`. A first run gets the greeting, because that is the
/// whole reason the greeting exists and a warm second is what somebody who has just double
/// clicked a fresh app is owed. Every other way this window opens is somebody who has been here
/// before: the Help menu, or a later launch where the machine stopped working. Those open on the
/// checks, because a person who came back came back for the checks, and greeting them again
/// would be the app not remembering them. Back is still offered from there, so the greeting is
/// never a screen that has been taken away.
public struct OnboardingFlow: Sendable, Hashable {
    public private(set) var step: OnboardingStep
    /// Every step this window has shown, in the order it showed them. What makes back honest when
    /// the sequence did not start at the beginning.
    public private(set) var history: [OnboardingStep]

    public init(step: OnboardingStep = .greeting) {
        self.step = step
        self.history = [step]
    }

    /// Where a window opened by this trigger starts.
    public static func firstStep(trigger: OnboardingTrigger) -> OnboardingStep {
        switch trigger {
        case .firstRun: .greeting
        case .blocked, .none: .checks
        }
    }

    public static func opening(trigger: OnboardingTrigger) -> OnboardingFlow {
        OnboardingFlow(step: firstStep(trigger: trigger))
    }

    public var canGoBack: Bool { step.canGoBack }
    public var forwardButtonTitle: String? { step.forwardButtonTitle }
    public var backButtonTitle: String? { step.backButtonTitle }

    /// Moves on, if there is anywhere to move on to. Returns whether anything changed, so a view
    /// only animates a transition that happened.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let next = step.next else { return false }
        step = next
        history.append(next)
        return true
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let back = step.back else { return false }
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
