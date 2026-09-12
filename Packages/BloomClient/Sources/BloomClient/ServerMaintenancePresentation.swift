import Foundation

/// Reports use public maintenance snapshots only. Request envelopes and access keys never enter
/// the copyable diagnostic path, and both native clients describe the same server-owned jobs.
public enum ServerMaintenancePresentation {
    public static func date(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: value)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: value)
        }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    public static func report(server: String, components: [ServerMaintenanceComponent], jobs: [ServerMaintenanceJob],
                              failure: ServerMaintenanceFailure?) -> String {
        var sections = ["Bloom Server maintenance", server]
        sections.append(components.map { component in
            [component.title, "Installed: " + (component.installedVersion ?? "Unavailable"),
             "Available: " + (component.availableVersion ?? "Unavailable"), component.detail].joined(separator: "\n")
        }.joined(separator: "\n\n"))
        sections.append(jobs.map { job in
            ([job.component.title + " " + job.targetVersion, job.phase.title, "Job: " + job.id,
              "Updated: " + job.updatedAt] + (job.message.map { [$0] } ?? []) + job.logs.map(\.message))
                .joined(separator: "\n")
        }.joined(separator: "\n\n"))
        if let failure { sections.append([failure.message, failure.recovery].joined(separator: "\n")) }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
