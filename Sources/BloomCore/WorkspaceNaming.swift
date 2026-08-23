import Foundation

/// What a model came back with, once Bloom has decided it is usable.
///
/// Both fields are already sanitised: `name` is one line of plain text, `branch` has been through
/// `Git.slug` and `Git.isValidBranchName`. Nothing constructs one of these from raw model output
/// except `WorkspaceNaming.suggestion(from:)`.
public struct WorkspaceNameSuggestion: Sendable, Hashable {
    public let name: String
    public let branch: String

    public init(name: String, branch: String) {
        self.name = name
        self.branch = branch
    }
}

/// Naming a workspace: the codename it wears while the model thinks, and the rules that decide
/// whether the model's answer is fit to use.
///
/// All of it is pure. The process that actually asks a model is `WorkspaceNamer`, and it does no
/// validation of its own: everything that decides what reaches the sidebar is here, where it can
/// be tested against the answers a model actually gives, including the bad ones.
public enum WorkspaceNaming {
    // MARK: - The placeholder

    /// The codename a workspace wears between being created and being named.
    ///
    /// Plants, because the app is called Bloom and because a workspace called Foxglove sitting in
    /// a list beside "Fix the invoices N+1" cannot be mistaken for a description of a task, which
    /// is the whole job of a placeholder. It has to be obvious that the name has not arrived yet
    /// without a spinner saying so.
    ///
    /// One word each, all common enough to be readable at a glance and to be told apart in a
    /// list, and none of them a word that turns up in a prompt about code. There are 140 of them,
    /// so `placeholder(avoiding:)` can hand out a distinct one to more concurrent workspaces than
    /// anyone will ever have open, and only starts appending a number past that.
    public static let placeholders: [String] = [
        "Alyssum", "Amaranth", "Anemone", "Angelica", "Aster", "Azalea", "Basil", "Bay",
        "Begonia", "Bellflower", "Bergamot", "Betony", "Bilberry", "Bindweed", "Bluebell",
        "Borage", "Bramble", "Briar", "Bryony", "Buttercup", "Calendula", "Camellia",
        "Campion", "Caraway", "Cardamom", "Catmint", "Cedar", "Celandine", "Chamomile",
        "Chervil", "Chicory", "Cinnamon", "Clematis", "Clover", "Columbine", "Comfrey",
        "Coriander", "Cornflower", "Cowslip", "Crocus", "Cyclamen", "Daffodil", "Dahlia",
        "Daisy", "Damson", "Dandelion", "Delphinium", "Dogwood", "Elder", "Fennel",
        "Fescue", "Feverfew", "Flax", "Foxglove", "Freesia", "Fuchsia", "Gardenia",
        "Gentian", "Geranium", "Ginger", "Gorse", "Hawthorn", "Hazel", "Heather",
        "Hellebore", "Hibiscus", "Hollyhock", "Honeysuckle", "Hyacinth", "Hydrangea",
        "Hyssop", "Iris", "Ivy", "Jasmine", "Juniper", "Laburnum", "Larkspur", "Lavender",
        "Lilac", "Linden", "Lobelia", "Lovage", "Lupin", "Magnolia", "Mallow", "Marigold",
        "Marjoram", "Meadowsweet", "Mimosa", "Mint", "Mistletoe", "Mullein", "Myrtle",
        "Narcissus", "Nasturtium", "Nettle", "Nigella", "Oleander", "Orchid", "Oregano",
        "Pansy", "Parsley", "Peony", "Periwinkle", "Petunia", "Phlox", "Pimpernel",
        "Poppy", "Primrose", "Privet", "Ragwort", "Rosemary", "Rowan", "Rue", "Saffron",
        "Sage", "Salvia", "Scabious", "Snapdragon", "Snowdrop", "Sorrel", "Speedwell",
        "Spurge", "Sunflower", "Sweetbriar", "Tansy", "Tarragon", "Thistle", "Thyme",
        "Trefoil", "Tulip", "Valerian", "Verbena", "Veronica", "Vervain", "Vetch",
        "Viburnum", "Wallflower", "Willow", "Wisteria", "Wormwood", "Yarrow", "Zinnia",
    ]

    /// A codename no other workspace is currently wearing.
    ///
    /// `taken` is every name already in the store, active and archived alike, so a placeholder
    /// cannot collide with a workspace that is merely out of sight. Past 140 concurrent
    /// placeholders it falls back to a numbered one rather than repeating, because two rows
    /// called Foxglove is the one outcome a placeholder scheme cannot survive.
    ///
    /// `using` is injected so the tests get a fixed sequence rather than a random one.
    public static func placeholder(
        avoiding taken: Set<String>,
        using generator: inout some RandomNumberGenerator
    ) -> String {
        let free = placeholders.filter { !taken.contains($0) }
        if let choice = free.randomElement(using: &generator) { return choice }

        // Everything is spoken for. Number them rather than repeat: `Foxglove 2`, `Foxglove 3`.
        let base = placeholders.randomElement(using: &generator) ?? "Seedling"
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    public static func placeholder(avoiding taken: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        return placeholder(avoiding: taken, using: &generator)
    }

    /// Whether a name is one of ours.
    ///
    /// Used for nothing but reporting: nothing decides whether to overwrite a name by inspecting
    /// its text, because a user is perfectly entitled to call a workspace Foxglove themselves. The
    /// overwrite decision compares against the exact string Bloom wrote, which is what
    /// `WorkspaceNamingRequest` carries.
    public static func isPlaceholder(_ name: String) -> Bool {
        let base = name.components(separatedBy: " ").first ?? name
        return placeholders.contains(base)
    }

    // MARK: - Reading the answer

    /// The longest name the sidebar is asked to carry.
    ///
    /// Well below `Git.title`'s 72, because this one is being written to order and a model that
    /// answers with a paragraph has misunderstood rather than been thorough.
    public static let nameLimit = 60

    /// Pulls a usable suggestion out of whatever the model said, or nothing.
    ///
    /// Returning nil is a first-class outcome and the caller's only job is to fall back. Every
    /// shape of nonsense observed or imagined ends here: an empty answer, an answer with a
    /// newline in it, an answer wrapped in quotes or backticks, a two hundred character sentence,
    /// a branch with a slash or a space or a leading dash in it, a branch git would refuse.
    public static func suggestion(
        name rawName: String?,
        branch rawBranch: String?,
        branchPrefix: String? = nil
    ) -> WorkspaceNameSuggestion? {
        guard let name = cleanName(rawName) else { return nil }
        // A name with no usable branch is still worth having: the workspace gets its name and
        // keeps the branch it was cut with, which is exactly what happens when the rename is
        // refused for a git reason.
        let branch = cleanBranch(rawBranch, prefix: branchPrefix) ?? ""
        return WorkspaceNameSuggestion(name: name, branch: branch)
    }

    /// One line of plain text, or nothing.
    public static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }

        // Only the first non-empty line. A model that explains itself underneath its answer would
        // otherwise put the explanation in the sidebar.
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""

        var name = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Wrapping punctuation, which models add far more often than they are asked to.
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’*"))
        name = name.trimmingCharacters(in: .whitespaces)

        // Control characters would draw as boxes or, worse, reorder the row. Turned into spaces
        // rather than dropped: a tab between two words is a word break, and deleting it outright
        // is what turned "Dark mode\ttoggle" into "Dark modetoggle".
        name = String(String.UnicodeScalarView(name.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F ? " " : $0
        }))

        // Runs of space, so a name pasted out of a wrapped answer does not arrive with a gap in it.
        name = name
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        while name.hasSuffix(".") || name.hasSuffix(":") {
            name = String(name.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        guard !name.isEmpty else { return nil }

        if name.count > nameLimit {
            let cut = name.prefix(nameLimit)
            if let lastSpace = cut.lastIndex(of: " ") {
                name = String(cut[..<lastSpace])
            } else {
                name = String(cut)
            }
            name = name.trimmingCharacters(in: .whitespaces)
        }

        return name.isEmpty ? nil : name
    }

    /// A branch git will accept, or nothing.
    ///
    /// The model's answer is never trusted as a ref. It goes through `Git.slug`, which is the same
    /// function that produces the mechanical branch and already knows what a branch name may
    /// contain, and the result is then checked against `Git.isValidBranchName` with the prefix
    /// applied, because the prefix comes from a settings file and is no more trusted than the
    /// model is.
    public static func cleanBranch(_ raw: String?, prefix: String? = nil) -> String? {
        guard let raw else { return nil }
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        guard !firstLine.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // Models answer with `feature/dark-mode` about half the time even when told not to. The
        // prefix the model invented is dropped and the repository's own put back below, so the
        // setting wins outright rather than the two being concatenated into
        // `freek/feature-dark-mode`.
        let unprefixed: String
        if let slash = firstLine.firstIndex(of: "/") {
            unprefixed = String(firstLine[firstLine.index(after: slash)...])
                .replacingOccurrences(of: "/", with: " ")
        } else {
            unprefixed = firstLine
        }

        let slug = Git.slug(from: unprefixed)
        // `Git.slug` never fails: given nothing usable it answers "workspace", which is exactly as
        // useless as the branch the workspace already has.
        guard !slug.isEmpty, slug != "workspace" else { return nil }

        var branch = slug
        if let prefix, !prefix.isEmpty {
            branch = "\(prefix)/\(slug)"
        }
        guard Git.isValidBranchName(branch) else { return nil }
        return branch
    }

    /// Reads `{"name": ..., "branch": ...}` out of the CLI's `--output-format json` envelope.
    ///
    /// Two places are checked because the CLI puts the answer in both: `structured_output` when a
    /// `--json-schema` was honoured, and `result` as the raw text of the final turn. The envelope
    /// also carries fields Bloom must never read back out, so nothing here touches anything but
    /// those two keys.
    public static func decode(cliOutput: Data) -> (name: String?, branch: String?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: cliOutput)) as? [String: Any] else {
            return nil
        }

        if let structured = root["structured_output"] as? [String: Any] {
            return (structured["name"] as? String, structured["branch"] as? String)
        }

        guard let result = root["result"] as? String,
              let data = result.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return (object["name"] as? String, object["branch"] as? String)
    }

    // MARK: - Whether to ask at all

    /// Whether a workspace about to be created should be named by a model.
    ///
    /// Pure, and here rather than in the app, because every condition is a reason the answer would
    /// be useless or unwanted and each of them is a rule worth pinning down.
    ///
    /// - Parameter userSuppliedName: the user typed a name at creation. Theirs wins outright and
    ///   no model is asked at all, so there is never a codename to overwrite.
    /// - Parameter prompt: empty gives a model nothing to work from.
    /// - Parameter isChatWorkspace: a terminal workspace is opened with a branch and a shell and
    ///   has no task to name.
    /// - Parameter isEnabled: the setting.
    /// - Parameter isAgentAvailable: whether the CLI that would answer is installed. Asked before
    ///   a placeholder is ever written, so a machine with no `claude` on it gets the mechanical
    ///   name straight away rather than a codename that would never resolve.
    public static func shouldName(
        userSuppliedName: String?,
        prompt: String,
        isChatWorkspace: Bool,
        isEnabled: Bool,
        isAgentAvailable: Bool
    ) -> Bool {
        guard userSuppliedName == nil else { return false }
        guard isChatWorkspace else { return false }
        guard isEnabled, isAgentAvailable else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Applying the answer

    /// Whether the automatic rename is still allowed to touch this workspace's name.
    ///
    /// The comparison is against the exact string Bloom wrote at creation, not against the shape
    /// of it. A user who renamed the workspace while the model was thinking, to anything at all
    /// including another plant, keeps their name. A user who typed a name at creation never gets a
    /// placeholder in the first place and so never reaches this.
    ///
    /// Asked at the moment of applying and nowhere earlier. Everything this guards against
    /// happens during the few seconds the question is in flight, so a check made before asking
    /// would be a check made before the thing it is looking for could have happened.
    public static func mayApplyName(current: String, placeholder: String) -> Bool {
        current == placeholder
    }

    /// The sentence shown when the workspace was renamed and its branch was not.
    ///
    /// Built here rather than in a view because it is the only part of this feature the user is
    /// ever told in words, and it should be readable, and changeable, without a window.
    public static func branchNotice(
        name: String,
        branch: String,
        refusal: BranchRenameRefusal
    ) -> String? {
        guard refusal.isWorthReporting else { return nil }
        return "Bloom named this workspace \(name). Its branch is still `\(branch)`, because "
            + refusal.reason + "."
    }
}

// MARK: - The setting

/// Whether Bloom names new workspaces for you.
///
/// User defaults rather than the settings file chain, for exactly the reasons `PromptOverrides`
/// gives: this is a fact about how one person likes to work, it is edited in the Settings window,
/// and that chain has no writer. It sits beside the prompt it switches on, in the same store.
///
/// `@unchecked Sendable` for the same reason as `PromptOverrides`: `UserDefaults` is thread safe
/// and not annotated, and there is no other state here.
public struct WorkspaceNamingPreferences: @unchecked Sendable {
    public static let key = "naming.workspaces"

    /// On by default.
    ///
    /// The argument for off was that this sends the first prompt to a model without being asked.
    /// It does not hold: creating a workspace already sends that same prompt to the same provider
    /// a second later, as the workspace's first turn, so the naming call reveals nothing the
    /// user has not already decided to send. What it costs is under half a cent and a process
    /// that lives for five seconds. What defaulting to off would cost is that nobody would ever
    /// see the feature. The footer in Settings says plainly where the text goes, so turning it off
    /// is an informed choice rather than a discovery.
    public static let fallback = true

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? Self.fallback }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
