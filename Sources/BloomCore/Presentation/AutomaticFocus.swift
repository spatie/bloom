import Foundation

/// Redraws may prepare an unseen window, but must not change input focus in a visible
/// background window. Its responder should survive switching between app instances.
public enum AutomaticFocus {
    public static func mayUpdateResponder(
        applicationIsActive: Bool, windowIsKey: Bool, windowIsVisible: Bool
    ) -> Bool {
        !windowIsVisible || (applicationIsActive && windowIsKey)
    }
}
