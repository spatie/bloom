import Testing
import Foundation
@testable import BloomCore

@Suite("OceanCatalog")
struct OceanCatalogTests {
    @Test("ships exactly 400 seas, every slug a unique valid branch name on a real coordinate")
    func catalogueIsSound() {
        let all = OceanCatalog.all
        #expect(all.count == 400)
        #expect(Set(all.map(\.slug)).count == all.count)
        for ocean in all {
            #expect(Git.isValidBranchName(ocean.slug), "\(ocean.slug)")
            #expect((-90.0...90.0).contains(ocean.latitude), "\(ocean.slug)")
            #expect((-180.0...180.0).contains(ocean.longitude), "\(ocean.slug)")
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
