import Testing
@testable import BloomCore

@Suite("Project menu groups")
struct ProjectMenuGroupTests {
    @Test("visible projects come first and each group is alphabetical regardless of sidebar order")
    func alphabeticalGroups() {
        let repos = [
            Repo(name: "zebra", path: "/zebra", sortOrder: 0, hidden: true),
            Repo(name: "VicGames", path: "/VicGames", sortOrder: 1),
            Repo(name: "alpha", path: "/alpha", sortOrder: 2, hidden: true),
            Repo(name: "bloom", path: "/bloom", sortOrder: 3),
            Repo(name: "runbloom.app", path: "/runbloom.app", sortOrder: 4)
        ]

        let groups = ProjectMenuGroup.grouped(repos)

        #expect(groups.map(\.title) == ["Visible projects", "Hidden projects"])
        #expect(groups.map(\.hidden) == [false, true])
        #expect(groups.map { $0.repos.map(\.id) } == [
            [repos[3].id, repos[4].id, repos[1].id],
            [repos[2].id, repos[0].id]
        ])
    }

    @Test("empty groups have no heading", arguments: [false, true])
    func emptyGroups(hidden: Bool) {
        let repo = Repo(name: "bloom", path: "/bloom", hidden: hidden)
        let groups = ProjectMenuGroup.grouped([repo])

        #expect(groups.map(\.hidden) == [hidden])
        #expect(groups.flatMap(\.repos).map(\.id) == [repo.id])
        #expect(ProjectMenuGroup.grouped([]).isEmpty)
    }
}
