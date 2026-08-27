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

    @Test("every mode has a sentence on every backend, because the footnote always prints one")
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
        #expect(PermissionMode.plan.nearest(on: .codex) == .acceptEdits)
        // Everything else stays where it is, on both.
        for mode in PermissionMode.allCases {
            for kind in AgentKind.allCases {
                let landed = mode.nearest(on: kind)
                #expect(ComposerControls(agentKind: kind).availablePermissionModes.contains(landed))
            }
        }
    }

    @Test("the footnote says what the chosen mode does, and what is missing")
    func theFootnoteSaysBoth() {
        let codex = ComposerControls(agentKind: .codex, permissionMode: .autoReview)
        let note = codex.permissionModeNote
        #expect(note.contains("Approve for me"))
        #expect(note.contains("potentially unsafe"))
        // Still true after the relabelling, and now said in the vocabulary around it.
        #expect(note.contains("Plan is a Claude Code mode. Codex has no equivalent."))

        let claude = ComposerControls(agentKind: .claudeCode, permissionMode: .plan)
        #expect(claude.permissionModeNote.contains("Plan:"))
        #expect(!claude.permissionModeNote.contains("no equivalent"))
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
