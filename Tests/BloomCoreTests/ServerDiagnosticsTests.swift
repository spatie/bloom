import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerDiagnosticsTests {
    @Test func githubReadyMeansAuthenticationWasChecked() {
        let check = ServerDiagnosticsCollector.tool(.github, "GitHub", true, required: false, missing: "Missing", failed: "Failed")
        #expect(check.status == .ready)
        #expect(check.detail == "Signed in to GitHub as the server account.")
    }

    @Test func optionalToolsAreNotRequiredForPlainProjects() async {
        let report = await ServerDiagnosticsCollector.collect(directory: NSTemporaryDirectory()) { name, _ in
            switch name {
            case "git", "tmux": true
            default: nil
            }
        }
        #expect(report.checks.first { $0.id == .git }?.status == .ready)
        #expect(report.checks.first { $0.id == .docker }?.status == .unavailable)
        #expect(report.checks.first { $0.id == .github }?.status == .unavailable)
    }

    @Test func missingRequiredToolsAndBrokenOptionalToolsNeedAttention() {
        let missing = ServerDiagnosticsCollector.tool(.git, "Git", nil, required: true, missing: "Install Git", failed: "Cannot run")
        let broken = ServerDiagnosticsCollector.tool(.docker, "Docker", false, required: false, missing: "Optional", failed: "Check daemon")
        #expect(missing.status == .attention)
        #expect(broken.status == .attention)
        #expect(broken.detail == "Check daemon")
    }

    @Test func lowResourcesProduceSpecificAdviceWithoutRecommendingPrivilegesForAgents() {
        let checks = ServerDiagnosticsCollector.linuxResources(memory: "MemTotal: 2000000 kB\nMemAvailable: 100000 kB\nSwapFree: 500000 kB\n", watches: "14411\n")
        #expect(checks.allSatisfy { $0.status == .attention })
        #expect(checks[0].detail.contains("97 MiB available"))
        #expect(checks[1].detail.contains("administrator"))
        #expect(ServerDiagnosticsCollector.disk(freeBytes: 1_024).status == .attention)
        #expect(ServerDiagnosticsCollector.disk(freeBytes: nil).status == .unavailable)
    }

    @Test func invalidMemoryIsUnavailableInsteadOfHealthyOrOverflowing() {
        for value in ["", "MemTotal: -1 kB\nMemAvailable: 999 kB", "MemTotal: 100 kB\nMemAvailable: 999 kB", "MemTotal: 100 bytes\nMemAvailable: 50 bytes"] {
            let checks = ServerDiagnosticsCollector.linuxResources(memory: value, watches: "invalid")
            #expect(checks.count == 1)
            #expect(checks[0].status == .unavailable)
        }
    }

    @Test func wireRoundTripIsReadOnly() async throws {
        let request = ServerRequest(.diagnostics)
        #expect(!request.operation.mutates)
        #expect(try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(request)) == request)
        let report = await ServerDiagnosticsCollector.collect(directory: NSTemporaryDirectory()) { _, _ in true }
        let encoded = try JSONEncoder().encode(ServerReply(id: request.id, result: .diagnostics(report)))
        let reply = try JSONDecoder().decode(ServerReply.self, from: encoded)
        guard case .diagnostics(let received) = reply.result else { Issue.record("Missing report"); return }
        #expect(received == report)
    }
}
