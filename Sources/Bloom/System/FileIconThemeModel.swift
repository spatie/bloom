import AppKit
import Observation
import BloomCore

@MainActor @Observable
final class FileIconThemeModel {
    static let shared = FileIconThemeModel()

    private(set) var pack: VSCodeIconsInstaller.Pack?
    private(set) var isInstalling = false
    private(set) var error: String?
    private var hasLoaded = false
    @ObservationIgnored private var images: [String: NSImage?] = [:]
    @ObservationIgnored private var installTask: Task<Void, Never>?
    private let installer = VSCodeIconsInstaller(
        directory: Store.defaultDirectory.appendingPathComponent("File Icons/vscode-icons-\(VSCodeIconsInstaller.version)")
    )

    func load() async {
        guard !hasLoaded, !isInstalling else { return }
        hasLoaded = true
        pack = try? await installer.load()
    }

    // The shared model owns installation so closing Settings does not abandon the download.
    func install() {
        guard !isInstalling else { return }
        isInstalling = true
        error = nil
        installTask = Task {
            defer {
                isInstalling = false
                installTask = nil
            }
            do {
                pack = try await installer.install()
                images.removeAll()
                hasLoaded = true
                UserDefaults.standard.set(true, forKey: VSCodeIconsInstaller.defaultsKey)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func image(name: String, isDirectory: Bool, expanded: Bool, isLight: Bool) -> NSImage? {
        guard let pack,
              let identifier = pack.theme.iconID(name: name, isDirectory: isDirectory, expanded: expanded, isLight: isLight)
        else { return nil }
        if let cached = images[identifier] { return cached }
        let image = pack.artwork[identifier].flatMap { NSImage(data: $0) }
        images[identifier] = image
        return image
    }
}
