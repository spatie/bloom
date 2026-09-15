import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Pane state belongs to an execution origin, not a workspace ID copied from another database.
public enum PaneStateNamespace {
    public static func connectionID(_ endpoint: ServerEndpoint) -> String {
        let parts: [String]
        switch endpoint {
        case .local(let directory):
            parts = ["local-server", URL(fileURLWithPath: directory).standardizedFileURL.path]
        case .ssh(let host, _, let directory, _, _):
            // SSH aliases intentionally remain distinct. Resolving them would require a network/config read.
            parts = ["ssh", host, directory]
        case .https(let address):
            var url = URLComponents(string: address)
            url?.scheme = "https"
            if url?.path.isEmpty == true { url?.path = "/" }
            let hostname = url?.host?.lowercased()
            url?.host = hostname
            url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
            if url?.port == 443 { url?.port = nil }
            parts = ["https", url?.string ?? address]
        }
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func suiteName(connectionID: String, appDomain: String) -> String {
        appDomain + ".remote-panes." + connectionID
    }
}
