import Testing
@testable import BloomCore

@Suite("Browser tab title")
struct BrowserTabTitleTests {
    // MARK: - The chain

    @Test("A page with a title is called by it")
    func usesThePageTitle() {
        #expect(
            BrowserTabTitle.title(page: "Spatie", address: "https://spatie.be/", fallback: "Browser")
                == "Spatie"
        )
    }

    @Test("A page with no title falls back to the host, without its www")
    func fallsBackToTheHost() {
        #expect(
            BrowserTabTitle.title(page: "", address: "https://www.spatie.be/about", fallback: "Browser")
                == "spatie.be"
        )
    }

    /// A workspace's dev server is its port, and it is all that tells two of them apart.
    @Test("A dev server keeps its port")
    func keepsThePort() {
        #expect(
            BrowserTabTitle.title(page: "", address: "http://localhost:3000/", fallback: "Browser")
                == "localhost:3000"
        )
    }

    @Test("A page with neither a title nor a host is the tab's own name")
    func fallsBackToTheTabName() {
        for address in ["about:blank", "", "file:///tmp/index.html"] {
            #expect(
                BrowserTabTitle.title(page: "", address: address, fallback: "Browser 2") == "Browser 2"
            )
        }
    }

    /// WebKit hands back the address itself as the title of a page that has no `<title>`, and the
    /// address bar is directly above the tab. The host is shorter and says the same thing.
    @Test("A title that only restates the address is not used")
    func ignoresTheAddressAsATitle() {
        #expect(
            BrowserTabTitle.title(
                page: "http://localhost:3000/", address: "http://localhost:3000/", fallback: "Browser"
            ) == "localhost:3000"
        )
        #expect(
            BrowserTabTitle.title(page: "spatie.be", address: "https://spatie.be/", fallback: "Browser")
                == "spatie.be"
        )
    }

    @Test("A name the user typed beats anything the page says")
    func aTypedNameWins() {
        #expect(
            BrowserTabTitle.title(
                page: "Spatie", address: "https://spatie.be/", fallback: "Docs", isNamed: true
            ) == "Docs"
        )
    }

    // MARK: - Loading

    @Test("A link followed inside a site keeps the title up while the next page loads")
    func holdsTheTitleWithinAHost() {
        #expect(BrowserTabTitle.survives(
            navigationFrom: "https://spatie.be/", to: "https://spatie.be/open-source"
        ))
        #expect(BrowserTabTitle.survives(
            navigationFrom: "http://localhost:3000/", to: "http://localhost:3000/settings"
        ))
    }

    @Test("Leaving a site drops its title at once")
    func dropsTheTitleAcrossHosts() {
        #expect(!BrowserTabTitle.survives(navigationFrom: "https://spatie.be/", to: "https://github.com/"))
        #expect(!BrowserTabTitle.survives(navigationFrom: "https://spatie.be/", to: "about:blank"))
        #expect(!BrowserTabTitle.survives(navigationFrom: "", to: "https://spatie.be/"))
    }

    /// Two dev servers in two workspaces are the same host and different pages.
    @Test("A different port is a different place")
    func portsAreDifferentPlaces() {
        #expect(!BrowserTabTitle.survives(
            navigationFrom: "http://localhost:3000/", to: "http://localhost:4000/"
        ))
    }

    // MARK: - Moving and being renamed at once

    private func page(_ address: String, _ title: String = "") -> BrowserTabTitle.BrowserPage {
        BrowserTabTitle.BrowserPage(address: address, title: title)
    }

    @Test("A title arriving for the page the tab has just moved to is kept")
    func adoptsATitleWithItsNavigation() {
        let next = BrowserTabTitle.advance(
            from: page("https://spatie.be/", "Spatie"),
            to: page("https://github.com/spatie", "spatie · GitHub")
        )
        #expect(next == page("https://github.com/spatie", "spatie · GitHub"))
    }

    /// WebKit clears `title` on every commit, so "no title" is the ordinary state for a second
    /// and must not blank the tab.
    @Test("A navigation with no title yet keeps the name while the page is on the same host")
    func holdsTheNameWhileLoading() {
        let next = BrowserTabTitle.advance(
            from: page("https://spatie.be/", "Spatie"), to: page("https://spatie.be/open-source")
        )
        #expect(next == page("https://spatie.be/open-source", "Spatie"))
    }

    @Test("A navigation off the host drops the name at once")
    func dropsTheNameOnLeaving() {
        let next = BrowserTabTitle.advance(
            from: page("https://spatie.be/", "Spatie"), to: page("https://github.com/")
        )
        #expect(next == page("https://github.com/", ""))
    }

    /// A page that renames itself under the reader, which a single page app does on every route.
    @Test("A title changing with no navigation is taken")
    func adoptsATitleWithoutANavigation() {
        let next = BrowserTabTitle.advance(
            from: page("http://localhost:3000/", "Dashboard"),
            to: page("http://localhost:3000/", "Settings")
        )
        #expect(next == page("http://localhost:3000/", "Settings"))
    }

    /// The bug this covers: an Inertia site navigated with `history.pushState`, the tab strip
    /// followed it because the title is on KVO, and the address field sat on `/login` because the
    /// url was not. `BrowserSession` watches both now, so both halves arrive here, and what has to
    /// hold is that the address moves while the name the site has already given the tab stays up
    /// for the moment before the new one arrives.
    @Test("A client side navigation moves the address and keeps the name up")
    func followsAPushState() {
        let next = BrowserTabTitle.advance(
            from: page("https://there-there-6.test/login", "Log in"),
            to: page("https://there-there-6.test/tickets/429")
        )
        #expect(next == page("https://there-there-6.test/tickets/429", "Log in"))

        // And the title the site sets a beat later, with no navigation beside it, replaces it.
        let named = BrowserTabTitle.advance(from: next, to: page("", "#429 Large CSV support"))
        #expect(named == page("https://there-there-6.test/tickets/429", "#429 Large CSV support"))
    }

    @Test("A page with no address at all keeps the one the tab has")
    func keepsTheAddressWhenNoneIsGiven() {
        let next = BrowserTabTitle.advance(from: page("https://spatie.be/", "Spatie"), to: page(""))
        #expect(next == page("https://spatie.be/", "Spatie"))
    }

    // MARK: - Tidying what the page says

    @Test("A title is flattened to one line")
    func flattensToOneLine() {
        #expect(BrowserTabTitle.tidy("Spatie\n\tweb development") == "Spatie web development")
        #expect(BrowserTabTitle.tidy("  Spatie   ") == "Spatie")
        #expect(BrowserTabTitle.tidy(nil).isEmpty)
        #expect(BrowserTabTitle.tidy("   ").isEmpty)
    }

    @Test("A very long title is capped, at a word boundary where there is one")
    func caps() {
        let long = String(repeating: "word ", count: 200)
        let capped = BrowserTabTitle.tidy(long)
        #expect(capped.count <= BrowserTabTitle.limit + 1)
        #expect(capped.hasSuffix("…"))
        #expect(!capped.hasSuffix(" …"))

        let unbroken = String(repeating: "a", count: 400)
        #expect(BrowserTabTitle.tidy(unbroken).count == BrowserTabTitle.limit + 1)
    }

    @Test("A title that fits is left exactly as it is")
    func leavesShortTitlesAlone() {
        let title = "Spatie: web development in Antwerp"
        #expect(BrowserTabTitle.tidy(title) == title)
    }
}
