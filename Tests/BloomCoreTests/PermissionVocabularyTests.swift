import Testing
import Foundation
@testable import BloomCore

/// A user running Codex inside Bloom read the composer's permission menu, compared it with the
/// Codex app's, and could not match the two up. Two faults behind that, and both are pinned here:
/// Bloom printed Claude Code's names over a Codex chat, and it had no row at all for the preset
/// the Codex app calls "Approve for me".
@Suite("The permission menu, in each backend's own words")
struct PermissionVocabularyTests {
    @Test("a Codex chat's menu reads the way the Codex app reads")
    func codexUsesCodexsWords() {
        #expect(PermissionMode.auto.label(on: .codex) == "Read only")
        #expect(PermissionMode.acceptEdits.label(on: .codex) == "Ask for approval")
        #expect(PermissionMode.autoReview.label(on: .codex) == "Approve for me")
        #expect(PermissionMode.bypassPermissions.label(on: .codex) == "Full access")

        // The sentence that made the mode legible to the person who reported this, verbatim from
        // the Codex CLI at 0.149.1.
        #expect(
            PermissionMode.autoReview.summary(on: .codex)
                == "Only ask for actions detected as potentially unsafe."
        )
    }

    @Test("a Claude Code chat's menu reads the way Claude Code reads")
    func claudeCodeUsesItsOwnWords() {
        // "Ask" until this change, which was the label that hid the mode. `--permission-mode auto`
        // is documented in the CLI itself as "Use a model classifier to approve/deny permission
        // prompts", so Auto is both its name and what it does.
        #expect(PermissionMode.auto.label(on: .claudeCode) == "Auto")
        #expect(PermissionMode.acceptEdits.label(on: .claudeCode) == "Accept edits")
        #expect(PermissionMode.plan.label(on: .claudeCode) == "Plan")
        #expect(PermissionMode.bypassPermissions.label(on: .claudeCode) == "Bypass permissions")
    }

    @Test("with no backend said the words are Claude Code's, because that is what a chat starts as")
    func theBareLabelIsClaudeCodes() {
        for mode in PermissionMode.allCases {
            #expect(mode.label == mode.label(on: .claudeCode))
        }
    }

    @Test("every mode has a sentence on every backend, because every row prints one")
    func nothingIsSilent() {
        for mode in PermissionMode.allCases {
            for kind in AgentKind.allCases {
                #expect(!mode.label(on: kind).isEmpty)
                #expect(!mode.summary(on: kind).isEmpty)
            }
        }
    }

    @Test("each backend offers only the modes it has")
    func eachBackendOffersWhatItHas() {
        let codex = ComposerControls(agentKind: .codex).availablePermissionModes
        #expect(codex.contains(.autoReview))
        #expect(!codex.contains(.plan))

        let claude = ComposerControls(agentKind: .claudeCode).availablePermissionModes
        #expect(claude.contains(.plan))
        // Not a gap: `auto` already is this mode on Claude Code, so a second row would be two
        // names for one `--permission-mode auto`.
        #expect(!claude.contains(.autoReview))
        #expect(PermissionMode.autoReview.cliValue == PermissionMode.auto.cliValue)
    }

    @Test("a mode the new backend has no row for lands somewhere that mode still means something")
    func aModeThatMovesBackendLandsSomewhere() {
        #expect(PermissionMode.autoReview.nearest(on: .claudeCode) == .auto)
        // Read only, not Ask for approval. Plan is the strictest row there is and Ask for
        // approval writes the worktree without asking, so the old landing widened what the agent
        // could do on a backend switch nobody made for that reason. See `nearest(on:)`.
        #expect(PermissionMode.plan.nearest(on: .codex) == .auto)
        // Everything else stays where it is, on both.
        for mode in PermissionMode.allCases {
            for kind in AgentKind.allCases {
                let landed = mode.nearest(on: kind)
                #expect(ComposerControls(agentKind: kind).availablePermissionModes.contains(landed))
            }
        }
    }

    /// The owner read the menu and said "I cannot see what the option does before picking it".
    /// The sentences moved onto the rows, so the picker is drawn from these rather than from the
    /// labels alone, and each row says what it would do in the running backend's own words.
    @Test("every row carries its own sentence, in the backend's vocabulary")
    func everyRowSaysWhatItDoes() {
        let codex = ComposerControls(agentKind: .codex).permissionModeChoices
        #expect(codex.map(\.mode) == ComposerControls(agentKind: .codex).availablePermissionModes)
        #expect(codex.contains { $0.label == "Approve for me" })
        #expect(codex.contains { $0.summary.contains("potentially unsafe") })
        for choice in codex {
            #expect(!choice.label.isEmpty)
            #expect(!choice.summary.isEmpty)
        }

        let claude = ComposerControls(agentKind: .claudeCode).permissionModeChoices
        #expect(claude.contains { $0.mode == .plan && $0.label == "Plan" })
        #expect(claude.contains { $0.mode == .plan && $0.summary.contains("without making them") })
    }

    /// The footnote used to carry three facts and carries one. Two of them are gone rather than
    /// moved: the selected mode's sentence is on its row now, and the "Codex has no Plan" line
    /// went with the row it was about, because the owner asked for a picker that does the right
    /// thing rather than one that explains what it is not offering.
    @Test("the footnote is left with the one fact no row can carry")
    func theFootnoteIsOnlyAboutTheConversation() {
        let codex = ComposerControls(agentKind: .codex, permissionMode: .autoReview)
        #expect(codex.permissionModeNote == nil)

        let claude = ComposerControls(agentKind: .claudeCode, permissionMode: .plan)
        #expect(claude.permissionModeNote == nil)
    }

    /// Codex has no Plan row, so a chat on Codex can never be in Plan, whichever door it came in
    /// by. The picker is one door; a chat moved off Claude Code by picking a Codex model is the
    /// other, and it is the one that used to leave the mode behind.
    @Test("a mode a backend does not have can never be the selected one for that backend")
    func anAbsentModeIsNeverSelected() {
        for kind in AgentKind.allCases {
            for mode in PermissionMode.allCases {
                let made = ComposerControls(agentKind: kind, permissionMode: mode)
                #expect(made.availablePermissionModes.contains(made.permissionMode))

                // The same value arrived at by moving, which is the path the composer takes when
                // a model out of the other backend's section is chosen.
                var moved = ComposerControls(permissionMode: mode)
                moved.agentKind = kind
                #expect(moved.availablePermissionModes.contains(moved.permissionMode))

                // And by setting the mode after the backend, which is the path the picker takes.
                var picked = ComposerControls(agentKind: kind)
                picked.permissionMode = mode
                #expect(picked.availablePermissionModes.contains(picked.permissionMode))
            }
        }
    }

    /// Plan on Claude Code, moved to Codex and back. It must not come back as Plan, because
    /// nothing chose Plan on the way out, and Plan must be offered again the moment it can be.
    @Test("moving back to Claude Code offers Plan again without silently choosing it")
    func movingBackOffersPlanAgain() {
        var controls = ComposerControls(agentKind: .claudeCode, permissionMode: .plan)
        controls.agentKind = .codex
        #expect(controls.permissionMode == .auto)

        controls.agentKind = .claudeCode
        #expect(controls.permissionMode == .auto)
        #expect(controls.availablePermissionModes.contains(.plan))
    }

    /// "Start in plan mode" is an app-wide switch set long before any backend is chosen, and it
    /// was writing Plan onto whatever session was being opened.
    @Test("the app-wide plan default does not reach a Codex chat")
    func theDefaultLandsOnAModeTheBackendHas() {
        var defaults = AppDefaults()
        defaults.planMode = true

        #expect(
            ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, backend: .claudeCode)
                .permissionMode == .plan
        )
        #expect(
            ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, backend: .codex)
                .permissionMode == .auto
        )
    }

    /// The wire slugs are older than the labels over them and are grouped by on a chart, so the
    /// relabelling must not touch them. Only the new mode adds one.
    @Test("relabelling a mode does not rename the slug it is counted under")
    func slugsAreUnchanged() {
        #expect(Feedback.wireName(.auto) == "ask")
        #expect(Feedback.wireName(.acceptEdits) == "accept-edits")
        #expect(Feedback.wireName(.bypassPermissions) == "full-access")
        #expect(Feedback.wireName(.plan) == "plan")
        #expect(Feedback.wireName(.autoReview) == "approve-for-me")
        #expect(Set(PermissionMode.allCases.map(Feedback.wireName)).count == PermissionMode.allCases.count)
    }
}
