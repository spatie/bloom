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
    @State private var name = ""
    @State private var mark = ""
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
    /// The name and the mark are written to the database on commit rather than on every keystroke,
    /// because each write reloads the whole sidebar and typing a name would do it once a letter.
    @FocusState private var isEditingName: Bool
    @FocusState private var isEditingMark: Bool

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

    /// Long enough that the scripts are readable, narrow enough that the form's label column does
    /// not drift away from its fields.
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
                    .formStyle(.grouped)
                }

                Tab("Workspaces", systemImage: "square.stack.3d.up", value: Pane.workspaces) {
                    Form {
                        RepoFilesToCopySection(model: model)
                        branchSection
                    }
                    .formStyle(.grouped)
                }

                Tab("Scripts", systemImage: "terminal", value: Pane.scripts) {
                    Form {
                        RepoScriptsSection(model: model)
                    }
                    .formStyle(.grouped)
                }
            }

            Hairline()
            RepoSettingsSaveBar(model: model)
        }
        .background(Palette.windowBackground)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .navigationTitle("\(repo.name) Settings")
        // The tab bar sits where the title would be, and there is one of these windows per
        // project, so without this a window would not say which project it belongs to. The mark
        // comes along, which also puts a preview of it on the two tabs that cannot show one.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // A button rather than a label, because macOS draws a toolbar item as something
                // pressable whatever is put in it. It does what the proxy icon on a document
                // window does: it takes you to the folder.
                Button {
                    Reveal.inFinder(repo.path)
                } label: {
                    HStack(spacing: Metrics.spacingWide) {
                        markTile(size: Metrics.repoIcon)

                        Text(repo.name)
                            .font(Typo.labelEmphasis)
                            .lineLimit(1)
                    }
                }
                .help("Reveal \(repo.name) in Finder")
            }
        }
        .task {
            name = Self.nameWithoutMark(repo.name)
            mark = Self.mark(in: repo.name)
            await model.load()
        }
        // The usual way a settings file changes while this window is open is a `git pull` in a
        // terminal beside it, and coming back to the window is when that becomes visible.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .confirmationDialog(
            "Remove \(repo.name)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove project", role: .destructive, action: removeProject)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalConsequences)
        }
    }

    // MARK: - Project

    private var projectSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .focused($isEditingName)
                    .onSubmit(saveName)
                    .onChange(of: isEditingName) { wasEditing, editing in
                        if wasEditing, !editing { saveName() }
                    }
            }

            markRow

            LabeledContent("Colour") {
                AccentSwatches(selection: accentBinding)
            }

            LabeledContent("Folder") {
                HStack(spacing: Metrics.gutter) {
                    Text(shortPath(repo.path))
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        // For the reason the mark's summary has one: without it a long path
                        // takes the row out of the value column and puts the label above it.
                        .frame(idealWidth: Self.summaryWidth, maxWidth: .infinity, alignment: .leading)
                        .help(repo.path)

                    Button("Reveal") { Reveal.inFinder(repo.path) }

                    Spacer(minLength: 0)
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
    /// the ways out are here: look again, say which file it is, type an emoji, or have the letters
    /// back. A project added before Bloom knew how to look has never been searched, and its button
    /// says `Find icon` rather than pretending a search already happened and found nothing.
    ///
    /// Two lines: the mark, the emoji that can be it, and where the picture came from, then the
    /// buttons under them. The emoji field is on the first line rather than beside the buttons
    /// because a `Form` moves a row out of the value column as soon as the row's ideal width
    /// exceeds it, and a fourth control on the second line is what tips it over at this width.
    /// That is the whole reason the rows here did not line up before.
    private static let summaryWidth: CGFloat = 110

    private var markRow: some View {
        LabeledContent("Mark") {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                HStack(spacing: Metrics.gutter) {
                    markTile(size: Metrics.repoIcon * 1.75)

                    TextField("", text: $mark, prompt: Text("Emoji"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.center)
                        .focused($isEditingMark)
                        .onSubmit(saveName)
                        .onChange(of: isEditingMark) { wasEditing, editing in
                            if wasEditing, !editing { saveName() }
                        }
                        .help("An emoji here goes in front of the name, and becomes the mark.")

                    Text(markSummary)
                        .font(Typo.caption)
                        .foregroundStyle(iconNotice == nil ? Palette.textSecondary : Palette.warning)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        // A sentence asks for as much width as it has letters, and a row that
                        // asks for more than the value column holds is moved out of the column
                        // by the form, which is what made these rows start at four different
                        // places. An ideal width keeps the row where the others are.
                        .frame(idealWidth: Self.summaryWidth, maxWidth: .infinity, alignment: .leading)
                        .help(repo.iconPath ?? "")

                    Spacer(minLength: 0)
                }

                HStack(spacing: Metrics.gutter) {
                    Button(repo.iconSource == .undetected ? "Find icon" : "Look again", action: findIcon)
                    Button("Choose…", action: chooseIcon)
                    // One button for "draw the letters", where there were two. It clears both the
                    // picture and the emoji, because clearing only one of them leaves the other
                    // standing and the button would be lying about what it did.
                    Button("Use initials", action: useInitials)
                        .disabled(!repo.hasIcon && mark.isEmpty)

                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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
        if !mark.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The emoji in the name."
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
    private func useInitials() {
        iconNotice = nil
        if !mark.isEmpty {
            mark = ""
            saveName()
        }
        guard repo.hasIcon else { return }
        Task { await apply(icon: nil, source: .monogram) }
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
        await app.reload()
    }

    /// The name as the sidebar would show it, so the preview is the real thing and not an artist's
    /// impression of it.
    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let emoji = mark.trimmingCharacters(in: .whitespaces)
        if emoji.isEmpty { return trimmed }
        return trimmed.isEmpty ? emoji : "\(emoji) \(trimmed)"
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
                    await app.reload()
                }
            }
        )
    }

    private func saveName() {
        let composed = previewName
        // An empty field is a slip, not an instruction: put the stored name back rather than
        // leaving the project nameless.
        guard !composed.isEmpty else {
            name = Self.nameWithoutMark(repo.name)
            mark = Self.mark(in: repo.name)
            return
        }
        guard composed != repo.name else { return }
        Task { await app.rename(repo, to: composed) }
    }

    /// The leading emoji, if the name has one.
    ///
    /// Asked of `RepoMonogram` rather than worked out again here, so there is exactly one rule in
    /// the app for what counts as a picture. It answers with a single character that is not a
    /// letter or a digit precisely when the name starts with one.
    static func mark(in name: String) -> String {
        let initials = RepoMonogram.initials(for: name)
        guard initials.count == 1, let character = initials.first,
              !character.isLetter, !character.isNumber else { return "" }
        return initials
    }

    static func nameWithoutMark(_ name: String) -> String {
        let mark = mark(in: name)
        guard !mark.isEmpty else { return name }
        return String(name.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Branches

    private var branchSection: some View {
        Section {
            LabeledContent("Branch prefix") {
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    TextField("", text: $model.draft.branchPrefix, prompt: Text("None"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
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
                ForEach(model.loaded.sources, id: \.self) { source in
                    LabeledContent {
                        Button("Open") { Reveal.inEditor(source) }
                    } label: {
                        Text(shortPath(source))
                            .font(Typo.codeSmall)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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

    /// Says what disappears, named and counted, rather than asking "are you sure?" about nothing
    /// in particular. Matching the sidebar's own removal confirmation, which this cannot contradict.
    private var removalConsequences: String {
        let workspaces = app.workspaces.filter { $0.repoID == repo.id }
        let active = workspaces.filter { $0.state == .active }.count

        var text = "Bloom forgets this project"
        switch active {
        case 0 where workspaces.isEmpty: text += "."
        case 0: text += " and its \(workspaces.count) archived workspace\(workspaces.count == 1 ? "" : "s")."
        default:
            text += ", its \(active) active workspace\(active == 1 ? "" : "s") and their transcripts."
        }
        text += " Nothing on disk is deleted: the repository stays where it is"
        if active > 0 {
            text += ", and the worktrees stay checked out, so they have to be removed with `git worktree remove` if they are no longer wanted"
        }
        return text + "."
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
            \(short(origin)) was written for Conductor. Bloom reads it but does not edit it, so             saving states this setting in \(short(destination)) as well. Bloom uses the new value;             Conductor keeps reading the old one until the line is removed by hand.
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

            Spacer(minLength: 0)
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
