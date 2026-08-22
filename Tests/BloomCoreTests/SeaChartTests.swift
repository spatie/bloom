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

@Suite("SeaChartCamera")
struct SeaChartCameraTests {
    @Test("the default camera is the whole world, centred")
    func wholeWorld() {
        #expect(SeaChartCamera.whole.scale == 1)
        #expect(SeaChartCamera.whole.isWholeWorld)
        let region = SeaChartCamera.whole.visibleRegion
        #expect(region.x == 0 && region.y == 0 && region.width == 1 && region.height == 1)
    }

    @Test("the scale is held between the whole world and the coastline's limit")
    func scaleClamps() {
        #expect(SeaChartCamera(scale: 0.2, centerX: 0.5, centerY: 0.5).scale == 1)
        #expect(SeaChartCamera(scale: 400, centerX: 0.5, centerY: 0.5).scale == 10)
        #expect(SeaChartCamera(scale: .nan, centerX: 0.5, centerY: 0.5).scale == 1)
    }

    @Test("the visible region never leaves the world, however hard it is pushed")
    func centreClamps() {
        for scale in [1.0, 1.7, 4.0, 10.0] {
            for (x, y) in [(-5.0, -5.0), (5.0, 5.0), (0.5, 0.0), (0.0, 0.5)] {
                let region = SeaChartCamera(scale: scale, centerX: x, centerY: y).visibleRegion
                #expect(region.x >= -1e-12)
                #expect(region.y >= -1e-12)
                #expect(region.x + region.width <= 1 + 1e-12)
                #expect(region.y + region.height <= 1 + 1e-12)
            }
        }
        // At the floor there is exactly one legal centre, whatever was asked for.
        let pushed = SeaChartCamera(scale: 1, centerX: 0.9, centerY: 0.1)
        #expect(pushed.centerX == 0.5 && pushed.centerY == 0.5)
    }

    @Test("zooming about a point leaves that point where it was on the sheet")
    func zoomKeepsItsAnchor() {
        // The Adriatic, well inside the world so no clamp interferes.
        let anchor = SeaChartProjection.unitPoint(latitude: 43, longitude: 15)
        var camera = SeaChartCamera.whole
        for _ in 0..<3 {
            let before = camera.visibleRegion
            let fractionBefore = ((anchor.x - before.x) / before.width, (anchor.y - before.y) / before.height)
            camera = camera.zoomed(by: 1.6, aroundUnitX: anchor.x, unitY: anchor.y)
            let after = camera.visibleRegion
            let fractionAfter = ((anchor.x - after.x) / after.width, (anchor.y - after.y) / after.height)
            #expect(abs(fractionBefore.0 - fractionAfter.0) < 1e-9)
            #expect(abs(fractionBefore.1 - fractionAfter.1) < 1e-9)
        }
        #expect(abs(camera.scale - 1.6 * 1.6 * 1.6) < 1e-9)
    }

    @Test("zooming all the way back out lands on the whole world again")
    func zoomOutRecovers() {
        let camera = SeaChartCamera.whole
            .zoomed(by: 6, aroundUnitX: 0.8, unitY: 0.3)
            .zoomed(by: 0.01, aroundUnitX: 0.8, unitY: 0.3)
        #expect(camera.isWholeWorld)
        #expect(camera.centerX == 0.5 && camera.centerY == 0.5)
    }

    @Test("a nonsense zoom factor is ignored rather than obeyed")
    func badFactorIgnored() {
        let camera = SeaChartCamera(scale: 3, centerX: 0.4, centerY: 0.6)
        #expect(camera.zoomed(by: 0, aroundUnitX: 0.5, unitY: 0.5) == camera)
        #expect(camera.zoomed(by: -2, aroundUnitX: 0.5, unitY: 0.5) == camera)
        #expect(camera.zoomed(by: .infinity, aroundUnitX: 0.5, unitY: 0.5) == camera)
    }

    @Test("panning moves the view and stops at the world's edge")
    func panning() {
        let camera = SeaChartCamera(scale: 4, centerX: 0.5, centerY: 0.5)
        let moved = camera.panned(byUnitX: 0.1, unitY: -0.05)
        #expect(abs(moved.centerX - 0.6) < 1e-12)
        #expect(abs(moved.centerY - 0.45) < 1e-12)

        let shoved = camera.panned(byUnitX: 9, unitY: 9)
        #expect(abs(shoved.centerX - 0.875) < 1e-12)
        #expect(abs(shoved.centerY - 0.875) < 1e-12)
    }
}

@Suite("SeaChartProjection.worldRect")
struct SeaChartWorldRectTests {
    @Test("the whole world camera draws the world exactly on the sheet")
    func wholeWorldMatchesSheet() {
        let world = SeaChartProjection.worldRect(
            inX: 20, y: 10, width: 800, height: 400, camera: .whole
        )
        #expect(world.x == 20 && world.y == 10)
        #expect(world.width == 800 && world.height == 400)
    }

    @Test("a zoomed world overhangs the sheet and keeps the camera's centre in the middle")
    func zoomedWorldOverhangs() {
        let camera = SeaChartCamera(scale: 4, centerX: 0.25, centerY: 0.75)
        let world = SeaChartProjection.worldRect(
            inX: 0, y: 0, width: 800, height: 400, camera: camera
        )
        #expect(world.width == 3200 && world.height == 1600)
        // The camera's centre lands on the sheet's centre.
        #expect(abs(world.x + 0.25 * world.width - 400) < 1e-9)
        #expect(abs(world.y + 0.75 * world.height - 200) < 1e-9)
    }

    @Test("a sea inside the visible region lands inside the sheet, and one outside does not")
    func marksFollowTheCamera() {
        // The Sea of Japan, roughly 40 north 135 east.
        let japan = SeaChartProjection.unitPoint(latitude: 40, longitude: 135)
        let camera = SeaChartCamera(scale: 8, centerX: japan.x, centerY: japan.y)
        let world = SeaChartProjection.worldRect(
            inX: 0, y: 0, width: 800, height: 400, camera: camera
        )
        let onSheet = SeaChartProjection.markPoint(
            latitude: 40, longitude: 135,
            inX: world.x, y: world.y, width: world.width, height: world.height, inset: 0
        )
        #expect(abs(onSheet.x - 400) < 1e-6 && abs(onSheet.y - 200) < 1e-6)

        // The Caribbean is nowhere near, so it falls off the sheet entirely.
        let elsewhere = SeaChartProjection.markPoint(
            latitude: 15, longitude: -75,
            inX: world.x, y: world.y, width: world.width, height: world.height, inset: 0
        )
        #expect(elsewhere.x < 0 || elsewhere.x > 800)
    }
}

@Suite("SeaChartLabels under zoom")
struct SeaChartLabelZoomTests {
    @Test("names grow with the sheet, between a readable floor and a ceiling")
    func fontSizeScales() {
        #expect(SeaChartLabels.fontSize(forMapWidth: 420) == 11.5)
        #expect(SeaChartLabels.fontSize(forMapWidth: 4000) == 19)
        let middling = SeaChartLabels.fontSize(forMapWidth: 900)
        #expect(middling > 11.5 && middling < 19)
        // Monotonic, so a wider window never shrinks a name.
        var previous = 0.0
        for width in stride(from: 400.0, through: 3000.0, by: 100.0) {
            let size = SeaChartLabels.fontSize(forMapWidth: width)
            #expect(size >= previous)
            previous = size
        }
    }

    @Test("a crowd too tight to name at whole world scale gets its names back once zoomed in")
    func zoomRecoversDroppedNames() {
        // Seven seas within a few degrees of Japan, which is the cluster that loses names.
        let seas: [(Double, Double)] = [
            (40, 135), (38, 132), (36, 130), (34, 128), (42, 139), (44, 143), (33, 126),
        ]
        let sheet = (x: 0.0, y: 0.0, width: 800.0, height: 400.0)
        let size = (width: 70.0, height: 14.0)

        func placedCount(_ camera: SeaChartCamera) -> Int {
            let world = SeaChartProjection.worldRect(
                inX: sheet.x, y: sheet.y, width: sheet.width, height: sheet.height, camera: camera
            )
            let marks = seas.map { sea in
                let point = SeaChartProjection.markPoint(
                    latitude: sea.0, longitude: sea.1,
                    inX: world.x, y: world.y, width: world.width, height: world.height, inset: 0
                )
                return (x: point.x, y: point.y)
            }
            return SeaChartLabels.place(
                marks: marks, sizes: Array(repeating: size, count: seas.count), markRadius: 5,
                boundsX: sheet.x, boundsY: sheet.y,
                boundsWidth: sheet.width, boundsHeight: sheet.height
            ).count
        }

        let whole = placedCount(.whole)
        let centre = SeaChartProjection.unitPoint(latitude: 38, longitude: 134)
        let close = placedCount(SeaChartCamera(scale: 8, centerX: centre.x, centerY: centre.y))
        #expect(whole < seas.count)
        #expect(close > whole)
    }
}

@Suite("SeaChartProjection.defaultWindowSize")
struct SeaChartDefaultWindowSizeTests {
    @Test("the opening window is cut to the chart, so no side opens with dead paper")
    func fitsTheSheet() {
        for (width, height) in [(3456.0, 2160.0), (5120.0, 1440.0), (1440.0, 2560.0)] {
            let size = SeaChartProjection.defaultWindowSize(
                screenWidth: width, screenHeight: height, margin: 30, footerHeight: 34
            )
            let sheetWidth = size.width - 60
            let sheetHeight = size.height - 60 - 34
            #expect(abs(sheetWidth - sheetHeight * SeaChartProjection.aspectRatio) < 1e-9)
            #expect(size.width <= width * 0.8 + 1e-9)
            #expect(size.height <= height * 0.8 + 1e-9)
        }
    }

    @Test("a large screen opens large, and a tiny one still opens usable")
    func boundsAreSensible() {
        let big = SeaChartProjection.defaultWindowSize(
            screenWidth: 3456, screenHeight: 2160, margin: 30, footerHeight: 34
        )
        #expect(big.width > 2000)
        let tiny = SeaChartProjection.defaultWindowSize(
            screenWidth: 200, screenHeight: 200, margin: 30, footerHeight: 34
        )
        #expect(tiny.width >= 480 && tiny.height >= 360)
    }
}

@Suite("SeaChartLabels reserved paper")
struct SeaChartReservedTests {
    @Test("a name that would land on the cartouche is placed elsewhere or dropped")
    func reservedBlocksLabels() {
        let marks = [(x: 200.0, y: 200.0)]
        let sizes = [(width: 80.0, height: 14.0)]
        let free = SeaChartLabels.place(
            marks: marks, sizes: sizes, markRadius: 5,
            boundsX: 0, boundsY: 0, boundsWidth: 400, boundsHeight: 400
        )
        #expect(free.count == 1)
        #expect(free[0].x > 200)

        // A box over every candidate spot leaves the mark unnamed, which is the right answer:
        // the X still shows and the tooltip still answers.
        let smothered = SeaChartLabels.place(
            marks: marks, sizes: sizes, markRadius: 5,
            boundsX: 0, boundsY: 0, boundsWidth: 400, boundsHeight: 400,
            reserved: [(x: 60, y: 140, width: 300, height: 120)]
        )
        #expect(smothered.isEmpty)

        // A box covering only the first candidate pushes the name to the next one.
        let nudged = SeaChartLabels.place(
            marks: marks, sizes: sizes, markRadius: 5,
            boundsX: 0, boundsY: 0, boundsWidth: 400, boundsHeight: 400,
            reserved: [(x: 200, y: 180, width: 120, height: 40)]
        )
        #expect(nudged.count == 1)
        #expect(nudged[0].x < 200)
    }
}
