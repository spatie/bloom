import Testing
import Foundation
@testable import BloomCore

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("The sequence is a greeting and then the checks, and it ends there")
    func order() {
        #expect(OnboardingStep.order == [.greeting, .checks])
        #expect(OnboardingStep.greeting.next == .checks)
        #expect(OnboardingStep.checks.next == nil)
        #expect(OnboardingStep.checks.isLast)
        #expect(!OnboardingStep.greeting.isLast)
    }

    @Test("Back exists from the checks and nowhere else")
    func back() {
        #expect(OnboardingStep.greeting.back == nil)
        #expect(!OnboardingStep.greeting.canGoBack)
        #expect(OnboardingStep.checks.back == .greeting)
        #expect(OnboardingStep.checks.canGoBack)
    }

    @Test("Only the greeting carries a forward button, and only the checks a back one")
    func titles() {
        #expect(OnboardingStep.greeting.forwardButtonTitle != nil)
        #expect(OnboardingStep.checks.forwardButtonTitle == nil)
        #expect(OnboardingStep.greeting.backButtonTitle == nil)
        #expect(OnboardingStep.checks.backButtonTitle != nil)
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
