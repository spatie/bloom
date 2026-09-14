# Navigation and presentation

Use `NavigationStack` or `NavigationSplitView` for screens whose navigation they model. Preserve
Bloom's custom workspace tabs and AppKit window coordination when those provide the needed behaviour.

Value-based destinations suit a data-driven navigation path. `NavigationLink(destination:)` is
still valid for a local destination; mixing it with value-based navigation is not automatically
a bug. Check which destination registration wins, path restoration and back-navigation behaviour.

Use `sheet(item:)` when an optional model determines the presented sheet. Keep sheet identity
stable and ensure dismissal clears the right state. A Boolean sheet is appropriate when no item
is needed.

Attach dialogs near their triggering control for correct presentation context. Give destructive
choices explicit labels and roles. Preserve focus and keyboard behaviour on presentation and dismissal.
