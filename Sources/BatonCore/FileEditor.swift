import Foundation

/// A file read whole, together with the stamp that says which version of it these bytes are.
///
/// The stamp travels with the text rather than being looked up again at save time, because the
/// point of the whole type is to make "the version I showed the user" a value that can be checked
/// against the disk later.
public struct EditableFile: Sendable, Hashable {
    /// Absolute path. Relative paths are refused: this type writes to disk, and a working
    /// directory is not a thing a view can be trusted to have.
    public let path: String
    public let text: String
    public let modifiedAt: Date
    public let size: Int

    public var filename: String { (path as NSString).lastPathComponent }
}

public enum FileEditorError: Error, Sendable, Equatable {
    case notAbsolute(String)
    case missing(String)
    case notText(String)
    case tooLarge(path: String, bytes: Int)
    /// Somebody else wrote the file between the read and the save. Carries the disk's stamp so
    /// the message can say when, rather than only that.
    case changedOnDisk(path: String, at: Date)
    case unreadable(path: String, reason: String)
    case unwritable(path: String, reason: String)
}

extension FileEditorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notAbsolute(path):
            "\(path) is not an absolute path."
        case let .missing(path):
            "\((path as NSString).lastPathComponent) is no longer on disk."
        case let .notText(path):
            "\((path as NSString).lastPathComponent) is not UTF-8 text."
        case let .tooLarge(path, bytes):
            "\((path as NSString).lastPathComponent) is \(bytes / 1_048_576) MB, too large to edit here."
        case let .changedOnDisk(path, at):
            "\((path as NSString).lastPathComponent) changed on disk at "
                + "\(Self.clock.string(from: at)). Your edit was not saved."
        case let .unreadable(path, reason):
            "Could not read \((path as NSString).lastPathComponent): \(reason)"
        case let .unwritable(path, reason):
            "Could not save \((path as NSString).lastPathComponent): \(reason)"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Reading and writing one text file in a worktree an agent may be editing at the same moment.
///
/// Every rule here exists because the other writer is a coding agent, not a second human who
/// would notice a conflict:
///
/// - A read that cannot produce the whole file throws. There is no partial `EditableFile`, so a
///   truncated read cannot become a truncated write.
/// - A read stats, reads, and stats again, and starts over if the two stamps disagree. Otherwise
///   the bytes in hand could belong to a version the recorded stamp does not describe, and the
///   save check would be comparing against a version nobody ever saw.
/// - A save re-reads the file and compares its full contents to the baseline. The modification
///   date is recorded and reported, but the bytes are what the decision uses: two writes inside
///   one filesystem timestamp tick share a date, and a date comparison would wave the second one
///   through.
/// - A save writes atomically and puts the original mode back, so a half-written file never
///   exists and an executable script does not quietly lose its bit.
public enum FileEditor {
    /// Well past any source file. A worktree also holds minified bundles and fixtures, and
    /// putting one of those into a text view helps nobody.
    public static let sizeLimit = 4 * 1_048_576

    /// How far into a file to look for a NUL byte. Git's own binary heuristic reads the first
    /// 8000 bytes, and matching it means the editor refuses exactly the files the diff calls
    /// binary.
    private static let sniffLength = 8_000

    private struct Stamp: Equatable {
        var modifiedAt: Date
        var size: Int
    }

    public static func read(_ path: String) throws(FileEditorError) -> EditableFile {
        guard path.hasPrefix("/") else { throw FileEditorError.notAbsolute(path) }

        // Two attempts, because a single retry covers the one write that lands mid-read. A file
        // being rewritten continuously is not one this editor should open anyway.
        for _ in 0..<2 {
            let before = try stamp(path)
            guard before.size <= sizeLimit else {
                throw FileEditorError.tooLarge(path: path, bytes: before.size)
            }

            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
            } catch {
                throw FileEditorError.unreadable(path: path, reason: error.localizedDescription)
            }

            let after = try stamp(path)
            guard before == after, data.count == after.size else { continue }

            guard !data.prefix(sniffLength).contains(0) else { throw FileEditorError.notText(path) }
            guard let text = String(data: data, encoding: .utf8) else {
                throw FileEditorError.notText(path)
            }
            return EditableFile(
                path: path, text: text, modifiedAt: after.modifiedAt, size: data.count
            )
        }
        throw FileEditorError.changedOnDisk(path: path, at: (try? stamp(path).modifiedAt) ?? Date())
    }

    /// Whether a path is worth offering an editor for at all, answered without reading the whole
    /// file. Cheap enough to call while building a toolbar.
    public static func isEditable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let stamp = try? stamp(path), stamp.size <= sizeLimit else {
            return false
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sniffLength)) ?? Data()
        return !head.contains(0)
    }

    /// Replace the file, but only if it still holds exactly what `baseline` was read from.
    ///
    /// Returns the new baseline, so the caller can keep editing without a round trip that would
    /// reopen the same race it just closed.
    @discardableResult
    public static func write(_ text: String, over baseline: EditableFile) throws(FileEditorError) -> EditableFile {
        let current = try read(baseline.path)
        guard current.text == baseline.text else {
            throw FileEditorError.changedOnDisk(path: baseline.path, at: current.modifiedAt)
        }

        let url = URL(fileURLWithPath: baseline.path)
        // Foundation's atomic write is a write-to-temp-and-rename, and the temp file is born with
        // the process umask rather than the original's mode. Carrying the mode across by hand is
        // what keeps a reverted shell script executable.
        let mode = try? FileManager.default.attributesOfItem(atPath: baseline.path)[.posixPermissions]

        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
        } catch {
            throw FileEditorError.unwritable(path: baseline.path, reason: error.localizedDescription)
        }
        if let mode {
            try? FileManager.default.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: baseline.path
            )
        }
        return try read(baseline.path)
    }

    private static func stamp(_ path: String) throws(FileEditorError) -> Stamp {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw FileEditorError.missing(path)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FileEditorError.missing(path)
        }
        return Stamp(
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0
        )
    }
}
