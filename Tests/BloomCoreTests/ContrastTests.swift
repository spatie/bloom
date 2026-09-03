import Foundation
import Testing
@testable import BloomCore

/// `Contrast.deltaE` against the numbers its authors published.
///
/// A colour-difference formula written from a description is the kind of thing that is subtly
/// wrong and still looks plausible: drop the `G` stretch and near-neutrals stop separating, get
/// the mean-hue rule backwards and only pairs straddling 360 are wrong, leave out `Rt` and every
/// blue is over-counted. Each of those still returns a number that rises with difference, so an
/// app tuned against it would look fine and the claim in every doc comment would be false.
///
/// So the pairs come from Sharma, Wu and Dalal's test data, the set published with the paper
/// exactly so an implementation can be checked. They are stated in Lab and have no sRGB form,
/// which is why `deltaE` takes a Lab pair as well as two colours. The six chosen here are the ones
/// that fail differently: three near-neutral blues that need `G` and the mean-hue rule, a green
/// and a blue-grey that exercise the weights, and a near-black pair where the lightness term
/// dominates.
@Suite("Colour difference")
struct ContrastTests {
    @Test("CIEDE2000 answers the published pairs")
    func thePublishedPairs() {
        let pairs: [((l: Double, a: Double, b: Double), (l: Double, a: Double, b: Double), Double)] = [
            ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
            ((50, -1.3802, -84.2814), (50, 0, -82.7485), 1.0000),
            ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644),
            ((63.0109, -31.0961, -5.8663), (62.8187, -29.7946, -4.0864), 1.2630),
            ((22.7233, 20.0904, -46.6940), (23.0331, 14.9730, -42.5619), 2.0373),
            ((2.0776, 0.0795, -1.1350), (0.9033, -0.0636, -0.5514), 0.9082),
        ]

        for (one, other, expected) in pairs {
            let measured = Contrast.deltaE(one, other)
            #expect(
                abs(measured - expected) < 0.0001,
                "\(one) against \(other): \(measured) rather than \(expected)"
            )
        }
    }

    /// Order cannot change the answer, and a colour is no distance from itself. The first is what
    /// stops a pair passing because it was stated the other way round; the second is the case the
    /// report was about, and the one a hue term written wrong can get wrong.
    @Test("the difference is symmetric, and zero for one colour")
    func theShapeOfTheAnswer() {
        #expect(Contrast.deltaE(0x0C7A6E, 0x0C7A6E) == 0)
        let forwards = Contrast.deltaE(PaletteInk.running.light, PaletteInk.warning.light)
        let backwards = Contrast.deltaE(PaletteInk.warning.light, PaletteInk.running.light)
        #expect(abs(forwards - backwards) < 0.0001)
    }

    /// sRGB's own anchors, so a mistake in the white point or the transfer function cannot be
    /// absorbed by the pairs above, which are all stated in Lab and never touch the conversion.
    @Test("Lab is measured from sRGB the way the standard says")
    func theConversionIsTheStandardOne() {
        let white = Contrast.lab(of: 0xFFFFFF)
        #expect(abs(white.l - 100) < 0.01)
        #expect(abs(white.a) < 0.01)
        #expect(abs(white.b) < 0.01)

        let black = Contrast.lab(of: 0x000000)
        #expect(abs(black.l) < 0.0001)

        // Mid grey, which has no chroma and a lightness everybody quotes.
        let grey = Contrast.lab(of: 0x808080)
        #expect(abs(grey.l - 53.585) < 0.01)
        #expect(abs(grey.a) < 0.01)
        #expect(abs(grey.b) < 0.01)
    }

    /// **The reason there is now one transfer function where there were two.**
    ///
    /// `relativeLuminance` linearised a channel at WCAG's knee, 0.03928, and `lab` linearised it at
    /// the sRGB standard's, 0.04045. Two nearly identical functions in one file with silently
    /// different constants reads as a bug in one of them, and the honest answer is that both were
    /// right for the standard each quoted and that neither said so.
    ///
    /// They also cannot disagree. A channel here is always an integer 0 to 255, and both knees fall
    /// between 10/255 and 11/255, so every value lands on the same side of both. That is arithmetic
    /// somebody would otherwise have to redo, so it is walked instead: all 256 values, against both
    /// historical spellings, so that moving the shared number names the channel it broke.
    @Test("both standards' knees classify every channel the same way")
    func theTwoThresholdsAgreeEverywhere() {
        func linear(_ channel: UInt32, knee: Double) -> Double {
            let value = Double(channel) / 255
            return value <= knee ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        for channel in UInt32(0)...255 {
            let wcag = linear(channel, knee: 0.03928)
            let srgb = linear(channel, knee: 0.04045)
            #expect(wcag == srgb, "channel \(channel)")

            // And what the file actually calls, reached through the one public door it has.
            let grey = channel << 16 | channel << 8 | channel
            let luminance = Contrast.relativeLuminance(of: grey)
            #expect(abs(luminance - srgb) < 1e-12, "channel \(channel)")
        }
    }

    /// The unpack the two functions used to write out six times between them.
    @Test("a colour comes apart into the channels it was written with")
    func channelsAreUnpackedInWritingOrder() {
        let (r, g, b) = Contrast.channels(of: 0x1A2B3C)
        #expect((r, g, b) == (0x1A, 0x2B, 0x3C))
        #expect(Contrast.channels(of: 0x000000) == (0, 0, 0))
        #expect(Contrast.channels(of: 0xFFFFFF) == (255, 255, 255))
    }
}
