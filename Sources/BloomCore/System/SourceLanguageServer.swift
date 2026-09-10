import Foundation

public enum SourceLanguageServerError: LocalizedError, Sendable {
    case unavailable(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case let .unavailable(name): "Go to Definition needs \(name) installed on your PATH."
        case let .failed(message): message
        }
    }
}

/// A reusable LSP connection. A short idle lifetime lets background indexing finish between clicks.
public actor SourceLanguageServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var frames = LanguageServerFrames()
    private var stopped = false
    private var initialisation: Task<Void, Error>?
    private var idleStop: Task<Void, Never>?
    private var documents: [String: String] = [:]
    private var documentVersion = 0
    private var documentReaders: [String: Int] = [:]
    private var activeRequests = 0

    public var isStopped: Bool { stopped }
    public func close() { stop() }

    public init() {}

    public func definition(root: String, path: String, text: String, offset: Int, language: Language) async throws -> [CodeLocation] {
        idleStop?.cancel()
        let firstRequest = initialisation == nil
        activeRequests += 1
        defer {
            activeRequests -= 1
            if activeRequests == 0 { scheduleIdleStop() }
        }
        if let initialisation {
            try await initialisation.value
        } else {
            let task = Task { try await initialise(root: root, language: language) }
            initialisation = task
            try await task.value
        }
        try Task.checkCancellation()
        let absolute = (path as NSString).isAbsolutePath ? path : (root as NSString).appendingPathComponent(path)
        let uri = URL(fileURLWithPath: absolute).absoluteString
        documentVersion += 1
        if documents[uri] == nil {
            try send(method: "textDocument/didOpen", params: .object(["textDocument": .object([
                "uri": .string(uri), "languageId": .string(Self.languageID(language, path: path)),
                "version": .integer(documentVersion), "text": .string(text),
            ])]))
        } else if documents[uri] != text {
            try send(method: "textDocument/didChange", params: .object([
                "textDocument": .object(["uri": .string(uri), "version": .integer(documentVersion)]),
                "contentChanges": .array([.object(["text": .string(text)])]),
            ]))
        }
        documents[uri] = text
        documentReaders[uri, default: 0] += 1
        defer {
            documentReaders[uri, default: 1] -= 1
            if documentReaders[uri] == 0 {
                // Release the snapshot so agent writes on disk remain visible to the server.
                try? send(method: "textDocument/didClose", params: .object(["textDocument": .object(["uri": .string(uri)])]))
                documents[uri] = nil
                documentReaders[uri] = nil
            }
        }
        let position = CodeLocation.position(in: text, offset: offset)
        let params = JSONValue.object([
            "textDocument": .object(["uri": .string(uri)]),
            "position": .object(["line": .integer(position.line - 1), "character": .integer(position.column - 1)]),
        ])
        var locations = Self.locations(try await request("textDocument/definition", params))
        // A fresh server can answer before SwiftPM's background build settings and index arrive.
        // Keep the connection alive, and give the first lookup a bounded chance to become useful.
        if firstRequest, locations.isEmpty {
            for delay in [1, 2, 3] where locations.isEmpty {
                try await Task.sleep(for: .seconds(delay))
                locations = Self.locations(try await request("textDocument/definition", params))
            }
        }
        return locations
    }

    private func initialise(root: String, language: Language) async throws {
        let command = Self.command(for: language)
        guard let executable = Shell.which(command.0) else { throw SourceLanguageServerError.unavailable(command.0) }
        try Task.checkCancellation()
        try start(executable: executable, arguments: command.1, root: root)
        let rootURI = URL(fileURLWithPath: root).absoluteString
        // The TypeScript syntax server can stop at an import alias while its semantic server
        // starts. Definition-only clients need the semantic answer on the first click.
        let options: JSONValue = language == .typescript || language == .javascript
            ? .object(["tsserver": .object(["useSyntaxServer": .string("never")])]) : .object([:])
        let response = try await request("initialize", .object([
            "processId": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(rootURI),
            "initializationOptions": options,
            "workspaceFolders": .array([.object(["uri": .string(rootURI), "name": .string((root as NSString).lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                "textDocument": .object(["definition": .object(["linkSupport": .bool(true)])]),
            ]),
        ]))
        if let encoding = response["capabilities"]?["positionEncoding"]?.stringValue, encoding != "utf-16" {
            throw SourceLanguageServerError.failed("The language server selected an unsupported position encoding: \(encoding).")
        }
        try send(method: "initialized", params: .object([:]))
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    private static func command(for language: Language) -> (String, [String]) {
        switch language {
        case .swift: ("sourcekit-lsp", [])
        case .javascript, .typescript: ("typescript-language-server", ["--stdio"])
        case .php, .blade: ("intelephense", ["--stdio"])
        case .python: ("pyright-langserver", ["--stdio"])
        case .rust: ("rust-analyzer", [])
        case .go: ("gopls", [])
        case .ruby: ("ruby-lsp", [])
        case .vue: ("vue-language-server", ["--stdio"])
        default: ("a language server for \(language.rawValue)", [])
        }
    }

    private static func languageID(_ language: Language, path: String) -> String {
        if path.hasSuffix(".tsx") { return "typescriptreact" }
        if path.hasSuffix(".jsx") { return "javascriptreact" }
        return language == .shell ? "shellscript" : language.rawValue
    }

    public static func locations(_ result: JSONValue) -> [CodeLocation] {
        let values = result.arrayValue ?? (result.isNull ? [] : [result])
        return values.compactMap { value in
            guard let uri = (value["uri"] ?? value["targetUri"])?.stringValue,
                  let url = URL(string: uri), url.isFileURL,
                  let position = (value["targetSelectionRange"] ?? value["range"])?["start"],
                  let line = position["line"]?.intValue, let column = position["character"]?.intValue,
                  line >= 0, column >= 0, line < Int.max, column < Int.max else { return nil }
            return CodeLocation(path: url.path, line: line + 1, column: column + 1)
        }
    }

    private func start(executable: String, arguments: [String], root: String) throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = Shell.environment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A crashed server must fail the request, never send SIGPIPE to the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        Shell.countSpawn()
        do { try process.run() } catch { stop(); throw error }
        reader = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(data)
            }
            await self?.stop()
        }
    }

    private func send(method: String, params: JSONValue, id: Int? = nil) throws {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        if let id { object["id"] = .integer(id) }
        try write(.object(object))
    }

    private func write(_ value: JSONValue) throws {
        guard !stopped else { throw SourceLanguageServerError.failed("The language server stopped.") }
        let data = try JSONEncoder().encode(value)
        var packet = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        packet.append(data)
        try input.fileHandleForWriting.write(contentsOf: packet)
    }

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(method: method, params: params, id: id)
                    timers[id] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(method == "shutdown" ? 2 : 20))
                        guard !Task.isCancelled else { return }
                        await self?.fail(id, message: "The language server did not respond in time.")
                    }
                } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: Int) {
        try? send(method: "$/cancelRequest", params: .object(["id": .integer(id)]))
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func fail(_ id: Int, message: String) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: SourceLanguageServerError.failed(message))
    }

    private func receive(_ data: Data) {
        do {
            for message in try frames.append(data) {
                if let method = message["method"]?.stringValue {
                    if let id = message["id"] {
                        // Navigation never applies workspace edits requested by a server.
                        let result: JSONValue = method == "workspace/configuration"
                            ? .array((message["params"]?["items"]?.arrayValue ?? []).map { _ in .null }) : .null
                        try? write(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
                    }
                    continue
                }
                guard let id = message["id"]?.intValue else { continue }
                if let error = message["error"] {
                    fail(id, message: error["message"]?.stringValue ?? "The language server could not find a definition.")
                } else {
                    timers.removeValue(forKey: id)?.cancel()
                    pending.removeValue(forKey: id)?.resume(returning: message["result"] ?? .null)
                }
            }
        } catch { stop() }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        idleStop?.cancel()
        initialisation?.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        reader?.cancel()
        reader = nil
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        let requests = pending.values
        pending.removeAll()
        for continuation in requests { continuation.resume(throwing: SourceLanguageServerError.failed("The language server stopped.")) }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// LSP frames count UTF-8 bytes, and a pipe read may split a header or contain several messages.
public struct LanguageServerFrames: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data)
        guard buffer.count <= 16_777_216 else { throw SourceLanguageServerError.failed("Language server response too large.") }
        var messages: [JSONValue] = []
        while let header = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let fields = String(decoding: buffer[..<header.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            guard let field = fields.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(field.dropFirst(15).trimmingCharacters(in: .whitespaces)),
                  length >= 0, length <= 16_777_216 else { throw SourceLanguageServerError.failed("Invalid language server frame.") }
            let start = header.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { break }
            let end = buffer.index(start, offsetBy: length)
            guard let value = JSONValue.parse(Data(buffer[start..<end])) else { throw SourceLanguageServerError.failed("Invalid language server JSON.") }
            messages.append(value)
            buffer = Data(buffer[end...])
        }
        return messages
    }
}
