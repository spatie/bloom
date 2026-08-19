import Testing
@testable import BloomCore

@Suite("Software updates")
struct SoftwareUpdateTests {
    private let key = "s0kHQ4zCV5GHtI4fZGL6wsWO4Ch224tI6RcgvvfEC2o="

    @Test("updates a build that was stamped, configured and released")
    func configured() {
        #expect(
            SoftwareUpdate.availability(
                feedURL: "https://example.invalid/appcast.xml",
                publicKey: key,
                buildChannel: "release",
                masterCommit: nil
            ) == .configured(feedURL: "https://example.invalid/appcast.xml")
        )
    }

    @Test("never updates a build made from the source tree")
    func localBuildIsLeftAlone() {
        #expect(
            SoftwareUpdate.availability(
                feedURL: "https://example.invalid/appcast.xml",
                publicKey: key,
                buildChannel: "local",
                masterCommit: nil
            ) == .localBuild
        )

        #expect(
            SoftwareUpdate.availability(
                feedURL: "https://example.invalid/appcast.xml",
                publicKey: key,
                buildChannel: nil,
                masterCommit: nil
            ) == .localBuild
        )
    }

    /// The case that costs the most to get wrong: the copy the owner is using all day, built from
    /// a commit rather than from a release, must never be replaced by an older release zip.
    @Test("never updates the copy master.sh installed, whatever else the bundle claims")
    func masterBuildIsLeftAlone() {
        #expect(
            SoftwareUpdate.availability(
                feedURL: "https://example.invalid/appcast.xml",
                publicKey: key,
                buildChannel: "release",
                masterCommit: "e47a3b7"
            ) == .localBuild
        )
    }

    @Test("treats the build script's placeholders as no configuration at all")
    func placeholdersAreNotConfiguration() {
        #expect(
            SoftwareUpdate.availability(
                feedURL: "__BLOOM_UPDATE_FEED_URL__",
                publicKey: "__BLOOM_UPDATE_PUBLIC_KEY__",
                buildChannel: "release",
                masterCommit: nil
            ) == .notConfigured
        )

        #expect(
            SoftwareUpdate.availability(
                feedURL: "https://example.invalid/appcast.xml",
                publicKey: "__BLOOM_UPDATE_PUBLIC_KEY__",
                buildChannel: "release",
                masterCommit: nil
            ) == .notConfigured
        )
    }

    @Test("treats a blank or missing value as no configuration at all")
    func blanksAreNotConfiguration() {
        #expect(
            SoftwareUpdate.availability(
                feedURL: "   ",
                publicKey: key,
                buildChannel: "release",
                masterCommit: nil
            ) == .notConfigured
        )

        #expect(
            SoftwareUpdate.availability(
                feedURL: nil,
                publicKey: nil,
                buildChannel: "release",
                masterCommit: nil
            ) == .notConfigured
        )
    }

    @Test("looks in the background only when nothing is mid turn")
    func backgroundChecksWaitForTheAgents() {
        #expect(SoftwareUpdate.mayCheckInBackground(runningCount: 0))
        #expect(!SoftwareUpdate.mayCheckInBackground(runningCount: 1))
        #expect(!SoftwareUpdate.mayCheckInBackground(runningCount: 5))
    }

    @Test("counts the agents in the heading rather than saying 'some'")
    func headingCountsThem() {
        #expect(SoftwareUpdate.interruptionTitle(runningCount: 1) == "An agent is still running")
        #expect(SoftwareUpdate.interruptionTitle(runningCount: 4) == "4 agents are still running")
    }

    @Test("names the workspaces whose turns would be lost")
    func detailNamesThem() {
        let detail = SoftwareUpdate.interruptionDetail(
            runningCount: 2,
            workspaceNames: ["fix-the-parser", "rename-the-app"]
        )

        #expect(detail.contains("fix-the-parser"))
        #expect(detail.contains("rename-the-app"))
        #expect(detail.contains("restarts Bloom"))
    }

    @Test("caps the list rather than printing forty names")
    func detailCapsTheList() {
        let names = (1...9).map { "workspace-\($0)" }
        let detail = SoftwareUpdate.interruptionDetail(runningCount: 9, workspaceNames: names)

        #expect(detail.contains("workspace-5"))
        #expect(!detail.contains("workspace-6"))
        #expect(detail.contains("and 4 more"))
    }

    @Test("says nothing about workspaces when it has no names")
    func detailSurvivesWithoutNames() {
        let detail = SoftwareUpdate.interruptionDetail(runningCount: 1, workspaceNames: [])

        #expect(!detail.contains("\u{2022}"))
        #expect(detail.contains("cannot be resumed"))
    }

    @Test("checks once a day, which is what the Info.plist also says")
    func checksDaily() {
        #expect(SoftwareUpdate.checkInterval == 86_400)
    }

    @Test("explains itself only when there is nothing to switch on")
    func explainsWhyThereIsNoSwitch() {
        #expect(SoftwareUpdate.unavailableExplanation(.configured(feedURL: "https://example.invalid")) == nil)
        #expect(SoftwareUpdate.unavailableExplanation(.localBuild) != nil)
        #expect(SoftwareUpdate.unavailableExplanation(.notConfigured) != nil)
    }
}
