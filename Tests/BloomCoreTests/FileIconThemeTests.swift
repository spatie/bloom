import Foundation
import Testing
@testable import BloomCore

@Suite("File icon theme associations")
struct FileIconThemeTests {
    static let manifest = #"""
    {
      "iconDefinitions": {
        "file": {"iconPath": "../../icons/file.svg"},
        "folder": {"iconPath": "../../icons/folder.svg"},
        "open": {"iconPath": "../../icons/open.svg"},
        "source": {"iconPath": "../../icons/source.svg"},
        "sourceOpen": {"iconPath": "../../icons/sourceOpen.svg"},
        "swift": {"iconPath": "../../icons/swift.svg"},
        "ts": {"iconPath": "../../icons/ts.svg"},
        "react": {"iconPath": "../../icons/react.svg"},
        "declaration": {"iconPath": "../../icons/declaration.svg"},
        "package": {"iconPath": "../../icons/package.svg"},
        "lightPackage": {"iconPath": "../../icons/lightPackage.svg"},
        "empty": {"iconPath": ""}
      },
      "file": "file", "folder": "folder", "folderExpanded": "open",
      "fileNames": {"package.json": "package"},
      "fileExtensions": {"d.ts": "declaration", "json": "file"},
      "languageIds": {"swift": "swift", "typescript": "ts", "typescriptreact": "react"},
      "folderNames": {"src": "source"}, "folderNamesExpanded": {"src": "sourceOpen"},
      "light": {"file": "empty", "folder": "empty", "folderExpanded": "empty",
                "fileNames": {"package.json": "lightPackage"}}
    }
    """#

    @Test("filenames beat suffixes, compound suffixes beat language defaults", arguments: [
        ("PACKAGE.JSON", "package"), ("types.d.ts", "declaration"), ("index.ts", "ts"),
        ("App.swift", "swift"), ("Component.tsx", "react"), ("unknown.xyz", "file"),
    ])
    func files(name: String, expected: String) throws {
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(Self.manifest.utf8))
        #expect(theme.iconID(name: name, isDirectory: false, expanded: false, isLight: false) == expected)
    }

    @Test("folder names and expansion select their own artwork")
    func folders() throws {
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(Self.manifest.utf8))
        #expect(theme.iconID(name: "SRC", isDirectory: true, expanded: false, isLight: false) == "source")
        #expect(theme.iconID(name: "src", isDirectory: true, expanded: true, isLight: true) == "sourceOpen")
        #expect(theme.iconID(name: "other", isDirectory: true, expanded: true, isLight: false) == "open")
    }

    @Test("light overrides inherit missing associations and empty default artwork")
    func light() throws {
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(Self.manifest.utf8))
        #expect(theme.iconID(name: "package.json", isDirectory: false, expanded: false, isLight: true) == "lightPackage")
        #expect(theme.iconID(name: "App.swift", isDirectory: false, expanded: false, isLight: true) == "swift")
        #expect(theme.iconID(name: "unknown", isDirectory: false, expanded: false, isLight: true) == "file")
        #expect(theme.iconID(name: "other", isDirectory: true, expanded: true, isLight: true) == "open")
    }
    @Test("Symbols keeps folder artwork when the manifest has no expanded variants")
    func foldersWithoutExpandedVariants() throws {
        let manifest = #"""
        {"iconDefinitions":{"folder":{"iconPath":"icons/folder.svg"},"source":{"iconPath":"icons/source.svg"}},
         "folder":"folder","folderNames":{"src":"source"}}
        """#
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(manifest.utf8))
        #expect(theme.iconID(name: "src", isDirectory: true, expanded: true, isLight: false) == "source")
        #expect(theme.iconID(name: "other", isDirectory: true, expanded: true, isLight: false) == "folder")
    }

    @Test("Material Icon Theme filename associations match regardless of letter case")
    func mixedCaseAssociations() throws {
        let manifest = #"""
        {"iconDefinitions":{"file":{"iconPath":"icons/file.svg"},"cmake":{"iconPath":"icons/cmake.svg"}},
         "file":"file","fileNames":{"CMakePresets.json":"cmake"}}
        """#
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(manifest.utf8))
        #expect(theme.iconID(name: "CMakePresets.json", isDirectory: false, expanded: false, isLight: false) == "cmake")
    }

}
