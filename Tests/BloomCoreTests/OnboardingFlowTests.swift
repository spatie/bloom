import Testing
import Foundation
@testable import BloomCore

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("The sequence is a greeting, the checks, and an offer that is usually not there")
    func order() {
        #expect(OnboardingStep.order == [.greeting, .checks, .commandLine])
        #expect(!OnboardingStep.greeting.isOptional)
        #expect(!OnboardingStep.checks.isOptional)
        #expect(OnboardingStep.commandLine.isOptional)

        let plain = OnboardingFlow(step: .greeting)
        #expect(plain.steps == [.greeting, .checks])
        #expect(plain.next == .checks)

        let offered = OnboardingFlow(step: .greeting, offersCommandLine: true)
        #expect(offered.steps == [.greeting, .checks, .commandLine])
    }

    @Test("Without the offer the checks are the end of it")
    func endsAtTheChecks() {
        var flow = OnboardingFlow(step: .checks)
        #expect(flow.next == nil)
        #expect(!flow.advance())
        #expect(flow.step == .checks)
    }

    @Test("With the offer the checks lead to it, and it is the end")
    func endsAtTheOffer() {
        var flow = OnboardingFlow(step: .checks, offersCommandLine: true)
        #expect(flow.next == .commandLine)
        #expect(flow.advance())
        #expect(flow.step == .commandLine)
        #expect(flow.next == nil)
        #expect(!flow.advance())
    }

    @Test("Back exists from the checks and nowhere else, and from the offer once it is there")
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
    }

    @Test("The step somebody is standing on stays in the sequence when the offer is withdrawn")
    func standingOnAWithdrawnStep() {
        var flow = OnboardingFlow(step: .checks, offersCommandLine: true)
        #expect(flow.advance())
        flow.offerCommandLine(false)
        #expect(flow.step == .commandLine)
        #expect(flow.steps.contains(.commandLine))
        // And back still lands somewhere real rather than on the first step of a list this one
        // fell out of.
        #expect(flow.back == .checks)
    }

    @Test("The forward button names the screen it opens")
    func titles() {
        #expect(OnboardingStep.greeting.arrivalButtonTitle == nil)
        #expect(OnboardingFlow(step: .greeting).forwardButtonTitle == "See what Bloom needs")
        #expect(OnboardingFlow(step: .checks).forwardButtonTitle == nil)
        #expect(
            OnboardingFlow(step: .checks, offersCommandLine: true).forwardButtonTitle
                == OnboardingStep.commandLine.arrivalButtonTitle
        )
    }

    @Test("A first run opens on the greeting, and every other reason opens on the checks")
    func opening() {
        #expect(OnboardingFlow.firstStep(trigger: .firstRun) == .greeting)
        #expect(OnboardingFlow.firstStep(trigger: .blocked) == .checks)
        #expect(OnboardingFlow.firstStep(trigger: .none) == .checks)
    }

    @Test("Advancing walks forward once and then refuses")
    func advancing() {
        var flow = OnboardingFlow(step: .greeting)
        let moved = flow.advance()
        #expect(moved)
        #expect(flow.step == .checks)
        let movedAgain = flow.advance()
        #expect(!movedAgain)
        #expect(flow.step == .checks)
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
        let primary = OnboardingPrimary(step: .checks, verdict: .blocked, next: nil)
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
    }

    @Test("The last step's button leaves, whatever the verdict is doing behind it")
    func finishing() {
        for verdict in [SetupVerdict.checking, .ready, .readyWithNotes, .blocked] {
            let primary = OnboardingPrimary(step: .commandLine, verdict: verdict, next: nil)
            #expect(primary.action == .finish)
            #expect(primary.title == OnboardingPrimary.finishTitle)
        }
    }

    @Test("A machine that is fine leaves from the checks when nothing follows them")
    func finishingFromTheChecks() {
        let primary = OnboardingPrimary(step: .checks, verdict: .readyWithNotes, next: nil)
        #expect(primary.action == .finish)
        #expect(primary.title == "Start using Bloom")
    }

    @Test("Re-probing to blocked under the offer does not turn the way out into a re-check")
    func blockedWhileOnTheOffer() {
        // The column is not on screen there, so Check again would be a button about a list nobody
        // can see, and it would close nothing.
        let primary = OnboardingPrimary(step: .commandLine, verdict: .blocked, next: nil)
        #expect(primary.action == .finish)
    }
}
