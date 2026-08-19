import SwiftUI

/// Which scene the keyboard is in.
///
/// `BloomCommands` is installed on the application's menu bar, and the menu bar is shared by every
/// window the app owns: the main window, Settings, and each project's settings window. A command
/// that reads `AppModel.selectedModel` therefore fires against the main window's selection no
/// matter which window is key, which is wrong for anything that acts on a workspace and actively
/// harmful for Close Session, because it holds Cmd+W.
///
/// Cmd+W is the case that has to be fixed rather than merely noted. Two menu items cannot share a
/// key equivalent: Close Session sits in the File menu above the standard Close, so AppKit finds
/// it first and the window's own Close never fires. In Settings that meant Cmd+W left the Settings
/// window open and closed a session in the window behind it.
///
/// The marker is published by `RootView`, so it is present exactly while the main window is the
/// focused scene. A disabled item does not consume its key equivalent: AppKit keeps looking, finds
/// the standard Close underneath, and the Settings window closes the way every other window on the
/// Mac does.
struct MainWindowFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// True while the main window is the focused scene, nil in every other scene.
    var isMainWindowFocused: Bool? {
        get { self[MainWindowFocusKey.self] }
        set { self[MainWindowFocusKey.self] = newValue }
    }
}
