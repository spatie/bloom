import BloomCore

/// The check runs of one workflow, grouped the way GitHub groups them.
struct CheckRunGroup: Identifiable {
    var workflow: String
    var runs: [CheckRun]

    var id: String { workflow }

    static func build(from runs: [CheckRun]) -> [CheckRunGroup] {
        Dictionary(grouping: runs) { $0.workflowName ?? "Checks" }
            .map { workflow, runs in
                CheckRunGroup(
                    workflow: workflow,
                    runs: runs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { $0.workflow.localizedStandardCompare($1.workflow) == .orderedAscending }
    }
}
