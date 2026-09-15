import Foundation

/// Pack identity also namespaces the on-disk artwork and the user's saved choice.
public enum FileIconPack: String, CaseIterable, Sendable, Identifiable {
    case bloom
    case vscodeIcons = "vscode-icons"
    case material = "material-icon-theme"
    case symbols

    // A new key deliberately makes vscode-icons the default for existing users too. Once the
    // picker records a choice here, upgrades preserve it, including an explicit Bloom default.
    public static let defaultsKey = "fileIconPack"
    public static let defaultChoice = FileIconPack.vscodeIcons

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bloom: "Bloom default"
        case .vscodeIcons: "vscode-icons"
        case .material: "Material Icon Theme"
        case .symbols: "Symbols"
        }
    }

    public static func resolve(_ rawValue: String?) -> FileIconPack {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultChoice
    }

    public static func preferred(in defaults: UserDefaults) -> FileIconPack {
        resolve(defaults.string(forKey: defaultsKey))
    }

    public struct Download: Sendable {
        public let directoryName: String
        public let archiveURL: URL
        public let marketplaceURL: URL
        public let manifestPath: String
        public let artworkDirectory: String
        public let licencePath = "extension/LICENSE.txt"
    }

    public var download: Download? {
        switch self {
        case .bloom: nil
        case .vscodeIcons:
            Download(
                directoryName: "vscode-icons-12.19.0",
                archiveURL: URL(string: "https://github.com/vscode-icons/vscode-icons/releases/download/v12.19.0/vscode-icons-12.19.0.vsix")!,
                marketplaceURL: URL(string: "https://marketplace.visualstudio.com/items?itemName=vscode-icons-team.vscode-icons")!,
                manifestPath: "extension/dist/src/vsicons-icon-theme.json",
                artworkDirectory: "extension/icons"
            )
        case .material:
            Download(
                directoryName: "material-icon-theme-5.38.1",
                archiveURL: URL(string: "https://github.com/material-extensions/vscode-material-icon-theme/releases/download/v5.38.1/material-icon-theme-5.38.1.vsix")!,
                marketplaceURL: URL(string: "https://marketplace.visualstudio.com/items?itemName=PKief.material-icon-theme")!,
                manifestPath: "extension/dist/material-icons.json",
                artworkDirectory: "extension/icons"
            )
        case .symbols:
            Download(
                directoryName: "symbols-0.0.26",
                archiveURL: URL(string: "https://github.com/miguelsolorio/vscode-symbols/releases/download/0.0.26/symbols-0.0.26.vsix")!,
                marketplaceURL: URL(string: "https://marketplace.visualstudio.com/items?itemName=miguelsolorio.symbols")!,
                manifestPath: "extension/src/symbol-icon-theme.modified.json",
                artworkDirectory: "extension/src/icons"
            )
        }
    }
}
