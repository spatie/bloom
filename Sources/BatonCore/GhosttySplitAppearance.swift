import Foundation

/// How Ghostty tells a focused split pane apart from the rest.
///
/// Kept apart from `GhosttyTheme` because these two keys are not colours the terminal renders
/// with: they say how the pane that does NOT have the keyboard is faded out, which is a question
/// only a window with more than one pane in it ever asks.
///
/// Theme files are not consulted. A Ghostty theme is a palette, and a user who picks one has not
/// thereby asked for a different dimming.
public struct GhosttySplitAppearance: Sendable, Hashable {
    /// `unfocused-split-opacity`. Ghostty's own default is 0.7.
    public var unfocusedOpacity: Double?
    /// `unfocused-split-fill`. What the dimmed pane is composited over. Ghostty falls back to the
    /// terminal background when it is not set.
    public var unfocusedFill: GhosttyColor?
    /// `split-divider-color`. Read for the same reason as the other two: a user who has said what
    /// the rule between two panes looks like has said it about this app as well.
    public var dividerColor: GhosttyColor?

    public init(
        unfocusedOpacity: Double? = nil,
        unfocusedFill: GhosttyColor? = nil,
        dividerColor: GhosttyColor? = nil
    ) {
        self.unfocusedOpacity = unfocusedOpacity
        self.unfocusedFill = unfocusedFill
        self.dividerColor = dividerColor
    }

    public var isEmpty: Bool {
        unfocusedOpacity == nil && unfocusedFill == nil && dividerColor == nil
    }

    /// - Parameter sources: file contents, LOWEST precedence first, the same order
    ///   `GhosttyConfigLoader.configPaths()` returns them in.
    public static func resolve(sources: [String]) -> GhosttySplitAppearance {
        var appearance = GhosttySplitAppearance()

        for source in sources {
            for entry in GhosttyConfigParser.parse(source) {
                // An empty value is Ghostty's reset, so it clears rather than being ignored: that
                // is how a later file undoes what an earlier one set.
                let reset = entry.value.isEmpty

                switch entry.key {
                case "unfocused-split-opacity":
                    guard !reset else {
                        appearance.unfocusedOpacity = nil
                        continue
                    }
                    // Ghostty documents the range as zero to one and ignores anything else. Zero
                    // itself is pushed off the floor: a pane nobody can see is not a pane.
                    guard let value = Double(entry.value), value > 0, value <= 1 else { continue }
                    appearance.unfocusedOpacity = value

                case "unfocused-split-fill":
                    appearance.unfocusedFill = reset ? nil : GhosttyColor(hex: entry.value)
                        ?? appearance.unfocusedFill

                case "split-divider-color":
                    appearance.dividerColor = reset ? nil : GhosttyColor(hex: entry.value)
                        ?? appearance.dividerColor

                default:
                    break
                }
            }
        }

        return appearance
    }

    /// Reads the user's config files. Nothing found means Ghostty said nothing, which leaves
    /// Baton's own dimming in charge.
    public static func load(paths: [String] = GhosttyConfigLoader.configPaths()) -> GhosttySplitAppearance {
        resolve(sources: paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) })
    }
}
