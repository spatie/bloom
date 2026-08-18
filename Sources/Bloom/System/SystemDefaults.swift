import Foundation
import BloomCore

/// The two preferences about how Bloom behaves as a piece of the operating system, and the one
/// place their defaults are stated.
///
/// They are registered rather than written, so nothing is persisted until somebody actually
/// touches a switch and "never been set" stays distinguishable from "set back to the default".
///
/// Registration exists because these two keys are each read from more than one place and the reads
/// are not all `@AppStorage`. The menu bar item is AppKit and asks `UserDefaults` directly, where a
/// key that has never been written answers `false` no matter what any view declared as its
/// default; the Settings pane asks through `@AppStorage`, which answers with whatever literal that
/// particular view was written with. Two readers, two answers, and a switch that shows off while
/// the thing it controls is plainly on. A registered default is the only answer all of them share.
/// Main actor isolated because the only callers are view bodies, and because a `static var`
/// guard has to belong to some actor to be legal under strict concurrency.
@MainActor
enum SystemDefaults {
    private static var isRegistered = false

    /// Idempotent, and called from the view modifiers that own these two features before either
    /// of them reads anything. Cheap enough to call on every pass; guarded anyway so the
    /// dictionary is not rebuilt on every redraw.
    static func registerOnce() {
        guard !isRegistered else { return }
        isRegistered = true

        UserDefaults.standard.register(defaults: [
            SleepPrevention.settingKey: SleepPrevention.isOnByDefault,
            MenuBarStatusItem.settingKey: MenuBarStatusItem.isOnByDefault,
        ])
    }
}
