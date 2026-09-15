import AppKit
import SwiftUI
import BloomCore

/// The applications the user has added to the "Open in" menus, and the button that adds one.
///
/// For the application `EditorCatalog` does not list; `OpenInCustomApps` says why that needs a
/// way in at all. Every catalogued one is offered the moment it is installed and has no row here.
///
/// Each row carries a picker for what the application is offered, because that is the one thing
/// a bundle cannot tell us. A git client handed a single file has nothing to do with it, which is
/// the ambiguity `OpenInTarget` exists to avoid, and a wrong guess here would put the application
/// in exactly the menu where clicking it does nothing.
struct OpenInSettingsSection: View {
    @State private var apps: [ExternalApp] = []
    /// Where each addition is installed, looked up when the list is read rather than on every
    /// draw. Not taken from `InstalledApps`, which only holds what it could find: an application
    /// that was added and since uninstalled still has a row here, and the row is where the user
    /// finds out why it is not in the menu.
    @State private var locations: [String: URL] = [:]
    @State private var refusal: String?

    var body: some View {
        Section("Open in") {
            ForEach(apps) { app in
                row(app)
            }

            Button("Add Application…") {
                Task { await add() }
            }

            if let refusal {
                Text(refusal).foregroundStyle(Palette.negative)
            }

            Text(
                "Every editor, terminal and git client Bloom knows is already offered once it is installed. "
                + "Add one Bloom does not know and it joins every Open in menu, including Open Worktree in."
            )
            .settingsFootnote()
        }
        .onAppear(perform: load)
    }

    private func row(_ app: ExternalApp) -> some View {
        let url = locations[app.bundleID]
        return HStack(spacing: Metrics.gutter) {
            if let url {
                Image(nsImage: InstalledApps.icon(at: url))
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                if url == nil {
                    Text("Not installed").settingsFootnote()
                }
            }
            .lineLimit(1)
            Spacer()
            Picker("Offered for", selection: targets(of: app)) {
                Text("Files and folders").tag(OpenTargets.both)
                Text("Folders only").tag(OpenTargets.folder)
            }
            .labelsHidden()
            .fixedSize()
            Button("Remove") { remove(app) }
        }
    }

    private func targets(of app: ExternalApp) -> Binding<OpenTargets> {
        Binding(
            get: { app.targets },
            set: { targets in
                OpenInCustomApps().setTargets(targets, forBundleID: app.bundleID)
                reload()
            }
        )
    }

    private func add() async {
        refusal = nil
        guard let url = await ApplicationPicker.choose() else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            refusal = "\(url.lastPathComponent) has no bundle identifier, so Bloom cannot open anything with it."
            return
        }
        // Both by default, which is right for an editor and wrong for a git client, and the row's
        // picker is one click either way. The alternative, folders only, would hide a newly added
        // editor from every file's menu, which is the more surprising of the two mistakes.
        let app = ExternalApp(
            bundleID: bundleID,
            name: InstalledApps.name(of: url),
            targets: .both,
            fileName: url.lastPathComponent
        )
        switch OpenInCustomApps().add(app) {
        case .alreadyInCatalogue(let name):
            refusal = "\(name) is already offered in every Open in menu when it is installed."
        case .alreadyAdded:
            refusal = "\(app.name) has already been added."
        case nil:
            break
        }
        reload()
    }

    private func remove(_ app: ExternalApp) {
        refusal = nil
        OpenInCustomApps().remove(bundleID: app.bundleID)
        reload()
    }

    private func load() {
        apps = OpenInCustomApps().apps
        // Uniquing rather than trapping, because the list is a preferences file and can be edited by hand.
        let found = apps.compactMap { app in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID).map { (app.bundleID, $0) }
        }
        locations = Dictionary(found, uniquingKeysWith: { first, _ in first })
    }

    /// Reads the list back and forgets the menu's cache, so the next menu opened shows the change
    /// rather than the list from up to a minute ago. See `InstalledApps.invalidate`.
    private func reload() {
        load()
        InstalledApps.invalidate()
    }
}
