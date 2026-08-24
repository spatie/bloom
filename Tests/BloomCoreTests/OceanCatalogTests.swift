import Testing
import Foundation
@testable import BloomCore

@Suite("OceanCatalog")
struct OceanCatalogTests {
    @Test("ships exactly 132 seas, every slug a unique valid branch name on a real coordinate")
    func catalogueIsSound() {
        let all = OceanCatalog.all
        #expect(all.count == 132)
        #expect(Set(all.map(\.slug)).count == all.count)
        for ocean in all {
            #expect(Git.isValidBranchName(ocean.slug), "\(ocean.slug)")
            #expect((-90.0...90.0).contains(ocean.latitude), "\(ocean.slug)")
            #expect((-180.0...180.0).contains(ocean.longitude), "\(ocean.slug)")
        }
    }

    /// The catalogue's first release shipped 268 islands in what the notice calls a sea and
    /// the window calls Discovered Seas, so "the first to sail the Greenland" was one claim
    /// away. The words are the feature, so the data has to stay water, and this is that rule
    /// written down where a regenerated catalogue cannot slip past it.
    @Test("names only bodies of water, because the notice says the workspace sails them")
    func namesOnlyWater() {
        let waterWords: Set<String> = [
            "sea", "ocean", "gulf", "bay", "strait", "straits", "channel",
            "sound", "bight", "passage", "firth", "fjord", "lagoon", "estuary", "inlet",
        ]
        for ocean in OceanCatalog.all {
            let words = ocean.name.lowercased().components(separatedBy: CharacterSet(charactersIn: " -"))
            #expect(words.contains { waterWords.contains($0) }, "\(ocean.name) is not a body of water")
        }
    }

    @Test("drops a malformed line rather than inventing an entry")
    func dropsMalformedLines() {
        let tsv = [
            "name\tslug\tlatitude\tlongitude",
            "Good Sea\tgood-sea\t10.0\t20.0",
            "Bad Latitude\tbad-latitude\tnot-a-number\t20.0",
            "Too Few Fields\ttoo-few-fields\t10.0",
            "Bad Slug\tbad slug\t10.0\t20.0",
            "Out Of Range\tout-of-range\t95.0\t20.0",
            "\tno-name\t10.0\t20.0",
        ].joined(separator: "\n")

        #expect(OceanCatalog.parse(tsv: tsv).map(\.slug) == ["good-sea"])
    }

    @Test("skips the header even when it would scan as a row")
    func skipsHeader() {
        let tsv = "First Sea\tfirst-sea\t1.0\t2.0\nSecond Sea\tsecond-sea\t3.0\t4.0"
        #expect(OceanCatalog.parse(tsv: tsv).map(\.slug) == ["second-sea"])
    }
}

@Suite("Ocean claim gate")
struct OceanClaimGateTests {
    @Test("a plain chat workspace that left everything to Bloom spends a sea")
    func plainChatClaims() {
        #expect(OceanCatalog.shouldClaim(
            userSuppliedName: nil, userSuppliedBranch: nil,
            isChatWorkspace: true, wantsAutomaticName: true, hasTask: true
        ))
    }

    @Test("a caller that brings its own name spends no sea")
    func ownNameSpendsNothing() {
        #expect(!OceanCatalog.shouldClaim(
            userSuppliedName: "Fix the login flow", userSuppliedBranch: nil,
            isChatWorkspace: true, wantsAutomaticName: true, hasTask: true
        ))
    }

    @Test("a caller that brings its own branch spends no sea")
    func ownBranchSpendsNothing() {
        #expect(!OceanCatalog.shouldClaim(
            userSuppliedName: nil, userSuppliedBranch: "fix/login",
            isChatWorkspace: true, wantsAutomaticName: true, hasTask: true
        ))
    }

    @Test("a terminal workspace with a task written is named after the task, not after a sea")
    func terminalWithTaskSpendsNothing() {
        #expect(!OceanCatalog.shouldClaim(
            userSuppliedName: nil, userSuppliedBranch: nil,
            isChatWorkspace: false, wantsAutomaticName: false, hasTask: true
        ))
    }

    /// The promptless start. Nothing else in the app can name this workspace: no turn is sent, so
    /// no model is asked, and there is no sentence to slug a branch out of.
    @Test("a terminal workspace started with nothing written spends a sea")
    func promptlessTerminalClaims() {
        #expect(OceanCatalog.shouldClaim(
            userSuppliedName: nil, userSuppliedBranch: nil,
            isChatWorkspace: false, wantsAutomaticName: false, hasTask: false
        ))
    }

    @Test("a promptless terminal start with its own branch still spends no sea")
    func promptlessTerminalWithBranchSpendsNothing() {
        #expect(!OceanCatalog.shouldClaim(
            userSuppliedName: nil, userSuppliedBranch: "spike/perf",
            isChatWorkspace: false, wantsAutomaticName: false, hasTask: false
        ))
    }

    @Test("no automatic rename coming means no sea, because nothing would ever replace it")
    func noRenameSpendsNothing() {
        #expect(!OceanCatalog.shouldClaim(
            userSuppliedName: nil, userSuppliedBranch: nil,
            isChatWorkspace: true, wantsAutomaticName: false, hasTask: true
        ))
    }
}

@Suite("OceanPick notice")
struct OceanPickNoticeTests {
    private let coral = Ocean(name: "Coral Sea", slug: "coral-sea", latitude: -18, longitude: 152)

    @Test("counts the seas still waiting after a first use")
    func manyRemaining() {
        let pick = OceanPick(ocean: coral, isFirstUse: true, remainingUndiscovered: 17)
        #expect(pick.notice == "This workspace is the first to sail the Coral Sea. 17 seas are still waiting to be discovered.")
    }

    @Test("says one sea in the singular")
    func oneRemaining() {
        let pick = OceanPick(ocean: coral, isFirstUse: true, remainingUndiscovered: 1)
        #expect(pick.notice == "This workspace is the first to sail the Coral Sea. One sea is still waiting to be discovered.")
    }

    @Test("announces the last discovery")
    func zeroRemaining() {
        let pick = OceanPick(ocean: coral, isFirstUse: true, remainingUndiscovered: 0)
        #expect(pick.notice == "This workspace is the first to sail the Coral Sea, and it was the last sea left. All of them have now been discovered.")
    }

    @Test("says nothing on a repeat")
    func silentOnRepeat() {
        let pick = OceanPick(ocean: coral, isFirstUse: false, remainingUndiscovered: 0)
        #expect(pick.notice == nil)
    }
}
