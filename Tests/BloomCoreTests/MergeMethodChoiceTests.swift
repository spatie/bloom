import Testing
import Foundation
@testable import BloomCore

/// The merge split button's decisions, which are all of them except the drawing.
///
/// The control is a view and cannot be tested; which methods it offers, which one is in force,
/// what it promises for each and what a stored choice reads back as are not the view's decisions
/// and are held here.
@Suite("Merge method choice")
struct MergeMethodChoiceTests {
    // MARK: - What is on offer

    @Test("all three of GitHub's methods are offered, in GitHub's order")
    func offersThree() {
        #expect(MergeMethodChoice.offered == [.merge, .squash, .rebase])
    }

    @Test("every offered method can actually be performed")
    func everyMethodIsReal() {
        // The turn names the method twice, once for the reader and once for the command. A method
        // offered in the menu with nothing behind it would be a button that asks an agent to do
        // something the prompt cannot express.
        for method in MergeMethodChoice.offered {
            #expect(!method.phrase.isEmpty)
            #expect(method.flag == "--\(method.rawValue)")
        }
    }

    // MARK: - What the button says

    @Test(
        "the button promises the method in force",
        arguments: [
            (GitHub.MergeMethod.merge, "Merge"),
            (.squash, "Squash and merge"),
            (.rebase, "Rebase and merge"),
        ]
    )
    func buttonLabels(method: GitHub.MergeMethod, label: String) {
        #expect(method.buttonLabel == label)
    }

    @Test("the menu keeps GitHub's own wording, which is not always the button's")
    func menuLabels() {
        // The menu is read beside the web UI the user checks afterwards, so it says what GitHub
        // says. The button is a promise about the next press. Only the plain merge differs.
        #expect(GitHub.MergeMethod.merge.label == "Merge commit")
        #expect(GitHub.MergeMethod.merge.buttonLabel == "Merge")
        #expect(GitHub.MergeMethod.squash.label == GitHub.MergeMethod.squash.buttonLabel)
        #expect(GitHub.MergeMethod.rebase.label == GitHub.MergeMethod.rebase.buttonLabel)
    }

    // MARK: - Reading a stored choice

    @Test("a project nobody has chosen for squashes, as the single button always did")
    func fallsBack() {
        #expect(MergeMethodChoice.resolve(nil) == .squash)
        #expect(MergeMethodChoice.fallback == .squash)
    }

    @Test("a value this version cannot read falls back rather than leaving no method")
    func resolvesRubbish() {
        #expect(MergeMethodChoice.resolve("") == .squash)
        #expect(MergeMethodChoice.resolve("fast-forward") == .squash)
        #expect(MergeMethodChoice.resolve("Squash") == .squash)
    }

    @Test("each method reads back as itself", arguments: MergeMethodChoice.offered)
    func resolvesEach(method: GitHub.MergeMethod) {
        #expect(MergeMethodChoice.resolve(method.rawValue) == method)
    }

    // MARK: - Where it is kept

    @Test("the choice is keyed by project, so two projects cannot share one convention")
    func keyIsPerProject() {
        let one = MergeMethodChoice.key(repoID: RepoID("alpha"))
        let other = MergeMethodChoice.key(repoID: RepoID("beta"))
        #expect(one != other)
        #expect(one == "repo.alpha.mergeMethod")
    }

    @Test("a chosen method survives the app being quit", .tags(.persistence), .scratchDirectory)
    func roundTrips() async throws {
        let store = try makeTestStore("merge-method")
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))

        #expect(await MergeMethodChoice.load(repoID: repo.id, from: store) == .squash)

        await MergeMethodChoice.save(.rebase, repoID: repo.id, to: store)

        #expect(await MergeMethodChoice.load(repoID: repo.id, from: store) == .rebase)
    }

    @Test("choosing for one project leaves every other project alone", .tags(.persistence), .scratchDirectory)
    func scopedToOneProject() async throws {
        let store = try makeTestStore("merge-method")
        let mine = try await store.upsert(Repo(name: "mine", path: TestScratch.unique("mine")))
        let theirs = try await store.upsert(Repo(name: "theirs", path: TestScratch.unique("theirs")))

        await MergeMethodChoice.save(.merge, repoID: mine.id, to: store)

        #expect(await MergeMethodChoice.load(repoID: mine.id, from: store) == .merge)
        #expect(await MergeMethodChoice.load(repoID: theirs.id, from: store) == .squash)
    }

    @Test("a deliberate choice of the fallback is stored rather than left as silence",
          .tags(.persistence), .scratchDirectory)
    func storesTheFallbackToo() async throws {
        let store = try makeTestStore("merge-method")
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))

        await MergeMethodChoice.save(.squash, repoID: repo.id, to: store)

        // Kept whole, so the day the fallback changes, the project that picked squash still
        // squashes. Silence means "never asked" and nothing else.
        #expect(try await store.setting(MergeMethodChoice.key(repoID: repo.id)) == "squash")
    }
}
