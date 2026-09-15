import Foundation

/// The only JavaScript Bloom will ever run in a browser pane on an agent's behalf.
///
/// **Every one of these is written here, in full, at compile time.** There is no case carrying a
/// string from a caller, and there is deliberately no initialiser that takes one: the type is the
/// guarantee. `BrowserSession.evaluate` takes a `BrowserPageScript` and nothing else, so there is
/// no expression anywhere in the app that puts a caller's text into a page. That is not a
/// convention somebody has to remember, it is the signature.
///
/// The one thing a caller influences is a distance, and it reaches the script as an `Int` that has
/// already been parsed out of JSON, range checked and rendered back by Swift. A string cannot
/// survive that trip: there is no path from a caller's characters into the source below.
///
/// Why the substitute is drawn here rather than at the top of `BrowserPaneCommand` is that this is
/// the file somebody adding a seventh script will open, and the argument they need is the one
/// about what these scripts may not become.
public enum BrowserPageScript: Sendable, Equatable {
    /// What the reader would see if they read the page: the rendered text, not the markup.
    ///
    /// `innerText` rather than `textContent`, and the difference is the whole reason this is a
    /// reasonable substitute for handing over the page. `textContent` returns the text of every
    /// node including the ones CSS has hidden, script bodies and template contents among them,
    /// which is both more than the reader can see and the easiest place on a page to hide a
    /// paragraph addressed at a model. `innerText` is what is laid out and visible, which is the
    /// question actually being asked: what is in that browser?
    case visibleText

    /// Move the page, and say where it ended up.
    case scroll(BrowserScroll)

    /// The source, as one expression.
    ///
    /// Wrapped in a function that returns, because `evaluateJavaScript` hands back the completion
    /// value of the script and a bare statement has none worth reading. An expression with a
    /// return in it is also the shape that cannot leave anything behind on the page: no globals,
    /// no listeners, nothing the next call could find.
    public var source: String {
        switch self {
        case .visibleText:
            return """
                (function () {
                  var body = document.body;
                  return body ? body.innerText : "";
                })()
                """
        case .scroll(let scroll):
            return """
                (function () {
                  \(scroll.movement)
                  var page = document.documentElement || {};
                  return [
                    Math.round(window.scrollY || 0),
                    Math.round(page.scrollHeight || 0),
                    Math.round(window.innerHeight || 0)
                  ];
                })()
                """
        }
    }
}

/// Which way a browser pane should be moved, and how far.
///
/// A vocabulary of four directions rather than a pixel offset, because a model does not know how
/// tall the pane is and a person saying "scroll down a bit" is not thinking in pixels. The
/// distance is in screenfuls, which is the unit the space bar works in.
public struct BrowserScroll: Sendable, Equatable {
    public enum Direction: String, Sendable, Equatable, CaseIterable {
        case down
        case up
        case top
        case bottom

        /// Whether a distance means anything for this direction. It does not for the two that name
        /// an end of the page, and passing one is refused rather than ignored, for the reason a
        /// url on a terminal pane is: a caller that passes it believes something.
        var takesDistance: Bool { self == .down || self == .up }
    }

    public var direction: Direction

    /// How many screenfuls, as a percentage, so that the number reaching the script is an integer.
    ///
    /// **Held as a percentage rather than as the fraction the caller passes**, which looks like
    /// fussiness and is not. A `Double` rendered into script source is a `Double` whose text
    /// depends on the locale and the formatter, and "how does this number print" is exactly the
    /// sort of question that turns into a string bug in a place where a string bug is a script
    /// bug. An `Int` prints one way everywhere.
    public var percent: Int

    /// One screenful, which is what a caller that names no distance means.
    public static let defaultPercent = 100
    /// A tenth of a screen, below which nothing visibly moves.
    public static let minimumPercent = 10
    /// Twenty screens. A long page is reached with `bottom`, and a model that means the bottom
    /// should say so rather than guessing at a big number.
    public static let maximumPercent = 2_000

    public init(direction: Direction, percent: Int = BrowserScroll.defaultPercent) {
        self.direction = direction
        self.percent = percent
    }

    /// The one line of the script that moves the page. See `BrowserPageScript.source`.
    var movement: String {
        switch direction {
        case .down: "window.scrollBy(0, Math.round(window.innerHeight * \(percent) / 100));"
        case .up: "window.scrollBy(0, -Math.round(window.innerHeight * \(percent) / 100));"
        case .top: "window.scrollTo(0, 0);"
        case .bottom:
            "window.scrollTo(0, (document.documentElement || {}).scrollHeight || 0);"
        }
    }

    /// Reads the two arguments, or says why it could not, naming what would have worked.
    public static func parse(direction rawDirection: String?, pages rawPages: JSONValue?)
        -> Result<BrowserScroll, PaneRefusal> {
        let list = Direction.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let raw = rawDirection?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !raw.isEmpty else {
            return .failure(
                PaneRefusal("browser_scroll needs a 'direction'. It takes \(list).")
            )
        }
        guard let direction = Direction(rawValue: raw) else {
            return .failure(
                PaneRefusal("Bloom does not scroll '\(raw)'. 'direction' takes \(list).")
            )
        }

        switch rawPages {
        case .none, .null:
            return .success(BrowserScroll(direction: direction))
        default:
            guard direction.takesDistance else {
                return .failure(
                    PaneRefusal(
                        "'pages' means nothing with direction '\(raw)', which goes to the end of "
                            + "the page. Drop it, or scroll 'up' or 'down' by that much."
                    )
                )
            }
            guard let pages = number(rawPages) else {
                return .failure(
                    PaneRefusal(
                        "'pages' is how many screenfuls to scroll, as a number. Leave it out for "
                            + "one screenful."
                    )
                )
            }
            let percent = Int((pages * 100).rounded())
            guard percent >= minimumPercent, percent <= maximumPercent else {
                return .failure(
                    PaneRefusal(
                        "'pages' is between \(fraction(minimumPercent)) and "
                            + "\(fraction(maximumPercent)) screenfuls. For the whole page use "
                            + "direction 'top' or 'bottom'."
                    )
                )
            }
            return .success(BrowserScroll(direction: direction, percent: percent))
        }
    }

    /// A JSON number, whether the caller wrote it with a decimal point or without. A model that
    /// says `1` and a model that says `1.0` mean the same screenful.
    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let double): double
        case .integer(let integer): Double(integer)
        default: nil
        }
    }

    private static func fraction(_ percent: Int) -> String {
        let pages = Double(percent) / 100
        return pages == pages.rounded() ? String(Int(pages)) : String(pages)
    }

    /// What the tool says back, in the units the caller asked in and with the one fact it could
    /// not have known: where the page ended up.
    ///
    /// The three numbers come from the page, so they arrive as whatever the page's own layout
    /// says. They are read as integers and rendered here, which is what makes them safe to put in
    /// a sentence: a number that has been through `Int` carries nothing a page wrote.
    public func report(offset: Int, height: Int, viewport: Int) -> String {
        let moved: String
        switch direction {
        case .down, .up: moved = "Scrolled \(direction.rawValue) \(fraction)."
        case .top: moved = "Scrolled to the top of the page."
        case .bottom: moved = "Scrolled to the bottom of the page."
        }
        guard height > 0 else { return moved }
        let atBottom = offset + viewport >= height - 2
        let position = atBottom
            ? "The view is at the bottom of a \(height) pixel page."
            : "The view starts \(offset) pixels into a \(height) pixel page and shows \(viewport) "
                + "of them."
        return "\(moved) \(position)"
    }

    private var fraction: String {
        percent == 100 ? "one screen" : "\(Self.fraction(percent)) screens"
    }
}

/// How much of a page one call may carry back.
///
/// A cap rather than the whole document, and the number is not about the socket. A single page can
/// be a hundred thousand words, and a tool that quietly fills a turn's context with a page nobody
/// has looked at is a tool that costs the owner money and buries whatever he was actually asking
/// about. Cut with a sentence saying it was cut, so a model that genuinely needs the rest knows
/// there is a rest.
public enum BrowserPageText {
    public static let limit = 20_000

    public static func trim(_ text: String) -> (text: String, cut: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}
