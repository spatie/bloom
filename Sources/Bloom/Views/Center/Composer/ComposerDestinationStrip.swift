import SwiftUI
import BloomCore

/// One chat this composer could be pointed at.
///
/// A value rather than a `Session`, so the strip compares on what it draws and a poll that
/// rewrites the session rows without changing a title does not redraw the menu.
struct ComposerDestination: Identifiable, Hashable {
    var id: SessionID
    var title: String

    /// What the menu row says. The strip's own sentence is `ReviewDestination.label`; this is the
    /// name on its own, so an untitled chat is still something to aim at.
    var name: String { title.isEmpty ? PaneNaming.untitledChat : title }
}

/// The line above a composer that says where a message goes, and, when there is more than one
/// place it could go, lets the reader pick.
///
/// **Asked for: a review is not always about the chat that happens to be in front.** The review
/// pane used to say "Messages are sent to Chat" and mean the workspace's active session, so
/// redirecting a review meant leaving the diff to make another chat active, which moves the whole
/// window and loses the reader's place. The comments themselves belong to the workspace rather
/// than to a chat, so which conversation they are handed to is a choice, and this is where it is
/// made. `ReviewDestination` holds what the choice resolves to when the chosen chat is closed
/// under it.
///
/// A plain line when there is nothing to choose between, and that is deliberate: a menu that
/// opens onto one item, already ticked, teaches the reader that the control does nothing.
struct ComposerDestinationStrip: View {
    /// The whole sentence, `ReviewDestination.label` or whatever the caller says instead.
    var label: String
    /// Everywhere this composer could send. Fewer than two leaves the line unpressable.
    var destinations: [ComposerDestination] = []
    /// Which of them it is pointed at now.
    var selected: SessionID?
    /// Nil leaves the line unpressable however many destinations were passed, which is what the
    /// chat pane's own composer wants: it is already in the conversation it sends to.
    var onSelect: ((SessionID) -> Void)?

    private var isChoosable: Bool {
        onSelect != nil && ReviewDestination.isChoosable(sessions: destinations.map(\.id))
    }

    var body: some View {
        Group {
            if isChoosable, let onSelect {
                Menu {
                    // A picker rather than a row of buttons, so the chat being sent to carries the
                    // tick the reader is looking for when they open this to check rather than to
                    // change.
                    Picker("Send to", selection: Binding(
                        get: { selected },
                        set: { if let id = $0 { onSelect(id) } }
                    )) {
                        ForEach(destinations) { destination in
                            Text(destination.name).tag(SessionID?.some(destination.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    line(showsIndicator: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Choose the chat this review is sent to")
                .accessibilityLabel(label)
                .accessibilityHint("Choose the chat this review is sent to")
            } else {
                line(showsIndicator: false)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
    }

    /// The same line either way, with a chevron only when there is somewhere else to send. A
    /// pressable thing that looks exactly like an unpressable one is the reason the indicator is
    /// drawn here rather than left to the menu, whose own indicator sits at the far edge of the
    /// pane and reads as belonging to nothing.
    private func line(showsIndicator: Bool) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "bubble.left")
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsIndicator {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textTertiary)
        .contentShape(Rectangle())
    }
}
