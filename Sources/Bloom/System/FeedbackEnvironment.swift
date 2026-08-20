import AppKit
import Foundation
import BloomCore

/// Assembles the block of facts that travels with a feedback report or a prompt submission.
///
/// The list itself, and every rule about what may be in it, is `Feedback.Environment` in the core.
/// What is left here is the part that needs a running app: reading this bundle's keys, asking the
/// kernel what kind of Mac this is, asking `PATH` which agent CLIs exist, and asking the one CLI
/// that is actually used what version it is.
///
/// **Nothing here opens a file that holds a credential.** Which backends are installed is answered
/// by `AgentCatalog.installedKinds`, which stats directories on `PATH` and nothing else, and the
/// version is a `--version` subprocess. `~/.claude.json` and `~/.codex/auth.json` are never read,
/// which is the difference between this and the settings screen's own detection: that one builds
/// an account table, and an account is exactly what a feedback report must not carry.
///
/// **Nothing here blocks a sheet.** The gather runs as a task started when the sheet appears and
/// is awaited only when Send is pressed, by which time somebody has been typing for long enough
/// that it has finished. The one slow part, the CLI's `--version`, is remembered for a day in the
/// app's defaults, so the second sheet of the day pays nothing for it at all.
@MainActor
enum FeedbackEnvironment {
    // MARK: - The slow fact, remembered

    /// Where the agent CLI's version is kept between sheets.
    static let versionKey = "feedback.agentVersion"
    static let versionCheckedKey = "feedback.agentVersionCheckedAt"

    /// How long a remembered version is trusted.
    ///
    /// A day. A CLI that updated itself an hour ago is reported as the version it was this
    /// morning, which is a small wrongness in one field, against running a subprocess every time
    /// somebody opens a sheet, which is a cost paid on every open forever. The version is also
    /// re-read whenever the remembered one is missing, so the first report from a machine is
    /// always accurate.
    static let versionLifetime: TimeInterval = 24 * 60 * 60

    /// How long the CLI gets to answer. The same five seconds `AgentCatalog` gives it.
    static let versionTimeout: Duration = .seconds(5)

    // MARK: - Gathering

    /// Every fact, ready to send.
    static func current(app: AppModel?) async -> Feedback.Environment {
        let defaults = UserDefaults.standard
        let bundle = Bundle.main

        let overrides = await executablePathOverrides(app: app)
        let permissionMode = await permissionMode(app: app)

        // Off the main actor: this stats directories on `PATH` and may spawn one short-lived
        // process. Neither belongs on the actor that is drawing the sheet somebody is typing into.
        let installed = await Task.detached(priority: .userInitiated) {
            AgentCatalog.installedKinds(overrides: overrides)
        }.value

        // The backend a turn would actually run on, which is the one whose version is worth
        // having. Not simply the first runnable kind: a machine that has Codex and not Claude
        // would otherwise report the version of a CLI it does not have.
        let running = AgentKind.allCases.first { $0.canRunWorkspaces && installed.contains($0) }
        let agentVersion = await agentVersion(of: running, overrides: overrides, defaults: defaults)

        let system = ProcessInfo.processInfo.operatingSystemVersion

        return Feedback.Environment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            macOSVersion: InstallPing.macOSVersion(
                major: system.majorVersion, minor: system.minorVersion, patch: system.patchVersion
            ),
            architecture: architecture(),
            translated: isTranslated(),
            installSource: Feedback.InstallSource(
                buildChannel: bundle.object(forInfoDictionaryKey: SoftwareUpdate.buildChannelKey) as? String,
                masterCommit: bundle.object(forInfoDictionaryKey: SoftwareUpdate.masterCommitKey) as? String,
                // Nothing writes this today, so this is nil and the answer is `local`. It is read
                // rather than assumed so that the day a build script stamps it, a report from a
                // modified working tree says so without a change here. See `InstallSource`.
                isDirty: bundle.object(forInfoDictionaryKey: Feedback.InstallSource.dirtyKey) as? Bool
            ),
            agent: InstallPing.agentName(installed: installed),
            agentVersion: agentVersion,
            availableAgents: installed.map(InstallPing.wireName),
            permissionMode: Feedback.wireName(permissionMode),
            theme: InstallPing.Theme(in: defaults),
            displayScale: displayScale(),
            locale: locale()
        )
    }

    /// The anonymous install token, which is sent with a submission so it can be read beside the
    /// install it came from. The same token the daily ping uses, and the same one either way: it
    /// is generated on first use and derived from nothing. See `InstallPing.installToken(in:)`.
    static func token() -> String {
        InstallPing.installToken()
    }

    // MARK: - The parts

    /// What the machine is, asked of the kernel rather than of the compiler.
    ///
    /// `#if arch(arm64)` would answer for the slice that was built, not for the Mac it is running
    /// on, so a translated build would report an Intel Mac and the most interesting report there
    /// is would be filed under the wrong hardware.
    static func architecture() -> Feedback.Architecture {
        Feedback.Architecture(isARM: sysctlFlag(armFlag), isTranslated: isTranslated())
    }

    /// Whether this process is running under Rosetta, which is a fact about the process and not
    /// about the Mac: the same binary on the same machine can answer differently depending on
    /// which slice was launched. Sent beside `architecture` rather than folded into it, because
    /// "Intel Mac" and "translated on Apple silicon" are different bugs.
    static func isTranslated() -> Bool {
        sysctlFlag(translatedFlag)
    }

    static let armFlag = "hw.optional.arm64"
    static let translatedFlag = "sysctl.proc_translated"

    /// One integer sysctl, read as a flag. Absent means no, which is what both of these mean on a
    /// Mac that does not have them.
    static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    /// The scale of the screen Bloom is being read on. `2` on any Retina display.
    static func displayScale() -> Double {
        Double(NSScreen.main?.backingScaleFactor ?? 1)
    }

    /// The language tag Bloom is being read under: `nl-BE`, `en`.
    ///
    /// Built from the two codes rather than taken from `Locale.identifier`, which is a string the
    /// user's settings can shape (`en_BE@calendar=hebrew`) and which is therefore exactly the kind
    /// of free text that has no business in a fixed field.
    static func locale() -> String {
        let language = (Locale.current.language.languageCode?.identifier ?? "").lowercased()
        guard !language.isEmpty else { return "" }
        guard let region = Locale.current.region?.identifier, !region.isEmpty else { return language }
        return "\(language)-\(region)"
    }

    /// The permission mode a new session starts in, resolved exactly as the composer resolves it.
    ///
    /// The app-level answer rather than the one in front of somebody right now: a report is about
    /// how this copy of Bloom is set up, and the mode a single session was switched into is that
    /// session's business.
    static func permissionMode(app: AppModel?) async -> PermissionMode {
        guard let store = app?.store else { return AppDefaults.fallbackPermissionMode }
        let defaults = await AppDefaults.load(from: store)
        return defaults.planMode ? .plan : defaults.permissionMode
    }

    /// The per-agent executable paths the Agents pane stored, so an agent installed somewhere
    /// unusual is seen as present rather than missing. Read the same way `InstallPingService`
    /// reads them.
    static func executablePathOverrides(app: AppModel?) async -> [AgentKind: String] {
        guard let store = app?.store else { return [:] }

        var found: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            guard let value = try? await store.setting(AgentCatalog.executablePathSettingKey(kind)) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { found[kind] = trimmed }
        }
        return found
    }

    /// What the agent CLI answers `--version` with, from memory if it was asked today.
    ///
    /// Empty when there is no CLI to ask or it did not answer. Empty is a real answer here and is
    /// sent as one: a version nobody could read is not the same as a CLI that is not installed,
    /// and `agent` already says which of the two happened.
    static func agentVersion(
        of kind: AgentKind?,
        overrides: [AgentKind: String],
        defaults: UserDefaults
    ) async -> String {
        guard let kind else { return "" }

        if let remembered = rememberedVersion(in: defaults) { return remembered }

        // Read on this actor and captured, because everything on this enum is isolated to it and
        // the work below deliberately is not.
        let timeout = versionTimeout
        let name = overrides[kind].map { ($0 as NSString).expandingTildeInPath } ?? kind.executableName

        let found = await Task.detached(priority: .userInitiated) { () -> String in
            guard let path = Shell.which(name) else { return "" }
            guard let result = try? await Shell.run(path, ["--version"], timeout: timeout) else {
                return ""
            }
            let stdout = result.trimmed
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // The same reading `AgentCatalog` does, borrowed rather than repeated, so the version
            // in a report and the version in the Agents pane are the same string.
            return AgentCatalog.parseVersion(stdout.isEmpty ? stderr : stdout) ?? ""
        }.value

        remember(found, in: defaults)
        return found
    }

    static func rememberedVersion(in defaults: UserDefaults) -> String? {
        guard let checked = defaults.object(forKey: versionCheckedKey) as? Date else { return nil }
        // A stored date in the future means the clock moved under us, so the answer is asked again
        // rather than trusted until the calendar catches up.
        guard checked <= Date(), Date().timeIntervalSince(checked) < versionLifetime else { return nil }
        guard let version = defaults.string(forKey: versionKey), !version.isEmpty else { return nil }
        return version
    }

    static func remember(_ version: String, in defaults: UserDefaults) {
        defaults.set(version, forKey: versionKey)
        defaults.set(Date(), forKey: versionCheckedKey)
    }
}
