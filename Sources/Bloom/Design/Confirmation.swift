import SwiftUI
import AppKit

/// The dialog Bloom asks a yes-or-no question in, drawn by Bloom rather than by AppKit.
///
/// **Why this exists.** Every confirmation in the app was a `.confirmationDialog`, which is a
/// perfectly good control right up to the moment you need one thing out of it that it does not
/// offer. Merging is that moment. It is the only confirmation in the app whose answer is not a
/// loss, and a system dialog can draw its confirm button in exactly two ways: red, or grey.
/// `a595dfb` measured every route to a third colour and found none. `.tint` is ignored on an
/// alert button, and `.foregroundStyle` or `.buttonStyle` do not restyle it, they drop it from the
/// dialog.
///
/// The trap in that measurement is why this is a component and not a repaint. In a system dialog
/// the button's role is two switches wired together and the second one is the safety: the roles
/// that draw grey are exactly the roles that hand the answer to the Return key. A scratch build
/// with the role dropped merged a real pull request on one keystroke. The price of colour, in a
/// system dialog, is the guard. Owning the dialog is what buys both, and owning it means owning
/// the key handling, which is written out under `Keys` below.
///
/// **Why a component and not a bespoke merge dialog.** The app asks eleven of these questions and
/// they have always looked alike. If merging alone became a hand-drawn panel the app would have
/// two kinds of confirmation, and the difference between them would tell the reader nothing: they
/// would differ by when they were written rather than by what they ask. So this is the shape all
/// eleven are meant to end in.
///
/// Three are converted: merging, archiving and throwing a queued message away. The other eight
/// are still `.confirmationDialog`, and the count is written here rather than left to be guessed
/// because this paragraph said six and one for as long as it took four of them to be written.
/// They are the revert in the file header bar and the one in the changed file list, the removal
/// of a project asked from three places (one question, see `ProjectRemoval`), the discard in the
/// file edit pane and the two in `RootView`.
///
/// **Why it looks like the system's.** The eight are still system dialogs and they are the
/// baseline the reader has in their eye, so every number in `Layout` was read off a real
/// `.confirmationDialog` in a window capture rather than chosen. The controls are the system's
/// own `.bordered` buttons, so their plate, their corner radius, their pressed state and their
/// inactive-window rendering are AppKit's and cannot drift away from the five. Measured against
/// the system dialog on the same machine the reproduction is exact except for the buttons, which
/// come out 28 points tall against the alert's 30: an alert button is not a size `controlSize`
/// offers, `.large` is 28 and `.extraLarge` is 36, and 28 for both is worth more than 30 for one.
/// The sheet is 260 by 180 where the system's is 260 by 188, and that difference is those two
/// buttons.
struct ConfirmationSheet: View {
    let confirmation: Confirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Which button the keyboard is on. It starts on the safe one, and `Keys` says why that is
    /// not a detail.
    @FocusState private var focus: Field?

    private enum Field: Hashable { case cancel, confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(confirmation.title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Layout.textInset)
                .padding(.top, Layout.top)

            // Primary ink, not secondary. It is the rung the system alert sets its message in,
            // and this is the paragraph that says the thing cannot be undone, so it is not a
            // caption.
            Text(confirmation.message)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Layout.textInset)
                .padding(.top, Layout.titleToMessage)

            VStack(spacing: Layout.betweenButtons) {
                confirmButton
                cancelButton
            }
            .padding(.horizontal, Layout.buttonInset)
            .padding(.top, Layout.messageToButtons)
            .padding(.bottom, Layout.bottom)
        }
        .frame(width: Layout.width, alignment: .leading)
        // The system alert's ground, and it took a measurement to say that. Sampled off window
        // captures against Bloom's own surfaces: in light it comes out a neutral grey a step
        // below the white pane, in dark a step above the deep blue one and carrying its hue.
        // That is a material rather than a colour, which is why no value from `Palette` is right
        // here and why this one follows whatever window it is opened over.
        .background(.regularMaterial)
        .background(AlertRole())
        // The keyboard is handled entirely on the two buttons below. Nothing at this level adds a
        // shortcut of its own, and that is deliberate: see `Keys`.
        .defaultFocus($focus, .cancel)
    }

    // MARK: - Buttons

    /// The answer that does the thing, drawn in the colour of what it does.
    ///
    /// The system's `.bordered` button with the tone painted on, rather than a control of Bloom's
    /// own. `.tint` does nothing to a bordered button's plate on this SDK, so the colour arrives
    /// in two pieces: `.foregroundStyle` colours the label, and a capsule of the same colour at
    /// `Layout.plateTint` sits behind the plate, which is translucent, so the two composite into
    /// the pale tinted plate macOS 26 draws for a destructive alert button. The control's shape,
    /// its press and its inactive-window state are still AppKit's.
    ///
    /// Deliberately not `.borderedProminent`. A filled button says "press me" about the one
    /// action in this app that cannot be undone, which is the mistake
    /// `PullRequestSummary.continueButton` was changed to stop making: the filled control marks
    /// what is recommended, and nothing is recommended less than the irreversible one.
    private var confirmButton: some View {
        Button { onConfirm() } label: {
            Text(confirmation.confirmLabel).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .foregroundStyle(confirmation.tone.color)
        .background(Capsule().fill(confirmation.tone.color.opacity(Layout.plateTint)))
        .focused($focus, equals: .confirm)
    }

    /// The answer that changes nothing, and the one Escape is wired to.
    private var cancelButton: some View {
        Button { onCancel() } label: {
            Text(confirmation.cancelLabel).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .focused($focus, equals: .cancel)
        // Escape, and only Escape. `.cancelAction` is a key equivalent, not a default button: it
        // does not put Return on this button, and it does not take Return off anything.
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Keys
    //
    // Now that the app draws the dialog, the app owns the risk. Every claim here was measured
    // with real `CGEvent` key presses, first against a scratch build showing this dialog and the
    // system one side by side, one key sequence per launch, where the two answered identically;
    // then inside Bloom itself, on the real merge confirmation, against a `gh` that logged what
    // it was asked to do and refused to do it. Return three times, then Space, Tab, Space: the
    // sheet stayed and `gh pr merge` was never reached. Escape closed it, also without reaching
    // it. Clicking the confirm button did reach it, which is the half that has to still work.
    //
    // **Escape cancels.** The cancel button carries `.keyboardShortcut(.cancelAction)` and that
    // is the whole of it. `3d431e0` exists because six confirmations once put `.defaultAction` on
    // their cancel button to keep Return off the destructive answer, which REPLACED the cancel
    // button's own binding and took Escape away from every confirmation in the app. Nothing here
    // repeats that: the safe answer keeps the key it is meant to have.
    //
    // **Return does nothing.** No button carries `.defaultAction`, so this sheet has no default
    // button and Return is inert. Making the SAFE answer the default is the more usual advice and
    // it is not taken, because on a cancel button `.defaultAction` is exactly the modifier
    // `3d431e0` removed: a button holds one key equivalent, and giving it Return costs it Escape.
    // The choice is between "Return cancels, Escape does nothing" and "Escape cancels, Return
    // does nothing", and the second is the one where the key a Mac user reaches for to back out
    // of a dialog backs out of the dialog. Merging costs a deliberate click, and no keystroke a
    // hand resting on Return can produce.
    //
    // **The keyboard starts on the safe answer.** `.defaultFocus($focus, .cancel)`, and not an
    // `.onAppear` that sets the same thing, which loses to SwiftUI's own initial focus. It
    // matters because a focused button is activated by Space, so where focus starts is a second
    // Return question wearing a different key. Measured: with the buttons made explicitly
    // focusable and no `defaultFocus`, the ring opens on the CONFIRM button, which is the failure
    // this line exists to prevent.
    //
    // What is NOT here is `.focusable()` on the buttons. It looks like the way to give a dialog a
    // tab order and it costs more than it buys: it wraps each button in an unnamed `AXGroup` and
    // moves accessibility focus off the sheet onto that group, which is a worse thing for a
    // screen reader to land on than the sheet itself. Without it the buttons are focusable
    // exactly when macOS says controls are focusable, which is what the other five dialogs do.

    // MARK: - Measurements

    /// Read off the real system dialog rather than chosen, so this and the five that are still
    /// system dialogs cannot drift apart. The top of the file says how.
    private enum Layout {
        static let width: CGFloat = 260
        static let textInset: CGFloat = 21
        static let buttonInset: CGFloat = 15
        static let top: CGFloat = 19
        static let titleToMessage: CGFloat = 8
        static let messageToButtons: CGFloat = 14
        static let betweenButtons: CGFloat = 4
        static let bottom: CGFloat = 15
        /// How much of the tone shows through the button's own plate. macOS 26's destructive
        /// alert button samples as its red at roughly a fifth over the sheet; thirteen percent
        /// here, because this colour goes UNDER a plate that already darkens what is behind it
        /// rather than replacing that plate.
        static let plateTint: Double = 0.13
    }
}

/// Tells the accessibility system that this sheet is an alert.
///
/// Without it the sheet is announced as a sheet and nothing more, where AppKit's own alert sheet
/// carries the description "alert". It is set on the presentation window rather than through an
/// accessibility modifier because the sheet element in the tree IS that window, so nothing put on
/// the SwiftUI content inside it reaches it. Checked against the accessibility tree: the sheet
/// now reports `AXSheet desc=alert`, the same as the system dialog it replaces, with the title,
/// the message and both buttons under it.
private struct AlertRole: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        /// A representable is made before it has a window, so this is set on attachment.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.setAccessibilityLabel("alert")
        }
    }
}

// MARK: - The question

/// One confirmation's worth of words, and what its confirm button means.
///
/// A value rather than five arguments, so a call site reads as the question it asks, and so the
/// app's confirmations can be compared side by side without opening a file each.
struct Confirmation: Equatable, Sendable {
    /// The one line a reader reliably reads. A question, ending in a question mark.
    var title: String
    /// What the answer does, said as consequences rather than as "are you sure?", and cut to the
    /// facts that change the answer. `PullRequest.mergeConfirmation` is the standard.
    var message: String
    var confirmLabel: String
    var cancelLabel: String
    var tone: ConfirmationTone = .destructive
}

/// What the confirm button means, which is the only thing that varies between the app's
/// confirmations and the only thing its colour has to report.
enum ConfirmationTone: Sendable {
    /// The answer loses something. Every confirmation in the app but one.
    case destructive
    /// The answer finishes something. Merging is the only one today, and it is why this has a
    /// second case at all: red on a merge reads as a deletion, and merging is the good end of the
    /// workflow.
    case completing

    /// Green for completing, and it was purple until the owner reported it from a screenshot.
    ///
    /// `Palette.merged` is the colour of a pull request that HAS merged, in this app and on GitHub
    /// and in Conductor. On the button that has not merged anything yet it named the state rather
    /// than the action, so the dialog asking whether to land the branch was already wearing the
    /// answer. `Palette.positive` is the app's one green, the same value a passed check is drawn
    /// in, and green on a merge button is what every tool this one sits beside does.
    ///
    /// No green of its own: the ramp is explicit that this app does not get a second one, and
    /// `positive` is the accent for exactly that reason.
    var color: Color {
        switch self {
        case .destructive: Palette.negative
        case .completing: Palette.positive
        }
    }
}

// MARK: - Presentation

extension View {
    /// Asks a confirmation about a pending value, and runs the action only if the answer is yes.
    ///
    /// Item-driven rather than boolean-driven, because that is the shape the app's confirmations
    /// already have: something is pending, and the dialog exists exactly as long as it is. Every
    /// route out clears the binding first, so a slow action cannot be asked for twice and cannot
    /// find the dialog still standing behind it.
    ///
    /// Window modal rather than application modal, because a `.sheet` is. Measured on a real
    /// build with a second window open: the other window still takes clicks and keystrokes while
    /// this is up, and the window it belongs to takes none.
    func confirmation<Item: Equatable>(
        _ item: Binding<Item?>,
        _ question: @escaping (Item) -> Confirmation,
        onConfirm: @escaping (Item) -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        sheet(isPresented: item.isPresent()) {
            if let value = item.wrappedValue {
                ConfirmationSheet(
                    confirmation: question(value),
                    onConfirm: {
                        item.wrappedValue = nil
                        onConfirm(value)
                    },
                    onCancel: {
                        item.wrappedValue = nil
                        onCancel()
                    }
                )
            }
        }
    }
}
