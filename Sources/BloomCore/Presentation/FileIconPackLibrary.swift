import Foundation
import Observation

/// One load per pack, shared by every file row and settings window. Downloads outlive the view
/// that started them, and results remain keyed by pack when the user switches during a download.
@MainActor @Observable
public final class FileIconPackLibrary {
    public private(set) var packs: [FileIconPack: FileIconPackInstaller.Pack] = [:]
    public private(set) var loading: Set<FileIconPack> = []
    public private(set) var errors: [FileIconPack: String] = [:]
    @ObservationIgnored private var tasks: [FileIconPack: Task<Void, Never>] = [:]
    private let loader: @Sendable (FileIconPack) async throws -> FileIconPackInstaller.Pack

    public init(loader: @escaping @Sendable (FileIconPack) async throws -> FileIconPackInstaller.Pack) {
        self.loader = loader
    }

    @discardableResult
    public func prepare(_ choice: FileIconPack, retry: Bool = false) -> Task<Void, Never>? {
        guard choice != .bloom, packs[choice] == nil else { return nil }
        if let task = tasks[choice] { return task }
        guard retry || errors[choice] == nil else { return nil }
        errors[choice] = nil
        loading.insert(choice)
        let task = Task {
            defer {
                loading.remove(choice)
                tasks[choice] = nil
            }
            do {
                packs[choice] = try await loader(choice)
            } catch {
                errors[choice] = error.localizedDescription
            }
        }
        tasks[choice] = task
        return task
    }
}
