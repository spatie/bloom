import Foundation

/// One of the maker's products: a name, one sentence saying what it is, and the host the About
/// window prints and links to.
public struct MakerProduct: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let host: String

    /// The bundle resource holding the product's mark, without extension. The names point at the
    /// same three files the download email on runbloom.app renders, copied into `Resources/`
    /// rather than referenced across repositories, so the app and the email show the same marks.
    /// A name rather than an image, because this target draws nothing.
    public let logoResource: String

    /// Force unwrapped for the same reason `BuildIdentity` never apologises for its literals: the
    /// hosts below are literals with nothing in them that can fail to parse, so a fallback here
    /// would be an unreachable branch dressed up as a safety net.
    public var url: URL { URL(string: "https://\(host)")! }

    public init(name: String, summary: String, host: String, logoResource: String) {
        self.name = name
        self.summary = summary
        self.host = host
        self.logoResource = logoResource
    }
}

/// The app's own address, printed and linked from the About window's plinth. Beside `Maker`
/// rather than inside it because runbloom.app is Bloom's page, not a fact about Spatie; in this
/// file because the About window reads the two together and they are held to the same rule, data
/// in the core, rendered by the view.
public enum AppSite {
    public static let host = "runbloom.app"
    public static let url = URL(string: "https://runbloom.app")!
}

/// Who made this app, and what else they make. The About window renders this; it decides none of it.
///
/// Data rather than strings in a view, because `Tests/BloomCoreTests` depends on this target alone
/// and a sentence typed into `AboutView` is a sentence nothing can test. The wording below tracks
/// the download email on runbloom.app, tightened for a window rather than an email, so the app and
/// the site describe the same products in the same terms and a claim changed in one place is a
/// test failure rather than a quiet fork.
///
public enum Maker {
    public static let name = "Spatie"

    /// Printed without a scheme, because that is how the site prints it: the ghost button at the
    /// foot of the makers section says `spatie.be`.
    public static let host = "spatie.be"

    public static let url = URL(string: "https://spatie.be")!

    /// Who they are and where Bloom stands in it, for a reader who has never heard the name.
    /// Two paragraphs rather than one, the company and then the app, because as a single block
    /// the four lines read as a wall; the split falls where the subject changes. The second
    /// stands on its own: "the same spirit" points at the giving away the first has just
    /// described, not at a clause of its own sentence. It ends on free, which is a claim the
    /// site's approved about page makes in as many words, and there are no package counts and
    /// no download figures anywhere in it: both are true today and wrong by next month, and a
    /// stale boast in an About window outlives every correction.
    public static let identityParagraphs = [
        "An Antwerp web development company, known for a large body of open source work for "
            + "Laravel and PHP, given away over many years, and for the products below.",
        "Bloom is made in the same spirit: a tool we built for our own daily work, free for "
            + "anyone who wants it.",
    ]

    /// The email's order, kept: Flare, Mailcoach, There There.
    public static let products: [MakerProduct] = [
        MakerProduct(
            name: "Flare",
            summary: "Error tracking and performance monitoring, built for Laravel and PHP.",
            host: "flareapp.io",
            logoResource: "MakerFlare"
        ),
        MakerProduct(
            name: "Mailcoach",
            summary: "Sends newsletters, drip campaigns and transactional email, on our servers or yours.",
            host: "mailcoach.app",
            logoResource: "MakerMailcoach"
        ),
        MakerProduct(
            name: "There There",
            summary: "A help desk, AI assisted and human led.",
            host: "there-there.app",
            logoResource: "MakerThereThere"
        ),
    ]
}
