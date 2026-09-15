#if DEBUG
import AppKit
import SwiftUI
import BloomCore

/// Exercises the real import sheet with fake account metadata and injected operations.
/// No local credentials, provider APIs or server connections are accessed by this probe.
@MainActor
enum ServerCredentialImportProbe {
    static func verify(window: NSWindow, capture: @MainActor (String) async throws -> Void) async throws {
        let connection = try ServerSetupConnection(host: "bloom@development.example", identityFile: "/tmp/fixture-key", knownHostsFile: "/tmp/fixture-hosts")
        let github = ServerCredentialImport.Candidate.github(hostname: "github.com", user: "developer")
        let alternate = ServerCredentialImport.Candidate.github(hostname: "github.com", user: "work-account")
        let codex = ServerCredentialImport.Candidate.codex(home: "/Users/example/.codex")
        let model = ServerCredentialImportModel(connection: connection, discover: {
            ServerCredentialImport.Discovery(candidates: [github, alternate, codex], notices: [])
        }, importAccount: { candidate, _ in
            if candidate == codex { throw ServerFailure("This must not appear in the import UI: fixture-secret") }
            return ServerCredentialImport.Outcome(verified: true, message: "Signed in as work-account on github.com.",
                removalGuidance: "Use gh auth logout on the server to remove its saved sign-in.")
        })
        await model.discover()
        guard model.selected.isEmpty, model.results.isEmpty, !model.canImport else {
            throw ServerFailure("Opening credential import must not select or transfer accounts.")
        }
        model.select(github, enabled: true)
        model.select(alternate, enabled: true)
        guard model.selected == [alternate] else { throw ServerFailure("Only one GitHub account can be imported at once.") }
        model.select(codex, enabled: true)
        window.setContentSize(NSSize(width: 660, height: 570))
        window.contentView = NSHostingView(rootView: ServerCredentialImportView(model: model, close: {}).environment(\.colorScheme, .light).background(Palette.windowBackground))
        try await Task.sleep(for: .milliseconds(150))
        try await capture("account-import-review-fixture")
        model.startImport()
        try await finish(model)
        guard model.results[alternate]?.succeeded == true, model.results[codex]?.succeeded == false,
              model.results[codex]?.message.contains("fixture-secret") == false,
              model.selected == [codex] else { throw ServerFailure("Partial import must preserve each account's result without exposing raw errors.") }
        try await capture("account-import-partial-result-fixture")
        let stopping = ServerCredentialImportModel(connection: connection, discover: {
            ServerCredentialImport.Discovery(candidates: [codex], notices: [])
        }, importAccount: { _, _ in
            try await Task.sleep(for: .seconds(20))
            throw ServerFailure("The cancelled operation should not finish.")
        })
        await stopping.discover()
        stopping.select(codex, enabled: true)
        stopping.startImport()
        try await Task.sleep(for: .milliseconds(20))
        stopping.stop()
        try await finish(stopping)
        guard !stopping.isStopping, stopping.results[codex]?.message.contains("may already have reached") == true else {
            throw ServerFailure("Cancellation must warn about uncertain remote completion and allow closing the sheet.")
        }
        model.cancel(); stopping.cancel()
    }

    private static func finish(_ model: ServerCredentialImportModel) async throws {
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        guard !model.isBusy else { throw ServerFailure("The credential import fixture did not complete.") }
    }
}
#endif
