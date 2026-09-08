import Testing
import Foundation
@testable import BloomCore

/// The "Open in" menu is two decisions: which applications belong in it at all, and what order
/// they are in. Both are pure, so both are pinned here rather than judged from a screenshot of one
/// developer's Applications folder.
@Suite("Editor catalogue")
struct EditorCatalogTests {
    @Test("only what is installed is offered")
    func onlyInstalledApps() {
        let installed: Set<String> = ["dev.zed.Zed", "com.apple.Terminal"]

        let apps = EditorCatalog.installed { installed.contains($0) }

        #expect(apps.map(\.bundleID) == ["dev.zed.Zed", "com.apple.Terminal"])
    }

    @Test("the catalogue's own order is kept, whatever order the lookups happen in")
    func theOrderIsTheCatalogues() {
        let installed: Set<String> = ["com.apple.Terminal", "com.apple.dt.Xcode", "com.microsoft.VSCode"]

        let apps = EditorCatalog.installed { installed.contains($0) }

        // Editors before terminals, in the order the catalogue lists them.
        #expect(apps.map(\.name) == ["Visual Studio Code", "Xcode", "Terminal"])
    }

    @Test("a terminal is not offered a single file")
    func aTerminalOpensFoldersOnly() {
        let apps = EditorCatalog.installed { _ in true }

        let forFiles = EditorCatalog.opening(.file, from: apps).map(\.bundleID)
        let forFolders = EditorCatalog.opening(.folder, from: apps).map(\.bundleID)

        #expect(!forFiles.contains("com.mitchellh.ghostty"))
        #expect(forFolders.contains("com.mitchellh.ghostty"))
        // An editor is offered both, because both are things it does.
        #expect(forFiles.contains("dev.zed.Zed"))
        #expect(forFolders.contains("dev.zed.Zed"))
    }

    @Test("a git client wants the repository, not a file out of it")
    func aGitClientOpensFoldersOnly() {
        let apps = EditorCatalog.installed { _ in true }

        #expect(!EditorCatalog.opening(.file, from: apps).contains { $0.bundleID == "com.github.GitHubClient" })
        #expect(EditorCatalog.opening(.folder, from: apps).contains { $0.bundleID == "com.github.GitHubClient" })
    }

    @Test("every entry can open something")
    func noEntryIsUseless() {
        #expect(EditorCatalog.known.allSatisfy { !$0.targets.isEmpty })
    }

    @Test("a bundle's file name is its name, except where it is not")
    func fileNamesAreDerivedButOverridable() {
        func app(_ id: String) -> ExternalApp? { EditorCatalog.known.first { $0.bundleID == id } }

        // The fallback for the case LaunchServices does not answer. See `EditorCatalog`.
        #expect(app("com.apple.dt.Xcode")?.fileName == "Xcode.app")
        #expect(app("com.microsoft.VSCode")?.fileName == "Visual Studio Code.app")
        // The one whose bundle is not called what the menu calls it.
        #expect(app("com.microsoft.VSCodeInsiders")?.fileName == "Visual Studio Code - Insiders.app")
        #expect(EditorCatalog.known.allSatisfy { $0.fileName.hasSuffix(".app") })
    }

    @Test("no bundle id is listed twice")
    func idsAreUnique() {
        #expect(EditorCatalog.knownIDs.count == EditorCatalog.known.count)
    }

    // MARK: - The identifiers an application actually ships under
    //
    // Reported as "opening a file in PhpStorm does not work", and measured on the reporter's Mac:
    // `/Applications/PhpStorm.app` is `com.jetbrains.PhpStormLight-EAP`, and the catalogue held
    // `com.jetbrains.PhpStorm` and nothing else. LaunchServices answered nothing for the id it was
    // asked for, the folder sweep found the bundle and threw it away for having the wrong id, and
    // PhpStorm was in no "Open in" menu at all on a Mac running PhpStorm.

    @Test("the PhpStorm that is actually installed is PhpStorm")
    func aLightEAPBuildIsTheSameApplication() {
        let phpStorm = EditorCatalog.known.first { $0.bundleID == "com.jetbrains.PhpStorm" }

        // The exact identifier measured on the machine the report came from.
        #expect(phpStorm?.matches(bundleID: "com.jetbrains.PhpStormLight-EAP") == true)
        #expect(phpStorm?.matches(bundleID: "com.jetbrains.PhpStorm-EAP") == true)
        #expect(phpStorm?.matches(bundleID: "com.jetbrains.PhpStormLight") == true)
        #expect(phpStorm?.matches(bundleID: "com.jetbrains.PhpStorm") == true)
        // And a suffix nobody has typed here yet, which is the point of the family rule.
        #expect(phpStorm?.matches(bundleID: "com.jetbrains.PhpStorm-Nightly-2027") == true)
    }

    @Test("a bundle that could not be read is nobody's")
    func anUnreadableBundleMatchesNothing() {
        let phpStorm = EditorCatalog.known.first { $0.bundleID == "com.jetbrains.PhpStorm" }

        #expect(phpStorm?.matches(bundleID: nil) == false)
        #expect(phpStorm?.matches(bundleID: "com.jetbrains.WebStorm") == false)
        #expect(phpStorm?.matches(bundleID: "com.microsoft.VSCode") == false)
    }

    @Test("the family rule is JetBrains only, so Zed Preview is not Zed")
    func theFamilyRuleDoesNotReachOtherVendors() {
        let zed = EditorCatalog.known.first { $0.bundleID == "dev.zed.Zed" }
        let code = EditorCatalog.known.first { $0.bundleID == "com.microsoft.VSCode" }

        // Both of these are entries of their own with names of their own, so a prefix rule that
        // swallowed them would show the wrong name for the copy it found.
        #expect(zed?.matches(bundleID: "dev.zed.Zed-Preview") == false)
        #expect(code?.matches(bundleID: "com.microsoft.VSCodeInsiders") == false)
    }

    @Test("a full stop is a different product, not a different build")
    func communityEditionIsNotUltimate() {
        let ultimate = EditorCatalog.known.first { $0.bundleID == "com.jetbrains.intellij" }

        #expect(ultimate?.matches(bundleID: "com.jetbrains.intellij.ce") == false)
        #expect(EditorCatalog.owner(ofBundleID: "com.jetbrains.intellij.ce")?.name == "IntelliJ IDEA CE")
        #expect(EditorCatalog.owner(ofBundleID: "com.jetbrains.intellij-EAP")?.name == "IntelliJ IDEA")
    }

    @Test("an installed variant is one of ours, so the system default does not add it twice")
    func aVariantCountsAsKnown() {
        // The menu adds whatever the user set as the handler for a file type only when it is not
        // already in the catalogue. This identifier IS the handler for `.php` on the reporter's
        // Mac, and `knownIDs` answered no for it, which would have drawn PhpStorm twice the
        // moment the catalogue started finding it.
        #expect(EditorCatalog.isKnown(bundleID: "com.jetbrains.PhpStormLight-EAP"))
        #expect(EditorCatalog.owner(ofBundleID: "com.jetbrains.PhpStormLight-EAP")?.name == "PhpStorm")
        #expect(!EditorCatalog.isKnown(bundleID: "com.example.SomeEditor"))
    }

    @Test("installed is asked about every identifier, not only the canonical one")
    func installedSeesAVariant() {
        let apps = EditorCatalog.installed { $0 == "com.jetbrains.PhpStormLight-EAP" }

        #expect(apps.map(\.name) == ["PhpStorm"])
        // And the menu still keys its order and its memory by the canonical identifier.
        #expect(apps.map(\.bundleID) == ["com.jetbrains.PhpStorm"])
    }

    @Test("a bundle named after the application is worth opening; one merely starting with it is not")
    func fileNamesAreMatchedAtABoundary() {
        let phpStorm = EditorCatalog.known.first { $0.bundleID == "com.jetbrains.PhpStorm" }

        #expect(phpStorm?.matchesFileName("PhpStorm.app") == true)
        #expect(phpStorm?.matchesFileName("PhpStorm EAP.app") == true)
        #expect(phpStorm?.matchesFileName("PhpStorm 2025.2.app") == true)
        #expect(phpStorm?.matchesFileName("phpstorm.app") == true)
        // The boundary: a different application whose name happens to start the same way.
        #expect(phpStorm?.matchesFileName("PhpStormy.app") == false)
        #expect(phpStorm?.matchesFileName("WebStorm.app") == false)
        #expect(phpStorm?.matchesFileName("PhpStorm") == false)
    }

    @Test("every catalogue entry still resolves to itself")
    func everyEntryOwnsItsOwnIdentifier() {
        for app in EditorCatalog.known {
            for bundleID in app.bundleIDs {
                #expect(EditorCatalog.owner(ofBundleID: bundleID)?.bundleID == app.bundleID)
            }
        }
    }

    // MARK: - Order

    @Test("the one used last is at the top")
    func theLastUsedComesFirst() {
        let apps = EditorCatalog.installed { ["com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode"].contains($0) }

        let ordered = EditorCatalog.ordered(apps, lastUsed: "com.apple.dt.Xcode")

        #expect(ordered.map(\.name) == ["Xcode", "Visual Studio Code", "Zed"])
    }

    @Test("everything else stays exactly where it was, so the menu can be learned")
    func theRestDoesNotReshuffle() {
        let apps = EditorCatalog.installed { _ in true }

        let first = EditorCatalog.ordered(apps, lastUsed: "dev.zed.Zed").dropFirst()
        let second = EditorCatalog.ordered(apps, lastUsed: "com.apple.dt.Xcode").dropFirst()

        // Two different applications used last, and both leave the tail in the catalogue's order
        // with only the promoted one missing from it.
        #expect(Array(first.map(\.bundleID)) == apps.map(\.bundleID).filter { $0 != "dev.zed.Zed" })
        #expect(Array(second.map(\.bundleID)) == apps.map(\.bundleID).filter { $0 != "com.apple.dt.Xcode" })
    }

    @Test("nothing used yet, or something since uninstalled, leaves the order alone")
    func anUnknownLastUsedChangesNothing() {
        let apps = EditorCatalog.installed { _ in true }

        #expect(EditorCatalog.ordered(apps, lastUsed: nil) == apps)
        #expect(EditorCatalog.ordered(apps, lastUsed: "com.example.NotInstalled") == apps)
    }

    // MARK: - What was used last

    private func preferences() -> (OpenInPreferences, UserDefaults) {
        // A suite of its own, never the app's own domain, so a test run cannot change what the
        // menu does in the copy of Bloom the user is running.
        let name = "bloom.tests.openIn.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (OpenInPreferences(defaults: defaults), defaults)
    }

    @Test("nothing has been used yet")
    func nothingRecorded() {
        let (preferences, _) = preferences()

        #expect(preferences.lastUsed(repo: RepoID("repo-1")) == nil)
    }

    @Test("a project remembers its own editor")
    func aRepoRemembersItsOwn() {
        let (preferences, _) = preferences()

        preferences.record("com.jetbrains.PhpStorm", repo: RepoID("laravel"))
        preferences.record("com.apple.dt.Xcode", repo: RepoID("bloom"))

        #expect(preferences.lastUsed(repo: RepoID("laravel")) == "com.jetbrains.PhpStorm")
        #expect(preferences.lastUsed(repo: RepoID("bloom")) == "com.apple.dt.Xcode")
    }

    @Test("a project opened for the first time inherits whatever was used last anywhere")
    func aNewRepoInheritsTheGlobalAnswer() {
        let (preferences, _) = preferences()

        preferences.record("dev.zed.Zed", repo: RepoID("laravel"))

        #expect(preferences.lastUsed(repo: RepoID("a-project-never-opened")) == "dev.zed.Zed")
        #expect(preferences.lastUsed(repo: nil) == "dev.zed.Zed")
    }

    @Test("a place with no project of its own still remembers")
    func recordingWithoutARepoIsStillRemembered() {
        let (preferences, _) = preferences()

        preferences.record("dev.zed.Zed", repo: nil)

        #expect(preferences.lastUsed(repo: nil) == "dev.zed.Zed")
        // And it does not invent an answer for a project that has one already.
        preferences.record("com.jetbrains.PhpStorm", repo: RepoID("laravel"))
        preferences.record("com.microsoft.VSCode", repo: nil)
        #expect(preferences.lastUsed(repo: RepoID("laravel")) == "com.jetbrains.PhpStorm")
    }
}
