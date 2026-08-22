import Testing
import Foundation
@testable import BloomCore

@Suite("SeaChartProjection")
struct SeaChartProjectionTests {
    @Test("the corners of the world land on the corners of the unit square")
    func cornersProject() {
        let northWest = SeaChartProjection.unitPoint(latitude: 90, longitude: -180)
        #expect(northWest.x == 0 && northWest.y == 0)
        let southEast = SeaChartProjection.unitPoint(latitude: -90, longitude: 180)
        #expect(southEast.x == 1 && southEast.y == 1)
        let origin = SeaChartProjection.unitPoint(latitude: 0, longitude: 0)
        #expect(origin.x == 0.5 && origin.y == 0.5)
    }

    @Test("a catalogue sea projects where the catalogue says it is")
    func catalogueSeaProjects() {
        // The Adriatic at 43 north, 15 east: east of centre, north of the equator.
        let point = SeaChartProjection.unitPoint(latitude: 43, longitude: 15)
        #expect(abs(point.x - (195.0 / 360.0)) < 1e-12)
        #expect(abs(point.y - (47.0 / 180.0)) < 1e-12)
    }

    @Test("a wide window is limited by height and a tall one by width, both centred")
    func mapRectFits() {
        let wide = SeaChartProjection.mapRect(fittingWidth: 1000, height: 300, margin: 25)
        #expect(wide.height == 250 && wide.width == 500)
        #expect(wide.x == 250 && wide.y == 25)

        let tall = SeaChartProjection.mapRect(fittingWidth: 500, height: 1000, margin: 25)
        #expect(tall.width == 450 && tall.height == 225)
        #expect(tall.x == 25 && tall.y == 387.5)
    }

    @Test("the map keeps the projection's two by one shape whatever the window's shape")
    func mapRectKeepsAspect() {
        for (width, height) in [(760.0, 520.0), (480.0, 360.0), (2000.0, 400.0)] {
            let rect = SeaChartProjection.mapRect(fittingWidth: width, height: height, margin: 28)
            #expect(abs(rect.width - rect.height * SeaChartProjection.aspectRatio) < 1e-9)
        }
    }

    @Test("a mark on the sheet's edge is pulled onto the sheet, and one in open water is not")
    func markPointClampsToSheet() {
        // The Arctic Ocean is catalogued at 90 north: projected literally it sits on the
        // neatline with half its X outside the frame.
        let arctic = SeaChartProjection.markPoint(
            latitude: 90, longitude: 0, inX: 10, y: 10, width: 700, height: 350, inset: 6
        )
        #expect(arctic.y == 16)
        let koro = SeaChartProjection.markPoint(
            latitude: -17.5, longitude: 179.98, inX: 10, y: 10, width: 700, height: 350, inset: 6
        )
        #expect(koro.x == 704)
        let adriatic = SeaChartProjection.markPoint(
            latitude: 43, longitude: 15, inX: 0, y: 0, width: 720, height: 360, inset: 6
        )
        #expect(abs(adriatic.x - 390) < 1e-9)
        #expect(abs(adriatic.y - 94) < 1e-9)
    }

    @Test("a window smaller than its margins collapses to nothing rather than inverting")
    func degenerateSizeCollapses() {
        let rect = SeaChartProjection.mapRect(fittingWidth: 20, height: 20, margin: 25)
        #expect(rect.width == 0 && rect.height == 0)
    }
}

@Suite("SeaChartCoast")
struct SeaChartCoastTests {
    @Test("the baked coastline parses whole: enough rings for the continents, every point on the sheet")
    func bakedDataParses() {
        let rings = SeaChartCoast.rings
        #expect(rings.count > 50)
        #expect(rings.allSatisfy { $0.count >= 3 })
        for ring in rings {
            for point in ring {
                #expect((0.0...1.0).contains(point.x))
                #expect((0.0...1.0).contains(point.y))
            }
        }
    }

    @Test("a vertex that does not scan is dropped, and a ring that cannot close goes with it")
    func malformedLinesDrop() {
        let rings = SeaChartCoast.parse("""
        0,0 10,10 20,0 not,numbers
        1,1 2,2
        5,95 6,96 7,97
        """)
        #expect(rings.count == 1)
        #expect(rings[0].count == 3)
    }
}

@Suite("SeaChartLabels")
struct SeaChartLabelsTests {
    private let bounds = (x: 0.0, y: 0.0, width: 400.0, height: 200.0)

    private func place(
        _ marks: [(x: Double, y: Double)], sizes: [(width: Double, height: Double)]
    ) -> [SeaChartLabel] {
        SeaChartLabels.place(
            marks: marks, sizes: sizes, markRadius: 5,
            boundsX: bounds.x, boundsY: bounds.y,
            boundsWidth: bounds.width, boundsHeight: bounds.height
        )
    }

    @Test("a lone mark gets its label to the right, clear of the mark")
    func loneMarkLabelsRight() throws {
        let labels = place([(100, 100)], sizes: [(40, 10)])
        let label = try #require(labels.first)
        #expect(label.mark == 0)
        #expect(label.x > 105)
        #expect(abs((label.y + label.height / 2) - 100) < 1e-9)
    }

    @Test("a mark against the right edge carries its label on the left instead")
    func edgeMarkFlipsLeft() throws {
        let labels = place([(395, 100)], sizes: [(40, 10)])
        let label = try #require(labels.first)
        #expect(label.x + label.width < 395)
    }

    @Test("two close neighbours both keep their names by taking different sides")
    func neighboursTakeDifferentSides() {
        let labels = place([(100, 100), (104, 100)], sizes: [(40, 10), (40, 10)])
        #expect(labels.count == 2)
        #expect(!labels[0].intersects(labels[1]))
    }

    @Test("a cluster too tight for every name drops names rather than stacking them")
    func tightClusterDropsLabels() {
        // Seven marks within a few points, the Japanese inland seas at world scale. Whatever
        // fits must not overlap; the rest go unlabelled, and every mark keeps its tooltip.
        let cluster = (0..<7).map { (x: 200.0 + Double($0) * 3, y: 100.0) }
        let labels = place(cluster, sizes: cluster.map { _ in (50.0, 10.0) })
        #expect(labels.count < 7)
        for a in labels {
            for b in labels where a.mark < b.mark {
                #expect(!a.intersects(b))
            }
        }
    }

    @Test("a label never sits on top of another sea's mark")
    func labelsCoverNoMarks() {
        let marks: [(x: Double, y: Double)] = [(100, 100), (130, 100)]
        let labels = place(marks, sizes: [(60, 10), (60, 10)])
        for label in labels {
            for (index, mark) in marks.enumerated() where index != label.mark {
                let inside = mark.x + 5 > label.x && mark.x - 5 < label.x + label.width
                    && mark.y + 5 > label.y && mark.y - 5 < label.y + label.height
                #expect(!inside)
            }
        }
    }

    @Test("placement is stable: the same marks in the same order place the same labels")
    func placementIsDeterministic() {
        let marks: [(x: Double, y: Double)] = (0..<20).map { index in
            let x = Double((index * 17) % 380) + 10
            let y = Double((index * 41) % 180) + 10
            return (x: x, y: y)
        }
        let sizes = marks.map { _ in (width: 45.0, height: 10.0) }
        #expect(place(marks, sizes: sizes) == place(marks, sizes: sizes))
    }
}
