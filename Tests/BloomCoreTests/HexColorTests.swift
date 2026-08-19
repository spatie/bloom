import Testing
@testable import BloomCore

@Suite("Reading a hex colour")
struct HexColorTests {
    @Test(
        "six digits parse with or without a hash, in either case",
        arguments: [
            ("#fdf6e3", HexColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("fdf6e3", HexColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("#FDF6E3", HexColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("  #fdf6e3  ", HexColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("#000000", HexColor(red: 0, green: 0, blue: 0)),
            ("#ffffff", HexColor(red: 255, green: 255, blue: 255)),
        ]
    )
    func sixDigits(input: String, expected: HexColor) {
        #expect(HexColor(hex: input) == expected)
    }

    @Test(
        "three digits expand each digit to a byte, which is what every other tool does",
        arguments: [
            ("#abc", HexColor(red: 0xAA, green: 0xBB, blue: 0xCC)),
            ("abc", HexColor(red: 0xAA, green: 0xBB, blue: 0xCC)),
            ("#000", HexColor(red: 0, green: 0, blue: 0)),
            ("#fff", HexColor(red: 255, green: 255, blue: 255)),
        ]
    )
    func threeDigits(input: String, expected: HexColor) {
        #expect(HexColor(hex: input) == expected)
    }

    @Test(
        "anything that is not three or six hex digits is refused rather than guessed at",
        arguments: [
            "", "#", "#ab", "#abcd", "#abcde", "#abcdefa", "#abcdefab",
            "0xabcdef", "rebeccapurple", "#gggggg", "#12 34 56", "#-12345",
        ]
    )
    func refused(input: String) {
        #expect(HexColor(hex: input) == nil)
    }

    @Test("a Ghostty colour reads the same string the palette does")
    func ghosttyAgrees() {
        #expect(GhosttyColor(hex: "#abc") == GhosttyColor(red: 0xAA, green: 0xBB, blue: 0xCC))
        #expect(GhosttyColor(hex: "rebeccapurple") == nil)
    }
}
