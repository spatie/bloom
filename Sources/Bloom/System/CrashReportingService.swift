import Foundation
import Flare
import FlareCrashReporter
import BloomCore

/// Installs capture after preference migration and uploads independently of the launch sequence.
/// Reporting errors stay in Console; neither startup nor shutdown waits for Flare.
@MainActor
final class CrashReportingService {
    static let shared = CrashReportingService()
    private var reporter: FlareCrashReporter?
    private var upload: Task<Void, Never>?

    func start() {
        guard reporter == nil else { return }
        SystemDefaults.registerOnce()
        let identity = BuildIdentity.read(from: .main)
        guard CrashReporting.isEligible(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            identity: identity,
            enabled: UserDefaults.standard.bool(forKey: CrashReporting.settingKey),
            debuggerAttached: Self.debuggerAttached
        ) else { return }

        do {
            let capture = try FlareCrashReporter(client: Self.client(environment: CrashReporting.environment(for: identity)))
            try capture.start(context: Self.buildContext)
            reporter = capture
            upload = Task {
                let result = await capture.sendPendingReports()
                Log.crashes.debug("Crash uploads: \(result.sent) sent, \(result.failures.count) failed")
            }
        } catch {
            Log.crashes.error("Could not enable crash reporting: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func client(
        environment: String,
        apiKey: String = "OvJ6sOhaJcIGEshRdazHOxi7KAr9m6yj"
    ) -> FlareClient {
        FlareClient(
            configuration: .init(
                apiKey: apiKey,
                applicationName: "Bloom",
                applicationVersion: BuildIdentity.read(from: .main).line,
                environment: environment,
                context: buildContext,
                timeout: 10
            ),
            beforeSend: { report in
                var report = report
                // Probe-only filtering also exercises the same hook used to remove private context.
                if report.context["bloom_probe_filter"] == .bool(true) { return nil }
                report.context.removeValue(forKey: "private_note")
                return report
            }
        )
    }

    static var buildContext: [String: FlareValue] {
        [
            "app": "Bloom",
            "bundle_identifier": .string(Bundle.main.bundleIdentifier ?? "unbundled"),
            "build": .string(BuildIdentity.read(from: .main).line),
        ]
    }

    private static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return true }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}
