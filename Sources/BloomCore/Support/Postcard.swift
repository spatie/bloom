import Foundation

/// What Bloom asks for in return, which is a postcard.
///
/// Bloom is postcardware. Every Spatie package README has said the same thing for years, in the
/// same words, and this is those words adapted for an app: it is Bloom somebody is using rather
/// than a package, so what they are asked to mention is what they are building with it.
///
/// Beside `Maker` rather than inside it, and the split is the same one `AppSite` makes. `Maker` is
/// who built this and what else they build; this is the one thing they ask of anybody who keeps
/// it. Three surfaces render what is below, the postcard window, the last step of the welcome
/// sequence and a line in the About window, and a sentence typed into any one of them is a
/// sentence nothing in `Tests/BloomCoreTests` can hold still.
///
/// **There is no count anywhere in here, and there must not be.** The wall has had cards on it for
/// years and the number goes up every week, so a figure compiled into a shipped app is wrong
/// inside a month and stays wrong until somebody ships a correction. `Maker.identityParagraphs`
/// makes the same argument about package counts and download figures, and `MakerTests` holds it
/// by refusing a digit in the prose. This file is held the same way.
public enum Postcard {
    /// The word, and the whole idea, in the register the site uses for it: free to use if you send
    /// us a postcard. What the postcard window leads with.
    public static let headline = "Bloom is postcardware"

    /// The two paragraphs under that headline, and the same two the welcome step sets.
    ///
    /// Two rather than one, and the split falls where the subject changes, which is the shape
    /// `Maker.identityParagraphs` already established: the ask, and then what happens to what you
    /// send. The second stands on its own so that a surface with room for one paragraph can take
    /// the first and lose nothing but the wall.
    ///
    /// "We would love" rather than "please send", because the whole point of postcardware is that
    /// nothing is owed. Bloom does not check, does not ask twice, and works exactly the same
    /// either way.
    public static let paragraphs = [
        "Bloom is free to use. If it earns a place in your day, we would love a postcard from "
            + "your hometown, telling us what you are building with it.",
        "Every card we receive goes up on our virtual postcard wall, next to the ones people have "
            + "sent us for our open source work over the years.",
    ]

    /// The first of them on its own, for a surface with room for one.
    ///
    /// The welcome step is that surface: the card is 340 points wide and a card's worth of height,
    /// and a second paragraph over it would push the last screen of the sequence past the height
    /// of the ones before it. What it loses is the sentence about the wall, and the link under the
    /// card says where the wall is anyway.
    public static var lead: String { paragraphs[0] }

    /// One line for a window that has room for a line: the About window, under the sentence that
    /// already says Bloom is made in Antwerp.
    ///
    /// The site's own framing, which is "all of our packages are postcardware: free to use if you
    /// send us a postcard", with the colon kept because the colon is what makes the unfamiliar
    /// word explain itself in the same breath.
    public static let summary =
        "Bloom is postcardware: free to use, and if you like it, send us a postcard from your "
            + "hometown."

    /// What a postcard is addressed to, one line per line of an address, because that is how it
    /// goes onto a card and how it goes onto a label.
    ///
    /// Copied as these lines joined by newlines rather than as the one line form below. Somebody
    /// pressing a copy button next to an address is about to paste it somewhere it will be
    /// written out, and an address that arrives as a single comma separated run has to be taken
    /// apart again by hand.
    public static let addressLines = [
        "Spatie",
        "Kruikstraat 22, Box 12",
        "2018 Antwerp",
        "Belgium",
    ]

    /// The address as it goes on a card.
    public static var address: String { addressLines.joined(separator: "\n") }

    /// The same address written as a sentence, which is how the contact page prints it and the
    /// form a test can compare against without knowing where the lines were broken.
    public static var addressLine: String { addressLines.joined(separator: ", ") }

    /// Where the cards end up. Printed without a scheme, the way `Maker.host` is and for the same
    /// reason: a printed address says where a click goes before it is clicked.
    public static let wallHost = "spatie.be/open-source/postcards"

    /// Force unwrapped for the reason `MakerProduct.url` is: a literal with nothing in it that can
    /// fail to parse does not want a fallback branch dressed up as a safety net.
    public static let wall = URL(string: "https://\(wallHost)")!

    /// What the printed address is labelled with. A bare URL in a window is a string somebody has
    /// to decode before they know whether it is worth a click, and this one is a place with things
    /// in it rather than a company's front door.
    public static let wallTitle = "The postcard wall"
}
