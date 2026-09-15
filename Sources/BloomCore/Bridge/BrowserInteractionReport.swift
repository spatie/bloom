import Foundation

/// What the tools that act inside a page say back, turned from the short words the scripts answer
/// with into sentences a model can act on.
///
/// Here rather than in the window because each of these is a decision about what went wrong and
/// what to do next, and the window is the one place nothing can test.
public enum BrowserInteractionReport {
    /// What every answer that used a reference says when the reference no longer names anything.
    static func lost(_ word: String, ref: BrowserElementRef) -> BrowserPaneAnswer? {
        switch word {
        case "missing":
            return .refused(
                "There is no \(ref.label) on this page. References last until the next "
                    + "browser_snapshot or until the page navigates, whichever comes first. Take a "
                    + "new snapshot and use a reference from it."
            )
        case "detached":
            return .refused(
                "\(ref.label) is no longer on the page: it was removed or drawn again since the "
                    + "snapshot. Take a new snapshot."
            )
        case "disabled":
            return .refused("\(ref.label) is disabled, so Bloom left it alone.")
        default:
            return nil
        }
    }

    static let unanswered = BrowserPaneAnswer.refused(
        "That page did not answer. It may have navigated while Bloom was acting on it. "
            + "browser_read says where it is now."
    )

    /// What follows every outline: how to use it, and what a reference is good for.
    public static let snapshotFooter = """
        Pass a reference such as e3 to browser_click, browser_fill or browser_press. References \
        stop working when the page navigates or you take another snapshot.
        """

    public static func click(_ answer: [String], ref: BrowserElementRef) -> BrowserPaneAnswer {
        guard let word = answer.first else { return unanswered }
        if let lost = lost(word, ref: ref) { return lost }
        guard word == "clicked" else { return unanswered }
        var sentence = "Clicked \(ref.label)."
        if answer.count > 1, !answer[1].isEmpty {
            sentence += " Something else lies over the middle of it (\(answer[1]), as the page "
                + "describes it), so a person clicking there would have hit that instead. The "
                + "click went to \(ref.label) itself."
        }
        sentence += " If it changed the page, take a new snapshot before using another reference."
        return .told(sentence)
    }

    public static func fill(_ answer: [String], ref: BrowserElementRef, text: String) -> BrowserPaneAnswer {
        guard let word = answer.first else { return unanswered }
        if let lost = lost(word, ref: ref) { return lost }
        let detail = answer.count > 1 ? answer[1] : ""
        switch word {
        case "filled":
            return .told(
                text.isEmpty
                    ? "Cleared \(ref.label)."
                    : "Filled \(ref.label) with \(text.count) characters."
            )
        case "selected":
            return .told("Chose the option \"\(detail)\" in \(ref.label).")
        case "no-option":
            return .refused(
                "\(ref.label) has no option matching that. Its options, as the page writes them, "
                    + "are: \(detail)."
            )
        case "not-editable":
            return .refused(
                "\(ref.label) is \(detail.isEmpty ? "not a field" : "a \(detail)"), which cannot be "
                    + "filled. Use browser_click for buttons, checkboxes and radio buttons."
            )
        case "readonly":
            return .refused("\(ref.label) is read only, so Bloom left it alone.")
        default:
            return unanswered
        }
    }

    public static func press(_ answer: [String], key: BrowserKey, ref: BrowserElementRef?) -> BrowserPaneAnswer {
        guard let word = answer.first else { return unanswered }
        if let ref, let lost = lost(word, ref: ref) { return lost }
        let spoken = key.spoken
        var sentence: String
        switch word {
        case "pressed": sentence = "Pressed \(spoken)."
        case "cancelled": sentence = "Pressed \(spoken), and the page handled it itself."
        case "submitted": sentence = "Pressed \(spoken), which submitted the form."
        case "activated": sentence = "Pressed \(spoken) on a button or link, which activated it."
        case "moved": sentence = "Pressed \(spoken), which moved focus."
        default: return unanswered
        }
        if answer.count > 1, !answer[1].isEmpty {
            sentence += " Focus is on \(answer[1]), as the page describes it."
        }
        return .told(sentence)
    }

    public static func wait(_ wait: BrowserWait, _ outcome: BrowserWait.Outcome) -> BrowserPaneAnswer {
        switch outcome {
        case .met(let elapsed): .told(wait.report(met: true, afterMilliseconds: elapsed))
        case .timedOut(let elapsed): .told(wait.report(met: false, afterMilliseconds: elapsed))
        case .badSelector:
            .refused("That is not a CSS selector the page can read. Check it, or wait for 'text' instead.")
        }
    }

    /// What `browser_console` adds after the log, on the call that started the listening.
    public static let consoleJustStarted = """
        Bloom started listening to this page's console with this call, so nothing logged before \
        it is here. Call browser_console again after doing something, or browser_reload and then \
        browser_console to hear the page from the start.
        """

    /// What `browser_network` adds after the list, because it is not a network panel and a model
    /// should not read it as one.
    public static let networkNote = """
        This is the browser's Resource Timing record: what was fetched, how long it took, and a \
        status where WebKit reports one ("-" where it does not). It has no methods, headers or \
        bodies. Requests made from a cross-origin frame are not in it.
        """
}

extension BrowserWait {
    /// How a wait ended.
    public enum Outcome: Sendable, Equatable {
        case met(Int)
        case timedOut(Int)
        case badSelector
    }
}
