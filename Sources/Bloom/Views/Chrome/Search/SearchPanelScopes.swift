import SwiftUI
import BloomCore

/// The chips at the head of the panel's list: Everything, Workspaces, Transcripts, Archived, each
/// with its count.
///
/// **Home's own control, not a second one.** It is the same segmented picker over the same
/// `HomeScope.offered(searching:)` with the same `HomeScopeCounts.badge`, so the two surfaces
/// cannot offer different chips or different numbers for one machine. They split the answer by
/// what kind of thing matched rather than filtering rows, which is the distinction Home already
/// draws between browsing and searching.
///
/// Tab and Shift+Tab step them, which is why the picker is never given the keyboard: the field
/// keeps it, and `SearchPanelKeys` decides what Tab means. See `MenuSearchField`.
struct SearchPanelScopes: View {
    var counts: HomeScopeCounts
    @Binding var scope: HomeScope

    var body: some View {
        Picker("Scope", selection: $scope) {
            ForEach(HomeScope.offered(searching: true), id: \.self) { scope in
                Text(title(for: scope))
                    .tag(scope)
                    .accessibilityLabel(accessibilityLabel(for: scope))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, Metrics.spacingSmall)
        .help("Choose which kind of thing the answer is narrowed to")
    }

    /// Every chip carries its own number here, where Home's strip prints only two of them.
    ///
    /// **That is a difference from Home and it is deliberate.** On Home the numbers were five
    /// figures across a strip somebody was reading past; here there are four chips, they exist
    /// only while a search is running, and the number is the reason to press one: "Transcripts 14"
    /// is what tells you the answer you want is in the half not on screen.
    private func title(for scope: HomeScope) -> String {
        let label = scope.label(searching: true)
        let count = counts.count(of: scope, searching: true)
        return count == 0 ? label : "\(label) \(count)"
    }

    private func accessibilityLabel(for scope: HomeScope) -> String {
        let label = scope.label(searching: true)
        let count = counts.count(of: scope, searching: true)
        return count == 0 ? label : "\(label), \(count)"
    }
}
