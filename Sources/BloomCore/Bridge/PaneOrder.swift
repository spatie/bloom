import Foundation

/// What an agent asked the window to put in front of the reader, once it has been read off the
/// wire and found to make sense.
///
/// **One value for two tools, and that is the whole reason it exists.** `pane_open` puts a kind in
/// a new tab and `pane_split` puts the same kind beside what is already there; everything else
/// about them is identical, and a second copy of "which kinds are there, what does a url mean,
/// what does focus mean" is how the two would come to disagree about a word the model has already
/// learnt. The verb differs, the noun does not.
///
/// Parsed here rather than in the handlers, and pure, so the suite can hold the refusals: what a
/// model is told when it names a kind that does not exist is a sentence somebody has to be able
/// to read back.
public enum PaneOrderReading: Sendable, Equatable {
    case order(PaneOrder)
    /// Why not, in words a model can act on. Never "invalid input": a model told that tries the
    /// same thing again, and one told which words are accepted picks one of them.
    case refused(String)
}

/// What came of asking the window for a pane.
///
/// An enum rather than a `Result`, because the failure here is a sentence for a model rather than
/// an `Error` anything catches, and `WorkspaceMergeHandoff` next door says the same thing the same
/// way.
public enum PaneOutcome: Sendable, Equatable {
    /// The pane is there. The string is what the model is told, and carries the one fact the
    /// caller could not have known: whether it is in front of the reader.
    case opened(String)
    case refused(String)
}

public struct PaneOrder: Sendable, Equatable {
    public var kind: PaneKind

    /// Where a browser pane should start, and nothing at all for the other two kinds.
    ///
    /// Optional even for a browser: opening one on its own start page is a reasonable ask, and a
    /// tool that demanded an address would make the agent invent one.
    public var url: String?

    /// Whether the new pane is brought to the front.
    ///
    /// **Defaults to true, and can be turned off, which is the shape the owner asked for.** A
    /// terminal opened because somebody said "open me a terminal" and left behind another tab has
    /// not been opened as far as they are concerned. But an agent that opens a browser to check
    /// something while the reader is typing in a chat should be able to say so: `workspace_start`
    /// makes the same distinction with `select: false`, for the same reason, and this is that
    /// choice handed to the caller instead of decided for it.
    public var focus: Bool

    /// What the tab is called, or nothing for the name the strip hands out.
    ///
    /// A name is the difference between four tabs called Terminal and four a reader can tell
    /// apart, and an agent opening one usually knows what it is for: it is opening it in order to
    /// do something nameable. Optional because the strip's own numbering is right whenever
    /// nothing better is known, and a tool that demanded a name would get one invented.
    public var title: String?

    public init(kind: PaneKind, url: String? = nil, focus: Bool = true, title: String? = nil) {
        self.kind = kind
        self.url = url
        self.focus = focus
        self.title = title
    }

    /// A name somebody meant, or nothing.
    ///
    /// Trimmed, and empty is nothing rather than a tab with a blank name: a model passing "" is
    /// saying it has no name to give, and the strip's own numbering is the answer to that.
    public static func name(from raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The kinds named in a tool's description, in the order a reader meets them.
    public static var kindList: String {
        PaneKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    /// Reads an order out of a call, or says why it could not.
    ///
    /// Every refusal names the argument and what would have worked. A model that is told "invalid
    /// input" tries the same thing again; one that is told which words are accepted picks one.
    public static func parse(
        kind rawKind: String?,
        url rawURL: String?,
        focus rawFocus: JSONValue?,
        title rawTitle: String? = nil,
        tool: String
    ) -> PaneOrderReading {
        guard let rawKind, !rawKind.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .refused(
                "\(tool) needs to know what to open. Pass 'kind' as one of \(kindList)."
            )
        }
        guard let kind = PaneKind(rawValue: rawKind.trimmingCharacters(in: .whitespaces)) else {
            return .refused(
                "Bloom has no pane called '\(rawKind)'. It opens \(kindList)."
            )
        }

        let url = rawURL?.trimmingCharacters(in: .whitespaces)
        if let url, !url.isEmpty, kind != .browser {
            // Refused rather than ignored. A url handed to a terminal is a caller that believes
            // something about what it is opening, and silently dropping it would leave that
            // belief in place and the address nowhere.
            return .refused(
                "Only a browser pane takes a 'url'. Drop it, or pass kind 'browser'."
            )
        }

        let focus: Bool
        switch rawFocus {
        case .none, .null: focus = true
        case .bool(let value): focus = value
        default:
            return .refused("'focus' is true or false. Leave it out to bring the pane to the front.")
        }

        return .order(
            PaneOrder(
                kind: kind,
                url: url?.isEmpty == true ? nil : url,
                focus: focus,
                title: name(from: rawTitle)
            )
        )
    }

    /// What the tool says back once the window has done it.
    ///
    /// A sentence rather than an object. Nothing downstream parses this, the model reads it, and
    /// it has to carry the one thing the caller could not have known: whether the pane it asked
    /// for is the one now in front of the reader.
    public var confirmation: String {
        let named = title.map { "\(kind.title) called '\($0)'" } ?? kind.title
        let what = url.map { "\(named) on \($0)" } ?? named
        return focus
            ? "Opened \(what) and brought it to the front."
            : "Opened \(what) in the background. It is in the tab strip but the reader is still on what they were looking at."
    }
}

/// A refusal that travels as an `Error`, for the places a `Result` is the natural shape.
///
/// `PaneSplitTool.axis` reads one word and either has an answer or does not, and `PaneRenameTool`
/// reads two, which is exactly what `Result` is for; the tools themselves refuse through
/// `PaneOrderReading` or `PaneOutcome`, because those carry a success worth naming.
public struct PaneRefusal: Error, Sendable, Equatable {
    public let sentence: String

    public init(_ sentence: String) {
        self.sentence = sentence
    }
}
