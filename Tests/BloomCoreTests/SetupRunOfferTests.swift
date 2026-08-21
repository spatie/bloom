import Testing
import Foundation
@testable import BloomCore

/// The setup item three menus draw: the menu bar's Workspace menu, and a workspace row's menu in
/// both the sidebar and Home.
///
/// Settled here rather than in any of them, because a menu is a place nothing can reach. The rule
/// the item is worth having at all is the one below about absence and greying: it is the whole
/// reason a project with no setup script never sees a row, and the reason a run in flight leaves
/// the row where it was.
@Suite("Setup run offer")
struct SetupRunOfferTests {
    @Test("a repository with no setup script is offered nothing at all")
    func noScriptNoItem() {
        #expect(SetupRunOffer.offer(hasSetupScript: false, hasRunSetup: false, isRunning: false) == nil)
        #expect(SetupRunOffer.offer(hasSetupScript: false, hasRunSetup: true, isRunning: false) == nil)
    }

    /// Absent and greyed are two different noes and the split is the point. A project that will
    /// never have a setup script should not carry a dead row for ever; a run that is going should
    /// not make the row vanish out from under the person who opened the menu to look at it.
    @Test("a run in flight greys the item rather than removing it")
    func aRunGreysRatherThanHides() throws {
        let offer = try #require(
            SetupRunOffer.offer(hasSetupScript: true, hasRunSetup: true, isRunning: true)
        )
        #expect(offer.isEnabled == false)
        #expect(offer.title == "Run Setup Again")
    }

    /// "Run Setup Again" on a workspace where it has never run is the app contradicting the setup
    /// header an inch above it.
    @Test("the title says again only when there was a first time")
    func theTitleSaysAgainOnlyAfterARun() throws {
        let first = try #require(
            SetupRunOffer.offer(hasSetupScript: true, hasRunSetup: false, isRunning: false)
        )
        #expect(first.title == "Run Setup")

        let again = try #require(
            SetupRunOffer.offer(hasSetupScript: true, hasRunSetup: true, isRunning: false)
        )
        #expect(again.title == "Run Setup Again")
    }

    @Test("nothing but a run in flight can disable an item that is offered")
    func onlyARunDisables() throws {
        for hasRunSetup in [true, false] {
            let offer = try #require(
                SetupRunOffer.offer(
                    hasSetupScript: true, hasRunSetup: hasRunSetup, isRunning: false
                )
            )
            #expect(offer.isEnabled)
        }
    }
}
