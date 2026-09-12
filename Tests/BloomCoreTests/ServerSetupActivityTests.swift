import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerSetupActivityTests {
    @Test func progressCompletesOnlyStagesActuallyStarted() {
        var activity = ServerSetupActivity()
        #expect(ServerSetupActivity.Stage.allCases.allSatisfy { activity.status(of: $0) == .pending })
        activity.begin(browser: true, docker: true, swap: true)
        #expect(activity.status(of: .transfer) == .running)
        #expect(activity.status(of: .verify) == .pending)

        let stages: [(String, ServerSetupActivity.Stage)] = [
            ("verify", .verify), ("dependencies", .dependencies), ("account", .account),
            ("service", .service), ("swap_check", .swap), ("browser_download", .browser), ("docker_dependencies", .docker), ("accounts", .accounts)
        ]
        var previous = ServerSetupActivity.Stage.transfer
        for (step, stage) in stages {
            activity.receive(ServerInstallEvent(event: "progress", step: step, message: "Working on " + step))
            #expect(activity.status(of: previous) == .complete)
            #expect(activity.status(of: stage) == .running)
            #expect(activity.currentMessage == "Working on " + step)
            previous = stage
        }
        activity.finish()
        #expect(ServerSetupActivity.Stage.allCases.allSatisfy { activity.status(of: $0) == .complete })
    }

    @Test func jumpingToAccountsSkipsUnobservedStagesInsteadOfClaimingSuccess() {
        var activity = ServerSetupActivity()
        activity.begin(browser: false)
        #expect(activity.status(of: .browser) == .skipped)
        activity.start(.accounts, message: "Checking accounts")
        #expect(activity.status(of: .transfer) == .complete)
        for stage in [ServerSetupActivity.Stage.verify, .dependencies, .account, .service, .browser] {
            #expect(activity.status(of: stage) == .skipped)
        }
        #expect(activity.status(of: .accounts) == .running)
        activity.finish()
        #expect(activity.status(of: .accounts) == .complete)
        #expect(activity.status(of: .browser) == .skipped)
    }

    @Test func failedBrowserRemainsFailedWhenOptionalSetupContinues() {
        var activity = ServerSetupActivity()
        activity.begin(browser: true)
        activity.start(.browser, message: "Checking Chromium")
        activity.fail()
        #expect(activity.status(of: .browser) == .failed)
        activity.start(.accounts, message: "Checking agent sign-ins")
        activity.finish()
        #expect(activity.status(of: .browser) == .failed)
        #expect(activity.status(of: .accounts) == .complete)
    }

    @Test func finishCannotTurnAFailureIntoSuccessAndRetryResetsTheRun() {
        var activity = ServerSetupActivity()
        activity.begin(browser: true)
        activity.start(.dependencies, message: "Installing development tools")
        activity.fail()
        activity.finish()
        #expect(activity.status(of: .dependencies) == .failed)
        #expect(activity.status(of: .account) == .pending)
        activity.begin(browser: false)
        #expect(activity.status(of: .transfer) == .running)
        #expect(activity.status(of: .dependencies) == .pending)
        #expect(activity.status(of: .browser) == .skipped)
        #expect(activity.lines.count == 1)
        #expect(!activity.output.contains("Installing development tools"))
    }

    @Test func ordinaryOutputDoesNotAdvanceStagesAndBrowserSubstepsStayRunning() {
        var activity = ServerSetupActivity()
        activity.begin(browser: true)
        activity.start(.browser, message: "Preparing browser")
        for step in ["browser_dependencies", "browser_download", "browser_smoke"] {
            activity.receive(ServerInstallEvent(event: "progress", step: step, message: step))
            #expect(activity.status(of: .browser) == .running)
        }
        activity.receive(ServerInstallEvent(event: "output", message: "Downloaded Chromium\nChecking launch"))
        #expect(activity.currentMessage == "browser_smoke")
        #expect(activity.status(of: .browser) == .running)
        #expect(activity.lines.suffix(2).map(\.text) == ["Downloaded Chromium", "Checking launch"])
        activity.receive(ServerInstallEvent(event: "progress", step: "future-step", message: "Additional preparation"))
        #expect(activity.activeStage == .browser)
        #expect(activity.currentMessage == "Additional preparation")
        #expect(activity.status(of: .accounts) == .pending)
    }

    @Test func optionalSwapIsSkippedUnlessSelectedAndFailureSurvivesLaterStages() {
        var activity = ServerSetupActivity()
        activity.begin(browser: false)
        #expect(activity.status(of: .swap) == .skipped)
        activity.begin(browser: false, swap: true)
        #expect(activity.status(of: .swap) == .pending)
        activity.start(.service, message: "Starting server")
        for step in ["swap_check", "swap_create", "swap_activate", "swap_persist"] {
            activity.receive(ServerInstallEvent(event: "progress", step: step, message: step))
            #expect(activity.activeStage == .swap)
            #expect(activity.status(of: .swap) == .running)
        }
        #expect(activity.status(of: .service) == .complete)
        activity.fail(message: "Swap could not be enabled")
        activity.start(.accounts, message: "Checking accounts")
        activity.finish()
        #expect(activity.status(of: .swap) == .failed)
        #expect(activity.status(of: .accounts) == .complete)
    }

    @Test func optionalDockerFailureSurvivesAccountChecksAndCanBeRetried() {
        var activity = ServerSetupActivity()
        activity.begin(browser: false)
        #expect(activity.status(of: .docker) == .skipped)
        for step in ["docker_dependencies", "docker_account", "docker_service", "docker_verify"] {
            activity.receive(ServerInstallEvent(event: "progress", step: step, message: step))
            #expect(activity.activeStage == .docker)
            #expect(activity.status(of: .docker) == .running)
        }
        activity.fail(message: "Rootless daemon did not start")
        activity.start(.accounts, message: "Checking accounts")
        activity.finish()
        #expect(activity.status(of: .docker) == .failed)
        activity.start(.docker, message: "Retrying Docker")
        activity.finish()
        #expect(activity.status(of: .docker) == .complete)
    }

    @Test func lineEvictionKeepsRecentOutputAndNeverReusesIDs() throws {
        var activity = ServerSetupActivity()
        for index in 0..<1005 { activity.append("Output \(index)") }
        #expect(activity.lines.count == 1000)
        #expect(activity.lines.first?.text == "Output 5")
        #expect(activity.lines.last?.text == "Output 1004")
        let lastID = try #require(activity.lines.last?.id)
        activity.append("Latest output")
        #expect(activity.lines.count == 1000)
        #expect(activity.lines.last?.id == lastID + 1)
        #expect(Set(activity.lines.map(\.id)).count == activity.lines.count)
        #expect(zip(activity.lines, activity.lines.dropFirst()).allSatisfy { $0.id < $1.id })
    }

    @Test func byteLimitIncludesSeparatorsAndHandlesMultibyteOutput() throws {
        var activity = ServerSetupActivity()
        let line = String(repeating: "🧪", count: 4096)
        for _ in 0..<25 { activity.append(line) }
        #expect(!activity.lines.isEmpty)
        #expect(activity.output.utf8.count <= 256 * 1024)
        #expect(activity.lines.count <= 1000)
        #expect(activity.lines.allSatisfy { $0.text == line })
        let lastID = try #require(activity.lines.last?.id)
        activity.append("Final check")
        #expect(activity.lines.last?.id == lastID + 1)
        #expect(activity.output.utf8.count <= 256 * 1024)
    }
}
