import AppIntents
import BloomCore

/// `WorkspaceStatus` in a form a Shortcut can compare against.
///
/// A parallel type rather than a conformance on the core enum: the precedence order is decided
/// and tested in `BloomCore`, and the core has no business importing AppIntents to say so. The
/// mapping is written out case by case so that adding a state to the core fails to compile here
/// rather than silently arriving in Shortcuts as something else.
enum WorkspaceStatusAppEnum: String, AppEnum {
    case settingUp
    case awaitingPermission
    case running
    case setupFailed
    case unread
    case merged
    case closed
    case conflicted
    case checksFailing
    case checksRunning
    case checksPassed
    case draft
    case pullRequestOpen
    case changed
    case clean

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace Status")

    static let caseDisplayRepresentations: [WorkspaceStatusAppEnum: DisplayRepresentation] = [
        .settingUp: DisplayRepresentation(title: "Setting up"),
        .awaitingPermission: DisplayRepresentation(title: "Waiting on you"),
        .running: DisplayRepresentation(title: "Agent running"),
        .setupFailed: DisplayRepresentation(title: "Setup failed"),
        .unread: DisplayRepresentation(title: "Unread"),
        .merged: DisplayRepresentation(title: "Merged"),
        .closed: DisplayRepresentation(title: "Pull request closed"),
        .conflicted: DisplayRepresentation(title: "Merge conflicts"),
        .checksFailing: DisplayRepresentation(title: "Checks failing"),
        .checksRunning: DisplayRepresentation(title: "Checks running"),
        .checksPassed: DisplayRepresentation(title: "Checks passed"),
        .draft: DisplayRepresentation(title: "Draft pull request"),
        .pullRequestOpen: DisplayRepresentation(title: "Pull request open"),
        .changed: DisplayRepresentation(title: "Has changes"),
        .clean: DisplayRepresentation(title: "No changes"),
    ]

    init(_ status: WorkspaceStatus) {
        switch status {
        case .settingUp: self = .settingUp
        case .awaitingPermission: self = .awaitingPermission
        case .running: self = .running
        case .setupFailed: self = .setupFailed
        case .unread: self = .unread
        case .merged: self = .merged
        case .closed: self = .closed
        case .conflicted: self = .conflicted
        case .checksFailing: self = .checksFailing
        case .checksRunning: self = .checksRunning
        case .checksPassed: self = .checksPassed
        case .draft: self = .draft
        case .pullRequestOpen: self = .pullRequestOpen
        case .changed: self = .changed
        case .clean: self = .clean
        }
    }
}
