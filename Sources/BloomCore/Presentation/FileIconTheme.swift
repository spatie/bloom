import Foundation

/// Resolves the published VS Code theme without requiring an editor or running extension code.
public struct FileIconTheme: Decodable, Sendable {
    public struct Definition: Decodable, Sendable {
        public let iconPath: String
    }

    public struct Associations: Decodable, Sendable {
        var file: String?
        var folder: String?
        var folderExpanded: String?
        var fileNames: [String: String]?
        var fileExtensions: [String: String]?
        var languageIds: [String: String]?
        var folderNames: [String: String]?
        var folderNamesExpanded: [String: String]?

        var normalised: Self {
            var result = self
            result.fileNames = Self.lowercasedKeys(fileNames)
            result.fileExtensions = Self.lowercasedKeys(fileExtensions)
            result.folderNames = Self.lowercasedKeys(folderNames)
            result.folderNamesExpanded = Self.lowercasedKeys(folderNamesExpanded)
            return result
        }

        private static func lowercasedKeys(_ values: [String: String]?) -> [String: String]? {
            values.map { entries in
                entries.keys.sorted().reduce(into: [:]) { result, key in
                    result[key.lowercased()] = entries[key]
                }
            }
        }
    }

    public let iconDefinitions: [String: Definition]
    private let associations: Associations
    private let light: Associations?

    private enum CodingKeys: String, CodingKey { case iconDefinitions, light }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iconDefinitions = try container.decode([String: Definition].self, forKey: .iconDefinitions)
        light = try container.decodeIfPresent(Associations.self, forKey: .light)?.normalised
        associations = try Associations(from: decoder).normalised
    }

    public func iconID(name: String, isDirectory: Bool, expanded: Bool, isLight: Bool) -> String? {
        let candidate = resolvedID(name: name.lowercased(), isDirectory: isDirectory, expanded: expanded, isLight: isLight)
        if let candidate, let definition = iconDefinitions[candidate], !definition.iconPath.isEmpty { return candidate }
        // The published theme uses empty paths for light defaults that inherit the normal artwork.
        return resolvedID(name: name.lowercased(), isDirectory: isDirectory, expanded: expanded, isLight: false)
    }

    private func resolvedID(name: String, isDirectory: Bool, expanded: Bool, isLight: Bool) -> String? {
        let overrides = isLight ? light : nil
        if isDirectory {
            if expanded {
                return overrides?.folderNamesExpanded?[name] ?? associations.folderNamesExpanded?[name]
                    ?? overrides?.folderNames?[name] ?? associations.folderNames?[name]
                    ?? overrides?.folderExpanded ?? associations.folderExpanded
                    ?? overrides?.folder ?? associations.folder
            }
            return overrides?.folderNames?[name] ?? associations.folderNames?[name]
                ?? overrides?.folder ?? associations.folder
        }
        if let icon = overrides?.fileNames?[name] ?? associations.fileNames?[name] { return icon }
        // Longest suffix wins: `test.ts` and `d.ts` take precedence over `ts`.
        for dot in name.indices where name[dot] == "." {
            let suffix = String(name[name.index(after: dot)...])
            if let icon = overrides?.fileExtensions?[suffix] ?? associations.fileExtensions?[suffix] { return icon }
        }
        let language = Self.languageID(name: name)
        return overrides?.languageIds?[language] ?? associations.languageIds?[language]
            ?? overrides?.file ?? associations.file
    }

    private static func languageID(name: String) -> String {
        let suffix = (name as NSString).pathExtension
        // These differ from the highlighter's deliberately smaller language set.
        let specialised = [
            "jsx": "javascriptreact", "tsx": "typescriptreact", "c": "c", "h": "c",
            "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "cs": "csharp",
            "m": "objective-c", "mm": "objective-cpp", "fs": "fsharp", "fsx": "fsharp",
            "scss": "scss", "sass": "sass", "less": "less", "svg": "svg", "jsonc": "jsonc",
            "txt": "plaintext", "ex": "elixir", "exs": "elixir", "erl": "erlang",
            "hs": "haskell", "pl": "perl", "ps1": "powershell", "bat": "bat", "cmd": "bat",
            "r": "r", "tf": "terraform", "tex": "latex", "lua": "lua", "dart": "dart",
            "svelte": "svelte", "astro": "astro", "zig": "zig",
        ]
        if let language = specialised[suffix] { return language }
        switch name {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        default: break
        }
        let language = Language.detect(path: name)
        switch language {
        case .shell: return "shellscript"
        case .plainText: return suffix
        default: return language.rawValue
        }
    }
}
