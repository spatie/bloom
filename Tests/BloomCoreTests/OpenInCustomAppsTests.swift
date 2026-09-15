import Testing
import Foundation
@testable import BloomCore

/// The applications a user adds to the "Open in" menus themselves, and how they join the
/// catalogue. Both halves are pure over a defaults suite of their own, so they are pinned here
/// rather than judged from one Mac's Applications folder.
@Suite("Open in, the user's own applications")
struct OpenInCustomAppsTests {
    private func customApps() -> OpenInCustomApps {
        // A suite of its own, never the app's own domain, so a test run cannot change what the
        // menu does in the copy of Bloom the user is running.
        let name = "bloom.tests.openIn.custom.\(UUID().uuidString)"
        return OpenInCustomApps(defaults: UserDefaults(suiteName: name)!)
    }

    private let smartGit = ExternalApp(bundleID: "com.syntevo.smartgit", name: "SmartGit", targets: .folder)
    private let helix = ExternalApp(bundleID: "com.helix-editor.Helix", name: "Helix", targets: .both)

    @Test("nothing has been added yet")
    func nothingAdded() {
        #expect(customApps().apps.isEmpty)
    }

    @Test("an application added is read back, in the order it was added")
    func addedApplicationsAreReadBack() {
        let custom = customApps()

        #expect(custom.add(smartGit) == nil)
        #expect(custom.add(helix) == nil)

        #expect(custom.apps == [smartGit, helix])
    }

    @Test("what an application is offered for survives the round trip")
    func targetsSurviveStorage() {
        let custom = customApps()

        custom.add(smartGit)
        custom.add(helix)

        #expect(custom.apps.first { $0.bundleID == smartGit.bundleID }?.targets == .folder)
        #expect(custom.apps.first { $0.bundleID == helix.bundleID }?.targets == .both)
    }

    @Test("an application already in the catalogue is refused, by the name the catalogue gives it")
    func aCatalogueEntryIsRefused() {
        let custom = customApps()

        let gitKraken = ExternalApp(bundleID: "com.axosoft.gitkraken", name: "Git Kraken", targets: .folder)
        #expect(custom.add(gitKraken) == .alreadyInCatalogue(name: "GitKraken"))
        // A variant the catalogue owns is the same refusal: the menu would draw PhpStorm twice.
        let phpStorm = ExternalApp(bundleID: "com.jetbrains.PhpStormLight-EAP", name: "PhpStorm", targets: .both)
        #expect(custom.add(phpStorm) == .alreadyInCatalogue(name: "PhpStorm"))

        #expect(custom.apps.isEmpty)
    }

    @Test("adding the same application twice is refused, whatever case its identifier arrives in")
    func aSecondAddIsRefused() {
        let custom = customApps()

        custom.add(smartGit)
        let again = ExternalApp(bundleID: "com.syntevo.SmartGit", name: "SmartGit", targets: .both)

        #expect(custom.add(again) == .alreadyAdded)
        #expect(custom.apps == [smartGit])
    }

    @Test("removing one leaves the others where they were")
    func removingKeepsTheRest() {
        let custom = customApps()
        custom.add(smartGit)
        custom.add(helix)

        custom.remove(bundleID: "COM.SYNTEVO.SMARTGIT")

        #expect(custom.apps == [helix])
    }

    @Test("changing what an application is offered for keeps its place in the list")
    func changingTargetsKeepsThePlace() {
        let custom = customApps()
        custom.add(smartGit)
        custom.add(helix)

        custom.setTargets(.folder, forBundleID: helix.bundleID)

        #expect(custom.apps.map(\.bundleID) == [smartGit.bundleID, helix.bundleID])
        #expect(custom.apps.last?.targets == .folder)
        #expect(custom.apps.last?.name == "Helix")
    }

    @Test("an unreadable value reads as nothing added rather than failing")
    func corruptStorageReadsAsEmpty() {
        let name = "bloom.tests.openIn.custom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(Data("not json".utf8), forKey: OpenInCustomApps.key)

        #expect(OpenInCustomApps(defaults: defaults).apps.isEmpty)
    }

    // MARK: - Joining the catalogue

    @Test("additions come after the catalogue, in the order they were added")
    func additionsFollowTheCatalogue() {
        let merged = EditorCatalog.catalogue(adding: [smartGit, helix])

        #expect(Array(merged.prefix(EditorCatalog.known.count)) == EditorCatalog.known)
        #expect(Array(merged.suffix(2)) == [smartGit, helix])
    }

    @Test("an addition the catalogue has since learnt about is not drawn twice")
    func aCatalogueEntryIsNotDuplicated() {
        // The shape of a list written before GitKraken was built in: the catalogue's entry wins,
        // because it is the one carrying the variant identifiers and the file name.
        let stale = ExternalApp(bundleID: "com.axosoft.gitkraken", name: "Git Kraken", targets: .both)
        let variant = ExternalApp(bundleID: "com.jetbrains.PhpStorm-EAP", name: "PhpStorm EAP", targets: .both)

        let merged = EditorCatalog.catalogue(adding: [stale, variant, smartGit])

        #expect(merged.count == EditorCatalog.known.count + 1)
        #expect(merged.filter { $0.name.lowercased().contains("kraken") }.map(\.name) == ["GitKraken"])
        #expect(merged.last == smartGit)
    }

    @Test("the merged list is what decides whether the system default is already offered")
    func knownReachesAdditions() {
        let merged = EditorCatalog.catalogue(adding: [helix])

        #expect(EditorCatalog.isKnown(bundleID: "com.helix-editor.helix", in: merged))
        #expect(!EditorCatalog.isKnown(bundleID: "com.helix-editor.helix"))
    }

    @Test("the system default keeps its file row unless an addition already offers files")
    func systemDefaultRow() {
        // Helix is offered files, so its file row is already there. SmartGit is folders only, and
        // being added must not take away the row it had as the default for a file type.
        #expect(!EditorCatalog.needsSystemDefaultRow(bundleID: "com.helix-editor.Helix", adding: [helix, smartGit]))
        #expect(EditorCatalog.needsSystemDefaultRow(bundleID: "com.syntevo.smartgit", adding: [helix, smartGit]))
        #expect(!EditorCatalog.needsSystemDefaultRow(bundleID: "com.jetbrains.PhpStormLight-EAP", adding: []))
        #expect(EditorCatalog.needsSystemDefaultRow(bundleID: "com.example.SomeEditor", adding: []))
    }

    @Test("the file name on disk survives the round trip")
    func fileNameSurvivesStorage() {
        let custom = customApps()
        let renamed = ExternalApp(
            bundleID: "com.example.Thing", name: "Thing", targets: .both, fileName: "Thing Beta.app"
        )

        custom.add(renamed)

        #expect(custom.apps.first?.fileName == "Thing Beta.app")
    }

    @Test("GitKraken is a git client, so it wants the repository and not a file out of it")
    func gitKrakenIsFolderOnly() {
        let gitKraken = EditorCatalog.known.first { $0.bundleID == "com.axosoft.gitkraken" }

        #expect(gitKraken?.name == "GitKraken")
        #expect(gitKraken?.opens(.folder) == true)
        #expect(gitKraken?.opens(.file) == false)
        #expect(gitKraken?.fileName == "GitKraken.app")
    }
}
