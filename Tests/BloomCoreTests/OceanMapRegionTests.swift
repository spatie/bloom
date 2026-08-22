import Testing
import Foundation
@testable import BloomCore

@Suite("OceanMapRegion")
struct OceanMapRegionTests {
    @Test("no pins means no region, which is the empty state's cue")
    func emptyIsNil() {
        #expect(OceanMapRegion.fitting([]) == nil)
    }

    @Test("one pin gets the floor, centred on the pin, so the first discovery has a coastline")
    func onePinGetsFloor() throws {
        let region = try #require(OceanMapRegion.fitting([(43.0, 15.0)]))
        #expect(region.centerLatitude == 43.0)
        #expect(region.centerLongitude == 15.0)
        #expect(region.latitudeDelta == OceanMapRegion.minimumLatitudeDelta)
        #expect(region.longitudeDelta == OceanMapRegion.minimumLongitudeDelta)
        #expect(region.contains(latitude: 43.0, longitude: 15.0))
    }

    @Test("two neighbours share one floor-sized frame rather than a fit tight enough to lose the coast")
    func closeNeighboursStayAtFloor() throws {
        // The Adriatic and the Ionian, a few degrees apart.
        let region = try #require(OceanMapRegion.fitting([(43.0, 15.0), (38.0, 19.0)]))
        #expect(region.latitudeDelta == OceanMapRegion.minimumLatitudeDelta)
        #expect(region.longitudeDelta == OceanMapRegion.minimumLongitudeDelta)
        #expect(region.contains(latitude: 43.0, longitude: 15.0))
        #expect(region.contains(latitude: 38.0, longitude: 19.0))
    }

    @Test("a tight pair astride the antimeridian is framed across it, not around the world")
    func antimeridianFramesTheShortWay() throws {
        // The Bering Sea at -178 and a neighbour at 170 are 12 degrees apart across the date
        // line; a min-to-max fit would call them 348 apart and refuse the floor.
        let region = try #require(OceanMapRegion.fitting([(58.0, -178.0), (56.0, 170.0)]))
        #expect(region.longitudeDelta == OceanMapRegion.minimumLongitudeDelta)
        #expect(region.contains(latitude: 58.0, longitude: -178.0))
        #expect(region.contains(latitude: 56.0, longitude: 170.0))
    }

    @Test("pins on opposite sides of the world defer to the map's own fit")
    func oppositeSidesDefer() {
        #expect(OceanMapRegion.fitting([(10.0, 0.0), (10.0, 180.0)]) == nil)
        // Opposite across the antimeridian too: the Bering Sea against the Coral Sea.
        #expect(OceanMapRegion.fitting([(58.0, -178.0), (-18.0, 158.0)]) == nil)
    }

    @Test("a pin in the far north keeps its span and gives up its centre, not the pole")
    func farNorthClampsCentre() throws {
        // The Lincoln Sea sits at 83: half the floor past it is 98, which MapKit rejects.
        let region = try #require(OceanMapRegion.fitting([(83.0, -60.0)]))
        #expect(region.latitudeDelta == OceanMapRegion.minimumLatitudeDelta)
        #expect(region.centerLatitude + region.latitudeDelta / 2 <= 90)
        #expect(region.contains(latitude: 83.0, longitude: -60.0))
    }

    @Test("a wide scatter of pins defers to the map's own fit, because the floor has nothing to add")
    func wideScatterDefers() {
        // The first cut framed every spread itself, and a worldwide scatter came back as a
        // Pacific close-up: the padded latitude clamps to 180, which Mercator cannot draw.
        let scattered = Array(OceanCatalog.all.prefix(40)).map { ($0.latitude, $0.longitude) }
        #expect(OceanMapRegion.fitting(scattered) == nil)
        let everything = OceanCatalog.all.map { ($0.latitude, $0.longitude) }
        #expect(OceanMapRegion.fitting(everything) == nil)
    }

    @Test("every region the floor hands out frames all of its pins")
    func flooredRegionsFrameTheirPins() throws {
        // Clusters at awkward places: straddling the antimeridian, hugging a pole, plain.
        let clusters: [[(latitude: Double, longitude: Double)]] = [
            [(52.0, 178.0), (54.0, -176.0), (50.0, 172.0)],
            [(82.0, -60.0), (80.0, -50.0)],
            [(-34.0, 18.0), (-36.0, 22.0), (-33.0, 26.0)],
        ]
        for cluster in clusters {
            let region = try #require(OceanMapRegion.fitting(cluster))
            for (latitude, longitude) in cluster {
                #expect(region.contains(latitude: latitude, longitude: longitude))
            }
        }
    }
}
