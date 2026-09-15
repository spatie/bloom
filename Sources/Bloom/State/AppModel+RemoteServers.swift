import Foundation
import BloomCore

/// What the app does at the moment remote servers are switched on or off in Settings.
///
/// The background loops are not stopped here: `RootView` keys them on the same answer, so they
/// are cancelled with the view task that ran them. What is left for this file is the state a
/// cancelled loop leaves behind, which is an open connection and a window still pointing at a
/// server's workspace.
extension AppModel {
    func remoteServersAvailabilityChanged(to isEnabled: Bool) async {
        guard isEnabled else {
            leaveRemoteSelection()
            // `shutdown` saves the drafts and closes the Mac's side only, so the server's agents
            // keep running and every saved profile is untouched.
            await remoteServer.shutdown()
            return
        }
        // `shutdown` cleared this so a deliberate disconnect stays disconnected. Turning the
        // feature back on is the launch that never happened, and launch starts with it set.
        remoteServer.shouldReconnect = true
    }
}
