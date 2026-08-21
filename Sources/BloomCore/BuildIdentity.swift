import Foundation

/// What this copy of Bloom actually is: a release, the copy `Tools/master.sh` installs, or a build
/// somebody made from the source tree.
///
/// It exists because the honest answer is not in `CFBundleShortVersionString`. `Resources/Info.plist`
/// carries a fixed `0.1.0 (1)`, and `Tools/build.sh` overwrites it only when handed both
/// `BLOOM_VERSION` and `BLOOM_BUILD`, which only the release workflow does. So every build made on
/// this machine reports `0.1.0 (1)`, and an About window that printed those two keys was printing a
/// version number that had never been released, in the same shape a real one would take. A wrong
/// answer wearing the format of a right one is worse than no answer: it is the number somebody
/// reads back in a bug report.
///
/// `BloomBuildChannel` is the key that knows, which is the same key `SoftwareUpdate.availability`
/// already refuses to update on, and `BloomMasterCommit` takes precedence over it there for the
/// same reason it does here: it is the more specific fact about the same bundle.
public enum BuildIdentity: Equatable, Sendable {
    /// Stamped by the release workflow from a tag. The only case carrying a version anyone else has.
    case release(version: String, build: String)

    /// The copy `Tools/master.sh` installs into `~/Applications`, built from a commit rather than a
    /// tag. Its commit is the only version-like thing about it that means anything.
    case master(commit: String)

    /// `Tools/build.sh` or `Tools/dev-build.sh`, with nothing stamped on it at all.
    case local

    /// Reads the keys that decide it.
    ///
    /// The master commit is checked first, matching `SoftwareUpdate.availability`: a bundle
    /// carrying one was built from a working copy whatever else is stamped on it.
    public static func read(
        version: String?,
        build: String?,
        buildChannel: String?,
        masterCommit: String?
    ) -> BuildIdentity {
        if let commit = filled(masterCommit) { return .master(commit: commit) }
        guard buildChannel == SoftwareUpdate.releaseChannel, let version = filled(version) else {
            return .local
        }
        return .release(version: version, build: filled(build) ?? version)
    }

    /// Reads it out of a bundle. The app calls this with `Bundle.main`.
    public static func read(from bundle: Bundle) -> BuildIdentity {
        read(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            buildChannel: bundle.object(forInfoDictionaryKey: SoftwareUpdate.buildChannelKey)
                as? String,
            masterCommit: bundle.object(forInfoDictionaryKey: SoftwareUpdate.masterCommitKey)
                as? String
        )
    }

    /// One line naming the build, for the About window and for anywhere else that has to say which
    /// copy this is.
    ///
    /// A release repeats its build number only when it differs from the version, because
    /// `Version 1.2.0 · Build 1.2.0` is noise. The commit is shortened to the seven characters git
    /// itself shows, which is what somebody would paste back.
    public var line: String {
        switch self {
        case .release(let version, let build) where build == version:
            "Version \(version)"
        case .release(let version, let build):
            "Version \(version) · Build \(build)"
        case .master(let commit):
            "Development build · \(commit.prefix(7))"
        case .local:
            "Development build"
        }
    }

    /// The same fact for a row that already carries the word "Version" as its label, where `line`
    /// would print it twice. The development cases are unchanged, because "Version: 0.1.0" and
    /// "Version: Development build" are both answers to the label's question and the first of them
    /// would be the wrong one.
    public var value: String {
        switch self {
        case .release(let version, let build) where build == version: version
        case .release(let version, let build): "\(version) (\(build))"
        case .master, .local: line
        }
    }

    /// Whether this build claims a version anyone else could be running.
    public var isRelease: Bool {
        if case .release = self { return true }
        return false
    }

    private static func filled(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
