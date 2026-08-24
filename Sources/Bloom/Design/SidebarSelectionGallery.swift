import SwiftUI
import AppKit
import BloomCore

/// The sidebar's selection fill, its marks and the button underneath them, on one page.
///
/// It exists because the question it answers cannot be looked at any other way. The pane's
/// selection is drawn into an `NSTableView`, so `ImageRenderer` cannot photograph it: an offscreen
/// render has no table, no key window and no first responder, and the loud fill is exactly what
/// those three produce. `--snapshot-window` cannot reach it either. A capture run never clicks a
/// row, so every picture of the real window shows the RESTING selection, and the question is about
/// the other one.
///
/// So this is a real `List` with the real `.listStyle(.sidebar)` in a real window, drawing the
/// app's own `SidebarNavRow` and `SidebarSelectionFill`, with the table made first responder by
/// hand and with a top level row and a workspace row selected at once so both fills are in one
/// photograph. Multiple selection is not a state the pane itself offers; it is here only so that
/// the two rows can be compared without flicking between two files.
///
/// The prominent button at the foot is the third colour in the argument: `Palette.accentFill` on a
/// control, which is what "our blue" meant when it was asked for. Before this page's own change it
/// was the only thing on it wearing that colour.
///
///     Bloom --snapshot-gallery <dir> --gallery sidebar-selection
struct SidebarSelectionGallery: View {
    /// Both rows at once, which is the whole point of the page.
    @State private var selection: Set<String> = ["home", "workspace"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sidebar selection")
                .font(Typo.title)
            Text("A top level row and a workspace row, both selected, in a focused source list.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            List(selection: $selection) {
                Section {
                    row("Home", "house", "home")
                    row("Search", "magnifyingglass", "search")
                    row("Archive", "archivebox", "archive")
                }

                Section("Projects") {
                    row("sidebar blue", "arrow.triangle.branch", "workspace")
                    row("limits panel", "arrow.triangle.branch", "other")
                }
            }
            .listStyle(.sidebar)
            .background(FirstResponderProbe())
            .frame(height: 300)

            Button("Choose a folder", systemImage: "folder") {}
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The app's own row and the app's own fill, so the page cannot flatter the pane.
    ///
    /// Emphasized always, which is a true statement about THIS page rather than a shortcut: the
    /// probe below hands the table the keyboard, so the list really is the loud case. The resting
    /// fill is the one `--snapshot-window` can already photograph, since a capture run never
    /// clicks a row, so it is not drawn twice here.
    private func row(_ title: String, _ icon: String, _ tag: String) -> some View {
        SidebarNavRow(title: title, icon: icon)
            .tag(tag)
            .listRowBackground(fill(for: tag))
            .selectedRowInk(isEmphasized: selection.contains(tag))
    }

    @ViewBuilder
    private func fill(for tag: String) -> some View {
        if selection.contains(tag) {
            SidebarSelectionFill(isEmphasized: true)
        }
    }
}

/// Hands the keyboard to the table the list drew, which is what makes its selection the loud fill
/// rather than the resting one.
///
/// A capture run has no pointer, and a source list is only loud while it holds the keyboard, so
/// without this the page would photograph the one state that is not in question. It searches the
/// window downwards for the table rather than upwards from itself: a `.background` sits beside the
/// list's scroll view rather than inside it, so the walk upwards that `RepoHeaderRow` uses to find
/// a row view finds nothing from here.
///
/// Nothing outside this file should want it. The app's own pane is focused by the person using it.
private struct FirstResponderProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, let root = window.contentView,
                  let table = Self.firstTable(under: root)
            else { return }
            window.makeFirstResponder(table)
        }
    }

    private static func firstTable(under view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTable(under: subview) { return found }
        }
        return nil
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// A source list draws the emphasized fill only while it holds the keyboard, and that fill is the
    /// whole page.
    static let sidebarSelection = Gallery(
        name: "sidebar-selection",
        title: "Sidebar selection",
        size: CGSize(width: 520, height: 520),
        needsFocus: true,
        view: { _ in AnyView(SidebarSelectionGallery()) }
    )
}
