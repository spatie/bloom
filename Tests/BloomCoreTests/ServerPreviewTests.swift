import Foundation
import Testing
@testable import BloomCore

@Suite("ServerPreview")
struct ServerPreviewTests {
    private let hostname = "bloom.example.ts.net"

    private func status(_ state: String = "Running") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["BackendState": state, "Self": ["DNSName": hostname + "."]])
    }

    private func configuration(
        proxy: String = "http://127.0.0.1:8000", port: Int = 18443,
        funnel: Bool = false, https: Bool = true, host: String? = nil,
        extraPath: Bool = false
    ) throws -> Data {
        var handlers = ["/": ["Proxy": proxy]]
        if extraPath { handlers["/admin/"] = ["Proxy": "http://127.0.0.1:9000"] }
        let authority = "\(host ?? hostname):\(port)"
        return try JSONSerialization.data(withJSONObject: [
            "TCP": [String(port): ["HTTPS": https]],
            "Web": [authority: ["Handlers": handlers]],
            "AllowFunnel": [authority: funnel],
        ])
    }

    @Test func preservesTheFullAddressAcrossDevices() throws {
        let resolved = try ServerPreview.resolve("http://localhost:8000/projects/a%20b?q=x%2Fy#section",
            status: status(), configuration: configuration())
        #expect(resolved == "https://bloom.example.ts.net:18443/projects/a%20b?q=x%2Fy#section")
    }

    @Test func ordinaryHttpsPortHasNoExplicitPort() throws {
        let resolved = try ServerPreview.resolve("http://127.0.0.1:8000/", status: status(), configuration: configuration(port: 443))
        #expect(resolved == "https://bloom.example.ts.net/")
    }

    @Test func refusesPublicFunnel() throws {
        #expect(throws: ServerFailure.self) {
            try ServerPreview.resolve("http://localhost:8000", status: status(), configuration: configuration(funnel: true))
        }
    }

    @Test func keepsSshFallbackWhenServeIsNotConfiguredOrSignedIn() throws {
        let address = "http://localhost:8000"
        #expect(try ServerPreview.resolve(address, status: status("NeedsLogin"), configuration: configuration()) == address)
        #expect(try ServerPreview.resolve(address, status: status(), configuration: Data("{}".utf8)) == address)
        #expect(try ServerPreview.resolve(address, status: status(), configuration: configuration(proxy: "http://127.0.0.1:5173")) == address)
    }

    @Test func doesNotSubstituteUnrelatedOrPartiallyProxiedServices() throws {
        let address = "http://localhost:8000/admin/"
        for config in [
            try configuration(host: "another.example.ts.net"),
            try configuration(https: false),
            try configuration(proxy: "http://127.0.0.1:8000/subpath"),
            try configuration(proxy: "http://example.org:8000"),
            try configuration(proxy: "http://user:password@127.0.0.1:8000"),
            try configuration(extraPath: true),
        ] {
            #expect(try ServerPreview.resolve(address, status: status(), configuration: config) == address)
        }
    }

    @Test func externalAndNonHttpAddressesAreUntouched() throws {
        for address in ["https://example.org", "http://localhost.example.org:8000", "file:///etc/passwd", "http://user:password@localhost:8000"] {
            #expect(try ServerPreview.resolve(address, status: status(), configuration: configuration()) == address)
        }
    }

    @Test func eachDevelopmentPortResolvesIndependently() throws {
        let resolved = try ServerPreview.resolve("http://localhost:5173/@vite/client", status: status(),
            configuration: configuration(proxy: "http://127.0.0.1:5173", port: 15173))
        #expect(resolved == "https://bloom.example.ts.net:15173/@vite/client")
    }

    @Test func previewLookupIsAReadAndSurvivesProtocolRoundTrip() throws {
        let request = ServerRequest(.previewAddress("http://localhost:8000"))
        #expect(!request.operation.mutates)
        #expect(try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}
