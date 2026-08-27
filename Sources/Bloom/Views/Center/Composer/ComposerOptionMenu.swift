import SwiftUI

/// One of the composer's per-turn pickers: model, effort, output style, permission mode.
///
/// They are per turn rather than per app on purpose. A setting that lives in a preferences window
/// is a setting nobody changes per task, and per task is exactly the granularity these need.
///
/// The rows themselves are `ComposerOptionItems`, which exists so `MenuProbe` can photograph the
/// real ones without a `Menu` label to hang them off.
struct ComposerOptionMenu: View {
    var options: [ComposerOption]
    /// When set, the rows are grouped under headings instead of run together. The model menu is
    /// the one that needs it: with two backends a flat list of five names says nothing about which
    /// agent each name belongs to, and picking a name is picking an agent.
    var sections: [ComposerModelSection]?
    /// A disabled line under the rows, for something the menu has to say rather than offer. Two
    /// pickers use it and both use it to describe the selected row, because a row's own sentence
    /// is the only thing that says what picking it would do and an `NSMenu` row is one line with
    /// no room for it. The permission mode menu adds what is absent to that: Codex has no Plan
    /// mode, and a picker that simply dropped it would leave somebody who knows Bloom has one
    /// wondering where it went.
    var footnote: String?
    var selection: String
    /// What the list is a list of, drawn as the menu's own heading, or nil when the items name
    /// their own category and a heading over them would only be a word to read past.
    ///
    /// Effort is Low through Max and permission mode is Ask through Plan: bare adjectives and
    /// bare verbs that say nothing about what they are settings for. Models are Opus 5 and Sonnet
    /// 5, which are names, and the chip the menu opened from is already showing one of them.
    var heading: String?
    var systemImage: String
    var tint: Color = Palette.textSecondary
    /// Drops the word and keeps the glyph, for a footer that has run out of room. The tooltip and
    /// the accessibility label still say which picker this is, so nothing is lost but the width.
    var isCompact: Bool = false
    var help: String
    var onSelect: @MainActor (String) -> Void

    var body: some View {
        Menu {
            ComposerOptionItems(
                options: options,
                sections: sections,
                footnote: footnote,
                selection: selection,
                heading: heading,
                help: help,
                onSelect: onSelect
            )
        } label: {
            ComposerControlLabel(
                systemImage: systemImage,
                text: isCompact ? nil : label,
                tint: tint,
                showsMenuIndicator: true
            )
        }
        // `.button` plus `.plain` is the only combination that lets the label keep its own height.
        // The indicator is hidden because the label already draws one on the row's baseline.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Vertically fixed only. Fixed in both axes the three pickers were incompressible, and an
        // HStack whose children all refuse to shrink overflows rather than truncating: in a split
        // pane the model picker fell off the leading edge while the attach and send buttons fell
        // off the trailing one. `ComposerFooterView` drops the words first; this is what lets what
        // is left give a few more points before anything is pushed off the row.
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(label)
    }

    private var label: String {
        ComposerOption.label(for: selection, in: sections?.flatMap(\.options) ?? options)
    }
}
