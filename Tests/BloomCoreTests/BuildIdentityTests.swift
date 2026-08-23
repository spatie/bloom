import Foundation
import Testing
@testable import BloomCore

/// The bug this file is about: `Resources/Info.plist` carries a fixed `0.1.0 (1)`, so reading
/// `CFBundleShortVersionString` on a build made from the source tree returned a version that had
/// never been released, in the shape a real one takes. Every case below is one build route.
@Suite("Build identity")
struct BuildIdentityTests {
    @Test("A build with nothing stamped on it says so, rather than repeating the placeholder")
    func localBuildIsNotAVersion() {
        let identity = BuildIdentity.read(
            version: "0.1.0", build: "1", buildChannel: "local", masterCommit: nil
        )

        #expect(identity == .local)
        #expect(identity.line == "Development build")
        #expect(identity.isRelease == false)
    }

    @Test("A missing channel is a local build too")
    func missingChannelIsLocal() {
        #expect(
            BuildIdentity.read(version: "0.1.0", build: "1", buildChannel: nil, masterCommit: nil)
                == .local
        )
    }

    @Test("The release workflow's stamp is the only thing that produces a version")
    func releaseCarriesItsVersion() {
        let identity = BuildIdentity.read(
            version: "0.2.0", build: "431", buildChannel: "release", masterCommit: nil
        )

        #expect(identity == .release(version: "0.2.0", build: "431"))
        #expect(identity.line == "Version 0.2.0 · Build 431")
        #expect(identity.value == "0.2.0 (431)")
        #expect(identity.isRelease)
    }

    @Test("A build number equal to the version is not printed twice")
    func repeatedBuildNumberIsDropped() {
        let identity = BuildIdentity.read(
            version: "1.0", build: "1.0", buildChannel: "release", masterCommit: nil
        )

        #expect(identity.line == "Version 1.0")
        #expect(identity.value == "1.0")
    }

    /// `Tools/master.sh` stamps a commit and no version, and it is the copy in `~/Applications`
    /// that somebody is using all day, so it is the one most likely to be read off in a report.
    @Test("The master copy names the commit it was built from, shortened the way git shows it")
    func masterNamesItsCommit() {
        let identity = BuildIdentity.read(
            version: "0.1.0", build: "1", buildChannel: "local", masterCommit: "10320b4c9f1e2a3"
        )

        #expect(identity == .master(commit: "10320b4c9f1e2a3"))
        #expect(identity.line == "Development build · 10320b4")
        #expect(identity.value == identity.line)
    }

    /// The same precedence `SoftwareUpdate.availability` applies, and for the same reason: a
    /// bundle carrying a master commit was built from a working copy whatever else is stamped on
    /// it, so it must not be able to claim a released version by also setting the channel.
    @Test("A master commit outranks a release channel")
    func masterCommitWins() {
        let identity = BuildIdentity.read(
            version: "0.2.0", build: "431", buildChannel: "release", masterCommit: "deadbeef1"
        )

        #expect(identity == .master(commit: "deadbeef1"))
        #expect(identity.isRelease == false)
    }

    @Test("Blank strings count as absent, not as a version")
    func blanksAreAbsent() {
        #expect(
            BuildIdentity.read(
                version: "  ", build: "1", buildChannel: "release", masterCommit: nil
            ) == .local
        )
        #expect(
            BuildIdentity.read(
                version: "0.2.0", build: "431", buildChannel: "release", masterCommit: "   "
            ) == .release(version: "0.2.0", build: "431")
        )
    }

    /// A release with no build number is not a case any script produces, but falling back to the
    /// version keeps `line` from printing "Version 0.2.0 · Build ".
    @Test("A release missing its build number prints the version alone")
    func releaseWithoutBuildNumber() {
        let identity = BuildIdentity.read(
            version: "0.2.0", build: nil, buildChannel: "release", masterCommit: nil
        )

        #expect(identity.line == "Version 0.2.0")
    }

    // MARK: The build's own timestamp

    private static let brussels = TimeZone(identifier: "Europe/Brussels")!
    private static let belgium = Locale(identifier: "en_GB")
    /// 23 August 2026 at 14:32 in Brussels, read on the evening of the same day.
    private static let built = Date(timeIntervalSince1970: 1_787_488_320)
    private static let now = Date(timeIntervalSince1970: 1_787_500_800)

    private static func line(_ identity: BuildIdentity, built: Date?) -> String {
        identity.line(built: built, now: now, locale: belgium, timeZone: brussels)
    }

    /// The copy in `~/Applications` is rebuilt from a new commit most days, and an agent's build
    /// is rebuilt from the same commit several times an hour. The commit alone does not separate
    /// those, which is the whole reason the time is there.
    @Test("A development build says when it was made")
    func developmentBuildCarriesItsTimestamp() {
        #expect(Self.line(.local, built: Self.built) == "Development build · 23 Aug 14:32")
        #expect(
            Self.line(.master(commit: "10320b4c9f1e2a3"), built: Self.built)
                == "Development build · 10320b4 · 23 Aug 14:32"
        )
    }

    /// A release's version is the fact somebody reads back, and it is the same in every copy of
    /// that release. When the release runner happened to assemble the zip is not.
    @Test("A release is left exactly as it was")
    func releaseNeverShowsATimestamp() {
        let identity = BuildIdentity.release(version: "0.5.0", build: "570")

        #expect(Self.line(identity, built: Self.built) == "Version 0.5.0 · Build 570")
        #expect(Self.line(identity, built: Self.built) == identity.line)
    }

    /// A bundle assembled by something other than `Tools/build.sh`, and old enough that the
    /// executable's date could not be read either. The line goes back to what it always was.
    @Test("No date is the line without one, not a gap where one would go")
    func missingDateChangesNothing() {
        #expect(Self.line(.local, built: nil) == "Development build")
        #expect(
            Self.line(.master(commit: "10320b4c9f1e2a3"), built: nil)
                == "Development build · 10320b4"
        )
    }

    /// Reading a bundle rather than four strings, which is what both call sites actually do.
    @Test("Reading it out of a bundle agrees with reading the keys by hand")
    func readsFromABundle() {
        #expect(BuildIdentity.read(from: Bundle.main).isRelease == false)
    }
}
