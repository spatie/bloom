import Foundation

/// Forgets what the terminal panel at the bottom of the inspector left behind.
///
/// The panel is gone, and the height somebody dragged it to is the one piece of it that outlives
/// the code: `@AppStorage("inspector.panelHeight")` is a row in the preferences plist, and a
/// preference nothing reads any more is a preference that will confuse whoever finds it next.
///
/// It runs on every launch rather than once behind a flag. Removing a key that is not there costs
/// a lookup, and a flag guarding a lookup is more state than the thing it is guarding.
enum BottomPanelDefaults {
    private static let keys = ["inspector.panelHeight"]

    static func forget() {
        let defaults = UserDefaults.standard
        for key in keys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}
