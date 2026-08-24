import SwiftUI
import AppKit
import BloomCore

/// Everything that belongs to one project rather than to the app: what it is called and what it
/// looks like in the sidebar, which ignored files a new workspace needs, what runs when one is
/// created, and how to stop tracking it.
///
/// Three panes rather than one long scroll, because the three are different kinds of thing and
/// nobody arrives here wanting all of them: what the project IS, what a new workspace STARTS with,
/// and what Bloom RUNS in it. The tab bar is the one macOS draws for a `TabView`, and it is the
/// same control the app's own Settings window is built from, so the two windows read as one app.
///
/// Two kinds of setting live here and they are stored in two different places, which the screen is
/// explicit about. The name, mark and colour are Bloom's own record of a folder and live in its
/// database. Everything else is stated in the repository's settings files, is shared with whoever
/// else works on it, and is written back to the file it came from. Every field that writes a file
/// names the file underneath it, so the destination is known before Save is pressed. See
/// `SettingsWriter` for why there is no third, invisible copy in the database.
struct RepoSettingsView: View {
    let repo: Repo

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model: RepoSettingsModel
    /// The project's whole stored name, emoji and all.
    ///
    /// It used to be two fields. The name lived here with any leading emoji stripped off it, a
    /// second field beside the tile held that emoji, and `saveName` glued the two back together.
    /// The split bought nothing: an emoji mark is not a separate column, it IS the first character
    /// of `Repo.name`, and `RepoMonogram.initials(for:)` reads it straight off the stored string.
    /// So the field showed a name the project did not have, and the one place that mattered, the
    /// title bar, said the real one.
    ///
    /// **Typing an emoji at the front of this field is now how a mark is set**, and that is the
    /// intended way in rather than a side effect. It is also the only way the mark was ever
    /// stored, so nothing has been taken away: the removed field wrote the same character to the
    /// same place. See `RepoMonogram.initials(for:)` for what counts as one, which is a single
    /// leading pictograph and nothing else.
    @State private var name = ""
    /// Which pane a window opens on. `BLOOM_PANE=workspaces|scripts` for a capture run, because
    /// `--repo-settings` can open this window but cannot press a tab, and a tab nobody can
    /// photograph is a tab that changes unverified. Anything else, including nothing, is Project.
    @State private var pane: Pane = {
        switch ProcessInfo.processInfo.environment["BLOOM_PANE"] {
        case "workspaces": return .workspaces
        case "scripts": return .scripts
        default: return .project
        }
    }()
    @State private var isConfirmingRemove = false
    /// What the last thing the Mark row did came to, when it came to nothing. Cleared as soon as
    /// something else is pressed, because it is about that press and not about the project.
    @State private var iconNotice: String?
    /// The name is written to the database on commit rather than on every keystroke, because each
    /// write reloads the whole sidebar and typing a name would do it once a letter.
    @FocusState private var isEditingName: Bool

    init(repo: Repo) {
        self.repo = repo
        _model = State(initialValue: RepoSettingsModel(repo: repo))
    }

    /// Which pane is showing. An enum rather than an index, so the value says what it selects.
    ///
    /// Named `Pane` because `Tab` is SwiftUI's own type, and the tabs below are declared with it.
    private enum Pane: Hashable {
        case project
        case workspaces
        case scripts
    }

    /// Long enough that the scripts are readable, and no wider than the longest sentence in the
    /// window wants: the rows themselves no longer care how wide it is, since `SettingsRow` keeps
    /// a field beside its label at any width, but a footer set across a very wide pane does not
    /// read.
    static let idealSize = CGSize(width: 640, height: 700)
    static let minimumSize = CGSize(width: 560, height: 460)

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pane) {
                Tab("Project", systemImage: "folder", value: Pane.project) {
                    Form {
                        projectSection
                        filesSection
                        removeSection
                    }
                    .settingsForm()
                }

                Tab("Workspaces", systemImage: "square.stack.3d.up", value: Pane.workspaces) {
                    Form {
                        RepoFilesToCopySection(model: model)
                        branchSection
                    }
                    .settingsForm()
                }

                Tab("Scripts", systemImage: "terminal", value: Pane.scripts) {
                    Form {
                        RepoScriptsSection(model: model)
                    }
                    .settingsForm()
                }
            }

            Hairline()
            RepoSettingsSaveBar(model: model)
        }
        .background(Palette.windowBackground)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        // There is one of these windows per project, so the window has to say which project it
        // belongs to. It says it the way every other Mac window does, in its own title, above the
        // tab bar rather than instead of it. See `RepoSettingsTitleBar`.
        .navigationTitle("\(repo.name) Settings")
        .showsProjectInTitleBar(repo)
        .task {
            // The stored name verbatim. Nothing is written back on load, so a project whose name
            // begins with an emoji keeps it whether or not this window is ever opened.
            name = repo.name
            await model.load()
        }
        // The usual way a settings file changes while this window is open is a `git pull` in a
        // terminal beside it, and coming back to the window is when that becomes visible.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .confirmationDialog(
            removal.title,
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button(removal.confirmLabel, role: .destructive, action: removeProject)
            Button(removal.cancelLabel, role: .cancel) {}
        } message: {
            Text(removal.message)
        }
    }

    // MARK: - Project

    private var projectSection: some View {
        Section {
            SettingsRow("Name") {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditingName)
                    .onSubmit(saveName)
                    .onChange(of: isEditingName) { wasEditing, editing in
                        if wasEditing, !editing { saveName() }
                    }
            }

            markRow

            if drawsColour {
                SettingsRow("Colour") {
                    // Circles and a colour well, with not a word between them. See the modifier.
                    AccentSwatches(selection: accentBinding)
                        .settingsRowBaseline()
                }
            }

            SettingsRow("Folder") {
                HStack(spacing: Metrics.gutter) {
                    Text(shortPath(repo.path))
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(repo.path)

                    Button("Reveal") { Reveal.inFinder(repo.path) }
                }
            }
        } footer: {
            Text("Bloom's own record of this folder. Everything on the other two tabs is saved in the repository.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: - Mark

    /// The one row that answers "what is drawn beside this project", in the order the app draws it.
    ///
    /// It used to be two rows. One held an emoji field and a preview tile, the other held a second
    /// preview tile and the icon buttons, and between them they showed the same project twice and
    /// offered two different ways to say "letters, please". They are one row now: the tile as the
    /// sidebar will draw it, one line saying where that came from, and the three things that can
    /// change it.
    ///
    /// Bloom looks for artwork once, when a project is added, at the places a favicon and an
    /// application icon conventionally live. Everything about that is a guess, however good, so all
    /// the ways out are here: look again, say which file it is, put an emoji at the front of the
    /// name, or have the letters back. A project added before Bloom knew how to look has never been searched, and its button
    /// says `Find icon` rather than pretending a search already happened and found nothing.
    ///
    /// Two lines: the mark itself with the three things that change it beside it, and then the
    /// line saying where it came from. It was three, with an emoji field between the tile and the
    /// buttons. That field wrote a leading emoji into the project's name, which is the only place
    /// a mark has ever been stored, so typing the same character at the front of the Name field
    /// above does exactly what it did. What it cost was a Name field showing a name the project
    /// did not have. See `name`.
    ///
    /// The tile shares a line with the buttons rather than sitting above them. It was kept apart
    /// once by the value column this row used to be laid out in, where a fourth control on a line
    /// tipped the row out of the column and started it at a different edge from its neighbours.
    /// `SettingsRow` has no such column, and with the field gone the line has room. The sentence
    /// underneath stays on a line of its own, because it is prose. See `summaryLine`.
    private var markRow: some View {
        SettingsRow("Mark") {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                HStack(spacing: Metrics.gutter) {
                    markTile(size: Self.markTileSize)

                    Button(repo.iconSource == .undetected ? "Find icon" : "Look again", action: findIcon)
                    Button("Choose…", action: chooseIcon)
                    // One button for "draw the letters", where there were two. It clears both the
                    // picture and the emoji, because clearing only one of them leaves the other
                    // standing and the button would be lying about what it did.
                    Button("Use initials", action: useInitials)
                        .disabled(!repo.hasIcon && !canDropMark)
                }
                .controlSize(.small)

                summaryLine
            }
        }
    }

    /// Where the mark came from, on a line of its own at the full width of the row.
    ///
    /// It used to sit beside the tile and the emoji field, sharing the value column with both,
    /// and four of its five answers are short enough that nobody noticed. The fifth is the one
    /// that matters most: pressing Look again and finding nothing answers with the three places
    /// Bloom searched, and that sentence arrived middle-truncated, so the one message a user
    /// reads word for word was the one they could not read. On its own line it has three times
    /// the width and needs no truncation at either end of the window.
    ///
    /// Under the buttons rather than above them, so a message that runs to two lines pushes
    /// nothing that can be pressed. `Look again` is a button people press twice, and a button
    /// that steps away from the pointer between the two presses is worse than a long sentence.
    ///
    /// Two lines are held whether or not two are used, because the row sits above Colour and
    /// Folder and the height of a sentence is not a reason for either of them to move. The
    /// reservation is for the longest of the five answers, and that is the only one that needs a
    /// second line.
    private var summaryLine: some View {
        Text(markSummary)
            .font(Typo.caption)
            .foregroundStyle(iconNotice == nil ? Palette.textSecondary : Palette.warning)
            .lineLimit(2, reservesSpace: true)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(repo.iconPath ?? "")
    }

    /// Whether the project's colour is on screen at all, and therefore whether the Colour row is.
    ///
    /// A project's colour is drawn in exactly one place in the whole app: it is the ground the
    /// mark's letters, or its emoji, sit on. `RepoIcon` is the only view that draws `Repo.accent`
    /// at all, and it draws it only on that branch: the rest of the app reads the colour to offer
    /// it back in a picker or to bake the same tile into a menu item's image, and everything that
    /// merely looks accent coloured is `Palette.accent`, which belongs to Bloom and not to any
    /// project. So a project whose mark is a picture has a colour that changes nothing anywhere,
    /// and ten swatches offering to change it are ten swatches that do nothing. Hidden rather than
    /// disabled: a dimmed row still has to be read and still has to be explained, and the
    /// explanation would be longer than the control.
    ///
    /// It comes back the moment the colour is drawn again, which is what makes hiding it safe.
    /// Pressing `Use initials` is the obvious way, and the row arrives directly under the button
    /// that was just pressed. The other way is the file going: a project on an unmounted volume
    /// falls back to its letters, and this is asked of the artwork as it actually loaded rather
    /// than of `hasIcon`, so the row is back exactly when the tile beside it is back to letters.
    private var drawsColour: Bool {
        RepoIconArt.artwork(for: repo) == nil
    }

    /// The preview tile, drawn larger than the sidebar's 16 so the artwork can actually be judged.
    /// Named because it is the tallest thing on the mark row's first line, and therefore what the
    /// label beside it is centred against.
    static let markTileSize: CGFloat = Metrics.repoIcon * 1.75

    /// The tile as the sidebar will draw it: the project's own artwork when it has some, and
    /// otherwise the name being typed, so the preview is the real thing and not an impression.
    @ViewBuilder
    private func markTile(size: CGFloat) -> some View {
        if repo.hasIcon {
            RepoIcon(repo: repo, size: size)
        } else {
            RepoIcon(name: previewName, accent: repo.accent, size: size)
        }
    }

    /// Where the tile beside it comes from, in one line.
    private var markSummary: String {
        if let iconNotice { return iconNotice }
        if repo.hasIcon, let path = repo.iconPath {
            let location = shortPath(path)
            return repo.iconSource == .chosen ? "Chosen: \(location)" : "Found: \(location)"
        }
        if !RepoMonogram.mark(in: name).isEmpty {
            return "The emoji at the front of the name."
        }
        switch repo.iconSource {
        // Never searched, rather than searched and empty handed. The button beside it says
        // `Find icon` for the same reason.
        case .undetected: return "Bloom has not looked for an icon here."
        case .monogram, .detected, .chosen: return "Initials on the project's colour."
        }
    }

    // MARK: - Changing the mark

    /// Runs the same search that runs when a project is added. Off the main actor, because it
    /// reads directories and this window has a text field in it.
    private func findIcon() {
        iconNotice = nil
        let path = repo.path
        Task {
            guard let found = await Task.detached(operation: { RepoIconDetector.detect(in: path) }).value
            else {
                iconNotice = "Nothing found. Bloom looks for a favicon, a manifest icon and an app icon."
                return
            }
            await apply(icon: found.path, source: .detected)
        }
    }

    /// A file the user names, which is the last word: no size floor, no ranking, no second guess.
    private func chooseIcon() {
        iconNotice = nil
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.image, .svg]
            panel.prompt = "Use icon"
            panel.message = "Choose the picture to draw \(repo.name) with."
            panel.directoryURL = URL(fileURLWithPath: repo.path)
            guard await panel.present() == .OK, let url = panel.url else { return }

            // Refused here rather than silently falling back to initials later, which is what an
            // unreadable file would otherwise look like from the sidebar.
            guard NSImage(contentsOf: url) != nil else {
                iconNotice = "That file could not be read as a picture."
                return
            }
            await apply(icon: url.path, source: .chosen)
        }
    }

    /// Back to the letters, whichever of the two things was covering them.
    ///
    /// The emoji half of this is now an edit to the name, because that is where the emoji lives.
    /// `canDropMark` is what keeps it honest: a project called nothing but an emoji has no letters
    /// underneath to fall back to, and stripping it would leave the project nameless, so the
    /// button is not offered for that case rather than being offered and doing nothing.
    private func useInitials() {
        iconNotice = nil
        if canDropMark {
            name = RepoMonogram.nameWithoutMark(name)
            saveName()
        }
        guard repo.hasIcon else { return }
        Task { await apply(icon: nil, source: .monogram) }
    }

    /// Whether there is an emoji at the front of the name with a name still left under it.
    private var canDropMark: Bool {
        let stripped = RepoMonogram.nameWithoutMark(name)
        return stripped != name.trimmingCharacters(in: .whitespaces) && !stripped.isEmpty
    }

    private func apply(icon: String?, source: RepoIconSource) async {
        guard let store = app.store else { return }
        // Both paths, because the one being left may be back in a moment and the one arriving may
        // be a file that has changed since it was last read.
        RepoIconArt.forget(repo.iconPath)
        RepoIconArt.forget(icon)
        // The two icon columns only. This value was captured before the detection walk, or
        // before an open panel that somebody may have spent a minute in, and writing all of it
        // would put the project's name, colour and collapsed state back to whatever they were
        // when the button was pressed.
        _ = try? await store.update(repoID: repo.id) {
            $0.iconPath = icon
            $0.iconSource = source
        }
    }

    /// The name as the sidebar would show it, so the preview is the real thing and not an artist's
    /// impression of it. One field now holds the whole of it, emoji included, so there is nothing
    /// left to compose: this is here because the tile wants the name as it is being typed rather
    /// than the name as last saved.
    private var previewName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: repo.accent) },
            set: { color in
                guard let hex = color.hexString, hex != repo.accent else { return }
                Task {
                    guard let store = app.store else { return }
                    // The colour and nothing else: the icon buttons above write from a value
                    // this one knows nothing about.
                    _ = try? await store.update(repoID: repo.id) { $0.accent = hex }
                }
            }
        )
    }

    private func saveName() {
        let trimmed = previewName
        // An empty field is a slip, not an instruction: put the stored name back rather than
        // leaving the project nameless.
        guard !trimmed.isEmpty else {
            name = repo.name
            return
        }
        guard trimmed != repo.name else { return }
        Task { await app.rename(repo, to: trimmed) }
    }

    // MARK: - Branches

    private var branchSection: some View {
        Section {
            SettingsRow("Branch prefix") {
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    TextField("", text: $model.draft.branchPrefix, prompt: Text("None"))
                        // Without this the form claims the field for its value column, which put
                        // it at the far edge of the row with the destination label under it
                        // starting at the leading one. See the emoji field above.
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    SettingsDestinationLabel(model: model, key: .branchPrefix)
                }
            }

            Toggle(isOn: $model.draft.deleteBranchOnArchive) {
                Text("Delete the branch when a workspace is archived")
                Text("Off by default. The worktree goes either way, the branch is what is kept.")
            }
        } header: {
            Text("Branches")
        }
    }

    // MARK: - Settings files

    private var filesSection: some View {
        Section {
            if model.loaded.sources.isEmpty {
                Text("No settings file applies to this project yet. Saving creates \(shortPath(SettingsWriter.defaultFile(repo: repo.path))).")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                // Not a `SettingsRow`. The leading half is a path rather than a short label, and
                // a path in the column every other row in this pane lines up against would push
                // `Name` and its field most of the way across the window. So it is an ordinary
                // row: the file, then the button that opens it, held apart.
                ForEach(model.loaded.sources, id: \.self) { source in
                    HStack(spacing: Metrics.gutter) {
                        Text(shortPath(source))
                            .font(Typo.codeSmall)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(source)

                        Spacer(minLength: Metrics.spacingSmall)

                        Button("Open") { Reveal.inEditor(source) }
                    }
                }
            }
        } header: {
            Text("Settings files")
        } footer: {
            Text("Lowest precedence first. A file inside the project outranks a machine-wide one, and a .local file outranks the one beside it that is committed.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// A path written the way the user thinks of it: relative to the project, or with the home
    /// folder as a tilde. The full path is still what a click opens.
    private func shortPath(_ path: String) -> String {
        if path.hasPrefix(repo.path + "/") {
            return String(path.dropFirst(repo.path.count + 1))
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Removing

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingRemove = true
            } label: {
                Label("Remove Project", systemImage: "trash")
                    .foregroundStyle(Palette.negative)
            }
        } footer: {
            Text("Bloom forgets the project. Nothing on disk is deleted.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// The one question, asked here and in the sidebar and in Settings. See `ProjectRemoval`.
    private var removal: Confirmation {
        ProjectRemoval.confirmation(
            for: repo, workspaces: app.workspaces.filter { $0.repoID == repo.id }
        )
    }

    private func removeProject() {
        Task {
            await app.removeRepository(repo)
            dismiss()
        }
    }
}

/// Names the file a field will be written to, before anything is written to it.
///
/// Three sentences rather than one, because there are three situations and only one of them is
/// "it goes back where it came from".
struct SettingsDestinationLabel: View {
    let model: RepoSettingsModel
    let key: SettingsKey

    var body: some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(isForking ? Palette.warning : Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help)
    }

    private var destination: String { model.destination(for: key) }
    private var origin: String? { model.loaded.origins[key] }

    /// True when saving will state this setting in a second file rather than change the first.
    ///
    /// Only ever a `.conductor` file: Bloom reads those so an existing repository works with
    /// nothing to configure, and writes its own. Both files then state the setting, Bloom's wins
    /// here, and Conductor goes on reading the old one. Nobody should have to work that out from
    /// a diff, so the label says it and is drawn in the warning colour while it is true.
    private var isForking: Bool {
        guard let origin, SettingsLoader.repoPaths(repo: model.repo.path).contains(origin)
        else { return false }
        return origin != destination
    }

    private var text: String {
        if isForking, let origin {
            return "Read from \(short(origin)), saved to \(short(destination))"
        }
        // A value a machine-wide file states is worth saying out loud: editing it here does not
        // touch that file, it writes an override for this project only.
        if let origin, !SettingsLoader.repoPaths(repo: model.repo.path).contains(origin) {
            return "Saved to \(short(destination)), overriding \(short(origin))"
        }
        return "Saved to \(short(destination))"
    }

    private var help: String {
        guard isForking, let origin else { return text }
        return """
            \(short(origin)) was written for Conductor. Bloom reads it but does not edit it, \
            so saving states this setting in \(short(destination)) as well. Bloom uses the new \
            value; Conductor keeps reading the old one until the line is removed by hand.
            """
    }

    private func short(_ path: String) -> String {
        path.hasPrefix(model.repo.path + "/")
            ? String(path.dropFirst(model.repo.path.count + 1))
            : (path as NSString).abbreviatingWithTildeInPath
    }
}

/// The ten colours Bloom hands out, and a picker for any other.
///
/// A `ColorPicker` alone is one small filled pill sitting at the end of a row, and a pill that
/// never changes shape does not read as something you can press: the row announced "green" rather
/// than offering a choice. These are the same ten `Accent.next` assigns from, so the colour a
/// project was given is one of the swatches and changing it is one click, with the system picker
/// still on the end for a colour that is not in the list.
struct AccentSwatches: View {
    @Binding var selection: Color

    private static let size: CGFloat = 14
    /// Room around each swatch, so a 14 point circle is still something a pointer can hit.
    private static let padding: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Accent.all, id: \.self) { hex in
                swatch(hex)
            }

            // The escape hatch, held off from the ten so it reads as another kind of thing rather
            // than as an eleventh colour.
            ColorPicker("Another colour", selection: $selection, supportsOpacity: false)
                .labelsHidden()
                .help("Another colour")
                .padding(.leading, Metrics.spacingWide)
        }
        // The swatches carry their own padding, for the hit area. Taking it back on this edge is
        // what puts the first circle on the same line as the field above it.
        .padding(.leading, -Self.padding)
    }

    private func swatch(_ hex: String) -> some View {
        let isSelected = selection.hexString?.caseInsensitiveCompare(hex) == .orderedSame

        return Button {
            selection = Color(hexString: hex)
        } label: {
            Circle()
                .fill(Color(hexString: hex))
                .frame(width: Self.size, height: Self.size)
                .overlay {
                    Circle().strokeBorder(Palette.textPrimary.opacity(0.12), lineWidth: Metrics.hairline)
                }
                // A ring cut out of the swatch, which is what macOS itself marks a chosen colour
                // with, and which needs no room between the swatches to be drawn in.
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Palette.surface, lineWidth: 2)
                            .padding(2)
                    }
                }
                .padding(Self.padding)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("#\(hex)")
        .accessibilityLabel("Colour #\(hex)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
