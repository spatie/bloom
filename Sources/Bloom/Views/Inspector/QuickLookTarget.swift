import Foundation

/// Whether a path is worth handing to Quick Look at all.
///
/// There is no public API that answers "can you preview this", so the question is asked the only
/// way it can be: is there a regular, readable, non-empty file at the end of the path. That
/// already covers the cases the inspector actually produces. A deleted file is still a row in the
/// changed list, a directory is still a row in the tree, and both would open a panel that shows
/// the reader nothing they cannot see in the row itself.
enum QuickLookTarget {
    static func url(for path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? 0
        guard size > 0 else { return nil }

        return URL(fileURLWithPath: path)
    }
}
