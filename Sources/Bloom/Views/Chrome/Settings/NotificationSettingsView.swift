import AppKit
import SwiftUI
import BloomCore

/// The Notifications pane.
///
/// Its own tab rather than four more rows in General. General is four unrelated rows about how the
/// app looks and where it keeps things; this is a master switch, a permission that macOS can revoke
/// behind Bloom's back, and one row per event. Folded into General it would more than double that
/// pane and bury the one control that has to be findable the moment somebody notices they are not
/// being told anything: the button that opens System Settings. The window already gives a feature
/// with its own state a tab of its own, which is what Models, Agents, Prompts and Tools are.
struct NotificationSettingsView: View {
    @AppStorage(NotificationPreferences.enabledKey) private var isEnabled = false
    /// Default on, and matched by `AgentActivityReporter`, which is what actually applies it.
    @AppStorage(DockBadge.settingKey) private var badgesUnread = true

    /// The singleton rather than an `@Environment` value: there is one Notification Center, the
    /// app delegate already talks to the same instance, and a second one would answer a different
    /// question about the permission.
    private let service = NotificationService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about agents I am not watching", isOn: $isEnabled)
                    .disabled(service.isRequestingPermission)
                    .onChange(of: isEnabled, requestPermissionIfTurnedOn)

                if isEnabled, service.isBlockedBySystem {
                    blockedNotice
                }
            } footer: {
                Text("Nothing is sent for the workspace already on screen while Bloom is in front of you.")
                    .settingsFootnote()
            }

            Section("Tell me when") {
                ForEach(NotificationEvent.allCases, id: \.self) { event in
                    EventToggle(event: event)
                }
            }
            .disabled(!isEnabled)

            // Outside the master switch, and outside the "tell me when" list, because the badge
            // is not a notification: it needs no permission, macOS cannot revoke it, and it says
            // nothing while Bloom is in front of you. It belongs on this pane all the same, since
            // this is the pane about being told things.
            Section {
                Toggle("Badge the Dock icon with unread agent results", isOn: $badgesUnread)
            } footer: {
                Text("How many workspaces an agent has finished in and nobody has read yet. It clears as you read them.")
                    .settingsFootnote()
            }

            Section {
                Button("Send a Test Notification", action: service.sendTestNotification)
                    .disabled(!isEnabled || service.isBlockedBySystem)
            } footer: {
                Text("Sends one banner now, so you can see where macOS puts it.")
                    .settingsFootnote()
            }
        }
        .settingsForm()
        .task { await service.refreshAuthorization() }
        // Revoking the permission happens in System Settings, which means it happens while Bloom is
        // in the background. Coming back is the only moment Bloom gets to notice.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.refreshAuthorization() }
        }
    }

    /// Said plainly rather than left as a switch that is on and does nothing. This is the state
    /// somebody lands in by clicking "Don't Allow" once, months ago, and never thinking about it
    /// again.
    /// Not a `SettingsRow`: the leading half is a sentence rather than a label, and a sentence in
    /// the column the rest of the pane lines up against is a column the width of a sentence.
    private var blockedNotice: some View {
        HStack(spacing: Metrics.gutter) {
            Label("macOS is blocking Bloom's notifications", systemImage: "bell.slash.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.spacingSmall)

            Button("Open Notification Settings", action: service.openSystemSettings)
        }
    }

    /// The permission is asked for here and nowhere else: at the moment somebody says they want
    /// notifications, which is the only moment the prompt is an answer to a question they asked.
    /// The switch deliberately stays on if macOS refuses, because it records what the user wants
    /// and the refusal is not theirs. `blockedNotice` is what tells them the difference.
    private func requestPermissionIfTurnedOn(_ was: Bool, _ isOn: Bool) {
        guard isOn else { return }
        Task { await service.requestPermission() }
    }
}

/// One row per event.
///
/// A view of its own so the key can be built from the event. `@AppStorage` takes its key in the
/// initialiser, which a `ForEach` over the cases cannot do from a stored property.
private struct EventToggle: View {
    let event: NotificationEvent
    @AppStorage private var isOn: Bool

    init(event: NotificationEvent) {
        self.event = event
        _isOn = AppStorage(wrappedValue: true, NotificationPreferences.key(for: event))
    }

    var body: some View {
        Toggle(event.title, isOn: $isOn)
            .help(event.detail)
    }
}
