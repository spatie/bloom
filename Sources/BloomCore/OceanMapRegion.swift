import Foundation

/// The region the Discovered Seas map should frame when the pins alone would not say where on
/// Earth they are, computed here so a test can hold it still.
///
/// Left to itself, MapKit fits its camera to the annotations, and with a single pin that means
/// zooming all the way in: the first discovery, which is the view every new user sees first,
/// was a featureless close-up of open water with one dot and no coastline. The fix is a floor,
/// and the floor is the whole fix: a cluster tighter than a continent is framed at continent
/// scale, and anything wider is left to MapKit's own fit, which was never the defective case.
/// The first cut of this type built a padded region for every spread instead, and forty pins
/// across the globe came back as a close-up of the Pacific: the padded latitude clamps to 180,
/// Mercator cannot draw the poles, and MapKit settled the contradiction by cropping longitude.
/// So wide spreads return nil on purpose, and the view reads nil as "let the map decide".
///
/// In the core rather than the view because the choice of frame is a decision, the one-pin,
/// antimeridian and scattered cases are its edges, and a decision taken inside a view is a
/// decision nothing can test. The view only converts the numbers to MapKit's types.
public struct OceanMapRegion: Sendable, Equatable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    /// The frame handed to every cluster the floor catches. Roughly a continent in a window
    /// shaped like the map's: 30 by 40 keeps the Adriatic's first pin inside a frame that also
    /// holds the shape of Europe.
    public static let minimumLatitudeDelta = 30.0
    public static let minimumLongitudeDelta = 40.0

    /// Room the pins must keep from the frame's edge before the floor lets go: a cluster is
    /// only "tight" while the floor would still hold it with margin, so a pin never starts
    /// life under the window's border.
    static let padding = 1.3

    /// The floor-sized region centred on the pins, or nil when the pins are spread wide enough
    /// to frame themselves, which is the view's cue to leave the camera to MapKit. Nil for no
    /// coordinates too, where the view shows its empty state instead.
    public static func fitting(_ coordinates: [(latitude: Double, longitude: Double)]) -> OceanMapRegion? {
        guard !coordinates.isEmpty else { return nil }

        let latitudes = coordinates.map(\.latitude)
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0

        // Longitude is a circle, so a min-to-max span would call two pins either side of the
        // antimeridian, the Bering Sea at -178 and a neighbour at 170, nearly a world apart.
        // The smallest covering arc is the complement of the largest gap between neighbouring
        // longitudes, so find the gap and measure everything else.
        let sorted = coordinates.map(\.longitude).sorted()
        var gapStart = sorted.last ?? 0
        var largestGap = (sorted.first ?? 0) - (sorted.last ?? 0) + 360
        for (previous, next) in zip(sorted, sorted.dropFirst()) where next - previous > largestGap {
            largestGap = next - previous
            gapStart = previous
        }
        let lonSpan = 360 - largestGap

        // The moment padded pins would fill the floor on either axis, the floor has nothing to
        // add and plenty to break, so step aside for the map's own fit.
        guard (maxLat - minLat) * padding < minimumLatitudeDelta,
              lonSpan * padding < minimumLongitudeDelta else { return nil }

        var centerLon = gapStart + largestGap + lonSpan / 2
        if centerLon > 180 { centerLon -= 360 }

        // The floor can push the frame past a pole for a pin in the far north, the Lincoln Sea
        // at 83. The span survives and the centre gives way, because a region hanging past the
        // pole is what MapKit silently rejects.
        let halfLat = minimumLatitudeDelta / 2
        let centerLat = min(max((minLat + maxLat) / 2, -90 + halfLat), 90 - halfLat)

        return OceanMapRegion(
            centerLatitude: centerLat,
            centerLongitude: centerLon,
            latitudeDelta: minimumLatitudeDelta,
            longitudeDelta: minimumLongitudeDelta
        )
    }

    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// Whether the region frames this coordinate, longitude measured around the circle the same
    /// way the fit was. Here rather than in the tests because it is the property the fit
    /// promises, and a promise the type states is one the next edit has to keep.
    public func contains(latitude: Double, longitude: Double) -> Bool {
        guard abs(latitude - centerLatitude) <= latitudeDelta / 2 else { return false }
        var offset = (longitude - centerLongitude).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset -= 360 }
        if offset < -180 { offset += 360 }
        return abs(offset) <= longitudeDelta / 2
    }
}
