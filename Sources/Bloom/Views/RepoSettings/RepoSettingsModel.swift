import SwiftUI
import AppKit
import BloomCore

/// The state behind one project's settings window.
///
/// An editable copy of everything (`RepoSettingsDraft`, in the core so what a Save would write can
/// be asserted in a test) rather than bindings straight into the files, because a half-typed setup
/// script must not be written to a file the team shares. Nothing reaches disk until Save.
@MainActor
@Observable
final class RepoSettingsModel {
    let repo: Repo

    /// What the settings files say right now. The baseline every edit is compared against.
    private(set) var loaded = RepoSettings()
    private(set) var isLoaded = false

    /// The instruction files this project keeps of its own, which outrank the Instructions pane's
    /// fields. Read here rather than in the view, because it is a look at the disk. See
    /// `ProjectInstructions.files(in:)`.
    private(set) var instructionFiles: [ProjectInstructions.Subject: String] = [:]

    /// The editable copy the window's fields are bound to.
    var draft = RepoSettingsDraft()

    /// What the current patterns would actually copy. Recomputed off the main actor.
    private(set) var plan = FilesToCopyPlan()
    private(set) var isResolving = false

    /// Set when the files changed underneath an edit in progress. Nothing is overwritten either
    /// way: the window says so and leaves the choice to the user.
    private(set) var hasExternalChange = false
    private(set) var saveError: String?
    /// The paths the last save touched, so the window can say where the change landed.
    private(set) var savedPaths: [String] = []

    private var resolveTask: Task<Void, Never>?

    init(repo: Repo) {
        self.repo = repo
    }

    // MARK: - Reading

    func load() async {
        let path = repo.path
        let settings = await Task.detached { SettingsLoader.load(repo: path) }.value
        instructionFiles = await Task.detached { ProjectInstructions.files(in: path) }.value
        apply(settings)
        isLoaded = true
        scheduleResolve(immediately: true)
    }

    /// Rereads the files. Called when the window comes back to the front, because the usual way a
    /// settings file changes while this window is open is `git pull` in a terminal beside it.
    ///
    /// An edit in progress is never overwritten. If the file moved under one, the window says so
    /// and Revert is the way to take the new version.
    func refresh() async {
        guard isLoaded else { return }
        let path = repo.path
        let settings = await Task.detached { SettingsLoader.load(repo: path) }.value
        // Outside the guard below, because a `git pull` that adds `.bloom/merge-instructions.md`
        // changes which of the two sources wins without changing a line of any settings file.
        instructionFiles = await Task.detached { ProjectInstructions.files(in: path) }.value
        guard settings != loaded else {
            scheduleResolve()
            return
        }
        if isDirty {
            loaded = settings
            hasExternalChange = true
        } else {
            apply(settings)
        }
        scheduleResolve()
    }

    private func apply(_ settings: RepoSettings) {
        loaded = settings
        hasExternalChange = false
        draft = RepoSettingsDraft(settings)
    }

    func revert() {
        apply(loaded)
        saveError = nil
        savedPaths = []
        scheduleResolve(immediately: true)
    }

    // MARK: - Files to copy

    var globs: [String] { draft.globs }

    /// Debounced, because this runs while the pattern is being typed and every keystroke would
    /// otherwise walk a directory. The work itself is detached: a repository on a network volume
    /// can take long enough to drop frames, and a settings window that stutters while you type is
    /// worse than a preview that lands 250ms late.
    func scheduleResolve(immediately: Bool = false) {
        resolveTask?.cancel()
        let patterns = draft.globs
        let path = repo.path
        isResolving = true
        resolveTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            let resolved = await Task.detached {
                FilesToCopyResolver.resolve(patterns: patterns, in: path)
            }.value
            guard !Task.isCancelled else { return }
            self?.plan = resolved
            self?.isResolving = false
        }
    }

    // MARK: - Writing

    var edits: [SettingsEdit] { draft.edits(comparedTo: loaded) }

    var isDirty: Bool { !edits.isEmpty }

    /// Where an edit to `key` will land, so the window can name the file before anything is
    /// written to it.
    func destination(for key: SettingsKey) -> String {
        SettingsWriter.destination(for: key, in: loaded, repo: repo.path)
    }

    /// Where this script would be stored if Save were pressed now: a file of its own, stated
    /// repository-relative, or `nil` when it stays a string in the settings file.
    ///
    /// Asked of the writer rather than worked out again here, so the path named under the field is
    /// the path Save actually uses and the two can never drift apart.
    func scriptFile(for location: ScriptLocation, script: String) -> String? {
        SettingsWriter.scriptFile(for: location, script: script, in: loaded, repo: repo.path)
    }

    /// The script file the settings name and that is not on disk, if there is one.
    ///
    /// Worth its own line on screen: the field below it is empty, and an empty field otherwise
    /// means "there is no setup script" rather than "there is one and it has gone".
    func missingScriptFile(for location: ScriptLocation) -> String? {
        guard let file = loaded.scriptFiles[location], file.isMissing else { return nil }
        return file.path
    }

    /// The destinations this save would touch.
    var pendingDestinations: [String] {
        Array(Set(edits.map { destination(for: $0.key) })).sorted()
    }

    func save() async {
        let pending = edits
        guard !pending.isEmpty else { return }
        let path = repo.path
        let settings = loaded

        do {
            let written = try await Task.detached {
                try SettingsWriter.write(pending, repo: path, settings: settings)
            }.value
            savedPaths = written
            saveError = nil
        } catch {
            saveError = error.readableMessage
            return
        }

        await load()
    }
}
