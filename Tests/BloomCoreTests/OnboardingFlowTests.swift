import Testing
import Foundation
@testable import BloomCore

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("The sequence is a greeting, the checks, an offer that is usually not there, and a prompt")
    func order() {
        #expect(OnboardingStep.order == [.greeting, .checks, .commandLine, .promptSubmission])
        #expect(!OnboardingStep.greeting.isOptional)
        #expect(!OnboardingStep.checks.isOptional)
        #expect(OnboardingStep.commandLine.isOptional)
        // The one the owner asked for, and the reason it is not optional: nothing about a Mac can
        // make it empty, so there is no state in which leaving it out would be the honest answer.
        #expect(!OnboardingStep.promptSubmission.isOptional)

        let plain = OnboardingFlow(step: .greeting)
        #expect(plain.steps == [.greeting, .checks, .promptSubmission])
        #expect(plain.next == .checks)

        let offered = OnboardingFlow(step: .greeting, offersCommandLine: true)
        #expect(offered.steps == [.greeting, .checks, .commandLine, .promptSubmission])
    }

    @Test("Without the command line offer the checks lead straight to the prompt")
    func checksWithoutTheOffer() {
        var flow = OnboardingFlow(step: .checks)
        #expect(flow.next == .promptSubmission)
        let moved = flow.advance()
        #expect(moved)
        #expect(flow.step == .promptSubmission)
    }

    @Test("With the offer the checks lead to it, and the prompt is still the end")
    func endsAtThePrompt() {
        var flow = OnboardingFlow(step: .checks, offersCommandLine: true)
        #expect(flow.next == .commandLine)
        let moved = flow.advance()
        #expect(moved)
        #expect(flow.step == .commandLine)
        #expect(flow.next == .promptSubmission)
        let movedAgain = flow.advance()
        #expect(movedAgain)
        #expect(flow.step == .promptSubmission)
        #expect(flow.next == nil)
        let refused = flow.advance()
        #expect(!refused)
    }

    @Test("Back exists from the checks and nowhere else, and lands on whatever screen came before")
    func back() {
        let greeting = OnboardingFlow(step: .greeting)
        #expect(greeting.back == nil)
        #expect(!greeting.canGoBack)
        #expect(greeting.backButtonTitle == nil)

        let checks = OnboardingFlow(step: .checks)
        #expect(checks.back == .greeting)
        #expect(checks.canGoBack)
        #expect(checks.backButtonTitle != nil)

        let offer = OnboardingFlow(step: .commandLine, offersCommandLine: true)
        #expect(offer.back == .checks)

        // The step the command line offer is missing from is the step whose back skips it.
        #expect(OnboardingFlow(step: .promptSubmission).back == .checks)
        #expect(
            OnboardingFlow(step: .promptSubmission, offersCommandLine: true).back == .commandLine
        )
    }

    @Test("The step somebody is standing on stays in the sequence when the offer is withdrawn")
    func standingOnAWithdrawnStep() {
        var flow = OnboardingFlow(step: .checks, offersCommandLine: true)
        let moved = flow.advance()
        #expect(moved)
        flow.offerCommandLine(false)
        #expect(flow.step == .commandLine)
        #expect(flow.steps.contains(.commandLine))
        // And back still lands somewhere real rather than on the first step of a list this one
        // fell out of.
        #expect(flow.back == .checks)
        // Forward still lands somewhere real too, which is the half that only matters now the
        // withdrawn step is no longer the last one.
        #expect(flow.next == .promptSubmission)
    }

    @Test("The forward button names the screen it opens")
    func titles() {
        #expect(OnboardingStep.greeting.arrivalButtonTitle == nil)
        #expect(OnboardingFlow(step: .greeting).forwardButtonTitle == "See what Bloom needs")
        #expect(
            OnboardingFlow(step: .checks).forwardButtonTitle
                == OnboardingStep.promptSubmission.arrivalButtonTitle
        )
        #expect(
            OnboardingFlow(step: .checks, offersCommandLine: true).forwardButtonTitle
                == OnboardingStep.commandLine.arrivalButtonTitle
        )
        #expect(OnboardingFlow(step: .promptSubmission).forwardButtonTitle == nil)
        // The command line screen is no longer last, so its button may no longer say so. This is
        // the assertion that fails if "One more thing" ever comes back to a step with a step
        // after it.
        #expect(OnboardingStep.commandLine.arrivalButtonTitle == "Use Bloom from your terminal")
        #expect(OnboardingStep.promptSubmission.arrivalButtonTitle == "Say what Bloom does next")
    }

    @Test("A first run opens on the greeting, and every other reason opens on the checks")
    func opening() {
        #expect(OnboardingFlow.firstStep(trigger: .firstRun) == .greeting)
        #expect(OnboardingFlow.firstStep(trigger: .blocked) == .checks)
        #expect(OnboardingFlow.firstStep(trigger: .none) == .checks)
    }

    @Test("Advancing walks the whole sequence and then refuses")
    func advancing() {
        var flow = OnboardingFlow(step: .greeting)
        let moved = flow.advance()
        #expect(moved)
        #expect(flow.step == .checks)
        let movedAgain = flow.advance()
        #expect(movedAgain)
        #expect(flow.step == .promptSubmission)
        let refused = flow.advance()
        #expect(!refused)
        #expect(flow.step == .promptSubmission)
    }

    @Test("Going back walks to the greeting and then refuses")
    func goingBack() {
        var flow = OnboardingFlow(step: .checks)
        #expect(flow.canGoBack)
        let wentBack = flow.goBack()
        #expect(wentBack)
        #expect(flow.step == .greeting)
        #expect(!flow.canGoBack)
        let wentBackAgain = flow.goBack()
        #expect(!wentBackAgain)
        #expect(flow.step == .greeting)
    }

    @Test("Back is offered even when the window opened straight onto the checks")
    func backFromAReturningOpen() {
        var flow = OnboardingFlow.opening(trigger: .none)
        #expect(flow.step == .checks)
        #expect(flow.canGoBack)
        let wentBack = flow.goBack()
        #expect(wentBack)
        #expect(flow.step == .greeting)
    }

    @Test("The entrance plays once, and a step returned to is a return rather than an arrival")
    func firstVisit() {
        var flow = OnboardingFlow(step: .greeting)
        #expect(flow.isFirstVisit(to: .greeting))
        #expect(flow.isFirstVisit(to: .checks))
        _ = flow.advance()
        #expect(flow.isFirstVisit(to: .checks))
        _ = flow.goBack()
        #expect(!flow.isFirstVisit(to: .greeting))
        _ = flow.advance()
        #expect(!flow.isFirstVisit(to: .checks))
    }
}

@Suite("The welcome window's primary button")
struct OnboardingPrimaryTests {
    @Test("A blocked machine is offered another look rather than a closed door")
    func blocked() {
        let primary = OnboardingPrimary(step: .checks, verdict: .blocked, next: .promptSubmission)
        #expect(primary.action == .checkAgain)
        #expect(primary.title == "Check again")
    }

    @Test("A step with somewhere to go goes there, and says which screen that is")
    func advancing() {
        let toChecks = OnboardingPrimary(step: .greeting, verdict: .checking, next: .checks)
        #expect(toChecks.action == .advance(.checks))
        #expect(toChecks.title == "See what Bloom needs")

        let toOffer = OnboardingPrimary(step: .checks, verdict: .ready, next: .commandLine)
        #expect(toOffer.action == .advance(.commandLine))
        #expect(toOffer.title == OnboardingStep.commandLine.arrivalButtonTitle)

        // The command line screen leads somewhere now, so its own button moves rather than leaves.
        let toPrompt = OnboardingPrimary(
            step: .commandLine, verdict: .ready, next: .promptSubmission
        )
        #expect(toPrompt.action == .advance(.promptSubmission))
        #expect(toPrompt.title == OnboardingStep.promptSubmission.arrivalButtonTitle)
    }

    @Test("The last step's button leaves, whatever the verdict is doing behind it")
    func finishing() {
        for verdict in [SetupVerdict.checking, .ready, .readyWithNotes, .blocked] {
            let primary = OnboardingPrimary(step: .promptSubmission, verdict: verdict, next: nil)
            #expect(primary.action == .finish)
            #expect(primary.title == OnboardingPrimary.finishTitle)
        }
    }

    @Test("Re-probing to blocked past the checks does not turn the way out into a re-check")
    func blockedPastTheChecks() {
        // The column is not on screen there, so Check again would be a button about a list nobody
        // can see, and it would close nothing.
        let onOffer = OnboardingPrimary(
            step: .commandLine, verdict: .blocked, next: .promptSubmission
        )
        #expect(onOffer.action == .advance(.promptSubmission))

        let onPrompt = OnboardingPrimary(step: .promptSubmission, verdict: .blocked, next: nil)
        #expect(onPrompt.action == .finish)
        #expect(onPrompt.title == OnboardingPrimary.finishTitle)
    }
}
