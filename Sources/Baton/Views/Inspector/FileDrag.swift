import SwiftUI
import AppKit

/// Dragging a row out of the inspector hands over the file itself.
///
/// `NSItemProvider(contentsOf:)` registers a file representation under the file's own type, which
/// is what Finder, an editor and a mail compose window all reach for. A provider built from the
/// path string instead would drop as text into anything that accepts text, so the receiver would
/// get a sentence about the file rather than the file.
///
/// Both lists carry a single selection, so a drag is always one file. Nothing here would have to
/// change for a multiple selection beyond handing the modifier more than one path.
enum FileDrag {
    /// Nil for anything there is nothing to hand over: a deleted file, a path git still lists but
    /// the agent removed, an unreadable one. Starting a drag that resolves to nothing leaves the
    /// receiver with an empty drop, which reads as the app being broken rather than the file being
    /// gone.
    static func provider(for path: String) -> NSItemProvider? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        return NSItemProvider(contentsOf: URL(fileURLWithPath: path))
    }
}

/// The drag image: the icon Finder would draw for the same file.
///
/// The icon is read in `body` rather than by the caller, so the disk hit happens when a drag
/// actually starts instead of once per row on every pass through a list that can hold thousands.
private struct FileDragPreview: View {
    var path: String

    /// The size AppKit drags a file at from a list, so the image under the cursor matches what
    /// leaves a Finder window.
    private static let side: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: Self.side, height: Self.side)
    }
}

private struct FileDragModifier: ViewModifier {
    var path: String

    func body(content: Content) -> some View {
        // Whether the file is still there is asked when the drag begins rather than in `body`,
        // because deciding it here would stat every visible row on every pass through the list.
        // A provider with nothing registered in it is refused by every destination, which is the
        // right outcome for a row whose file the agent deleted.
        content.onDrag {
            FileDrag.provider(for: path) ?? NSItemProvider()
        } preview: {
            FileDragPreview(path: path)
        }
    }
}

extension View {
    /// Makes the row draggable as the file at `path`, with that file's icon under the cursor.
    func fileDrag(path: String) -> some View {
        modifier(FileDragModifier(path: path))
    }
}
