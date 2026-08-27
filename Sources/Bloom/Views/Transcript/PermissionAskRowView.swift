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
    /// What the project is called, so the widest scope can say where it applies, or nil when
    /// there is no project behind this conversation.
    ///
    /// **Nil is not a missing value, it is an answer**, and it changes what this card may offer.
    /// `permission_grants.repo_id` is `NOT NULL REFERENCES repos(id)`, so an always-allow rule is
    /// stored against a project; a chat that has none cannot store one. Ask Bloom is that chat.
    /// The buttons come from `PermissionScopeOffer` rather than from three `if`s here, so the
    /// widest thing on offer and the sentence under it are decided in one place, in the core,
    /// where a test can read them.
    var projectName: String?
    var onAnswer: (PermissionDecision) -> Void = { _ in }

    @State private var isWritingReason = false
    @State private var reason = ""
    @FocusState private var isReasonFocused: Bool

    /// What the conversation is set at, for the leading below and for nothing else. The face is
    /// read with it because `TranscriptLayout.codeLeading` takes both, and it costs nothing here:
    /// a monospaced rung resolves to the system mono whatever the prose face is.
    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont

    /// The leading a wrapped command is set with, held at a ratio of its own line box rather than
    /// at a fixed four points. See `TranscriptLayout.codeLeading` for why it moved and for why it
    /// is still not the number prose gets.
    private var codeLeading: CGFloat {
        TranscriptLayout.codeLeading(Typo.codeSmall, scale: fontScale, face: chatFont)
    }

    private var isOpen: Bool { decision == nil }

    /// Which allows this ask may honestly draw, widest first, and the sentence under them.
    private var offer: PermissionScopeOffer {
        PermissionScopeOffer.of(ask: ask, project: projectName)
    }

    var body: some View {
        // `cardInset` for both the margin and the gap between the groups, which is the bargain
        // `AgentQuestionCard` already struck and wrote down: the air inside a held-open card is the
        // same air that separates it from its edge. This panel is the other form in the transcript
        // and it had never been given that treatment. It stood on `inset`, the rung a one line ROW
        // keeps from the edge of a pane, with four points between its groups and two inside the
        // command box, so the header, the command and the buttons all sat on each other and the
        // whole thing read as a list that happened to have a border. That is, word for word, the
        // note on `cardInset` explaining why the question card stopped using `inset`.
        //
        // Two rungs, not five numbers. Twelve between the groups and twelve to the border; six and
        // eight inside the command block and six under the buttons, which is the nested rhythm the
        // question card's own preview block uses. A box inside a card keeps less air than the card
        // does, or the nesting stops reading as nesting.
        VStack(alignment: .leading, spacing: TranscriptLayout.cardInset) {
            header
            command
            if isOpen {
                if isWritingReason { reasonBox } else { actions }
            } else {
                outcome
            }
        }
        .padding(TranscriptLayout.cardInset)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(isOpen ? Palette.cautionWash : Palette.cautionWashSettled)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(
                    isOpen ? Palette.cautionBorder : Palette.border,
                    lineWidth: Metrics.outline
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

    /// What is actually being asked for, with the button that puts it on the pasteboard.
    ///
    /// This is the strongest case in the window for a copy button and the reason there is one. The
    /// command is long, it is wrapped over several lines, and it is the thing a person most wants
    /// to paste into a terminal and try by hand before deciding whether to let an agent run it. It
    /// is also whole here: unlike the collapsed row above, nothing has been cut, so what is copied
    /// is what is on screen.
    ///
    /// Always drawn rather than revealed on hover. The panel is a question waiting for an answer
    /// rather than one of four hundred rows being scrolled past, so there is no column of these to
    /// quieten, and a control somebody has to discover by waving the pointer at a box is a control
    /// most people never find.
    ///
    /// Its own column in the row rather than an overlay over the text, because the text wraps: an
    /// overlaid button sat on top of the first line of any command long enough to need it.
    ///
    /// The face follows `subjectIsCode`. When the CLI offers no literal at all the subject falls
    /// through to its own English description, and that was being set in this monospace block:
    /// prose drawn as code, which is the same mistake as the row above had, pointing the other way.
    ///
    /// **No cap and no fold, however long the command is.** Every other long block in this window
    /// is cut at a line count and hidden behind "Show all", and this is the one place that must not
    /// be. The oldest trick against a confirmation is a harmless looking first line with the damage
    /// past the fold, and a scroller inside the box is the same hiding with a thinner excuse: a
    /// panel is a thing people learn to answer without reading, and every point of the command has
    /// to be in front of somebody who is about to allow it. So the panel grows with the command,
    /// and the pane it sits in already scrolls. Measured on a twelve statement command: the panel
    /// is about 500 points tall, which is high but is a height a scroll wheel already handles, and
    /// is the price of never having hidden anything.
    ///
    /// The leading is a separate decision from the gaps around the block, and taken on its own:
    /// see `TranscriptLayout.codeLeading`. It costs nothing here, because nothing is capped.
    @ViewBuilder
    private var command: some View {
        if !ask.subject.isEmpty {
            HStack(alignment: .top, spacing: TranscriptLayout.glyphGap) {
                Text(ask.subject)
                    .font(ask.subjectIsCode ? Typo.codeSmall : Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(ask.subjectIsCode ? codeLeading : 0)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                CopyButton(
                    text: ask.subject,
                    title: ask.toolName == "Bash" ? "Copy command" : "Copy"
                )
            }
            .padding(.horizontal, Metrics.spacingWide)
            .padding(.vertical, Metrics.spacing)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(Palette.surfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: Metrics.outline)
            )
            // SwiftUI's selectable Text is a private NSTextField subclass whose own context
            // menu comes back empty, so a copy item has to be put here by hand. Kept alongside
            // the button: a right click is where somebody who has selected part of the command
            // looks, and the button is what somebody who wants all of it presses.
            .contextMenu {
                Button("Copy") { Clipboard.copy(ask.subject) }
            }
        }
    }

    private var actions: some View {
        // The scope line is the consequence of the buttons above it and belongs to them, so it is
        // set at the rung between controls in a row rather than at the twelve that separates one
        // group of the panel from the next. At two points it read as a caption crammed under them.
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            // One decision, so one group, at the leading edge with everything else in the panel.
            //
            // The allows and the denies used to be pushed to opposite ends of the panel by a
            // `Spacer` between them, and on a wide window that is most of a screen of travel
            // between the two halves of one choice. Worse, it stopped reading as a choice at all:
            // a control at the far left and a control at the far right read as two unrelated
            // things, the way a toolbar's ends do.
            //
            // Leading rather than trailing, which is the other honest option and is what a macOS
            // dialog would do. This is not a dialog. It is a block inside a scrolling transcript,
            // its header, its command and its scope sentence are all set against the left edge,
            // and an action row pinned to the right would be the one element in the panel that was
            // not. It also puts the affirmative button directly under the question, which is where
            // the eye already is, and it stops the buttons moving as the window is resized.
            //
            // Two gaps rather than one, and that is the whole grouping: six between controls that
            // do the same kind of thing, twelve between the allows and the denies. Adjacent
            // affirmative and destructive buttons want the wider gap so a slipped click lands on
            // nothing, and twelve is the same rung that separates one group of this panel from the
            // next, so the row is spaced the way the panel is.
            //
            // Nothing about the weights changes: the widest allow is still the filled one, deny is
            // still bordered and the one that asks for a sentence is still borderless.
            HStack(spacing: Metrics.gutter) {
                HStack(spacing: Metrics.spacing) {
                    // The widest one is the prominent one, and deliberately so rather than the
                    // narrowest. See the note at the top of this file: the ask rate is what
                    // decides whether this feature is kept or switched off, and "Allow once" as
                    // the default answer is what makes a long turn ask thirty times.
                    //
                    // Which scope IS the widest is `PermissionScopeOffer`'s answer rather than
                    // this view's. In a project it is "Always allow"; in a chat with no project it
                    // is "Allow for this session", because there is nothing wider that could
                    // honestly be stored. The button that used to be here in that case said
                    // "Always allow" and would have granted one call.
                    Button(offer.prominent.buttonLabel) { onAnswer(.allow(scope: offer.prominent)) }
                        .buttonStyle(.borderedProminent)
                        // The shared system control accent for a primary action.
                        .tint(Palette.controlAccent)
                        // Command and Return while there is more than one allow to choose between,
                        // and a bare Return when this is the only one. Exactly what the two
                        // branches this replaced did, kept because the modifier is what stops a
                        // reflexive Return granting the widest scope on the row.
                        .keyboardShortcut(.return, modifiers: offer.widens ? EventModifiers.command : [])

                    ForEach(Array(offer.scopes.dropFirst()), id: \.self) { scope in
                        Button(scope.compactLabel) { onAnswer(.allow(scope: scope)) }
                            .buttonStyle(.bordered)
                    }
                }

                HStack(spacing: Metrics.spacing) {
                    // No key equivalent, and that is the point. This carried Command+Delete, which
                    // the menu bar's Archive Workspace also carries, and both are live the moment
                    // an ask row is drawn. Measured on a reduction of exactly those two
                    // registrations, a button in the window's view hierarchy and a `CommandMenu`
                    // item: the button wins and the menu item never fires. So the hazard ran the
                    // harmless way round, with Archive Workspace quietly doing nothing while a
                    // question was open rather than a deny archiving a worktree, but the
                    // arbitration is AppKit's rather than anything Bloom asked for and it should
                    // not be trusted to keep pointing that way.
                    //
                    // Archive keeps the key because it is the discoverable one and Command+Delete
                    // is the system's delete idiom. Deny is one of two buttons the reader is
                    // already looking at. Escape was considered and refused: it already means Back
                    // inside this same row once "Deny and say why" is open, and a window-wide
                    // Escape that denied a tool call would fire every time somebody pressed it for
                    // anything else while an ask was on screen.
                    Button("Deny") { onAnswer(.deny(message: "", endsTurn: false)) }
                        .buttonStyle(.bordered)

                    Button("Deny and say why") {
                        isWritingReason = true
                        isReasonFocused = true
                    }
                    .buttonStyle(.borderless)
                    .font(Typo.caption)
                }

                // Holds the group against the leading edge instead of letting it stretch across a
                // wide pane. Last rather than in the middle, which is where it used to be and is
                // what pushed the two halves of the choice apart.
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            scopeLine
        }
    }

    /// The rule, in the CLI's spelling, and what each button would do with it. Printed rather than
    /// hidden behind a hover, because a scope nobody read is a scope nobody chose.
    private var scopeLine: some View {
        // One sentence from one place. It used to be three branches here, and a fourth was needed
        // the moment a chat could have no project: a rule the CLI offered, in a conversation with
        // nowhere to store it. See `PermissionScopeOffer`, which says what each of the four is.
        Text(offer.explanation)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The deny sentence goes to the model as the tool result, so it is worth typing: "not on this
    /// machine, use the docker one" is an instruction, where a bare refusal is a dead end.
    private var reasonBox: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            TextField("Why not? The agent reads this.", text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(Typo.label)
                .lineLimit(1...4)
                .focused($isReasonFocused)
                .onSubmit { onAnswer(.deny(message: reason, endsTurn: false)) }

            // The same two gaps as the row this replaces, for the same reason: the two denials do
            // the same kind of thing and sit six apart, and the way back out of the box is a
            // different kind of thing and sits twelve away from them.
            HStack(spacing: Metrics.gutter) {
                HStack(spacing: Metrics.spacing) {
                    Button("Deny") { onAnswer(.deny(message: reason, endsTurn: false)) }
                        .buttonStyle(.borderedProminent)
                        // The shared system control accent for a primary action.
                        .tint(Palette.controlAccent)
                        .keyboardShortcut(.return, modifiers: .command)

                    Button("Deny and stop the turn") {
                        onAnswer(.deny(message: reason, endsTurn: true))
                    }
                    .buttonStyle(.bordered)
                }

                Button("Back") { isWritingReason = false }
                    .buttonStyle(.borderless)
                    .font(Typo.caption)
                    .keyboardShortcut(.cancelAction)

                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
    }

    /// What a settled question says afterwards. It stays in the transcript as the record of what
    /// was asked and what was answered.
    @ViewBuilder
    private var outcome: some View {
        let decision = decision ?? ""
        // No padding of its own any more. This carried four points on top and two underneath,
        // added because the card's own spacing put the sentence 4 points off the command box and
        // its inset left it 6 off the border. Both of those numbers are twelve now, so the
        // compensation is what would read as wrong: a settled panel would have sat lower in its
        // border than an open one, for a reason that no longer exists.
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
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
            // A grant is stored against a project, so a row saying one answered this always has a
            // project to name. The fallback is for a transcript read after the project was
            // removed, which is the one way the pair can come apart.
            return "Allowed by \(ask.ruleText), which you approved for \(projectName ?? "this project")."
        case "allow-project":
            return "Always allowed. \(ask.ruleText) is granted for \(projectName ?? "this project")."
        case "allow-session": return "Allowed for this session."
        case "allow-once": return "Allowed once."
        case "deny-stop": return "Denied, and the turn was stopped."
        case "deny": return "Denied."
        default: return "Answered."
        }
    }
}
