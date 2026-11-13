import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wren serves mail and its admin API on the sign-in origin. A session URL or redirect must not
/// forward an app password, admin token, account password or uploaded file to another origin.
struct RequestOrigin: Sendable {
    let server: URL

    func allows(_ url: URL?) -> Bool {
        guard let url, let base = URLComponents(url: server, resolvingAgainstBaseURL: true),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = base.scheme?.lowercased(), let host = base.host?.lowercased(), !host.isEmpty,
              base.user == nil, base.password == nil, target.user == nil, target.password == nil
        else { return false }
        let local = ["localhost", "127.0.0.1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return target.scheme?.lowercased() == scheme && target.host?.lowercased() == host
            && (target.port ?? defaultPort) == (base.port ?? defaultPort)
    }

    func validate(_ url: URL?) throws {
        guard allows(url) else { throw JMAPError.unsafeEndpoint }
    }
}

/// A per-task delegate covers data, upload, download and push-stream requests, including injected
/// sessions in tests. Refusing a redirect returns its 3xx response; callers already reject that status.
final class ServerRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: RequestOrigin

    init(server: URL) { origin = RequestOrigin(server: server) }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(origin.allows(request.url) ? request : nil)
    }
}
