import SwiftUI

extension View {
    /// Closes the server window this is applied to when remote servers are switched off, and
    /// closes it straight away if one is opened or restored while they already are.
    ///
    /// On the window's content rather than in `RootView` with `dismissWindow(id:)`, because the
    /// Docker window is a `WindowGroup` keyed on a value and can have several open, and because a
    /// window reopened by an old link or a restored session has to notice for itself. The Updates
    /// pane's polling belongs to the Server Settings window, so closing it is also what stops that.
    func closesWhenRemoteServersAreOff() -> some View {
        modifier(RemoteServerWindowGuard())
    }
}

private struct RemoteServerWindowGuard: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    private let remoteServers = RemoteServerAvailability.shared

    func body(content: Content) -> some View {
        content.onChange(of: remoteServers.isEnabled, initial: true) { _, isEnabled in
            if !isEnabled { dismiss() }
        }
    }
}
