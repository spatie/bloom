import Foundation
import Testing
@testable import BloomCore

/// The postcard window, the welcome sequence's last step and one line of the About window all
/// render `Postcard` and decide none of it, so this file is where its claims are held.
///
/// The address is the reason this suite is worth more than most. Everything else in this app can
/// be wrong and be corrected in the next build; an address that ships wrong is acted on by
/// somebody with a pen, a stamp and no way to find out.
@Suite("Postcard")
struct PostcardTests {
    /// Spatie's address, exactly as the contact page gives it. The lines are a presentation of
    /// this string and nothing else, so joining them back up has to produce it.
    @Test("The four lines are the address, and joining them gives the address back")
    func addressIsTheAddress() {
        #expect(Postcard.addressLines.count == 4)
        #expect(Postcard.addressLine == "Spatie, Kruikstraat 22, Box 12, 2018 Antwerp, Belgium")
        #expect(Postcard.address == "Spatie\nKruikstraat 22, Box 12\n2018 Antwerp\nBelgium")
        for line in Postcard.addressLines {
            #expect(!line.isEmpty)
            #expect(line.trimmingCharacters(in: .whitespaces) == line)
        }
    }

    /// What the copy button puts on the pasteboard. Four lines with their breaks intact, because
    /// an address arriving as one comma separated run has to be taken apart again by hand.
    @Test("The copied form is line broken, and the printed form is not")
    func copiedFormKeepsItsLines() {
        #expect(Postcard.address.components(separatedBy: "\n").count == 4)
        #expect(!Postcard.addressLine.contains("\n"))
    }

    @Test("The wall is an https address for exactly the host that is printed")
    func wallResolves() {
        #expect(Postcard.wall.scheme == "https")
        #expect(Postcard.wall.host() == "spatie.be")
        #expect(Postcard.wall.path() == "/open-source/postcards")
        #expect(Postcard.wall.absoluteString == "https://" + Postcard.wallHost)
        // Printed without a scheme, the way `Maker.host` is.
        #expect(!Postcard.wallHost.contains("://"))
    }

    /// The rule the file's own head sets: the wall has had cards on it for years and the number
    /// goes up every week, so a figure compiled into a shipped app is wrong inside a month.
    /// `MakerTests` holds the identity paragraphs the same way.
    @Test("Nothing in the prose claims a figure that will go stale")
    func noStaleFigures() {
        for sentence in Postcard.paragraphs + [Postcard.summary, Postcard.headline] {
            #expect(!sentence.contains { $0.isNumber }, "\(sentence)")
        }
    }

    @Test("The prose is two paragraphs, a lead that is the first of them, and a one line summary")
    func proseIsShaped() {
        #expect(Postcard.paragraphs.count == 2)
        #expect(Postcard.lead == Postcard.paragraphs[0])
        for paragraph in Postcard.paragraphs {
            #expect(paragraph.hasSuffix("."))
        }
        #expect(Postcard.summary.hasSuffix("."))
        // The headline is a heading rather than a sentence, so it carries no stop.
        #expect(!Postcard.headline.hasSuffix("."))
        // The word itself has to be in the headline and in the line the About window sets, since
        // both are somebody's first meeting with it.
        #expect(Postcard.headline.lowercased().contains("postcardware"))
        #expect(Postcard.summary.lowercased().contains("postcardware"))
    }

    /// The ask is what it is: a postcard, from a hometown, saying what Bloom is being used for.
    /// Spatie's own wording for every package says the same three things, and this is that wording
    /// with the package swapped for the app.
    @Test("The lead asks for a postcard from a hometown, and says what to write on it")
    func theAskIsTheAsk() {
        let lead = Postcard.lead.lowercased()
        #expect(lead.contains("free to use"))
        #expect(lead.contains("postcard"))
        #expect(lead.contains("hometown"))
        #expect(lead.contains("building"))
        // Never an obligation. Bloom does not check and does not ask twice, so the copy may not
        // read as though it does.
        #expect(!lead.contains("please"))
        #expect(!lead.contains("must"))
    }

    @Test("The second paragraph is the one about the wall, so the first can stand alone")
    func theWallIsTheSecondParagraph() {
        #expect(Postcard.paragraphs[1].lowercased().contains("postcard wall"))
        #expect(!Postcard.lead.lowercased().contains("wall"))
    }
}

/// The one movement on the postcard screens. Two invariants matter and both are about numbers,
/// which is why they are here rather than inside a view where nothing could hold them.
@Suite("The postcard's arrival")
struct PostcardArrivalTests {
    @Test("Reduce Motion gets no movement at all, rather than a slower one")
    func reduceMotionIsAnAbsence() {
        #expect(PostcardArrival.settle(reduceMotion: true) == nil)
        #expect(PostcardArrival.seconds(reduceMotion: true) == 0)
        #expect(PostcardArrival.settle(reduceMotion: false) != nil)
    }

    /// The card lies a little off square whether it moved or not. The setting is about movement,
    /// and a card at an angle is not moving; taking the angle away as well would leave that reader
    /// looking at a different drawing rather than at the same one held still.
    @Test("The resting angle is a small one and survives Reduce Motion")
    func theCardLiesAskew() {
        #expect(PostcardArrival.restAngle != 0)
        #expect(abs(PostcardArrival.restAngle) < 5)
    }

    /// The whole of what makes the fall read as depth. A card that travelled with a fixed shadow
    /// would be a sticker sliding across glass.
    @Test("The shadow tightens on the way down rather than spreading")
    func theShadowTightens() throws {
        let settle = try #require(PostcardArrival.settle(reduceMotion: false))
        #expect(settle.startShadow.blur > settle.restShadow.blur)
        #expect(settle.startShadow.drop > settle.restShadow.drop)
        // And it darkens as it contracts, which is the other half of what a shadow does as the
        // thing casting it comes down.
        #expect(settle.startShadow.opacity < settle.restShadow.opacity)
        #expect(settle.restShadow == PostcardArrival.restShadow)
    }

    @Test("It starts above and to the side, larger, and out of nothing")
    func itArrivesFromSomewhere() throws {
        let settle = try #require(PostcardArrival.settle(reduceMotion: false))
        #expect(settle.offsetY < 0)
        #expect(settle.offsetX > 0)
        #expect(settle.startScale > 1)
        #expect(settle.startOpacity == 0)
        // A turn as it comes down rather than a tumble. Past about fifteen degrees the eye reads a
        // spin, and a spinning postcard is a graphic.
        #expect(settle.startAngle > PostcardArrival.restAngle)
        #expect(settle.startAngle < 15)
    }

    /// It plays once and rests. This card is on a window somebody leaves open beside their work,
    /// so an arrival that outstayed a second would be an animation rather than a landing.
    @Test("The whole thing is over inside a second")
    func itIsOverQuickly() throws {
        let settle = try #require(PostcardArrival.settle(reduceMotion: false))
        #expect(settle.delay > 0)
        #expect(settle.endsAfter == settle.delay + settle.seconds)
        #expect(settle.endsAfter < 1)
        #expect(PostcardArrival.seconds(reduceMotion: false) == settle.endsAfter)
    }
}

@Suite("The stamp's press")
struct PostcardPressTests {
    /// Reduce Motion answers with nothing rather than with a shorter press, so a caller cannot
    /// honour half of it. Same rule as `settle`.
    @Test func reducedMotionPressesNothing() {
        #expect(PostcardArrival.press(reduceMotion: true) == nil)
        #expect(PostcardArrival.press(reduceMotion: false) != nil)
    }

    /// It arrives large and fades in, which is a thumb pressing a stamp down rather than a card
    /// travelling across the page: no offset and no angle are offered at all.
    @Test func comesDownRatherThanAcross() throws {
        let press = try #require(PostcardArrival.press(reduceMotion: false))

        #expect(press.startScale > 1)
        #expect(press.startOpacity == 0)
    }

    /// Shorter than the card's descent, and over quickly enough that nobody waits for it. The card
    /// is a journey and this is one movement.
    @Test func isShorterThanTheCardsDescent() throws {
        let press = try #require(PostcardArrival.press(reduceMotion: false))
        let settle = try #require(PostcardArrival.settle(reduceMotion: false))

        #expect(press.seconds < settle.seconds)
        #expect(press.endsAfter < 1)
    }
}

@Suite("The wall in the prose")
struct PostcardWallLinkTests {
    /// The substitution is silent when it misses: a phrase that stopped matching would leave the
    /// paragraph unlinked rather than fail, and nobody would notice until the window shipped
    /// without a way to the wall.
    @Test func theLinkedPhraseIsActuallyInTheProse() {
        #expect(Postcard.paragraphs.contains { $0.contains(Postcard.wallPhrase) })
    }

    /// Exactly one paragraph gains a link, and the address of it is the wall.
    @Test func exactlyOneParagraphCarriesTheWall() {
        let linked = Postcard.linkedParagraphs.filter { $0.contains(Postcard.wall.absoluteString) }

        #expect(linked.count == 1)
        #expect(linked.first?.contains("[\(Postcard.wallPhrase)](") == true)
    }

    /// The plain wording is untouched, because the welcome step's spoken label and the wording
    /// test both read it and neither wants Markdown in it.
    @Test func thePlainParagraphsKeepNoMarkup() {
        for paragraph in Postcard.paragraphs {
            #expect(!paragraph.contains("]("))
        }
    }
}
