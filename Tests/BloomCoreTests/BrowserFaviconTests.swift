import Foundation
import Testing
@testable import BloomCore

/// What a browser tab wears: which of a page's declarations Bloom asks for, what it files the
/// answer under, and what it refuses to draw.
///
/// The last of those is the half with consequences. A favicon is a picture from the network drawn
/// at 14 points inside Bloom's own chrome, so `read` is the gate, and every case here is a way a
/// data URL can claim to be something it is not.
@Suite("Browser favicon")
struct BrowserFaviconTests {
    /// The smallest legal PNG: signature, IHDR, IDAT, IEND. Only the signature matters to `read`,
    /// but a fixture that is a real file is one nobody has to wonder about.
    private static let png = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])

    private static var dataURL: String {
        BrowserFavicon.dataPrefix + png.base64EncodedString()
    }

    private func link(
        _ rel: String, _ href: String, sizes: String = "", type: String = ""
    ) -> BrowserFaviconLink {
        BrowserFaviconLink(rel: rel, sizes: sizes, type: type, href: href)
    }

    // MARK: - Which page an icon belongs to

    @Test("An icon is filed under the origin, so every page of a site shares one")
    func originIgnoresThePath() {
        #expect(BrowserFavicon.origin(of: "https://spatie.be/open-source")
            == BrowserFavicon.origin(of: "https://spatie.be/docs/laravel-backup"))
    }

    @Test("The port is filled in, so the same site written two ways is one key")
    func defaultPortIsExplicit() {
        #expect(BrowserFavicon.origin(of: "https://spatie.be/") == "https://spatie.be:443")
        #expect(BrowserFavicon.origin(of: "https://spatie.be:443/") == "https://spatie.be:443")
        #expect(BrowserFavicon.origin(of: "http://example.com/") == "http://example.com:80")
    }

    @Test("A dev server IS its port, so two of them are two origins")
    func portsSeparateDevServers() {
        #expect(BrowserFavicon.origin(of: "http://localhost:3000/") == "http://localhost:3000")
        #expect(BrowserFavicon.origin(of: "http://localhost:3000/")
            != BrowserFavicon.origin(of: "http://localhost:5173/"))
    }

    @Test("The host is compared in one case", arguments: [
        "https://Spatie.BE/", "https://spatie.be/",
    ])
    func hostIsLowercased(address: String) {
        #expect(BrowserFavicon.origin(of: address) == "https://spatie.be:443")
    }

    /// Every one of these is a tab that has to show the globe, and they are the globe here rather
    /// than in three places further up.
    @Test("Nothing but http and https has an origin", arguments: [
        "about:blank",
        "file:///Users/freek/notes.html",
        "",
        "   ",
        "data:text/html,<h1>hi</h1>",
        "javascript:alert(1)",
        "https://",
    ])
    func nonPagesHaveNoOrigin(address: String) {
        #expect(BrowserFavicon.origin(of: address) == nil)
    }

    @Test("A cache file is named by a digest, so nothing a host is called becomes a path")
    func fileNameCarriesNoHostCharacters() {
        let name = BrowserFavicon.fileName(for: "https://evil..%2f..%2fetc:443")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".png"))
        #expect(name.count == 64 + ".png".count)
        #expect(name == BrowserFavicon.fileName(for: "https://evil..%2f..%2fetc:443"))
        #expect(name != BrowserFavicon.fileName(for: "https://spatie.be:443"))
    }

    // MARK: - Reading what the page said

    @Test("The flat list the script sends is read back four at a time")
    func linksAreReadInFours() {
        let links = BrowserFavicon.links(from: [
            "icon", "32x32", "image/png", "https://spatie.be/icon.png",
            "apple-touch-icon", "", "", "https://spatie.be/touch.png",
        ])
        #expect(links.count == 2)
        #expect(links[0] == link("icon", "https://spatie.be/icon.png", sizes: "32x32", type: "image/png"))
        #expect(links[1].rel == "apple-touch-icon")
    }

    @Test("A list that is not a multiple of four is not an answer, and is dropped whole")
    func raggedListIsRefused() {
        #expect(BrowserFavicon.links(from: ["icon", "32x32", "image/png"]).isEmpty)
        #expect(BrowserFavicon.links(from: []).isEmpty)
    }

    // MARK: - Which declaration is asked for

    @Test("A page that declares nothing gets no request at all")
    func nothingDeclaredIsNothingFetched() {
        #expect(BrowserFavicon.choose(from: []) == nil)
    }

    /// The whole of the argument against guessing at `/favicon.ico`: a page with no declaration is
    /// a page Bloom does not go looking at.
    @Test("A rel that names no icon is not an icon", arguments: [
        "stylesheet", "preload", "mask-icon", "manifest", "canonical", "",
    ])
    func otherRelsAreIgnored(rel: String) {
        #expect(BrowserFavicon.choose(from: [link(rel, "https://spatie.be/icon.png")]) == nil)
    }

    @Test("rel is a list of tokens, so `shortcut icon` is an icon and `iconography` is not")
    func relIsMatchedByToken() {
        #expect(BrowserFavicon.choose(from: [link("shortcut icon", "https://a.example/i.png")]) != nil)
        #expect(BrowserFavicon.choose(from: [link("iconography", "https://a.example/i.png")]) == nil)
    }

    /// A declaration is a string from the network naming somewhere to make a request. Only two
    /// schemes ever get one.
    @Test("Only http and https are ever asked for", arguments: [
        "javascript:alert(1)",
        "data:image/svg+xml,<svg onload='alert(1)'/>",
        "file:///etc/passwd",
        "bloom://workspace/1",
        "",
        "not a url at all",
    ])
    func hostileSchemesAreRefused(href: String) {
        #expect(BrowserFavicon.choose(from: [link("icon", href)]) == nil)
    }

    @Test("The smallest icon that still covers the square wins")
    func smallestSufficientWins() {
        let links = [
            link("icon", "https://a.example/16.png", sizes: "16x16"),
            link("icon", "https://a.example/180.png", sizes: "180x180"),
            link("icon", "https://a.example/32.png", sizes: "32x32"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString == "https://a.example/32.png")
    }

    /// `<link rel=icon href=/favicon.ico>` on its own is the most common declaration on the web,
    /// and ranking it under a declared 16x16 would pick the blurry one nearly everywhere.
    @Test("An icon that declares no size beats one that declares too small a size")
    func unsizedBeatsUndersized() {
        let links = [
            link("icon", "https://a.example/16.png", sizes: "16x16"),
            link("icon", "https://a.example/favicon.ico"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString
            == "https://a.example/favicon.ico")
    }

    @Test("`sizes=any` is a vector claiming nothing, not a claim of zero")
    func anyIsUnsized() {
        let links = [
            link("icon", "https://a.example/16.png", sizes: "16x16"),
            link("icon", "https://a.example/icon.svg", sizes: "any", type: "image/svg+xml"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString
            == "https://a.example/icon.svg")
    }

    @Test("With nothing big enough, the biggest there is")
    func largestOfTheSmallWins() {
        let links = [
            link("icon", "https://a.example/8.png", sizes: "8x8"),
            link("icon", "https://a.example/24.png", sizes: "24x24"),
            link("icon", "https://a.example/16.png", sizes: "16x16"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString == "https://a.example/24.png")
    }

    @Test("A multi size file is worth its biggest size")
    func multipleSizesTakeTheLargest() {
        let links = [
            link("icon", "https://a.example/multi.ico", sizes: "16x16 32x32 48x48"),
            link("icon", "https://a.example/16.png", sizes: "16x16"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString
            == "https://a.example/multi.ico")
    }

    @Test("A home screen tile loses to a real icon of the same standing")
    func iconBeatsAppleTouch() {
        let links = [
            link("apple-touch-icon", "https://a.example/touch.png"),
            link("icon", "https://a.example/icon.png"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString
            == "https://a.example/icon.png")
    }

    @Test("A tile is still better than nothing")
    func appleTouchIsTakenWhenItIsAllThereIs() {
        let links = [link("apple-touch-icon-precomposed", "https://a.example/touch.png", sizes: "180x180")]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString
            == "https://a.example/touch.png")
    }

    @Test("Nonsense in `sizes` says nothing rather than says small", arguments: [
        "banana", "32", "xx", "0x0", "-32x-32",
    ])
    func unparseableSizesAreUnknown(sizes: String) {
        let links = [
            link("icon", "https://a.example/16.png", sizes: "16x16"),
            link("icon", "https://a.example/odd.png", sizes: sizes),
        ]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString == "https://a.example/odd.png")
    }

    /// The bytes are asked for by position rather than by address, so the index has to point at
    /// the declaration that was chosen and be counted over the list exactly as the page sent it,
    /// including the entries that were skipped.
    @Test("The index counts over the page's own list, skipped entries included")
    func indexIsIntoTheReportedList() {
        let links = [
            link("stylesheet", "https://a.example/site.css"),
            link("icon", "javascript:alert(1)"),
            link("icon", "https://a.example/icon.png", sizes: "32x32"),
        ]
        let choice = BrowserFavicon.choose(from: links)
        #expect(choice?.index == 2)
        #expect(choice?.url.absoluteString == links[2].href)
    }

    @Test("The page's own order settles a tie")
    func documentOrderBreaksTies() {
        let links = [
            link("icon", "https://a.example/first.png", sizes: "32x32"),
            link("icon", "https://a.example/second.png", sizes: "32x32"),
        ]
        #expect(BrowserFavicon.choose(from: links)?.index == 0)
    }

    @Test("A page cannot bury the list under declarations nobody will read")
    func onlyTheFirstFewAreConsidered() {
        let padding = (0..<BrowserFavicon.linkLimit).map {
            link("icon", "https://a.example/pad\($0).png", sizes: "8x8")
        }
        let links = padding + [link("icon", "https://a.example/perfect.png", sizes: "32x32")]
        #expect(BrowserFavicon.choose(from: links)?.url.absoluteString.contains("perfect") == false)
    }

    // MARK: - What is accepted as an icon

    @Test("A PNG data URL from the page's own canvas is read")
    func aRealAnswerIsAccepted() {
        #expect(BrowserFavicon.read(Self.dataURL) == Self.png)
    }

    /// The label on a data URL is written by whoever wrote the URL, so the prefix is compared
    /// whole and the decoded bytes still have to open like a PNG.
    @Test("Anything that is not exactly a base64 PNG data URL is refused", arguments: [
        "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
        "data:image/png,notbase64",
        "data:image/png;charset=utf-8;base64,",
        "data:text/html;base64,PGgxPmhpPC9oMT4=",
        "https://a.example/icon.png",
        "",
        "data:image/png;base64,",
    ])
    func aLabelIsNotABitmap(dataURL: String) {
        #expect(BrowserFavicon.read(dataURL) == nil)
    }

    @Test("Base64 that decodes to something that is not a PNG is refused")
    func theSignatureIsChecked() {
        let gif = Data("GIF89a".utf8)
        #expect(BrowserFavicon.read(BrowserFavicon.dataPrefix + gif.base64EncodedString()) == nil)
    }

    @Test("The length is capped before any decoding happens")
    func oversizedIsRefusedWithoutDecoding() {
        let huge = BrowserFavicon.dataPrefix
            + String(repeating: "A", count: BrowserFavicon.dataLimit)
        #expect(BrowserFavicon.read(huge) == nil)
    }

    @Test("The cap is wide enough for what a canvas of that square can actually produce")
    func theCapFitsTheCanvas() {
        // Four bytes a pixel, uncompressed, is the worst a 32 point square can come to, and the
        // cap has to be past it or the feature refuses its own output.
        let worst = BrowserFavicon.pixels * BrowserFavicon.pixels * 4
        #expect(BrowserFavicon.byteLimit > worst)
        #expect(BrowserFavicon.dataLimit > BrowserFavicon.byteLimit)
    }
}
