import SwiftUI
import AppKit
import BloomCore

/// Native sidebar selection and row content, captured together in a real list.
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
                // One row, as the pane has. Search and Archive stood here and were the same list
                // of workspaces Home draws; see `SidebarSelection`.
                Section {
                    row("Home", "house", "home")
                }

                Section("Projects") {
                    row("workspace row", "arrow.triangle.branch", "workspace")
                    row("limits panel", "arrow.triangle.branch", "other")
                }
            }
            .listStyle(.sidebar)
            .background(FirstResponderProbe())
            .frame(height: 300)

            Button("Choose a folder", systemImage: "folder") {}
                .buttonStyle(.borderedProminent)
                .tint(Palette.controlAccent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ title: String, _ icon: String, _ tag: String) -> some View {
        SidebarNavRow(title: title, icon: icon)
            .tag(tag)
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
