import Foundation

/// How a caller names one of the workspace's tabs.
///
/// **Two ways rather than one, and that is not indecision.** `BrowserPaneChoice` takes a number
/// and nothing else, and the argument there holds: a uuid is a handle a model cannot read or say
/// back, and a browser's name is the page's own `<title>`, so it moves under the caller and two
/// tabs on one site share it. Neither objection survives the move to tabs.
///
/// A number is still the handle, because it is what a person can check by counting along the
/// strip. But a tab is also the one thing in this window that a person names out loud: "bring the
/// notes forward", "go back to the Fix the parser chat". A model that has just read the listing
/// has that string in front of it, and refusing it would mean the commonest instruction a reader
/// gives has to be translated into a number that will be wrong by the time it is used. So a title
/// is accepted, matched case insensitively, and refused when it names more than one tab, which is
/// exactly the case where a number is the only honest answer.
public enum WorkspaceTabChoice: Sendable, Equatable {
    case number(Int)
    case title(String)

    /// Reads the two arguments, or says why they do not name a tab.
    ///
    /// **Naming both is refused rather than resolved.** They are two ways of saying one thing, a
    /// call that passes both has not decided which it trusts, and picking one for it is how a
    /// model learns that the argument it thought it was using is being ignored.
    ///
    /// A float is refused rather than rounded, for the reason `BrowserPaneChoice.parse` gives: a
    /// caller passing 1.5 has computed something rather than counted, and rounding would act on a
    /// tab it did not choose.
    public static func parse(
        number rawNumber: JSONValue?, title rawTitle: JSONValue?
    ) -> Result<WorkspaceTabChoice, PaneRefusal> {
        let title: String?
        switch rawTitle {
        case .none, .null:
            title = nil
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? nil : trimmed
        default:
            return .failure(
                PaneRefusal(
                    "'title' is the name workspace_tabs prints for a tab, as text. Pass 'tab' "
                        + "instead to name one by its number."
                )
            )
        }

        let number: Int?
        switch rawNumber {
        case .none, .null:
            number = nil
        case .integer(let value):
            guard value >= 1 else {
                return .failure(
                    PaneRefusal(
                        "'tab' is a tab's place in the strip, counting from 1. \(value) is not "
                            + "one of them."
                    )
                )
            }
            number = value
        default:
            return .failure(
                PaneRefusal(
                    "'tab' is a whole number, as workspace_tabs prints it. Call workspace_tabs "
                        + "first and pass one of the numbers it gives."
                )
            )
        }

        switch (number, title) {
        case (let number?, nil):
            return .success(.number(number))
        case (nil, let title?):
            return .success(.title(title))
        case (nil, nil):
            return .failure(
                PaneRefusal(
                    "workspace_tab_select needs to know which tab. Pass 'tab' as the number "
                        + "workspace_tabs prints, or 'title' as the name the strip shows."
                )
            )
        case (.some, .some):
            return .failure(
                PaneRefusal(
                    "Pass 'tab' or 'title', not both. They are two ways of naming one tab, and a "
                        + "call that gives both has not said which it means."
                )
            )
        }
    }

    /// Picks the tab a call meant out of the ones the workspace has, or says why it could not.
    ///
    /// Every refusal lists the tabs. A model told only "no such tab" calls again with another
    /// guess; one handed the strip picks off it.
    public static func choose(
        _ choice: WorkspaceTabChoice, among tabs: [WorkspaceTabReport]
    ) -> Result<WorkspaceTabReport, PaneRefusal> {
        guard !tabs.isEmpty else {
            return .failure(
                PaneRefusal(
                    "That workspace has nothing open in the centre column, so there is no tab to "
                        + "bring forward. pane_open is what opens one."
                )
            )
        }

        switch choice {
        case .number(let number):
            guard let found = tabs.first(where: { $0.number == number }) else {
                return .failure(
                    PaneRefusal(
                        "There is no tab \(number) in this workspace. The tabs are \(list(tabs)). "
                            + "The numbers move as tabs are opened and closed, so call "
                            + "workspace_tabs again."
                    )
                )
            }
            return .success(found)

        case .title(let title):
            let matches = tabs.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            guard !matches.isEmpty else {
                return .failure(
                    PaneRefusal(
                        "This workspace has no tab called '\(title)'. The tabs are \(list(tabs))."
                    )
                )
            }
            // Two chats can carry one name, and a reader who renamed both meant something by it.
            // Guessing between them would be selecting a tab the caller did not name, which is the
            // one thing this tool must not do.
            guard matches.count == 1 else {
                return .failure(
                    PaneRefusal(
                        "\(matches.count) tabs are called '\(title)': "
                            + "\(list(matches)). Pass 'tab' with the number of the one you mean."
                    )
                )
            }
            return .success(matches[0])
        }
    }

    /// The tabs, named the way the refusals name them: the number, the title and what it is.
    ///
    /// All three, because none of them alone tells a strip of four chats apart from a strip of a
    /// chat, a terminal, a review and a browser.
    private static func list(_ tabs: [WorkspaceTabReport]) -> String {
        tabs.map { "\($0.number) '\($0.title)' (\($0.kind.rawValue))" }.joined(separator: ", ")
    }
}

/// What came of asking the window to bring a tab forward.
///
/// Its own two cases rather than `PaneOutcome`, whose success case is called `opened` and would
/// have this tool telling a model it opened something. Nothing here opens anything, and the word
/// is the whole point.
public enum WorkspaceTabSelection: Sendable, Equatable {
    case selected(String)
    case refused(String)
}
