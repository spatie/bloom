import AppKit
import UniformTypeIdentifiers

/// Asking the user for an application bundle. Wrapped for the reason `ProjectFolderPicker` is:
/// one place decides how the panel is configured.
@MainActor
enum ApplicationPicker {
    /// A sheet rather than an application-modal panel, for the reason `NSSavePanel.present`
    /// gives: `runModal()` would stop every other workspace's transcript from streaming for as
    /// long as the picker is open.
    static func choose() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // A bundle is a folder to the file system and a file to the panel, and it is the panel's
        // reading that lets one be picked whole rather than descended into.
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"
        panel.message = "Choose an application to offer in the Open in menus."
        guard await panel.present() == .OK, let url = panel.url else { return nil }
        return url
    }
}
