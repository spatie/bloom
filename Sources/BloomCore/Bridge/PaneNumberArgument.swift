import Foundation

/// How a caller names one thing out of several the reader has open, by the number a listing tool
/// printed beside it.
///
/// ## One rule, written three times
///
/// `BrowserPaneChoice`, `TerminalPaneChoice` and `WorkspaceTabChoice` each read a number argument
/// and each reached the same three conclusions: nothing at all is nothing, a whole number from 1
/// is a choice, and anything else is refused. A float is refused rather than rounded, and that is
/// the part worth keeping in one place: a caller passing 1.5 has computed something rather than
/// counted along a strip, and rounding would act on a pane it did not choose. Three copies of that
/// judgement are three chances for one of them to start rounding.
///
/// ## Why the prose is a field rather than a template
///
/// The refusals stay tool-specific because a good refusal names the argument, says what prints the
/// numbers and says what to do instead, and those differ: a browser and a terminal are both
/// numbered by `pane_list`, a tab by `workspace_tabs`, and "leave it out when only one is open" is
/// true of the first two and not of the third, which has no such shorthand. So the shape of the
/// sentence is here and the words in it are declared beside the tool family that says them. The
/// three values below are the sentences those three types used to hold, unchanged.
///
/// ## Why a number at all
///
/// **A number from a listing and nothing else**, and the alternatives were considered and are all
/// worse. An id is a uuid, which a model cannot read, cannot repeat to a person and can carry in
/// from somewhere stale. A name is the page's own title most of the time, so it changes under the
/// caller as the page navigates and two tabs on one site share it. A kind, which is what
/// `pane_close` and `pane_rename` take, works only while there is one of the thing.
///
/// So: 1, 2, 3, left to right in the strip, exactly as the listing prints them. It is a handle that
/// lives as long as the listing that produced it, which every tool description says out loud
/// rather than pretending away. `WorkspaceTabChoice` accepts a title as well, and its own head
/// argues why that objection does not survive the move from a browser to a tab.
public struct PaneNumberArgument: Sendable {
    /// What the argument is called on the wire: `browser`, `terminal`, `tab`.
    public let name: String
    /// What the number is, said the way the refusal says it: "the number pane_list gives a
    /// browser", "a tab's place in the strip".
    public let describedAs: String
    /// Which tool prints these numbers, for the refusal that has to send the caller to it.
    public let printedBy: String
    /// What to do instead, when the value was not a whole number at all. A whole sentence, because
    /// what a caller should do differs by family and half a sentence cannot say it.
    public let instead: String

    public init(name: String, describedAs: String, printedBy: String, instead: String) {
        self.name = name
        self.describedAs = describedAs
        self.printedBy = printedBy
        self.instead = instead
    }

    /// Reads the argument: a whole number from 1, or nothing at all.
    public func parse(_ raw: JSONValue?) -> Result<Int?, PaneRefusal> {
        switch raw {
        case .none, .null:
            return .success(nil)
        case .integer(let number):
            guard number >= 1 else {
                return .failure(
                    PaneRefusal(
                        "'\(name)' is \(describedAs), counting from 1. \(number) is not one of "
                            + "them."
                    )
                )
            }
            return .success(number)
        default:
            return .failure(
                PaneRefusal("'\(name)' is a whole number, as \(printedBy) prints it. \(instead)")
            )
        }
    }

    /// One of the reader's browsers, as `pane_list` numbers them.
    public static let browser = PaneNumberArgument(
        name: "browser",
        describedAs: "the number pane_list gives a browser",
        printedBy: "pane_list",
        instead: "Leave it out when there is only one browser open, and call pane_list first when "
            + "there is more than one."
    )

    /// One of the reader's terminals, as `pane_list` numbers them.
    public static let terminal = PaneNumberArgument(
        name: "terminal",
        describedAs: "the number pane_list gives a terminal",
        printedBy: "pane_list",
        instead: "Leave it out when only one terminal is open, and call pane_list first when there "
            + "is more than one."
    )

    /// A place in the workspace's tab strip, as `workspace_tabs` numbers them.
    ///
    /// No "leave it out" clause, and that is not an omission: `workspace_tab_select` needs to know
    /// which tab either way, and a call that names none is refused by `WorkspaceTabChoice.parse`
    /// with a sentence that offers the title instead.
    public static let tab = PaneNumberArgument(
        name: "tab",
        describedAs: "a tab's place in the strip",
        printedBy: "workspace_tabs",
        instead: "Call workspace_tabs first and pass one of the numbers it gives."
    )
}
