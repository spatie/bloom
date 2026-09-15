import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerUninstallPlanTests {
    private func check(existing: Bool = true, privilege: String = "root", home: String? = "/home/bloom") -> ServerInstallCheck {
        ServerInstallCheck(installedVersion: nil, installedPackageSHA256: nil, maintenanceManagement: true,
                           installationRoot: home.map { $0 + "/bloom/server" }, serviceHome: home, memoryBytes: nil,
                           activeSwapBytes: nil, configuredSwap: nil, platform: "Ubuntu 24.04", architecture: "x86_64",
                           privilege: privilege, existing: existing, blockers: [], warnings: [],
                           executable: "/home/bloom/bloom/server/current/bin/bloom-server",
                           dataDirectory: "/home/bloom/bloom/data", serviceUser: "bloom")
    }

    @Test func keepingDataSaysTheAccountAndItsProjectsStay() {
        let plan = ServerUninstallPlan(check: check(), deletesData: false)
        #expect(plan.kept.contains { $0.title.contains("account and its data") && $0.detail.contains("/home/bloom") })
        #expect(!plan.removed.contains { $0.title.contains("all of its data") })
        #expect(plan.removed.map(\.title).contains("Bloom Server"))
        #expect(plan.removed.map(\.title).contains("Maintenance service"))
        #expect(plan.confirmationButton == "Uninstall")
        #expect(plan.confirmationMessage.contains("keeps your projects"))
    }

    @Test func deletingDataNamesEverythingLostAndNeverClaimsTheAccountIsKept() {
        let plan = ServerUninstallPlan(check: check(), deletesData: true)
        let deleted = plan.removed.first { $0.title.contains("all of its data") }
        #expect(deleted?.detail.contains("repositories") == true)
        #expect(deleted?.detail.contains("sign-ins") == true)
        #expect(deleted?.detail.contains("can’t be undone") == true)
        #expect(!plan.kept.contains { $0.title.contains("account") })
        #expect(plan.confirmationButton == "Uninstall and Delete Data")
        #expect(plan.confirmationTitle(server: "Development").contains("delete all data"))
    }

    @Test(arguments: [false, true])
    func sharedPackagesAreAlwaysListedAsKept(deletesData: Bool) {
        let shared = ServerUninstallPlan(check: check(), deletesData: deletesData).kept.first { $0.title == "Shared software" }
        #expect(shared?.detail.contains("Git") == true)
        #expect(shared?.detail.contains("Docker") == true)
    }

    @Test func installerArgumentsAreFixedFlags() {
        #expect(ServerUninstallPlan.installerArguments(deletesData: false, force: false) == ["--uninstall"])
        #expect(ServerUninstallPlan.installerArguments(deletesData: true, force: true) == ["--uninstall", "--delete-data", "--force"])
        let command = ServerSetupConnection.uninstallCommand(deletesData: true, force: false)
        #expect(command.contains("sudo -n 'python3' '-' '--uninstall' '--delete-data'"))
        #expect(!command.contains("--force"))
    }

    @Test func uninstallNeedsAnExistingInstallationAndAdministratorAccess() {
        #expect(ServerUninstallPlan.canUninstall(check()))
        #expect(!ServerUninstallPlan.canUninstall(check(existing: false)))
        #expect(!ServerUninstallPlan.canUninstall(check(privilege: "none")))
    }

    @Test(arguments: [("server_busy", true), ("maintenance_busy", true), ("database_unavailable", true),
                      ("unmanaged_server", false), ("untrusted_maintenance", false), ("installation_conflict", false)])
    func onlyBusyRefusalsCanBeForced(code: String, forceable: Bool) {
        #expect(ServerUninstallPlan.canForce(afterFailure: code) == forceable)
    }

    @Test func outcomeComesOnlyFromACompletionWithLists() throws {
        let line = #"{"event":"complete","unchanged":false,"removed":["Bloom Server service"],"kept":["Shared"],"deletedData":false,"message":"Bloom Server was removed."}"#
        let event = try JSONDecoder().decode(ServerInstallEvent.self, from: Data(line.utf8))
        let outcome = try #require(ServerUninstallOutcome(event: event))
        #expect(outcome.removed == ["Bloom Server service"])
        #expect(outcome.title == "Bloom Server uninstalled")
        #expect(ServerUninstallOutcome(event: ServerInstallEvent(event: "complete", message: "Started")) == nil)
        #expect(ServerUninstallOutcome(event: ServerInstallEvent(event: "error", message: "Busy")) == nil)
        let nothing = ServerUninstallOutcome(unchanged: true, removed: [], kept: [], deletedData: false, message: "")
        #expect(nothing.title == "Nothing to uninstall")
    }

    @Test func summaryUsesTheInstallationPathsAndDefaultsToTheManagedLayout() {
        let fallback = ServerInstallationSummary()
        #expect(fallback.data.location == "/home/bloom/bloom")
        #expect(fallback.locationDetails.contains("/home/bloom/bloom/data"))
        let custom = ServerInstallationSummary(serviceUser: "agents", serviceHome: "/srv/agents", installationRoot: nil, dataDirectory: "/srv/data")
        #expect(custom.account.title == "A separate agents account")
        #expect(custom.locationDetails.contains("Bloom Server program: /srv/agents/bloom/server"))
        #expect(custom.locationDetails.contains("Server database: /srv/data"))
        #expect(ServerInstallationSummary.OptionalPart.docker.details(serviceHome: "/srv/agents").contains("/srv/agents/bloom/docker/data"))
    }

    @Test func savedConnectionRecoversTheManagedLayout() {
        let managed = ServerInstallationSummary(connectionHost: "bloom@203.0.113.10",
            executable: "/home/bloom/bloom/server/current/bin/bloom-server", dataDirectory: "/home/bloom/bloom/data")
        #expect(managed.serviceUser == "bloom")
        #expect(managed.serviceHome == "/home/bloom")
        #expect(managed.installationRoot == "/home/bloom/bloom/server")
        let https = ServerInstallationSummary(connectionHost: "", executable: "", dataDirectory: "")
        #expect(https.serviceUser == "bloom")
        #expect(https.dataDirectory == "/home/bloom/bloom/data")
        let custom = ServerInstallationSummary(connectionHost: "alias", executable: "/opt/bloom-server", dataDirectory: "/srv/data")
        #expect(custom.serviceUser == "bloom")
        #expect(custom.dataDirectory == "/srv/data")
    }

    @Test func requirementsNameTheSupportedSystemBeforeTheCheckRuns() {
        #expect(ServerInstallationSummary.supportedSystem.contains("24.04"))
        #expect(ServerInstallationSummary.supportedSystem.contains("26.04"))
        #expect(ServerInstallationSummary.supportedSystem.contains("x86_64"))
        #expect(ServerInstallationSummary.administratorAccess.contains("sudo"))
    }

    /// Copy is read by testers with no documentation beside it, so the jargon this replaced stays out.
    @Test func copyAvoidsUnexplainedJargonAndDashes() {
        let summary = ServerInstallationSummary()
        var copy = summary.rows.flatMap { [$0.title, $0.detail] } + ServerInstallationSummary.limits.map(\.detail)
        copy += ServerInstallationSummary.OptionalPart.allCases.flatMap { [$0.title, $0.summary, $0.details()] }
        for deletesData in [false, true] {
            let plan = ServerUninstallPlan(check: check(), deletesData: deletesData)
            copy += (plan.removed + plan.kept).flatMap { [$0.title, $0.detail] } + [plan.confirmationMessage]
        }
        copy += [ServerUninstallPlan.forceMessage, ServerInstallationSummary.addressHint]
        for text in copy {
            for banned in ["\u{2014}", "\u{2013}", "systemd", "AppArmor", "rootless", "root-owned"] {
                #expect(!text.contains(banned), "\(banned) in: \(text)")
            }
        }
    }
}
