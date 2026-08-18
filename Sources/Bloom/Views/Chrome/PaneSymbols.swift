import AppKit

/// The SF Symbols the pane commands wear, in one place.
///
/// Splitting a pane is offered from four unrelated views: the centre pane's context menu, a tab's
/// context menu, the menu bar, and the AppKit menu a terminal returns from `menu(for:)`. Four
/// literals would drift the first time one of them was renamed, and a menu where Split Right means
/// one glyph here and another there is worse than a menu with no glyphs at all.
///
/// The split pair shows the geometry that results rather than a direction: `2x1` is two columns,
/// which is what Split Right leaves behind, and `1x2` is two rows. An arrow would only say which
/// way something moves, which is the question the reader is not asking.
enum PaneSymbol {
    static let splitRight = "square.split.2x1"
    static let splitDown = "square.split.1x2"
    static let closePane = "xmark.rectangle"
    /// A tab closes to the same glyph its own close button already draws.
    static let closeTab = "xmark"
    static let rename = "pencil"
    static let zoomIn = "arrow.up.left.and.arrow.down.right"
    static let zoomOut = "arrow.down.right.and.arrow.up.left"

    /// The same glyph as an `NSImage`, for the menus that are built in AppKit.
    ///
    /// `NSMenuItem` sizes the image itself, so no symbol configuration is applied here: one set at
    /// a point size would fix the glyph while the menu font still followed the system.
    static func image(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }
}
