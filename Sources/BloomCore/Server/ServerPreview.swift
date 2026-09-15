import Foundation

/// Preview addresses belong to the server. A private Serve URL can be opened by another device
/// without depending on an SSH forward on the Mac that first opened the workspace.
public enum ServerPreview {
    public static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(url.host?.lowercased() ?? "")
    }

    static func resolve(_ address: String) async throws -> String {
        guard let url = URL(string: address), isLoopback(url),
              let executable = Shell.which("tailscale") else { return address }
        let status = try await Shell.run(executable, ["status", "--json"], timeout: .seconds(5))
        guard status.ok else { return address }
        let state = try JSONDecoder().decode(Status.self, from: Data(status.stdout.utf8))
        guard state.backendState == "Running" else { return address }
        let serve = try await Shell.run(executable, ["serve", "status", "--json"], timeout: .seconds(5))
        guard serve.ok else { throw ServerFailure("Could not read the server's private preview configuration.") }
        return try resolve(address, status: Data(status.stdout.utf8), configuration: Data(serve.stdout.utf8))
    }

    static func resolve(_ address: String, status: Data, configuration: Data) throws -> String {
        guard let input = URL(string: address), isLoopback(input),
              ["http", "https"].contains(input.scheme?.lowercased() ?? ""),
              input.user == nil, input.password == nil,
              var result = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return address }
        let state = try JSONDecoder().decode(Status.self, from: status)
        guard state.backendState == "Running", let dns = state.node?.dnsName else { return address }
        let hostname = dns.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard hostname.hasSuffix(".ts.net"), hostname.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }) else { return address }
        let config = try JSONDecoder().decode(Configuration.self, from: configuration)
        let inputPort = input.port ?? (input.scheme == "https" ? 443 : 80)
        for authority in (config.web ?? [:]).keys.sorted() {
            guard let endpoint = URLComponents(string: "https://" + authority),
                  endpoint.host == hostname, let port = endpoint.port,
                  (1...65_535).contains(port), config.tcp?[String(port)]?.https == true,
                  let handlers = config.web?[authority]?.handlers, handlers.count == 1,
                  let proxy = handlers["/"]?.proxy, let target = URL(string: proxy),
                  isLoopback(target), target.scheme == input.scheme,
                  target.user == nil, target.password == nil,
                  target.path.isEmpty || target.path == "/",
                  target.query == nil, target.fragment == nil,
                  (target.port ?? (target.scheme == "https" ? 443 : 80)) == inputPort else { continue }
            guard config.allowFunnel?[authority] != true else {
                throw ServerFailure("This preview uses public Tailscale Funnel. Configure private Tailscale Serve for this port before opening it in Bloom.")
            }
            result.scheme = "https"
            result.host = hostname
            result.port = port == 443 ? nil : port
            return result.string ?? address
        }
        return address
    }

    private struct Status: Decodable {
        var backendState: String?
        var node: Node?
        enum CodingKeys: String, CodingKey { case backendState = "BackendState", node = "Self" }
    }

    private struct Node: Decodable {
        var dnsName: String?
        enum CodingKeys: String, CodingKey { case dnsName = "DNSName" }
    }

    private struct Configuration: Decodable {
        var tcp: [String: Listener]?
        var web: [String: Web]?
        var allowFunnel: [String: Bool]?
        enum CodingKeys: String, CodingKey { case tcp = "TCP", web = "Web", allowFunnel = "AllowFunnel" }
    }

    private struct Listener: Decodable {
        var https: Bool?
        enum CodingKeys: String, CodingKey { case https = "HTTPS" }
    }

    private struct Web: Decodable {
        var handlers: [String: Handler]?
        enum CodingKeys: String, CodingKey { case handlers = "Handlers" }
    }

    private struct Handler: Decodable {
        var proxy: String?
        enum CodingKeys: String, CodingKey { case proxy = "Proxy" }
    }
}
