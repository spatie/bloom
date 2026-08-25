import Foundation

/// Where a pull request the picker offers came from.
///
/// Two ways in, and they cost different things. A listed one has already been fetched, so its
/// title, its author and its head are on the row before anything is clicked. A typed one is a
/// number or a URL somebody put in the search field, which is worth offering (a closed pull
/// request, somebody else's, or the hundred and first of a busy repository is never in the list)
/// but which nothing knows anything about until gh is asked.
///
/// The typed case carries the text as it was typed rather than the number alone, and that is the
/// whole reason it is not a bare `Int`: `WorkspaceCheckoutResolver.problem` compares the
/// repository half of a pasted URL against this project, and pasting another project's pull
/// request into this sheet otherwise resolves quietly to whatever this repository has as number
/// 42.
public enum PullRequestOffer: Sendable, Hashable {
    case listed(PullRequestListing)
    case typed(PullRequestReference, text: String)
}

/// One row the source picker can offer, over the three verbs the picker exists to put side by
/// side.
///
/// The bug that forced this: the create sheet's "Start from" menu listed "New branch from <name>"
/// for every branch in the project and filed "Open an existing branch" underneath all of them,
/// unsearchable. Picking a colleague's branch out of the top of that list cuts a fresh branch off
/// their head, so the workspace opens empty and its Changes tab says nothing differs. The two
/// verbs are one keystroke apart in intent and were a screenful apart on the menu, so the picker
/// draws them as two sections with the same branch in both, and every row says which verb it is.
public enum WorkspaceSource: Sendable, Hashable, Identifiable {
    /// Cut a fresh branch off a named ref. What Bloom could always do.
    case newBranch(from: String)
    /// Check out a branch somebody has already written on.
    case existingBranch(ExistingBranch)
    case pullRequest(PullRequestOffer)

    /// Identity is what the row names, never where it sits. See `WorkspaceSourcePicker`: a
    /// selection pinned to a position in a list that reranks under an open panel selects whatever
    /// has since moved into that slot. The prefix is what keeps a branch offered under both verbs
    /// from being one row twice.
    public var id: String {
        switch self {
        case .newBranch(let ref): "new:\(ref)"
        case .existingBranch(let branch): "branch:\(branch.name)"
        case .pullRequest(.listed(let request)): "pr:\(request.number)"
        case .pullRequest(.typed(let reference, _)): "typed:\(reference.number)"
        }
    }

    /// What this row will do, said in the row rather than only in the section heading. The
    /// headings scroll; the verb is the thing that was wrong.
    public var verb: String {
        switch self {
        case .newBranch: "New branch from"
        case .existingBranch: "Open"
        case .pullRequest: "Review"
        }
    }

    /// The thing the row names, as it is written everywhere else in the app.
    ///
    /// A listed pull request is named after the **branch it lands on**, not after its number and
    /// title, and that is the fix for the bug this whole picker keeps being rewritten around.
    /// `searchText` has always matched a pull request by its head, with a comment saying why ("the
    /// figma one" is how a head is recalled long after the title has gone), so searching a branch
    /// name already found the row. It found a row reading `#362 Lay the app-side styling
    /// foundation`, on which the searched word appeared nowhere, and the owner scrolled past his
    /// own result and concluded the branch was gone. A match nobody can see is not a match.
    ///
    /// The number and the title are not lost: they are `detail`, on the line underneath. The
    /// branch is what was searched for and what is being chosen, so the branch is what the row is
    /// called. The fallback matters, because an older gh does not answer `headRefName` at all.
    public var name: String {
        switch self {
        case .newBranch(let ref): ref
        case .existingBranch(let branch): branch.name
        case .pullRequest(.listed(let request)):
            request.qualifiedHead.isEmpty ? "#\(request.number) \(request.title)" : request.qualifiedHead
        case .pullRequest(.typed(let reference, _)): "#\(reference.number)"
        }
    }

    /// The tab this row belongs under, which is the verb it carries and nothing else.
    public var tab: WorkspaceSourceTab {
        switch self {
        case .newBranch: .newBranch
        case .existingBranch, .pullRequest: .existingBranch
        }
    }

    /// The second line of the row, or nothing.
    ///
    /// Only a listed pull request has one, and it is what `name` used to be. A branch with no pull
    /// request needs no second line, and drawing an empty one would make the list ragged for the
    /// sake of a shape.
    public var detail: String? {
        guard case .pullRequest(.listed(let request)) = self else { return nil }
        guard !request.qualifiedHead.isEmpty else { return nil }
        return "#\(request.number) \(request.title)"
    }

    /// What is worth saying after the name, or nothing.
    ///
    /// "In use by" wins over every other note. A branch git will refuse to check out twice is the
    /// one fact on the row that changes what selecting it does, so it is never crowded out by an
    /// author's login.
    public var note: String? {
        switch self {
        case .newBranch:
            return nil
        case .existingBranch(let branch):
            if let holder = branch.inUseBy { return holder.note }
            return branch.isLocal ? nil : "remote"
        case .pullRequest(.listed(let request)):
            let author = request.author.isEmpty ? nil : request.author
            return [request.isDraft ? "draft" : nil, author]
                .compactMap { $0 }
                .joined(separator: ", ")
                .nonEmpty
        case .pullRequest(.typed):
            return "Look it up on GitHub"
        }
    }

    /// What is already holding this branch, when something is.
    ///
    /// Selecting such a row does not create anything: git refuses one branch in two worktrees, so
    /// the honest answer to "open this branch" is whatever already has it. These rows used to be
    /// dropped from the list altogether, which answered the question by pretending the branch did
    /// not exist.
    ///
    /// Only one of the two answers is somewhere Bloom can take you. A workspace is selected; a
    /// worktree belonging to Conductor or to nobody is named, with its path, so the owner can go
    /// and close it himself. See `BranchHolder`.
    public var heldBy: BranchHolder? {
        guard case .existingBranch(let branch) = self else { return nil }
        return branch.inUseBy
    }

    /// What the sheet is being asked to open, or nil for the rows that are not a checkout: a new
    /// branch, which is the sheet's own route, and a typed pull request, which has to be resolved
    /// against gh before there is anything to open.
    public var checkout: WorkspaceCheckout? {
        switch self {
        case .newBranch: nil
        case .existingBranch(let branch): .branch(branch)
        case .pullRequest(.listed(let request)): .pullRequest(request)
        case .pullRequest(.typed): nil
        }
    }

    /// Everything a query is matched against. A pull request is looked for by all four of the
    /// things people remember about one: its number, its title, its author and the branch it is
    /// on. The branch is in here because "the figma one" is how a head is recalled long after the
    /// title has gone.
    var searchText: String {
        switch self {
        case .newBranch(let ref): ref
        case .existingBranch(let branch): branch.name
        case .pullRequest(.listed(let request)):
            "#\(request.number) \(request.title) \(request.author) \(request.headRefName)"
        case .pullRequest(.typed(let reference, let text)): "#\(reference.number) \(text)"
        }
    }
}

public extension WorkspaceSource {
    /// What the button that opens the picker says, and the other half of the fix.
    ///
    /// "on" against "from", because that is the distinction the old menu buried: a workspace that
    /// sits on somebody else's branch and one that cuts a fresh branch off it are different jobs,
    /// and the control that reports which was chosen has to be readable without opening anything.
    /// A pull request reports its head rather than its number for the same reason. The number is
    /// already on the heading above the box and on the chip under it, and neither of those says
    /// whether the worktree lands on that head or beside it.
    static func label(for checkout: WorkspaceCheckout?, baseBranch: String) -> String {
        guard let checkout else { return "from \(baseBranch)" }
        return "on \(checkout.preferredLocalBranch)"
    }
}

/// Everything the picker has to offer, and the ranking over it.
///
/// A value rather than a function over three arrays, because the panel asks it the same question
/// on every keystroke and the sections have to be built from one answer: a row that is in the
/// drawn list and not in the list the arrow keys walk is a row that cannot be selected.
public struct WorkspaceSourceOffering: Sendable, Hashable {
    public let pullRequests: [PullRequestListing]
    public let branches: [ExistingBranch]
    /// What a new branch may be cut from. The project's branches, which is a different list from
    /// `branches` above: that one has the default branch and the pull request heads taken out of
    /// it, and both are perfectly good things to cut a branch from.
    public let baseBranches: [String]

    public init(
        pullRequests: [PullRequestListing] = [],
        branches: [ExistingBranch] = [],
        baseBranches: [String] = []
    ) {
        self.pullRequests = pullRequests
        self.branches = branches
        self.baseBranches = baseBranches
    }

    /// The "Open, and carry on" section: what somebody else has already written.
    ///
    /// Pull requests first. A repository with anything open has one or two of them and a few
    /// hundred branches, so a list that opened on branch names would need scrolling before the
    /// thing most people came for was on screen.
    public var openRows: [WorkspaceSource] {
        pullRequests.map { .pullRequest(.listed($0)) } + branches.map { WorkspaceSource.existingBranch($0) }
    }

    /// The "New branch from" section: Bloom's original and still ordinary route.
    public var newBranchRows: [WorkspaceSource] {
        baseBranches.map { .newBranch(from: $0) }
    }

    /// Ranks the whole offering against what is in the search field.
    ///
    /// Pure and `nonisolated`, like `FileMatch.search` and for the same reason: it runs on every
    /// keystroke, over a list that is a few hundred branches long in any repository worth the
    /// name, and none of that belongs on the actor drawing the panel.
    public nonisolated func search(query: String, limit: Int = 40) -> WorkspaceSourceMatches {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceSourceMatches(
            query: trimmed,
            open: typedRows(for: trimmed) + Self.rank(openRows, query: trimmed, limit: limit),
            new: Self.rank(newBranchRows, query: trimmed, limit: limit)
        )
    }

    /// The row for a number or a URL that was typed rather than picked.
    ///
    /// Nothing is offered when the list already answers the number, because the listed row knows
    /// the title, the author and the base, and an identical looking row that costs a gh call to
    /// find that out is a coin flip nobody can see. The parsing is
    /// `WorkspaceCheckoutPlan.parseReference`, which already knows every shape a pull request
    /// arrives in.
    private func typedRows(for query: String) -> [WorkspaceSource] {
        guard let reference = WorkspaceCheckoutPlan.parseReference(query) else { return [] }
        guard !pullRequests.contains(where: { $0.number == reference.number }) else { return [] }
        return [.pullRequest(.typed(reference, text: query))]
    }

    /// The same shape of ranking `FileMatch.search` does: a hit anywhere keeps the row, a hit in
    /// the name it is known by pushes it up. Ties keep the order they arrived in, which is newest
    /// first for pull requests and alphabetical for branches, so an empty field reads as a list
    /// rather than as a shuffle.
    private nonisolated static func rank(
        _ rows: [WorkspaceSource], query: String, limit: Int
    ) -> [WorkspaceSource] {
        guard !query.isEmpty else { return Array(rows.prefix(limit)) }

        var scored: [(row: WorkspaceSource, score: Int, position: Int)] = []
        scored.reserveCapacity(rows.count)
        for (position, row) in rows.enumerated() {
            guard let score = FuzzyMatch.score(row.searchText, query: query) else { continue }
            let nameBonus = FuzzyMatch.score(row.name, query: query) ?? 0
            scored.append((row, score + nameBonus, position))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.position < rhs.position
        }
        return scored.prefix(limit).map(\.row)
    }
}

/// Which of the two things the picker can do is on screen.
///
/// The two verbs used to be two sections of one scrolling list, one above the other, so that the
/// choice could be made with both answers in view. That was right about the choice and wrong about
/// the search: half the offering was below the fold, the headings scrolled away, and "New branch
/// from" and "Open, and carry on" are not words anybody reads before they start typing. They are
/// tabs now, and the tab carries a sentence saying where a commit ends up, which is the only real
/// difference between them and the thing neither heading ever said.
///
/// What tabs cost, written down because it is not fixed and should not be forgotten: they make the
/// verb be chosen before the search, and people arrive knowing a branch name rather than the
/// vocabulary. `WorkspaceSource.name` naming a pull request after its head is what keeps that from
/// being the trap it was.
public enum WorkspaceSourceTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Cut a fresh branch off whatever is picked. The common case, so it leads.
    case newBranch
    /// Carry on a branch or a pull request that already exists.
    case existingBranch

    public var id: String { rawValue }

    /// The tab strip's own words. Both start with a verb so neither reads as a category.
    public var title: String {
        switch self {
        case .newBranch: "Create new branch"
        case .existingBranch: "Continue on existing branch"
        }
    }

    /// The line under the strip.
    ///
    /// Both halves open on the same three words so the eye lands on the fourth and reads only the
    /// difference. Both say where a commit ends up and what merging does with it, because that is
    /// the whole distinction: on a new branch the merge is yours to do later, and on an existing
    /// one the merge already belongs to that branch and your commits ride it.
    ///
    /// **Both fit on one line at the width the panel opens at, and the first one did not.** It was
    /// "Commits land on a new branch. Merging it brings them into the branch you pick here.", which
    /// measured at 436 points, the panel's 460 less its gutters, wraps after "pick" and leaves
    /// "here." alone on a second line. That cost a word of nothing to read and made the panel a
    /// line taller on one tab than the other, so switching tabs moved the search field under the
    /// pointer. One clause instead of two sentences says the same thing inside the width.
    public var explanation: String {
        switch self {
        case .newBranch:
            "Commits land on a new branch, and merge into the branch you pick here."
        case .existingBranch:
            "Commits land on the branch you pick here, and merge when it does."
        }
    }

    /// What the search field says. Only one tab can be given a pull request number to look up.
    public var searchPlaceholder: String {
        switch self {
        case .newBranch: "Search branches to start from"
        case .existingBranch: "Search branches and pull requests, or paste a pull request"
        }
    }

    /// The next tab along, wrapping, for the keyboard.
    public func stepped(by step: Int) -> WorkspaceSourceTab {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        return all[(index + step + all.count) % all.count]
    }
}

/// What the panel draws, in the order the arrow keys walk it.
public struct WorkspaceSourceMatches: Sendable, Hashable {
    /// What was searched for, so the empty state can say it rather than shrugging. See
    /// `MenuEmptyRow`, which is where that sentence is drawn everywhere else in the app.
    public let query: String
    public let open: [WorkspaceSource]
    public let new: [WorkspaceSource]

    public init(query: String = "", open: [WorkspaceSource] = [], new: [WorkspaceSource] = []) {
        self.query = query
        self.open = open
        self.new = new
    }

    /// Whether there is nothing at all, in either tab. The panel uses the per tab answer; this one
    /// is for asking whether the offering is empty rather than whether a tab is.
    public var isEmpty: Bool { open.isEmpty && new.isEmpty }

    /// What one tab draws, and the only rows its keyboard may reach.
    ///
    /// The keyboard walks this and the panel draws it, from the same value, so Return cannot pick
    /// something other than the highlighted row. It is scoped to the tab rather than spanning
    /// both, because a highlight that can step into a tab nobody can see is a Return that opens
    /// something off screen.
    public func rows(in tab: WorkspaceSourceTab) -> [WorkspaceSource] {
        switch tab {
        case .newBranch: new
        case .existingBranch: open
        }
    }

    public func isEmpty(in tab: WorkspaceSourceTab) -> Bool { rows(in: tab).isEmpty }

    /// Where the highlight lands after a step, given what is highlighted now.
    ///
    /// Here rather than in the panel because it is the whole of the keyboard's behaviour and a
    /// decision taken in a view is a decision nothing can test. It wraps at both ends, which is
    /// what every menu on the Mac does, and it answers with the first row when nothing is
    /// highlighted yet, so the first press of Down after typing does not swallow itself.
    public func stepped(
        from current: WorkspaceSource?, by step: Int, in tab: WorkspaceSourceTab
    ) -> WorkspaceSource? {
        let rows = rows(in: tab)
        guard !rows.isEmpty else { return nil }
        guard let current, let index = rows.firstIndex(of: current) else {
            return step < 0 ? rows.last : rows.first
        }
        let next = (index + step + rows.count) % rows.count
        return rows[next]
    }

    /// What stays highlighted when the list changes under the field: the same row if it survived
    /// the new query, otherwise the best one there is now. A highlight left pointing at a row that
    /// has been filtered out is a Return that does nothing, and one left pointing into the other
    /// tab is worse, so switching tab settles through here too.
    public func settled(
        after current: WorkspaceSource?, in tab: WorkspaceSourceTab
    ) -> WorkspaceSource? {
        let rows = rows(in: tab)
        guard let current, rows.contains(current) else { return rows.first }
        return current
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
