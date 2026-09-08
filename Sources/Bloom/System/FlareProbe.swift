#if DEBUG
import Foundation
import Flare
import FlareCrashReporter
import BloomCore

/// A headless entry into the real app binary, before AppModel exists. It only runs in the
/// separately identified bundle Tools/flare-probe.sh makes, with a marked temporary directory.
@MainActor
enum FlareProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--flare-probe") }

    static func runAndExit() async -> Never {
        do {
            guard Bundle.main.bundleIdentifier == CrashReporting.probeBundleIdentifier,
                  let mode = argument("--flare-probe"),
                  let path = argument("--flare-probe-root") else {
                throw ProbeError("The Flare probe requires its own bundle and temporary directory.")
            }
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            guard root.path.hasPrefix(temporary),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(".bloom-flare-probe").path) else {
                throw ProbeError("Refusing to use an unmarked directory outside the probe's temporary area.")
            }

            let client = CrashReportingService.client(environment: "testing")
            let queue = root.appendingPathComponent("queue")
            var results: [String: JSONValue] = ["mode": .string(mode), "run": .string(root.lastPathComponent)]

            switch mode {
            case "reports":
                results["cases"] = .object(try await reportCases(client: client, run: root.lastPathComponent))
            case "crash":
                guard CommandLine.arguments.contains("--confirm-crash") else {
                    throw ProbeError("An intentional crash requires --confirm-crash.")
                }
                let reporter = try FlareCrashReporter(client: client, directory: queue)
                try reporter.start(context: CrashReportingService.buildContext.merging([
                    "synthetic": true,
                    "run": .string(root.lastPathComponent),
                    "purpose": "Verify native crash recovery from the Bloom binary",
                ]) { _, new in new })
                fatalError("Intentional Bloom Flare probe crash")
            case "retry", "upload", "empty":
                let sender = mode == "retry" ? CrashReportingService.client(environment: "testing", apiKey: "") : client
                let reporter = try FlareCrashReporter(client: sender, directory: queue)
                let result = await reporter.sendPendingReports()
                results["sent"] = .integer(result.sent)
                results["filtered"] = .integer(result.filtered)
                results["failures"] = .integer(result.failures.count)
                results["cancelled"] = .bool(result.cancelled)
                let expectedSent = mode == "upload" ? 1 : 0
                let expectedFailures = mode == "retry" ? 1 : 0
                guard result.sent == expectedSent, result.failures.count == expectedFailures,
                      result.filtered == 0, !result.cancelled else {
                    throw ProbeError("Unexpected queue outcome: sent \(result.sent), failures \(result.failures.count).")
                }
            default:
                throw ProbeError("Unknown Flare probe mode: \(mode)")
            }

            let data = try JSONEncoder().encode(JSONValue.object(results))
            try data.write(to: root.appendingPathComponent("\(mode).json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch {
            print("Flare probe failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func reportCases(client: FlareClient, run: String) async throws -> [String: JSONValue] {
        var cases: [String: JSONValue] = [:]
        let caught = await client.report(
            ProbeError("Bloom Flare integration: a caught Swift error"),
            context: ["synthetic": true, "run": .string(run), "private_note": "THIS_MUST_BE_REMOVED"]
        )
        cases["caught_error"] = try accepted(caught)

        let report = FlareReport(
            exceptionClass: "Bloom.FlareProbe.SuppliedFrames",
            message: "Bloom Flare integration: Swift frames, breadcrumbs and context",
            code: "BLOOM_FLARE_PROBE",
            grouping: .exceptionMessageAndClass,
            stacktrace: [
                .init(file: "Demo/WorkspaceLoader.swift", lineNumber: 42, method: "openWorkspace(id:)",
                      className: "WorkspaceLoader", codeSnippet: ["41": "// Synthetic integration example", "42": "throw WorkspaceError.unavailable"]),
                .init(file: "Demo/AppModel.swift", lineNumber: 18, method: "selectWorkspace(_:)", className: "AppModel"),
            ],
            context: [
                "synthetic": true, "run": .string(run), "private_note": "THIS_MUST_BE_REMOVED",
                "attempt": 2, "progress": 0.5, "optional_value": nil,
                "details": ["screen": "workspace", "tags": ["swift", "bloom"]],
            ],
            attributes: ["user.id": "bloom-flare-probe", "user.full_name": "Synthetic test user"],
            breadcrumbs: [
                .init("Selected demo workspace", context: ["synthetic": true]),
                .init("Workspace unavailable", level: .warning, context: ["attempt": 2]),
            ]
        )
        guard let reportUUID = try await client.send(report) else { throw ProbeError("The supplied report was filtered.") }
        cases["frames_and_context"] = .string(reportUUID.uuidString)

        let filtered = await client.report(FlareReport(
            exceptionClass: "Bloom.FlareProbe.Filtered", message: "This report must never reach Flare",
            context: ["bloom_probe_filter": true]
        ))
        guard case .filtered = filtered else { throw ProbeError("The filtering hook did not suppress the report.") }
        cases["filtering"] = .string("passed")

        let invalid = CrashReportingService.client(environment: "testing", apiKey: "")
        let failure = await invalid.report(ProbeError("This missing-key failure must not terminate Bloom"))
        guard case .failed = failure else { throw ProbeError("The reporting failure was not returned safely.") }
        cases["nonthrowing_failure"] = .string("passed")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.report(ProbeError("This cancelled report must never reach Flare"))
        }
        guard case .cancelled = await cancelled.value else { throw ProbeError("Cancellation was not preserved.") }
        cases["cancellation"] = .string("passed")
        return cases
    }

    private static func accepted(_ result: FlareSendResult) throws -> JSONValue {
        guard case .accepted(let reportUUID) = result else {
            throw ProbeError("Flare did not accept the handled error: \(String(describing: result))")
        }
        return .string(reportUUID.uuidString)
    }

    private static func argument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    struct ProbeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
