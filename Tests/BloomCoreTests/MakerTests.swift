import Foundation
import Testing
@testable import BloomCore

/// The About window renders `Maker` and decides nothing, so this file is where its claims are
/// held. The products and their order come from the download email on runbloom.app; a change here
/// should be a deliberate change to what the app says about its makers, not a drive-by.
@Suite("Maker")
struct MakerTests {
    @Test("The email's products, in the email's order")
    func productsMatchTheEmail() {
        #expect(Maker.products.map(\.name) == ["Flare", "Mailcoach", "There There"])
        #expect(Maker.products.map(\.host) == ["flareapp.io", "mailcoach.app", "there-there.app"])
    }

    /// The names point at files in `Resources/` that `Tools/build.sh` copies into the bundle by
    /// the `Maker*.png` glob, so a rename on either side breaks this list or that glob, and this
    /// test is the cheaper of the two places to hear about it.
    @Test("Every product names the mark the download email renders")
    func productsCarryTheirMarks() {
        #expect(
            Maker.products.map(\.logoResource)
                == ["MakerFlare", "MakerMailcoach", "MakerThereThere"]
        )
    }

    @Test("Every printed host resolves to an https URL for exactly that host")
    func hostsAndURLsAgree() {
        for product in Maker.products {
            #expect(product.url.scheme == "https")
            #expect(product.url.host() == product.host)
        }
        #expect(Maker.url.scheme == "https")
        #expect(Maker.url.host() == Maker.host)
        #expect(AppSite.url.scheme == "https")
        #expect(AppSite.url.host() == AppSite.host)
    }

    @Test("A summary is a sentence, not a fragment and not a paragraph")
    func summariesAreSentences() {
        for product in Maker.products {
            #expect(product.summary.hasSuffix("."))
            #expect(!product.summary.isEmpty)
            // One line in a narrow window. The longest summary today is 84 characters; the cap
            // is where a summary stops being a line and starts being a pitch.
            #expect(product.summary.count <= 90)
        }
    }

    @Test("The identity copy is two paragraphs and claims no figure that will go stale")
    func identityIsTwoHonestParagraphs() {
        #expect(Maker.identityParagraphs.count == 2)
        for paragraph in Maker.identityParagraphs {
            #expect(!paragraph.contains { $0.isNumber })
            #expect(paragraph.hasSuffix("."))
        }
        #expect(Maker.identityParagraphs[0].contains("Antwerp"))
        #expect(Maker.identityParagraphs[1].contains("Bloom"))
    }
}
