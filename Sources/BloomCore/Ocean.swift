import Foundation

/// One sea from the catalogue every workspace is christened out of.
///
/// The catalogue is the owner's list of the world's seas, each with the point a map pin should
/// stand on. A sea is spent the first time a workspace is named after it, which is what `usedAt`
/// records, and the map window draws the spent ones. The slug is stored rather than derived
/// because it is about to become a git branch, and a branch name is not something to recompute
/// two ways.
public struct Ocean: Sendable, Hashable, Identifiable {
    public var id: String { slug }

    public let name: String
    public let slug: String
    public let latitude: Double
    public let longitude: Double
    /// When a workspace first wore this name, or nil while the sea is still waiting.
    public var usedAt: Date?

    public init(name: String, slug: String, latitude: Double, longitude: Double, usedAt: Date? = nil) {
        self.name = name
        self.slug = slug
        self.latitude = latitude
        self.longitude = longitude
        self.usedAt = usedAt
    }
}

/// What claiming a name from the catalogue came back with.
///
/// Carries enough to say the one sentence the user is shown, so the wording lives here in the
/// core where a test can read it, rather than in whichever view happens to show it.
public struct OceanPick: Sendable, Hashable {
    public let ocean: Ocean
    /// Whether this claim is the sea's first. False once every sea has been used and the
    /// catalogue has started handing out repeats, which is not worth a banner.
    public let isFirstUse: Bool
    /// How many seas were still unused after this claim.
    public let remainingUndiscovered: Int

    public init(ocean: Ocean, isFirstUse: Bool, remainingUndiscovered: Int) {
        self.ocean = ocean
        self.isFirstUse = isFirstUse
        self.remainingUndiscovered = remainingUndiscovered
    }

    /// The flash message for a first use, or nothing for a repeat.
    ///
    /// Deliberately does not name the seas that are left, only counts them: which ones remain is
    /// meant to stay a small surprise, and the map window keeps the same rule.
    public var notice: String? {
        guard isFirstUse else { return nil }
        switch remainingUndiscovered {
        case 0:
            return "This workspace is the first to sail the \(ocean.name), and it was the last sea left. All of them have now been discovered."
        case 1:
            return "This workspace is the first to sail the \(ocean.name). One sea is still waiting to be discovered."
        default:
            return "This workspace is the first to sail the \(ocean.name). \(remainingUndiscovered) seas are still waiting to be discovered."
        }
    }
}

/// Reads the catalogue.
///
/// The data ships inside the binary, in `OceanCatalogData.swift`, rather than as a bundle
/// resource: `Tools/test-core.sh` mirrors the core sources into a throwaway package, and a
/// resource is exactly the kind of file such a mirror quietly loses. The store seeds its table
/// from `all` on migration, and from then on the database is the truth about what has been used.
public enum OceanCatalog {
    public static let all: [Ocean] = parse(tsv: builtInTSV)

    /// One sea per line, tab separated: name, slug, latitude, longitude. The first line is the
    /// header and any line that does not scan is dropped rather than trusted, because this data
    /// came from a hand-kept file and a half-parsed row would become a branch name.
    public static func parse(tsv: String) -> [Ocean] {
        tsv.components(separatedBy: .newlines).dropFirst().compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 4,
                  let latitude = Double(fields[2]),
                  let longitude = Double(fields[3]),
                  (-90.0...90.0).contains(latitude),
                  (-180.0...180.0).contains(longitude) else { return nil }
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            let slug = fields[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, Git.isValidBranchName(slug) else { return nil }
            return Ocean(name: name, slug: slug, latitude: latitude, longitude: longitude)
        }
    }
}
