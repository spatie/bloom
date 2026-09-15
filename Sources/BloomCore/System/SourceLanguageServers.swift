import Foundation

/// At most four recent workspace/language pairs, each with its own short idle timeout.
public actor SourceLanguageServers {
    public static let shared = SourceLanguageServers()
    private struct Key: Hashable { var root: String; var language: Language; var laravel: Bool }
    private struct Entry { var server: SourceLanguageServer; var used: Date }
    private var entries: [Key: Entry] = [:]
    private var watcher: WorktreeWatcher?

    public func server(root: String, language: Language, laravel: Bool = false) async -> SourceLanguageServer {
        let key = Key(root: root, language: language == .blade ? .php : language, laravel: laravel)
        if let entry = entries[key], await !entry.server.isStopped {
            entries[key]?.used = .now
            return entry.server
        }
        if entries.count >= 4, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
           let old = entries.removeValue(forKey: oldest) {
            await old.server.close()
        }
        let server = SourceLanguageServer(laravel: laravel)
        entries[key] = Entry(server: server, used: .now)
        if watcher == nil, laravel {
            watcher = WorktreeWatcher(onFilesChanged: { [weak self] changes in
                Task { await self?.filesChanged(changes) }
            }, onChange: { _ in })
        }
        watcher?.watch(roots: entries.keys.filter(\.laravel).map(\.root))
        return server
    }

    public func definition(root: String, path: String, text: String, offset: Int, language: Language) async throws -> [CodeLocation] {
        var connections = [(await server(root: root, language: language), root)]
        if language == .php || language == .blade, let application = Self.laravelRoot(path: path, root: root) {
            connections.append((await server(root: application, language: language, laravel: true), application))
        }
        let absolute = (path as NSString).isAbsolutePath ? path : (root as NSString).appendingPathComponent(path)
        let results = await withTaskGroup(of: (Int, Result<[CodeLocation], Error>).self) { group in
            for (index, connection) in connections.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await connection.0.definition(root: connection.1,
                            path: absolute, text: text, offset: offset, language: language)))
                    } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<[CodeLocation], Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        var locations: [CodeLocation] = []
        var failure: Error?
        for result in results {
            switch result {
            case let .success(found): locations += found
            case let .failure(error): failure = error
            }
        }
        if locations.isEmpty, let failure { throw failure }
        return locations
    }

    public static func laravelRoot(path: String, root: String) -> String? {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        let file = (path as NSString).isAbsolutePath ? path : (root as NSString).appendingPathComponent(path)
        var directory = URL(fileURLWithPath: file).standardizedFileURL.deletingLastPathComponent()
        while directory.path == root || directory.path.hasPrefix(root + "/") {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("artisan").path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("composer.json").path) { return directory.path }
            if directory.path == root { break }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private func filesChanged(_ changes: [(path: String, type: Int)]) async {
        for entry in entries.filter({ $0.key.laravel }).values { await entry.server.filesChanged(changes) }
    }

    public func close() async {
        let servers = entries.values.map(\.server)
        entries = [:]
        watcher?.stop()
        watcher = nil
        for server in servers { await server.close() }
    }

}
