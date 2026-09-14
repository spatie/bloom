import AppKit
import BloomCore

/// The core library owns downloads; this layer turns its bytes into cached AppKit images.
@MainActor
final class FileIconThemeModel {
    static let shared = FileIconThemeModel()

    let library: FileIconPackLibrary
    private var images: [FileIconPack: [String: NSImage?]] = [:]

    init() {
        library = FileIconPackLibrary { choice in
            guard let download = choice.download else { throw CocoaError(.fileReadUnsupportedScheme) }
            let directory = Store.defaultDirectory.appendingPathComponent("File Icons/\(download.directoryName)")
            let installer = try FileIconPackInstaller(choice: choice, directory: directory)
            if let pack = try? await installer.load() { return pack }
            return try await installer.install()
        }
    }

    func image(pack choice: FileIconPack, name: String, isDirectory: Bool, expanded: Bool, isLight: Bool) -> NSImage? {
        guard let pack = library.packs[choice],
              let identifier = pack.theme.iconID(name: name, isDirectory: isDirectory, expanded: expanded, isLight: isLight)
        else { return nil }
        if let cached = images[choice]?[identifier] { return cached }
        let image = pack.artwork[identifier].flatMap { NSImage(data: $0) }
        images[choice, default: [:]][identifier] = image
        return image
    }
}
