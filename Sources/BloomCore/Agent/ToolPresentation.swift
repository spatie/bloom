import Foundation

/// One tool call compressed to the single line a collapsed transcript row shows.
///
/// The whole transcript design rests on this: an agent run is hundreds of actions, and the only way
/// to watch one is if every action costs exactly one line. So a presentation is a glyph, a short
/// label that names the intent, and a dimmed detail that names the target. Nothing here is ever raw
/// JSON, because a wall of braces is the thing this view exists to avoid.
public struct ToolPresentation: Equatable, Sendable {
    /// An SF Symbol name.
    public var glyph: String
    public var label: String
    public var detail: String
    /// A role, not a colour.
    ///
    /// It was a `Color`, which is what kept this type and every decision behind it in the app
    /// target where nothing could test any of it. What a tool row is saying about itself is
    /// "this made something", "this went wrong", "this is asking", and that is a decision;
    /// which teal that becomes is a drawing. `ToolTint.colour` below is the whole of the
    /// drawing, in one place, so a new tool cannot invent a sixth colour by accident.
    public var tint: ToolTint
    public var chips: [ToolChip] = []
    /// Drawn ahead of `detail` in its own ink, and `.none` for every row that is not a shell
    /// command whose `cd` has been read. See `CommandDisplay`: which prefix a row may hide is
    /// decided there, and this is what it left behind.
    public var detailLead: CommandDisplay.Lead = .none
    /// The whole of what `detail` was cut down from, and nil when the row's argument is prose.
    ///
    /// One field answering both of the questions a row asks about its own argument, because they
    /// are the same question. It is `ToolLiteral` that answers it, in the core, where it can be
    /// tested: whether the detail is set in the monospace face, and what a copy would put on the
    /// pasteboard. `detail` is a basename, or a command collapsed to one line and cut at the
    /// pane's edge; this is the path and the command themselves.
    public var literal: String?

    /// Whether the detail is something a machine will run or a machine named.
    ///
    /// The rule this window states everywhere else: mono is for what a machine said or what a
    /// machine will run, and English set in mono reads as data. A row with no literal keeps the
    /// proportional face, which is most of them.
    public var detailIsCode: Bool { literal != nil }

    /// The detail as one string, lead and all: what a row measures itself against and what it
    /// reads as to VoiceOver. Nothing draws it, because the two halves are drawn in two inks.
    public var detailLine: String {
        let lead = detailLead
        return lead.text.isEmpty ? detail : lead.text + lead.joiner + detail
    }

    /// Written out because a memberwise initialiser on a public struct is internal.
    public init(
        glyph: String,
        label: String,
        detail: String,
        tint: ToolTint,
        chips: [ToolChip] = [],
        detailLead: CommandDisplay.Lead = .none,
        literal: String? = nil
    ) {
        self.glyph = glyph
        self.label = label
        self.detail = detail
        self.tint = tint
        self.chips = chips
        self.detailLead = detailLead
        self.literal = literal
    }
}

/// One of the small labels a collapsed tool row carries after its detail.
///
/// Two kinds, and the difference is the whole of this change. A file is drawn the way the composer
/// draws an attached one, with the icon its type deserves and its name, and it opens in the centre
/// column when it is clicked: a file looks like a file wherever it appears in the window. Anything
/// else keeps the monospace plate it has always had, because a count, a flag, a model name or a
/// glob is not a file and putting a document icon on `app/Beacon/**/*.php` would be worse than
/// saying nothing.
///
/// Which one a given argument becomes is decided in `ToolPresenter`, from the tool's own contract
/// where there is one and from `FilePathGuess` where there is not. It is never decided here and
/// never in the view: the answer is part of the presentation, worked out once with the rest of it.
public enum ToolChip: Equatable, Sendable {
    /// Not a file. Set in the monospace face, because it is nearly always a fragment of code.
    case code(String)
    /// A file, holding the path exactly as the tool wrote it, absolute or not.
    case file(path: String)

    /// What is written on the chip. A file says its name, the way an attachment does: the folder is
    /// in the tooltip and in the tab that opens, and a path in a chip is the thing the chip
    /// replaced.
    public var text: String {
        switch self {
        case .code(let text): text
        case .file(let path): ToolPresenter.basename(path)
        }
    }
}
