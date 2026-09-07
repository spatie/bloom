import AppKit
import BloomCore

/// Finder offers file URLs. Screenshot apps may instead offer image bytes or a file that
/// they only write after the drop is accepted. Hovering must never request those bytes.
@MainActor
enum AttachmentDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL]
        + PastedImageFormat.allCases.map { NSPasteboard.PasteboardType($0.uti) }
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        ComposerTextView.hasAttachables(on: pasteboard)
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    static func receive(
        _ pasteboard: NSPasteboard,
        onReceive: @escaping @MainActor @Sendable ([AttachmentSource]) -> Bool,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) -> Bool {
        let sources = ComposerTextView.attachables(on: pasteboard)
        if !sources.isEmpty { return onReceive(sources) }

        guard let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !promises.isEmpty else { return false }

        for promise in promises {
            do {
                let storage = try PromisedAttachmentStorage()
                promise.receivePromisedFiles(
                    atDestination: storage.directory, options: [:], operationQueue: .main
                ) { url, error in
                    let failure = error?.localizedDescription
                    Task { @MainActor in
                        if let failure {
                            onFailure(failure)
                        } else {
                            _ = onReceive([.promisedFile(url, storage)])
                        }
                    }
                }
            } catch {
                onFailure(error.localizedDescription)
            }
        }
        return true
    }
}

/// Kept alive by the asynchronous attachment copy, then removed. A receiver can deliver
/// several files into this directory, so deleting it after the first file would lose the rest.
final class PromisedAttachmentStorage: Hashable, Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "bloom-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func == (lhs: PromisedAttachmentStorage, rhs: PromisedAttachmentStorage) -> Bool {
        lhs.directory == rhs.directory
    }

    func hash(into hasher: inout Hasher) { hasher.combine(directory) }
}
