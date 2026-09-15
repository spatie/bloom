import Foundation
import Testing
@testable import BloomCore

@Suite("File icon pack preferences")
struct FileIconPackTests {
    @Test("new and existing users start with vscode-icons")
    func defaultChoice() throws {
        let name = "bloom-icon-preferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(FileIconPack.preferred(in: defaults) == .vscodeIcons)
        defaults.set(false, forKey: "useVSCodeIcons")
        #expect(FileIconPack.preferred(in: defaults) == .vscodeIcons)
        defaults.set(true, forKey: "useVSCodeIcons")
        #expect(FileIconPack.preferred(in: defaults) == .vscodeIcons)
    }

    @Test("choices made with the pack picker survive reloads", arguments: FileIconPack.allCases)
    func savedChoice(pack: FileIconPack) throws {
        let name = "bloom-icon-preferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(pack.rawValue, forKey: FileIconPack.defaultsKey)
        #expect(FileIconPack.preferred(in: defaults) == pack)
    }

    @Test("an unknown saved pack falls back to vscode-icons")
    func unknownChoice() {
        #expect(FileIconPack.resolve("removed-pack") == .vscodeIcons)
    }

    @Test("the existing vscode-icons installation keeps its location")
    func existingInstallation() throws {
        #expect(try #require(FileIconPack.vscodeIcons.download).directoryName == "vscode-icons-12.19.0")
    }
}
