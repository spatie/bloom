import SwiftUI

extension Binding {
    /// Whether an optional currently holds a value, as the `Bool` binding every `isPresented:`
    /// modifier wants.
    ///
    /// Alerts and confirmation dialogs are driven from optional state all over the app (the
    /// pending archive, the file about to be reverted, the merge method being confirmed), and
    /// every one of them used to spell the same `Binding(get:set:)` out again inside a view body.
    /// One named helper is easier to read than five copies, and it puts the rule that dismissing
    /// by any route must clear the source of truth in a single place, which is what stops a
    /// refused dialog from re-presenting itself on the next redraw.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        // `Binding`'s accessors are declared `@Sendable` while `Binding` itself is not `Sendable`,
        // so the source has to be handed to them explicitly. It is safe: SwiftUI only ever reads
        // or writes a binding while updating a view, which is main actor work, and every optional
        // this is used on lives on a `@MainActor` type.
        nonisolated(unsafe) let source = self

        return Binding<Bool>(
            get: { source.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { source.wrappedValue = nil }
            }
        )
    }
}
