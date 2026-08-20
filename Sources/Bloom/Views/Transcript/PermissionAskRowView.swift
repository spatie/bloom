import SwiftUI
import BloomCore

/// The permission question, drawn where the call would have been.
///
/// The turn stops mid sentence and waits with its hand up. Nothing pops, nothing is seized: an
/// agent in a workspace nobody is looking at cannot take the window, and five of them cannot queue
/// sheets over somebody's typing. So the question lives exactly where its context is, and the
/// signals that it exists live somewhere findable (the sidebar mark, the dock badge, the menu bar
/// count and one notification).
///
/// ## The prominent button is the narrowest rule that stops the question recurring
///
/// This is the whole design, and it is the one thing that decides whether the feature survives
/// contact. If a long turn asks thirty times, nobody evaluates the thirtieth: they put the session
/// on Full access and never take it off, and Bloom ends up less safe than the refusal it replaced.
/// So "Always allow" is the filled button, not "Allow once", and the rule it would grant is
/// printed as text beside it before it can be pressed. Widening is never something that happens
/// without having been read.
///
/// The rule text is the CLI's own `ruleContent`. Bloom composes none of it, and when the CLI
/// offers no rule (a path outside the worktree is the case that prompted this) there is no rule
/// button at all rather than one Bloom invented. The same is true of the CLI's two undocumented
/// flags: `suppress_always_allow_rule` and `requires_user_interaction` both mean the persistent
/// option must not be offered, and `PermissionAsk.canWiden` is where all three are decided.
struct PermissionAskRowView: View {
    var ask: PermissionAsk
    /// Nil while the question is open. Anything else and the buttons are gone: a decided question
    /// answered again would write into a pipe nobody is reading.
    var decision: String?
    /// Set when a rule answered instead of a person, naming the rule that did it.
    var note: String
    /// What the project is called, so the widest scope can say where it applies.
    var projectName: String
    var onAnswer: (PermissionDecision) -> Void = { _ in }

    @State private var isWritingReason = false
    @State private var reason = ""
    @FocusState private var isReasonFocused: Bool

    private var isOpen: Bool { decision == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
            header
            command
            if isOpen {
                if isWritingReason { reasonBox } else { actions }
            } else {
                outcome
            }
        }
        .padding(TranscriptLayout.inset)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(Palette.warning.opacity(isOpen ? 0.07 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(
                    isOpen ? Palette.warning.opacity(0.46) : Palette.border,
                    lineWidth: Metrics.hairline
                )
        )
        .padding(.vertical, TranscriptLayout.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isOpen ? "The agent is asking permission" : "Permission question, answered")
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            // The same raised hand the sidebar mark and the menu bar strip use.
            Image(systemName: "hand.raised.fill")
                .font(Typo.caption)
                .imageScale(.small)
                .foregroundStyle(isOpen ? Palette.warning : Palette.textTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: TranscriptLayout.glyphGap)

            if !ask.reason.isEmpty {
                // The CLI's own sentence, not Bloom's paraphrase of it.
                Text(ask.reason)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// What is actually being asked for. Selectable, because the first thing anybody does with an
    /// unfamiliar command is copy it somewhere to read it.
    @ViewBuilder
    private var command: some View {
        if !ask.subject.isEmpty {
            Text(ask.subject)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TranscriptLayout.glyphGap)
                .padding(.vertical, TranscriptLayout.tight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                        .fill(Palette.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
                )
                // SwiftUI's selectable Text is a private NSTextField subclass whose own context
                // menu comes back empty, so a copy item has to be put here by hand.
                .contextMenu {
                    Button("Copy") { Clipboard.copy(ask.subject) }
                }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            HStack(spacing: TranscriptLayout.tight) {
                if ask.canWiden {
                    // The prominent one, and deliberately the widest rather than the narrowest.
                    // See the note at the top of this file: the ask rate is what decides whether
                    // this feature is kept or switched off, and "Allow once" as the default answer
                    // is what makes a long turn ask thirty times.
                    Button("Always allow") { onAnswer(.allow(scope: .project)) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)

                    Button("This session") { onAnswer(.allow(scope: .session)) }
                        .buttonStyle(.bordered)
                }

                // When there is a rule to grant, the once button is the quiet one and the rule is
                // prominent. When there is not, once is the only allow there is, so it takes the
                // emphasis and the return key rather than leaving the row with no default.
                if ask.canWiden {
                    Button("Once") { onAnswer(.allow(scope: .once)) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Allow once") { onAnswer(.allow(scope: .once)) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }

                Spacer(minLength: 0)

                Button("Deny") { onAnswer(.deny(message: "", endsTurn: false)) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.delete, modifiers: .command)

                Button("Deny and say why") {
                    isWritingReason = true
                    isReasonFocused = true
                }
                .buttonStyle(.borderless)
                .font(Typo.caption)
            }
            .controlSize(.small)

            scopeLine
        }
    }

    /// The rule, in the CLI's spelling, and what each button would do with it. Printed rather than
    /// hidden behind a hover, because a scope nobody read is a scope nobody chose.
    @ViewBuilder
    private var scopeLine: some View {
        if ask.canWiden {
            Text(PermissionScope.project.consequence(rule: ask.ruleText, project: projectName))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !ask.rules.isEmpty {
            // A rule exists and the CLI asked for it not to be offered. Saying so is better than
            // a button that is quietly missing.
            Text("\(ask.ruleText) cannot be granted from here: the agent asked for this one to be decided on its own.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No rule was offered for this, so it can only be allowed once.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    /// The deny sentence goes to the model as the tool result, so it is worth typing: "not on this
    /// machine, use the docker one" is an instruction, where a bare refusal is a dead end.
    private var reasonBox: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            TextField("Why not? The agent reads this.", text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(Typo.label)
                .lineLimit(1...4)
                .focused($isReasonFocused)
                .onSubmit { onAnswer(.deny(message: reason, endsTurn: false)) }

            HStack(spacing: TranscriptLayout.tight) {
                Button("Deny") { onAnswer(.deny(message: reason, endsTurn: false)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)

                Button("Deny and stop the turn") {
                    onAnswer(.deny(message: reason, endsTurn: true))
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button("Back") { isWritingReason = false }
                    .buttonStyle(.borderless)
                    .font(Typo.caption)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
    }

    /// What a settled question says afterwards. It stays in the transcript as the record of what
    /// was asked and what was answered.
    @ViewBuilder
    private var outcome: some View {
        let decision = decision ?? ""
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            Text(outcomeText(decision))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            let advice = PermissionAskOutcome.advice(decision)
            if !advice.isEmpty {
                Text(advice)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Copy

    private var title: String {
        let verb = ask.toolName == "Bash" ? "run a command" : "use \(ask.label)"
        return isOpen ? "The agent is asking to \(verb)" : "The agent asked to \(verb)"
    }

    /// Follows `SetupDiagnosis`: a real sentence when there is one, and nothing rather than
    /// filler when there is not.
    private func outcomeText(_ decision: String) -> String {
        // A rule answered it. Naming the rule is what makes the grant reviewable: a call that ran
        // because of a decision made days ago must not look like a call that simply ran.
        if !note.isEmpty { return note }

        let unanswered = PermissionAskOutcome.summary(decision)
        if !unanswered.isEmpty { return unanswered }

        switch decision {
        // A reloaded transcript has no note: the sentence was on the live event and the event is
        // long gone. It has to be rebuilt rather than dropped, because "Answered." beside a call
        // that ran is exactly the thing this row exists to prevent. The rule is on the ask itself,
        // which is why it can be said again a week later.
        case PermissionAskOutcome.auto:
            return "Allowed by \(ask.ruleText), which you approved for \(projectName)."
        case "allow-project": return "Always allowed. \(ask.ruleText) is granted for \(projectName)."
        case "allow-session": return "Allowed for this session."
        case "allow-once": return "Allowed once."
        case "deny-stop": return "Denied, and the turn was stopped."
        case "deny": return "Denied."
        default: return "Answered."
        }
    }
}
