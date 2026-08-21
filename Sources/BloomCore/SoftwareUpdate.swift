import Foundation

/// Whether this copy of Bloom is allowed to update itself, when it may look, and what it says when
/// an update would interrupt work.
///
/// A type of its own, in the core, for the reason `SleepPrevention` and `DockBadge` are: every
/// answer here is a judgement rather than a passthrough, several surfaces ask for the same one,
/// and none of it needs Sparkle to be decided. The app target owns the updater itself; this owns
/// what the updater is allowed to do.
public enum SoftwareUpdate {
    // MARK: - Info.plist keys

    /// Sparkle's own keys, named here so the build script, the app and the tests all spell them
    /// the same way.
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"

    /// Whether this bundle was stamped as a release. Written by `Tools/build.sh`. See `availability`.
    public static let buildChannelKey = "BloomBuildChannel"

    /// Written by `Tools/master.sh` into the copy it installs in `~/Applications`. See `availability`.
    public static let masterCommitKey = "BloomMasterCommit"

    /// What `Tools/build.sh` leaves in the two Sparkle keys when nothing has been configured.
    ///
    /// A placeholder rather than a plausible-looking URL, because a real-looking default is the
    /// one thing that could make an unconfigured build check a host nobody owns.
    public static let placeholderPrefix = "__BLOOM_"

    /// The value `Tools/build.sh` writes into `BloomBuildChannel` for a build that was given a version.
    public static let releaseChannel = "release"

    // MARK: - Scheduling

    /// How often a background check may run, in seconds.
    ///
    /// A day. Bloom is a tool people leave open for days at a time, so an interval measured in
    /// hours would mean several checks per working week for a project that releases far less
    /// often than that, and every one of them is a request to somebody's bucket and a chance to
    /// interrupt. Sparkle's own floor is an hour and its own default is a day.
    public static let checkInterval: TimeInterval = 86_400

    // MARK: - Availability

    /// Whether this bundle may update itself, and why not when it may not.
    public enum Availability: Equatable, Sendable {
        /// Configured, stamped, and free to check.
        case configured(feedURL: String)

        /// Built from source on this machine. See `availability`.
        case localBuild

        /// A release build whose feed URL or public key was never filled in.
        case notConfigured
    }

    /// Reads the four keys that decide it out of a bundle's Info dictionary.
    ///
    /// Two of the three refusals are about not updating over somebody's own work rather than
    /// about missing configuration.
    ///
    /// A build made by `Tools/build.sh` with no version stamped on it is a working copy of the source
    /// tree. Its `CFBundleVersion` is whatever `Resources/Info.plist` happens to carry, which
    /// bears no relation to what has been released, so comparing it against an appcast is
    /// meaningless in both directions: a released build looks newer than a working copy that is
    /// months ahead of it, and a working copy that has been hand-stamped looks newer than
    /// everything and would never update again. Neither answer is worth having, so an unstamped
    /// build simply does not ask.
    ///
    /// `Tools/master.sh` installs into `~/Applications/Bloom.app` under the real bundle id, and stamps
    /// the commit it built. That is the same case one step further along: an app somebody is
    /// using all day, built from a commit rather than from a release, which must not be replaced
    /// underneath them by an older release zip. It is checked separately from the channel because
    /// it is the case where being wrong costs the most.
    public static func availability(
        feedURL: String?,
        publicKey: String?,
        buildChannel: String?,
        masterCommit: String?
    ) -> Availability {
        if masterCommit?.isEmpty == false { return .localBuild }
        guard buildChannel == releaseChannel else { return .localBuild }

        guard let feedURL = filled(feedURL), filled(publicKey) != nil else { return .notConfigured }

        return .configured(feedURL: feedURL)
    }

    /// Reads it out of a bundle. The app calls this with `Bundle.main`.
    public static func availability(in bundle: Bundle) -> Availability {
        availability(
            feedURL: bundle.object(forInfoDictionaryKey: feedURLKey) as? String,
            publicKey: bundle.object(forInfoDictionaryKey: publicKeyKey) as? String,
            buildChannel: bundle.object(forInfoDictionaryKey: buildChannelKey) as? String,
            masterCommit: bundle.object(forInfoDictionaryKey: masterCommitKey) as? String
        )
    }

    /// A value that is present, not blank, and not the placeholder the build script leaves behind.
    private static func filled(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(placeholderPrefix) else { return nil }
        return trimmed
    }

    // MARK: - The rule that protects work in flight

    /// Whether a scheduled check in the background may run right now.
    ///
    /// False while any agent is mid turn. Nothing about downloading an appcast is dangerous, but
    /// what a successful background check produces is an alert offering to install and restart,
    /// and that alert appearing over five running agents is an invitation to lose all five. The
    /// check costs nothing to defer: Sparkle reschedules and asks again later, by which time the
    /// agents are usually done.
    ///
    /// This is deliberately not applied to a check the user asked for. Looking is not installing,
    /// and an updater that refuses to even look while a long turn is running would be answering a
    /// question nobody asked.
    public static func mayCheckInBackground(runningCount: Int) -> Bool {
        runningCount == 0
    }

    /// Why a background check was skipped, for the log and for Sparkle's own error.
    public static let backgroundCheckDeferred =
        "Bloom does not check for updates in the background while agents are running."

    // MARK: - What the user is asked before a restart

    /// The heading of the alert shown when an install would restart Bloom over running agents.
    public static func interruptionTitle(runningCount: Int) -> String {
        runningCount == 1
            ? "An agent is still running"
            : "\(runningCount) agents are still running"
    }

    /// The body of that alert, naming the workspaces where the work would be lost.
    ///
    /// Named rather than only counted, and capped, for the same reason the quit confirmation names
    /// them: past a handful the count is the useful fact and the names are noise.
    public static func interruptionDetail(runningCount: Int, workspaceNames: [String]) -> String {
        var detail = runningCount == 1
            ? "Installing this update restarts Bloom. The turn it is in the middle of will not be finished, and it cannot be resumed."
            : "Installing this update restarts Bloom. The turns they are in the middle of will not be finished, and they cannot be resumed."

        let shown = workspaceNames.prefix(5)
        if !shown.isEmpty {
            detail += "\n\n" + shown.map { "\u{2022} \($0)" }.joined(separator: "\n")
            if workspaceNames.count > shown.count {
                detail += "\n\u{2022} and \(workspaceNames.count - shown.count) more"
            }
        }

        return detail
    }

    /// The safe answer, and the default one.
    public static let waitButtonTitle = "Install When They Finish"

    /// The answer that costs the running turns.
    public static let installNowButtonTitle = "Install and Restart Now"

    // MARK: - The Settings row

    /// The Settings section header.
    public static let sectionTitle = "Updates"

    /// The switch.
    public static let settingTitle = "Check for updates automatically"

    /// Said in terms of when it will and will not interrupt, because that is the part that matters
    /// in an app that runs agents.
    public static let settingDetail =
        "Once a day, and never while an agent is running. Nothing is downloaded or installed until you say so."

    /// Shown in place of the switch on a build that cannot update itself.
    public static func unavailableExplanation(_ availability: Availability) -> String? {
        switch availability {
        case .configured: nil
        case .localBuild: "This copy was built from source, so it updates when you build it again."
        case .notConfigured: "This build has no update feed configured."
        }
    }
}
