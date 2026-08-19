import SwiftUI

/// One tool call compressed to the single line a collapsed transcript row shows.
///
/// The whole transcript design rests on this: an agent run is hundreds of actions, and the only way
/// to watch one is if every action costs exactly one line. So a presentation is a glyph, a short
/// label that names the intent, and a dimmed detail that names the target. Nothing here is ever raw
/// JSON, because a wall of braces is the thing this view exists to avoid.
struct ToolPresentation: Equatable {
    /// An SF Symbol name.
    var glyph: String
    var label: String
    var detail: String
    var tint: Color
    var chips: [ToolChip] = []
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
enum ToolChip: Equatable {
    /// Not a file. Set in the monospace face, because it is nearly always a fragment of code.
    case code(String)
    /// A file, holding the path exactly as the tool wrote it, absolute or not.
    case file(path: String)

    /// What is written on the chip. A file says its name, the way an attachment does: the folder is
    /// in the tooltip and in the tab that opens, and a path in a chip is the thing the chip
    /// replaced.
    var text: String {
        switch self {
        case .code(let text): text
        case .file(let path): ToolPresenter.basename(path)
        }
    }
}
