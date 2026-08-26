import Testing
import Foundation
@testable import BloomCore

@Suite("What a permission card may offer")
struct PermissionScopeOfferTests {
    private func ask(rule: String? = "bin/test:*", suppresses: Bool = false) -> PermissionAsk {
        let rules: [PermissionRule] = rule.map { [PermissionRule(toolName: "Bash", ruleContent: $0)] } ?? []
        return PermissionAsk(
            requestID: "r1",
            toolName: "Bash",
            suggestions: rules.isEmpty
                ? []
                : [PermissionSuggestion(type: "addRules", behavior: "allow", rules: rules)],
            suppressesAlwaysAllow: suppresses
        )
    }

    @Test("a chat in a project is offered all three, widest first")
    func inAProject() {
        let offer = PermissionScopeOffer.of(ask: ask(), project: "bloom")
        #expect(offer.scopes == [.project, .session, .once])
        #expect(offer.prominent == .project)
        #expect(offer.widens)
        #expect(offer.explanation.contains("bloom"))
    }

    /// The finding this type exists for. `permission_grants.repo_id` is `NOT NULL REFERENCES
    /// repos(id)`, so a conversation with no project cannot store an always-allow rule, and the
    /// card must not draw a button that would quietly do less than it says.
    @Test("a chat with no project is not offered Always allow, and is told why")
    func withNoProject() {
        let offer = PermissionScopeOffer.of(ask: ask(), project: nil)
        #expect(offer.scopes == [.session, .once])
        #expect(offer.prominent == .session)
        #expect(!offer.scopes.contains(.project))
        #expect(offer.explanation.contains("no project"))
        #expect(offer.explanation.contains("bin/test:*"))
    }

    @Test("an empty project name is the same as no project")
    func emptyProjectName() {
        #expect(PermissionScopeOffer.of(ask: ask(), project: "").scopes == [.session, .once])
    }

    /// An ask nobody may widen is one call and nothing else, project or no project. The whole
    /// question of scope is the CLI's here, and Bloom does not get a second opinion.
    @Test("an ask that cannot be widened is one call, in a project or out of one")
    func cannotWiden() {
        for project in ["bloom", nil] {
            let suppressed = PermissionScopeOffer.of(ask: ask(suppresses: true), project: project)
            #expect(suppressed.scopes == [.once])
            #expect(!suppressed.widens)
            #expect(suppressed.explanation.contains("decided on its own"))

            let noRule = PermissionScopeOffer.of(ask: ask(rule: nil), project: project)
            #expect(noRule.scopes == [.once])
            #expect(noRule.explanation.contains("No rule was offered"))
        }
    }

    @Test("every scope has both a long and a compact label")
    func labels() {
        for scope in PermissionScope.allCases {
            #expect(!scope.buttonLabel.isEmpty)
            #expect(!scope.compactLabel.isEmpty)
        }
        #expect(PermissionScope.project.compactLabel == "Always allow")
        #expect(PermissionScope.session.compactLabel == "This session")
        #expect(PermissionScope.once.compactLabel == "Once")
    }
}
