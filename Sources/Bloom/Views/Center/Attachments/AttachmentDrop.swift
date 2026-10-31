import AppKit
import BloomCore

/// Finder offers file URLs. Screenshot apps may instead offer image bytes or a file that
/// they only write after the drop is accepted. Hovering must never request those bytes.
@MainActor
enum AttachmentDrop {
    static let types: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types.append(contentsOf: PastedImageFormat.allCases
            .flatMap(\.providerTypeIdentifiers)
            .map { NSPasteboard.PasteboardType($0) })
        types.append(NSPasteboard.PasteboardType(ImageDropLoader.genericImageType))
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) })
        return types
    }()

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        ComposerTextView.hasAttachables(on: pasteboard)
            || pasteboard.pasteboardItems?.contains(where: {
                $0.types.contains(NSPasteboard.PasteboardType(ImageDropLoader.genericImageType))
            }) == true
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    static func receive(
        _ sender: any NSDraggingInfo,
        session: AttachmentDropSession,
        onReceive: @escaping @MainActor @Sendable ([AttachmentSource]) -> Bool,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) -> Bool {
        receive(sender.draggingPasteboard, session: session, onReceive: onReceive, onFailure: onFailure)
    }

    /// For a SwiftUI `onDrop`, which hands over item providers and no `NSDraggingInfo`: the drag
    /// pasteboard behind them is the same one, and the one this reads.
    static func receive(
        _ pasteboard: NSPasteboard,
        session: AttachmentDropSession,
        onReceive: @escaping @MainActor @Sendable ([AttachmentSource]) -> Bool,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) -> Bool {
        if let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !promises.isEmpty {
            for promise in promises {
                do {
                    let storage = try PromisedAttachmentStorage()
                    promise.receivePromisedFiles(
                        atDestination: storage.directory, options: [:], operationQueue: .main
                    ) { url, error in
                        let failure = error?.localizedDescription
                        Task { @MainActor in
                            guard session.isActive else { return }
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

        let items = pasteboard.pasteboardItems ?? []
        let offers = pasteboard.attachmentOffers(for: items)
        let inputs = zip(items, offers)
            .map { PasteboardDropProvider(($0.0, $0.1)).provider }
            .filter(ImageDropLoader.canLoad)
        guard !inputs.isEmpty else { return false }

        session.start {
            do {
                let result = try await ImageDropLoader.load(
                    inputs, maxByteCount: AttachmentFiles.maxPastedByteCount
                )
                try Task.checkCancellation()
                let attachments: [AttachmentSource] = result.loaded.map { loaded in
                    switch loaded.value {
                    case .file(let url): return .file(url)
                    case .image(let data, let format):
                        return .image(
                            data,
                            format: format,
                            named: PastedAttachment.filename(format: format.written)
                        )
                    }
                }
                await MainActor.run {
                    guard session.isActive else { return }
                    if !attachments.isEmpty { _ = onReceive(attachments) }
                    if !result.failures.isEmpty {
                        onFailure(result.failures.map(\.message).joined(separator: "\n\n"))
                    }
                }
            } catch is CancellationError {
                // The composer went away. A cancelled drop is a lifecycle outcome, not an alert.
            } catch {
                await MainActor.run {
                    guard session.isActive else { return }
                    onFailure(error.readableMessage)
                }
            }
        }
        return true
    }
}

/// Owns asynchronous provider loads for one drop target. Removing the target cancels every load,
/// and result delivery checks the same lifetime before changing the draft.
@MainActor
final class AttachmentDropSession {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isActive = true

    func start(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    func cancelAll() {
        isActive = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}

/// The AppKit half of `ImageDropProvider`. Transferable and `NSItemProvider` drags arrive at an
/// AppKit destination as pasteboard items carrying their registered uniform types. The byte read
/// happens in the loader rather than on the main actor that accepted the drop.
private final class PasteboardDropProvider: @unchecked Sendable {
    private let item: NSPasteboardItem
    private let offer: PastedAttachment.Offer

    init(_ pair: (NSPasteboardItem, PastedAttachment.Offer)) {
        item = pair.0
        offer = pair.1
    }

    var provider: ImageDropProvider {
        if let path = offer.filePath {
            return ImageDropProvider(
                typeIdentifiers: [ImageDropLoader.fileURLType],
                loadFileURL: { URL(filePath: path) },
                loadData: { _ in throw ImageDropLoader.Failure.unsupported }
            )
        }
        return ImageDropProvider(
            typeIdentifiers: offer.types,
            loadData: { [self] type in
                try Task.checkCancellation()
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else {
                    throw ImageDropLoader.Failure.empty
                }
                return data
            }
        )
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
