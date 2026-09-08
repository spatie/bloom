import Foundation

/// Only immediate child folders are scanned. Typing a path narrows the scan to that parent.
public enum ProjectCompletion {
    public static func matches(
        _ typed: String, locations: [String], home: String, limit: Int = 8
    ) -> [String] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let parents: [String]
        let prefix: String
        if ProjectTarget.looksLikeAPath(query) {
            let expanded = NewProjectPlan.expand(query, home: home)
            guard expanded.hasPrefix("/") else { return [] }
            if query.hasSuffix("/") || query == "~" {
                parents = [expanded]
                prefix = ""
            } else {
                parents = [(expanded as NSString).deletingLastPathComponent]
                prefix = (expanded as NSString).lastPathComponent
            }
        } else {
            parents = locations
            prefix = query
        }
        var paths = Set<String>()
        for parent in Set(parents) {
            let url = URL(fileURLWithPath: parent)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for child in children where child.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                paths.insert(child.standardizedFileURL.path)
            }
        }
        return Array(paths.sorted {
            let left = ($0 as NSString).lastPathComponent
            let right = ($1 as NSString).lastPathComponent
            return left == right ? $0 < $1 : left.localizedStandardCompare(right) == .orderedAscending
        }.prefix(limit))
    }
}
