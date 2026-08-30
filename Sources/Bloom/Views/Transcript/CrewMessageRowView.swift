import SwiftUI
import BloomCore

/// Something that arrived in this chat which the owner did not type.
///
/// One row for four events, because it is one thing happening: an agent working beside this one
/// said something, or Bloom is reporting what became of it. `CrewMessage` in the core is the
/// contract, and its head carries the bug the whole shape exists to end. The short of it: a
/// message is stored twice, as what a person reads and as what the model was handed, and it was
/// drawn once, in the envelope, in the bubble that means "the owner typed this". So the owner
/// appeared to have said six paragraphs about untrusted content that they had never seen.
///
/// **Nothing here is indented and nothing is right aligned.** The right hand side of a transcript
/// means one thing in this window, which is that the person reading it wrote the message, and a
/// second agent's words on that side would be the same lie in a new shape. What separates these
/// from the agent's own prose is a two point rule down the left in the colour of whoever spoke,
/// which is the quietest mark the transcript has and the one it already spends on a quote.
///
/// **A fact gets no rule at all.** `.stopped` and `.failed` are Bloom's own voice reporting that a
/// turn ended, not an agent talking, and colouring them like a message would say an agent said
/// something it did not. They are one dimmed line, which is what they are worth beside the answer
/// above them.
struct CrewMessageRowView: View {
    var message: CrewMessage

    /// Local, and deliberately not the row's own expansion state. The transcript's disclosure
    /// opens a row's evidence and is driven from the list; this opens a second thing inside an
    /// already open row, and giving the two one flag would make a keyboard toggle upstream reveal
    /// an envelope nobody asked for.
    @State private var showsEnvelope = false

    var body: some View {
        switch message.event {
        case .said, .brief: spoken
        case .stopped, .failed: fact
        }
    }

    // MARK: An agent speaking

    private var spoken: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            header

            MarkdownView(message.text)
                .font(Typo.body)
                .proseLeading()
                .textSelection(.enabled)
                // Capped and then left aligned in what is left, exactly as `ProseRowView` does it:
                // one frame would centre the paragraph in a wide pane and take it off the line the
                // rest of the transcript starts on.
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasEnvelope { envelope }
        }
        .padding(.leading, TranscriptLayout.block)
        .overlay(alignment: .leading) { rule }
        .padding(.leading, TranscriptLayout.inset)
        .padding(.trailing, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.block)
    }

    /// Who spoke, and one word for what they did.
    ///
    /// The name is in the monospace face for the reason a tool row's argument is: it is an address
    /// rather than a word. `read-the-cascade` is the exact string the agent above has to hand back
    /// to `agent_say`, it is what the sidebar row beside it is called, and a column of them only
    /// lines up in a face whose characters do.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.tight) {
            Text(message.from)
                .font(Typo.code)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(verb)
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        }
        .textSelection(.enabled)
    }

    /// One word, in the past tense, because the row is a record rather than a status.
    private var verb: String {
        switch message.event {
        case .said: "said"
        case .brief: "started you with"
        // Never drawn: a fact is its own line. Answered rather than defaulted so that a fifth
        // event has to be argued about here instead of arriving as the word "said".
        case .stopped, .failed: ""
        }
    }

    // MARK: The evidence

    /// Whether there is an envelope to show at all.
    ///
    /// A brief is handed to the model exactly as it is drawn, because it is the instruction the
    /// agent exists to follow rather than somebody else's writing arriving in its context, so
    /// `sent` and `text` are the same string and a control that reveals nothing is worse than no
    /// control. Asked of the payload rather than of the event, so the day a brief does get wrapped
    /// the disclosure appears on its own.
    private var hasEnvelope: Bool { message.sent != message.text }

    /// What the model was actually handed, behind a disclosure and closed.
    ///
    /// Both halves of that matter. It has to be reachable, because when an agent behaves strangely
    /// the bytes it was given are the only evidence there is, and it must not be the first thing
    /// anybody reads, because it is a fence and a paragraph of boilerplate around a sentence the
    /// row has already drawn.
    @ViewBuilder
    private var envelope: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            Button { showsEnvelope.toggle() } label: {
                HStack(spacing: TranscriptLayout.tight) {
                    Image(systemName: showsEnvelope ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .accessibilityHidden(true)

                    Text("What the model was handed")
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                // The whole line takes the click, not the eleven point word in the middle of it.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showsEnvelope {
                Text(message.sent)
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, TranscriptLayout.tight)
    }

    // MARK: Bloom reporting a fact

    /// One line, and the line is the whole row. `Crew.stoppedSummary` and `Crew.failedSummary`
    /// already name the agent, so there is no header to put above it: what the model was handed
    /// for the same event is a paragraph addressed to the orchestrator, and a reader watching
    /// their own window wants to know that an agent finished rather than to read the instruction
    /// that went with it.
    private var fact: some View {
        Text(message.text)
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TranscriptLayout.inset)
            .padding(.vertical, TranscriptLayout.tight)
    }

    // MARK: The rule

    @ViewBuilder
    private var rule: some View {
        if let ink = CrewInk.rule(for: message.sender) {
            Rectangle()
                .fill(ink)
                .frame(width: TranscriptLayout.rule)
        }
    }
}

/// What colour a speaker is, in one place.
///
/// **One colour for every agent, and the words say which one.** The first drawing gave a subagent
/// a purple rule, which meant borrowing `Palette.merged`, whose own doc says in as many words
/// that it is the colour of a landed pull request and of nothing else, after being spent once on
/// a confirmation button and taken back off it. That rule is worth more than a second hue here,
/// and a second hue was buying nothing: the header already reads "reader said" or "Chat started
/// you with", so the direction is in the sentence and the rule would have been repeating it in a
/// language the reader has to learn first.
///
/// So the rule says one thing, which is that an agent is speaking, and it says it in the accent
/// this window draws its own doing in.
///
/// Bloom's own voice gets no rule at all, and that is the case carrying the meaning: a fact is not
/// a message, and a rule down the left of one would say an agent spoke when none did.
enum CrewInk {
    static func rule(for sender: CrewMessage.Sender) -> Color? {
        switch sender {
        case .orchestrator, .subagent: Palette.accent
        case .bloom: nil
        }
    }
}
