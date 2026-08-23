import Foundation

/// When this copy of Bloom was built, for the one place that has a use for it: the line under the
/// name in the About window.
///
/// It exists because a development build has no version number to tell it apart from another
/// development build. `BuildIdentity` already answers with the commit for the copy `Tools/master.sh`
/// installs, and with nothing at all for a build made from a working tree, so two builds made an
/// hour apart from the same commit, or from an uncommitted tree, print the same line. With several
/// of those around at once, which is the normal state of this repository, the About window cannot
/// answer the only question being asked of it: which of these am I looking at.
///
/// WHERE THE ANSWER COMES FROM, and why it is stamped rather than measured. `Tools/build.sh` writes
/// `BloomBuildDate` into the assembled bundle beside `BloomBuildChannel`, which is the same place
/// and the same moment every other fact about a build is recorded, so the value means what it says.
/// The alternative was the executable's modification date, and an mtime is not a build time: it
/// moves when a bundle is copied, and `codesign` rewrites the binary, so the number would be an
/// approximation presented in the shape of a fact. That is the failure `BuildIdentity` was written
/// to prevent, one level down.
///
/// The mtime is still read, but only when the key is absent, which means only for a bundle
/// assembled before the key existed. Those are the builds already sitting in `~/Applications` right
/// now, and showing them nothing would be the one case where the feature is needed and missing.
/// Every one of them was assembled by `Tools/build.sh` and copied into place by `master.sh` or
/// `dev-build.sh` minutes later, so the mtime is wrong by the length of a build rather than by
/// anything a person would notice, and it is right about the thing being asked: which of these two
/// is the newer. The next rebuild replaces it with the stamp and it is never consulted again.
public enum BuildTimestamp {
    /// The Info.plist key `Tools/build.sh` writes. In the `Bloom` prefix the other two build facts
    /// use, so the three read as one family in a plist dump.
    public static let infoKey = "BloomBuildDate"

    /// Reads it out of a bundle. The app calls this with `Bundle.main`.
    public static func read(from bundle: Bundle) -> Date? {
        read(
            stamp: bundle.object(forInfoDictionaryKey: infoKey) as? String,
            executableModified: executableModified(of: bundle)
        )
    }

    /// The two sources in their order of precedence, taken apart so both can be tested. A stamp
    /// that cannot be parsed falls through to the mtime rather than to nothing: a malformed value
    /// is a broken build script, and the window is still better off with an approximation than
    /// with a blank.
    public static func read(stamp: String?, executableModified: Date?) -> Date? {
        parse(stamp) ?? executableModified
    }

    /// The stamp as `build.sh` writes it: an ISO 8601 instant in UTC. UTC rather than local time
    /// because it is stored, not read, and it is displayed in whatever zone the reader is in.
    public static func parse(_ stamp: String?) -> Date? {
        guard let stamp else { return nil }
        let trimmed = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// How it reads in the About window's spec line: `23 Aug 14:32`.
    ///
    /// Built from two localised templates rather than from a format string, because the order of
    /// the day and the month, the month's own abbreviation and the choice between a 24 hour and a
    /// 12 hour clock all belong to the reader's locale and region, and a hardcoded `d MMM HH:mm`
    /// gets all three wrong for anybody who is not in this office. Joined with a space rather than
    /// asked for as one skeleton, because a single skeleton produces the connective the locale
    /// prefers, which is "23 Aug at 14:32" here, and that word is a sentence in a line that is a
    /// spec.
    ///
    /// No seconds: two builds a second apart are not what this is telling apart, and the line
    /// already carries a label and a commit. The year appears only when the build is not from the
    /// current one, where leaving it out would make a build from last August indistinguishable
    /// from this morning's.
    public static func line(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)

        let day = formatter(template: sameYear ? "MMMd" : "yMMMd", locale, timeZone)
        let time = formatter(template: "jmm", locale, timeZone)
        return "\(day.string(from: date)) \(time.string(from: date))"
    }

    private static func formatter(
        template: String, _ locale: Locale, _ timeZone: TimeZone
    ) -> DateFormatter {
        // Made here rather than held in a static, and not only because a `DateFormatter` is not
        // `Sendable`: `.autoupdatingCurrent` means the answer can change while the app runs, and
        // this is read once each time an About window opens.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func executableModified(of bundle: Bundle) -> Date? {
        guard let url = bundle.executableURL else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}
