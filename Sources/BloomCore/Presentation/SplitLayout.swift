import CoreGraphics
import Foundation

/// How the two halves of one split are arranged.
///
/// Named after the arrangement rather than after the rule between them, the way `HStack` and
/// `VStack` are, because that is the thing every call site reasons about. iTerm and Ghostty name
/// the same two splits after the divider instead, so their "vertical split" is this `.horizontal`.
public enum SplitAxis: String, Codable, Sendable, Hashable {
    /// Side by side, divided by a vertical rule. What Cmd+D makes.
    case horizontal
    /// Stacked, divided by a horizontal rule. What Shift+Cmd+D makes.
    case vertical
}

/// Which way the keyboard is reaching for a neighbouring pane.
public enum SplitDirection: String, Sendable, Hashable, CaseIterable {
    case left
    case right
    case up
    case down

    public var axis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// What the View menu's Focus Pane rows are called. Capitalised here rather than by the view,
    /// because a menu item's title is a decision and the raw value is a stored spelling.
    public var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }
}

/// One node of the split tree: either a terminal, or a split holding two more nodes.
///
/// `ratio` is the share of the parent's length the FIRST child gets, so it grows as the divider
/// moves right or down, which is the direction the drag translation already runs in.
public indirect enum SplitNode: Codable, Sendable, Hashable {
    case pane(String)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
}

/// Where a pane ended up, in the coordinate space the caller asked about.
public struct SplitPaneFrame: Sendable, Hashable {
    public var pane: String
    public var frame: CGRect
}

/// One draggable boundary.
public struct SplitDividerFrame: Sendable, Hashable {
    /// Child indices from the root down to the split this divider belongs to. The root split is
    /// the empty path.
    public var path: [Int]
    public var axis: SplitAxis
    public var ratio: Double
    /// The reserved strip between the two panes. A view is free to draw a wider grab target over
    /// it, which is what every terminal on this platform does.
    public var frame: CGRect
    /// The length of the split along its own axis, minus what the divider itself takes. Dividing a
    /// drag in points by this is what turns it into a ratio.
    public var span: Double
}

public struct SplitGeometry: Sendable, Hashable {
    public var panes: [SplitPaneFrame]
    public var dividers: [SplitDividerFrame]
}

/// The split panes of one terminal tab: the tree, which pane has the keyboard, and whether one of
/// them is filling the tab on its own.
///
/// Every mutation here is a value on a value, which is the entire point. The live shells hang off
/// pane ids from somewhere else entirely, so this can be split, closed, resized and round-tripped
/// through a test without a terminal, a window or a run loop existing.
public struct SplitLayout: Codable, Sendable, Hashable {
    public private(set) var root: SplitNode
    /// The pane with the keyboard. Always names a pane that exists.
    public private(set) var focus: String
    /// The pane filling the whole tab, if the user zoomed one.
    public private(set) var zoomed: String?

    /// How small a drag may make either side of a split. A pane at zero is a pane the user cannot
    /// get back without knowing that a divider is hiding on the edge, so neither end is reachable.
    public static let minimumRatio: Double = 0.05

    public init(pane: String) {
        root = .pane(pane)
        focus = pane
    }

    // MARK: - Reading

    /// Every pane, left to right and top to bottom.
    public var panes: [String] { root.panes }

    public var paneCount: Int { root.paneCount }

    public func contains(_ pane: String) -> Bool { root.contains(pane) }

    public var isZoomed: Bool { zoomed != nil }

    // MARK: - Editing

    /// Puts a new pane next to an existing one: to its right for `.horizontal`, below it for
    /// `.vertical`. The new pane takes the keyboard, and a zoom is dropped, because a split the
    /// user cannot see is a split they will think did not happen.
    @discardableResult
    public mutating func split(_ pane: String, axis: SplitAxis, into newPane: String) -> Bool {
        guard contains(pane), !contains(newPane) else { return false }
        root = root.splitting(pane, axis: axis, into: newPane)
        focus = newPane
        zoomed = nil
        return true
    }

    /// Removes a pane and collapses the split that held it, so the survivor takes the whole of
    /// the space both used to share and no childless node is ever left behind.
    ///
    /// Returns false when `pane` was the last one, which is the tab's cue to close itself. The
    /// layout is left untouched in that case: a tree with no panes is not a state this can hold,
    /// and pretending otherwise would only move the problem into every caller.
    @discardableResult
    public mutating func close(_ pane: String) -> Bool {
        guard contains(pane), paneCount > 1, let removal = root.removing(pane),
              let remaining = removal.node else { return false }

        root = remaining
        if zoomed == pane { zoomed = nil }
        // The pane that grew into the closed one's space, which is where the user is looking.
        if focus == pane { focus = removal.promoted ?? remaining.panes[0] }
        return true
    }

    /// Moves a pane next to another one, **keeping its id**.
    ///
    /// A pane id is not a label. `TmuxSessions.sessionName` builds `bloom_<workspace>_<pane>` out
    /// of it, so the id IS the running shell's session name, and `TerminalPaneCensus` lets the
    /// orphan sweep kill every session whose pane id nothing can enumerate. Written as a close
    /// followed by a split, this move would hand the pane a fresh id, orphan the shell the user
    /// was working in, and have the sweep kill it at the next launch. So the tree is rebuilt
    /// around the same id rather than around a new one, and the id set before and after is exactly
    /// equal. `SplitLayoutTests` pins that.
    ///
    /// The pointer map a tab keeps beside this layout needs no edit at all for the same reason:
    /// `WorkspaceTabsStore.Arrangement.contents` is keyed by pane id, and none of them changed. A
    /// move is therefore the one edit to a tab's arrangement that `TabSurgery` has nothing to say
    /// about, because no pane appears and none goes.
    ///
    /// The dissolved split's ratio goes with it and the new one opens at even shares, which is
    /// what `close` and `split` already each do on their own. A moved pane lands the size of half
    /// of what it landed in, not the size it was, because the space it used to have belongs to
    /// whatever grew into it.
    ///
    /// The moved pane takes the keyboard. It is the thing the user just put down, and it is the
    /// one place on screen they are certainly looking at.
    ///
    /// - Parameters:
    ///   - pane: the pane being moved.
    ///   - target: the pane it is being put beside.
    ///   - axis: `.horizontal` to land beside it, `.vertical` to land above or below it.
    ///   - before: leading or top rather than trailing or bottom.
    @discardableResult
    public mutating func move(
        _ pane: String, beside target: String, axis: SplitAxis, before: Bool
    ) -> Bool {
        guard pane != target, contains(pane), contains(target) else { return false }
        // A drop that asks for the arrangement already on screen is refused rather than performed,
        // because performing it would not be free: the split holding the two would be dissolved
        // and reopened at even shares, silently throwing away a divider the user had set.
        guard root.siblingSplit(pane, target).map({ $0.axis != axis || $0.isFirst != before }) ?? true
        else { return false }
        // Nil only for a tree that IS the pane, which is a tab with one pane and nowhere to move
        // it to. The guards above cannot reach that case, since `target` would have to be the same
        // pane, but the tree is what says so rather than a count computed beside it.
        guard let removal = root.removing(pane), let remaining = removal.node else { return false }

        root = remaining.splitting(target, axis: axis, into: pane, before: before)
        focus = pane
        // A zoomed tab shows one pane and no divider, so there is nothing to grab and no
        // neighbour to aim at. Dropped all the same, for the reason `split` drops it: an
        // arrangement the user cannot see is one they will think did not happen.
        zoomed = nil
        return true
    }

    /// Exchanges two panes, keeping both ids, both live views and the shape of the tree.
    ///
    /// What a pane let go over the MIDDLE of another one means. The tab vocabulary reads a middle
    /// drop as "show it here", which for a tab is a replacement; a pane cannot be replaced that
    /// way, because the pane already there is a running shell or a loaded page and nothing about
    /// a drag says to end it. Exchanging the two is the reading that keeps both, and it is what
    /// the gesture looks like it should do.
    ///
    /// Ratios are untouched: each pane inherits the share the other one had, which is the whole of
    /// what "exchange" means on screen.
    @discardableResult
    public mutating func exchange(_ pane: String, with other: String) -> Bool {
        guard pane != other, contains(pane), contains(other) else { return false }
        root = root.exchanging(pane, other)
        // The keyboard follows the pane the user was dragging, wherever it has landed, exactly as
        // it does for a move.
        focus = pane
        return true
    }

    @discardableResult
    public mutating func setFocus(_ pane: String) -> Bool {
        guard contains(pane) else { return false }
        focus = pane
        return true
    }

    /// Moves the keyboard to the neighbour in a direction, if there is one.
    @discardableResult
    public mutating func moveFocus(_ direction: SplitDirection) -> Bool {
        // A zoomed pane is the only one on screen, so there is nothing to move to.
        guard zoomed == nil, let next = neighbour(of: focus, direction: direction) else {
            return false
        }
        focus = next
        return true
    }

    /// Fills the tab with the focused pane, or puts every pane back.
    @discardableResult
    public mutating func toggleZoom() -> Bool {
        guard paneCount > 1 else { return false }
        zoomed = zoomed == nil ? focus : nil
        return true
    }

    // MARK: - Neighbours

    /// The pane a directional move lands on, chosen by where the panes actually are rather than by
    /// their place in the tree. Geometry is what makes a neighbour nested three splits deep as
    /// reachable as a sibling: the tree shape that produced two touching rectangles does not
    /// matter to the user pressing the arrow.
    ///
    /// Ties go to the pane sharing most of the moving pane's edge, which is the one the eye
    /// expects when a tall pane faces two short ones.
    public func neighbour(of pane: String, direction: SplitDirection) -> String? {
        let frames = geometry(in: CGSize(width: 1, height: 1), dividerThickness: 0).panes
        guard let source = frames.first(where: { $0.pane == pane })?.frame else { return nil }

        let epsilon = 1e-9
        var best: (distance: Double, overlap: Double, pane: String)?

        for candidate in frames where candidate.pane != pane {
            let frame = candidate.frame
            let distance: Double
            switch direction {
            case .left: distance = source.minX - frame.maxX
            case .right: distance = frame.minX - source.maxX
            case .up: distance = source.minY - frame.maxY
            case .down: distance = frame.minY - source.maxY
            }
            guard distance >= -epsilon else { continue }

            let overlap: Double = direction.axis == .horizontal
                ? min(frame.maxY, source.maxY) - max(frame.minY, source.minY)
                : min(frame.maxX, source.maxX) - max(frame.minX, source.minX)
            guard overlap > epsilon else { continue }

            if let current = best {
                let closer = distance < current.distance - epsilon
                let sameDistance = abs(distance - current.distance) <= epsilon
                guard closer || (sameDistance && overlap > current.overlap) else { continue }
            }
            best = (distance, overlap, candidate.pane)
        }

        return best?.pane
    }

    // MARK: - Resizing

    public func ratio(at path: [Int]) -> Double? { root.node(at: path)?.ratio }

    /// The single pane on each side of one divider, and nil for a side that is a group of panes
    /// rather than one.
    ///
    /// What decides whether a divider offers something to pick up, and on which of its two sides.
    /// A group cannot be picked up, because `move` moves one pane and grafting a subtree into
    /// another tree is an operation this does not have. Nothing is lost by refusing: every pane is
    /// a leaf, so every pane is a direct child of some split, so every pane has a divider of its
    /// own that offers it. In `a | (b over c)` the outer divider offers `a` and nothing on its
    /// other side, and the inner one offers `b` and `c`.
    ///
    /// Nil for a path that names no split at all.
    public func sides(at path: [Int]) -> (first: String?, second: String?)? {
        guard case .split(_, _, let first, let second)? = root.node(at: path) else { return nil }
        func leaf(_ node: SplitNode) -> String? {
            guard case .pane(let id) = node else { return nil }
            return id
        }
        return (leaf(first), leaf(second))
    }

    /// Moves one divider. Clamped at both ends so neither side can be dragged out of existence.
    @discardableResult
    public mutating func setRatio(_ ratio: Double, at path: [Int]) -> Bool {
        let clamped = min(max(ratio, Self.minimumRatio), 1 - Self.minimumRatio)
        guard let updated = root.settingRatio(clamped, at: path) else { return false }
        root = updated
        return true
    }

    // MARK: - Geometry

    /// Where every pane and every divider lands in a rectangle of this size, with the origin at the
    /// top left and y growing downwards, which is the space SwiftUI lays out in.
    ///
    /// `dividerThickness` is what each split reserves between its two halves. Passing zero gives
    /// panes that touch exactly, which is what the neighbour search wants.
    public func geometry(in size: CGSize, dividerThickness: Double) -> SplitGeometry {
        var panes: [SplitPaneFrame] = []
        var dividers: [SplitDividerFrame] = []
        let bounds = CGRect(origin: .zero, size: size)

        // A zoomed pane is the only thing on screen, dividers included: iTerm and Ghostty both draw
        // the zoom as if the other panes were not there rather than as a pane over the top of them.
        if let zoomed, contains(zoomed) {
            return SplitGeometry(panes: [SplitPaneFrame(pane: zoomed, frame: bounds)], dividers: [])
        }

        func walk(_ node: SplitNode, _ rect: CGRect, _ path: [Int]) {
            switch node {
            case .pane(let id):
                panes.append(SplitPaneFrame(pane: id, frame: rect))

            case .split(let axis, let ratio, let first, let second):
                let total = axis == .horizontal ? rect.width : rect.height
                let span = max(0, total - dividerThickness)
                let head = span * ratio

                if axis == .horizontal {
                    walk(first, CGRect(x: rect.minX, y: rect.minY, width: head, height: rect.height), path + [0])
                    dividers.append(SplitDividerFrame(
                        path: path,
                        axis: axis,
                        ratio: ratio,
                        frame: CGRect(
                            x: rect.minX + head,
                            y: rect.minY,
                            width: dividerThickness,
                            height: rect.height
                        ),
                        span: span
                    ))
                    walk(
                        second,
                        CGRect(
                            x: rect.minX + head + dividerThickness,
                            y: rect.minY,
                            width: span - head,
                            height: rect.height
                        ),
                        path + [1]
                    )
                } else {
                    walk(first, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: head), path + [0])
                    dividers.append(SplitDividerFrame(
                        path: path,
                        axis: axis,
                        ratio: ratio,
                        frame: CGRect(
                            x: rect.minX,
                            y: rect.minY + head,
                            width: rect.width,
                            height: dividerThickness
                        ),
                        span: span
                    ))
                    walk(
                        second,
                        CGRect(
                            x: rect.minX,
                            y: rect.minY + head + dividerThickness,
                            width: rect.width,
                            height: span - head
                        ),
                        path + [1]
                    )
                }
            }
        }

        walk(root, bounds, [])
        return SplitGeometry(panes: panes, dividers: dividers)
    }

    // MARK: - Persistence

    /// JSON, because this is written to user defaults rather than to SQLite: what the user had open
    /// is worth restoring and not worth a table or a migration.
    ///
    /// Sorted keys, and that is not tidiness. Without them the same tree encodes to different bytes
    /// on different calls in the same process, which was measured rather than guessed: two runs of
    /// the phase A migration over one carve produced `{"focus":...,"root":...}` and
    /// `{"root":...,"focus":...}`. That migration writes its new key before it deletes the old one,
    /// so a crash between those two lines leaves it to run again next launch, and "run again" is
    /// only safe to reason about if the second run lands on exactly the first run's bytes.
    /// Decoding never cared about the order, so nothing already on disk is affected.
    public var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public init?(encoded: String) {
        guard let data = encoded.data(using: .utf8),
              var layout = try? JSONDecoder().decode(SplitLayout.self, from: data) else {
            return nil
        }
        layout.repair()
        self = layout
    }

    /// Drops a focus or a zoom naming a pane the tree does not have, which is the only thing a
    /// decoded layout can be wrong about, and pins any ratio a hand-edited file put out of range.
    public mutating func repair() {
        root = root.repaired(minimumRatio: Self.minimumRatio)
        if let zoomed, !contains(zoomed) { self.zoomed = nil }
        if !contains(focus) { focus = root.panes[0] }
    }
}

// MARK: - Tree walking

extension SplitNode {
    var panes: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, _, let first, let second): first.paneCount + second.paneCount
        }
    }

    var ratio: Double? {
        switch self {
        case .pane: nil
        case .split(_, let ratio, _, _): ratio
        }
    }

    func contains(_ pane: String) -> Bool {
        switch self {
        case .pane(let id): id == pane
        case .split(_, _, let first, let second): first.contains(pane) || second.contains(pane)
        }
    }

    func node(at path: [Int]) -> SplitNode? {
        guard let index = path.first else { return self }
        guard case .split(_, _, let first, let second) = self else { return nil }
        return (index == 0 ? first : second).node(at: Array(path.dropFirst()))
    }

    /// `before` puts the new pane on the leading or top side instead of the trailing or bottom
    /// one. Defaulted, so the two callers that only ever open after a pane read as they did.
    ///
    /// It is a real placement rather than a split followed by a swap of what the two panes hold.
    /// `WorkspaceTabsStore.split` does the swap, and for a pane opening on new content that is
    /// harmless, because neither pane is showing anything yet. For a pane being MOVED it is not:
    /// the swap would carry the target's live shell or loaded page into the pane that had just
    /// been made, which is the reparenting `CenterPanesView` exists to avoid.
    func splitting(
        _ pane: String, axis: SplitAxis, into newPane: String, before: Bool = false
    ) -> SplitNode {
        switch self {
        case .pane(let id):
            guard id == pane else { return self }
            return before
                ? .split(axis: axis, ratio: 0.5, first: .pane(newPane), second: .pane(id))
                : .split(axis: axis, ratio: 0.5, first: .pane(id), second: .pane(newPane))

        case .split(let axis0, let ratio, let first, let second):
            return .split(
                axis: axis0,
                ratio: ratio,
                first: first.splitting(pane, axis: axis, into: newPane, before: before),
                second: second.splitting(pane, axis: axis, into: newPane, before: before)
            )
        }
    }

    /// The split whose own two children are exactly these two panes, if there is one, and whether
    /// the first of them is that split's leading or top child.
    ///
    /// What a move asks in order to tell a real rearrangement from a drop onto the arrangement
    /// already on screen. Only a split of two leaves can answer: two panes with anything between
    /// them in the tree are not siblings, and moving one beside the other is a genuine change.
    func siblingSplit(_ pane: String, _ other: String) -> (axis: SplitAxis, isFirst: Bool)? {
        guard case .split(let axis, _, let first, let second) = self else { return nil }
        if case .pane(let head) = first, case .pane(let tail) = second {
            if head == pane, tail == other { return (axis, true) }
            if head == other, tail == pane { return (axis, false) }
        }
        return first.siblingSplit(pane, other) ?? second.siblingSplit(pane, other)
    }

    /// The same tree with two panes in each other's places. Every split, axis and ratio is left
    /// exactly as it was, which is what makes this an exchange rather than two moves.
    func exchanging(_ pane: String, _ other: String) -> SplitNode {
        switch self {
        case .pane(let id):
            if id == pane { return .pane(other) }
            if id == other { return .pane(pane) }
            return self

        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: first.exchanging(pane, other),
                second: second.exchanging(pane, other)
            )
        }
    }

    /// What is left of this subtree without `pane`, or nil when the pane is not in it.
    /// `node` is nil when the subtree WAS the pane, which is how a parent learns to collapse.
    func removing(_ pane: String) -> (node: SplitNode?, promoted: String?)? {
        switch self {
        case .pane(let id):
            return id == pane ? (nil, nil) : nil

        case .split(let axis, let ratio, let first, let second):
            if let hit = first.removing(pane) {
                guard let remaining = hit.node else { return (second, second.panes.first) }
                return (.split(axis: axis, ratio: ratio, first: remaining, second: second), hit.promoted)
            }
            if let hit = second.removing(pane) {
                guard let remaining = hit.node else { return (first, first.panes.last) }
                return (.split(axis: axis, ratio: ratio, first: first, second: remaining), hit.promoted)
            }
            return nil
        }
    }

    func settingRatio(_ ratio: Double, at path: [Int]) -> SplitNode? {
        guard case .split(let axis, let current, let first, let second) = self else { return nil }
        guard let index = path.first else {
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }

        let child = index == 0 ? first : second
        guard let updated = child.settingRatio(ratio, at: Array(path.dropFirst())) else { return nil }
        return index == 0
            ? .split(axis: axis, ratio: current, first: updated, second: second)
            : .split(axis: axis, ratio: current, first: first, second: updated)
    }

    func repaired(minimumRatio: Double) -> SplitNode {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        return .split(
            axis: axis,
            ratio: min(max(ratio.isFinite ? ratio : 0.5, minimumRatio), 1 - minimumRatio),
            first: first.repaired(minimumRatio: minimumRatio),
            second: second.repaired(minimumRatio: minimumRatio)
        )
    }
}
