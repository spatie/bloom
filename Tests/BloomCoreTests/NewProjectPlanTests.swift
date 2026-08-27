import Testing
import Foundation
@testable import BloomCore

/// Where a new project is offered, what it will be called, and the path those two make.
///
/// The location one is the reason this suite exists: it reads the owner's own disk layout, so
/// "does it suggest the right folder" is a question that cannot be answered by opening the sheet
/// on the machine it was written on, where every answer looks right.
@Suite("New project location and name")
struct NewProjectPlanTests {
    private let home = "/Users/tester"

    @Test("the commonest parent of the projects already added wins")
    func commonestParent() {
        let suggestion = NewProjectPlan.suggestedLocation(
            projectPaths: [
                "/Users/tester/dev/code/bloom",
                "/Users/tester/scratch/spike",
                "/Users/tester/dev/code/mailcoach",
                "/Users/tester/dev/code/flare",
            ],
            home: home
        )
        #expect(suggestion == "/Users/tester/dev/code")
    }

    /// Two folders holding one project each must not make the suggestion wander between them from
    /// one open of the sheet to the next.
    @Test("a tie goes to the first one, so the answer does not move about")
    func stableTie() {
        let paths = ["/Users/tester/one/a", "/Users/tester/two/b"]
        #expect(NewProjectPlan.suggestedLocation(projectPaths: paths, home: home) == "/Users/tester/one")
        #expect(NewProjectPlan.suggestedLocation(projectPaths: paths, home: home) == "/Users/tester/one")
    }

    @Test("with no projects at all it is ~/Developer")
    func fallback() {
        #expect(NewProjectPlan.suggestedLocation(projectPaths: [], home: home) == "/Users/tester/Developer")
    }

    /// A repository directly under the volume root is somebody's unusual choice, never the folder
    /// they keep projects in, and suggesting `/` would be suggesting a location every refusal in
    /// the file then turns down.
    @Test("a project at the volume root does not become the suggestion")
    func volumeRootIsNotAParent() {
        let suggestion = NewProjectPlan.suggestedLocation(
            projectPaths: ["/thing", "/Users/tester/dev/one"], home: home
        )
        #expect(suggestion == "/Users/tester/dev")
    }

    @Test("a name is trimmed and otherwise left exactly as it was typed")
    func nameIsNotSanitised() {
        #expect(NewProjectPlan.folderName(from: "  sparkline  ") == "sparkline")
        // A folder on this Mac takes both of these, and rewriting them would name the folder
        // something the person did not type.
        #expect(NewProjectPlan.folderName(from: "My App") == "My App")
        #expect(NewProjectPlan.folderName(from: "sparkline 2.0") == "sparkline 2.0")
    }

    @Test("the target is the location and the name, with the tilde expanded")
    func target() {
        #expect(
            NewProjectPlan.target(name: "sparkline", location: "~/Developer", home: home)
                == "/Users/tester/Developer/sparkline"
        )
        #expect(
            NewProjectPlan.target(name: " sparkline ", location: "/opt/work/", home: home)
                == "/opt/work/sparkline"
        )
        #expect(NewProjectPlan.target(name: "", location: "~/Developer", home: home) == nil)
        #expect(NewProjectPlan.target(name: "sparkline", location: "", home: home) == nil)
        #expect(NewProjectPlan.target(name: "sparkline", location: "Developer", home: home) == nil)
    }

    @Test("a path under the home directory is shown with a tilde")
    func display() {
        #expect(NewProjectPlan.display("/Users/tester/Developer/x", home: home) == "~/Developer/x")
        #expect(NewProjectPlan.display("/Users/tester", home: home) == "~")
        #expect(NewProjectPlan.display("/opt/work/x", home: home) == "/opt/work/x")
        // Not a prefix match on the string: another account whose name starts with the same
        // letters is not inside this one's home.
        #expect(NewProjectPlan.display("/Users/tester2/x", home: home) == "/Users/tester2/x")
    }
}

/// What pressing Create Project would do, and what it says when it will not.
@Suite("New project verdict")
struct NewProjectVerdictTests {
    private let home = "/Users/tester"

    private func facts(
        name: String = "sparkline",
        location: String = "~/Developer",
        path: String = "/Users/tester/Developer/sparkline",
        locationExists: Bool = true,
        targetExists: Bool = false,
        targetIsDirectory: Bool = false,
        targetIsEmpty: Bool = false,
        targetIsRepository: Bool = false,
        enclosing: String? = nil,
        ancestor: String = "/Users/tester/Developer",
        isAncestorWritable: Bool = true,
        isTargetWritable: Bool = true
    ) -> NewProjectFacts {
        NewProjectFacts(
            name: name,
            location: location,
            path: path,
            locationExists: locationExists,
            targetExists: targetExists,
            targetIsDirectory: targetIsDirectory,
            targetIsEmpty: targetIsEmpty,
            targetIsRepository: targetIsRepository,
            enclosingRepository: enclosing,
            nearestExistingAncestor: ancestor,
            isAncestorWritable: isAncestorWritable,
            isTargetWritable: isTargetWritable,
            homeDirectory: home,
            workspacesRoot: "/Users/tester/bloom/workspaces"
        )
    }

    @Test("a path with nothing at it is created")
    func creates() {
        #expect(NewProjectVerdict.of(facts()) == .create(makesLocation: false))
    }

    /// The first run, and the line the design note is written around.
    @Test("a location that is not there either is said out loud, and both are made")
    func createsBoth() {
        let verdict = NewProjectVerdict.of(facts(locationExists: false, ancestor: "/Users/tester"))
        #expect(verdict == .create(makesLocation: true))
        #expect(
            verdict.hint(path: "/Users/tester/Developer/sparkline", home: home)
                == "~/Developer/sparkline. Bloom will create both."
        )
    }

    @Test("a folder that is there and empty is adopted rather than refused")
    func adoptsAnEmptyFolder() {
        let verdict = NewProjectVerdict.of(
            facts(targetExists: true, targetIsDirectory: true, targetIsEmpty: true)
        )
        #expect(verdict == .adopt)
        #expect(verdict.allowsCreation)
        #expect(verdict.hint(path: "/Users/tester/Developer/sparkline", home: home)
            .contains("already there and empty"))
    }

    /// A folder that is there and cannot be written to is refused on its own permissions rather
    /// than its parent's, because nothing is being made above it.
    @Test("an existing folder Bloom cannot write to is refused, and names itself")
    func refusesAnUnwritableFolder() {
        let verdict = NewProjectVerdict.of(
            facts(
                targetExists: true, targetIsDirectory: true, targetIsEmpty: true,
                isTargetWritable: false
            )
        )
        #expect(verdict == .refuse(.notWritable("~/Developer/sparkline")))
    }

    /// The two refusals that retired when the two doors became one. Neither was about the disk:
    /// both ended by telling the person to close the window and come in through the other door,
    /// and there is one door now. A repository is `ProjectTargetVerdict.add` and a folder with
    /// files in it is `.track`, which is `ProjectTargetTests`' business rather than this rule's.
    @Test("an existing repository and a folder with files in it are no longer this rule's to judge")
    func theTwoRedirectionsAreGone() {
        // Asked outside its contract, this rule answers about the folder being there and says
        // nothing about what is in it. `ProjectTargetVerdict` is what stops it being asked.
        #expect(
            NewProjectVerdict.of(
                facts(targetExists: true, targetIsDirectory: true, targetIsRepository: true)
            ) == .adopt
        )
        for refusal in [NewProjectRefusal.somethingThere("~/x"), .insideRepository("~/y")] {
            #expect(!refusal.sentence.contains("add that folder as a project"), "\(refusal)")
        }
    }

    @Test("a file in the way is refused")
    func refusesAFile() {
        let verdict = NewProjectVerdict.of(facts(targetExists: true, targetIsDirectory: false))
        #expect(verdict == .refuse(.somethingThere("~/Developer/sparkline")))
    }

    @Test("a location inside another repository is refused, and names it")
    func refusesNesting() {
        let verdict = NewProjectVerdict.of(facts(enclosing: "/Users/tester/dev/outer"))
        #expect(verdict == .refuse(.insideRepository("~/dev/outer")))
        guard case .refuse(let refusal) = verdict else { return }
        #expect(refusal.sentence.contains("~/dev/outer"))
        // The one refusal with somewhere to go, offered as a button that writes the repository
        // into the field. The same accessor `FolderRefusal` has, for the same case.
        #expect(refusal.alternative == "~/dev/outer")
        #expect(NewProjectRefusal.noName.alternative == nil)
    }

    @Test("Bloom's own worktree folder is refused")
    func refusesTheWorkspacesRoot() {
        let verdict = NewProjectVerdict.of(
            facts(location: "~/bloom/workspaces", path: "/Users/tester/bloom/workspaces/sparkline")
        )
        #expect(verdict == .refuse(.insideBloomsWorkspaces("~/bloom/workspaces/sparkline")))
    }

    @Test("the folders macOS and the Finder own are refused", arguments: [
        "/Users/tester/Desktop",
        "/Users/tester/Documents",
        "/Library/Preferences",
        "/Users/tester",
    ])
    func refusesReserved(path: String) {
        let verdict = NewProjectVerdict.of(facts(path: path))
        guard case .refuse(.reservedLocation) = verdict else {
            Issue.record("\(path) was not refused: \(verdict)")
            return
        }
    }

    /// A project one level inside Documents is the owner's own filing and none of Bloom's
    /// business. Only the standard folder itself is refused.
    @Test("a folder inside one of them is still allowed")
    func allowsInsideAStandardFolder() {
        #expect(
            NewProjectVerdict.of(facts(path: "/Users/tester/Documents/notes"))
                == .create(makesLocation: false)
        )
    }

    @Test("a location that cannot be written to names the folder that refused")
    func refusesUnwritable() {
        let verdict = NewProjectVerdict.of(facts(ancestor: "/opt", isAncestorWritable: false))
        #expect(verdict == .refuse(.notWritable("/opt")))
    }

    @Test("a name that is empty, a path or hidden is refused before anything else")
    func refusesTheName() {
        #expect(NewProjectVerdict.of(facts(name: "   ")) == .refuse(.noName))
        #expect(NewProjectVerdict.of(facts(name: "dev/sparkline")) == .refuse(.nameHasSeparator("dev/sparkline")))
        #expect(NewProjectVerdict.of(facts(name: "a:b")) == .refuse(.nameHasSeparator("a:b")))
        #expect(NewProjectVerdict.of(facts(name: ".hidden")) == .refuse(.nameIsHidden(".hidden")))
        #expect(NewProjectVerdict.of(facts(name: "..")) == .refuse(.nameIsHidden("..")))
    }

    @Test("no location, and one that is not a full path, are told apart")
    func refusesTheLocation() {
        #expect(NewProjectVerdict.of(facts(location: "  ", path: "")) == .refuse(.noLocation))
        #expect(
            NewProjectVerdict.of(facts(location: "Developer", path: ""))
                == .refuse(.locationNotAbsolute("Developer"))
        )
    }

    /// Every refusal is read under a text field while somebody is typing, so every one of them has
    /// to be a sentence rather than a fault code.
    @Test("every refusal says something, ending in a full stop")
    func everyRefusalSpeaks() {
        let all: [NewProjectRefusal] = [
            .noName, .nameHasSeparator("a/b"), .nameIsHidden(".x"), .noLocation,
            .locationNotAbsolute("dev"), .somethingThere("~/x"),
            .insideRepository("~/y"), .insideBloomsWorkspaces("~/z"),
            .reservedLocation("~/Desktop"), .notWritable("/opt"),
        ]
        for refusal in all {
            #expect(!refusal.sentence.isEmpty, "\(refusal)")
            #expect(refusal.sentence.hasSuffix("."), "\(refusal)")
        }
    }
}
