import Foundation
import XCTest
@testable import WrenKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RequestSecurityTests: XCTestCase {
    func testOriginIncludesSchemeHostAndEffectivePort() {
        let origin = RequestOrigin(server: URL(string: "https://MAIL.test")!)
        for link in ["https://mail.test/a", "https://MAIL.test:443/a?b=1"] {
            XCTAssertTrue(origin.allows(URL(string: link)), link)
        }
        for link in ["http://mail.test/a", "https://mail.test:8443/a", "https://evil.test/a",
                     "https://mail.test.evil.test/a", "https://mail.test@evil.test/a",
                     "https://user:secret@mail.test/a", "file:///tmp/a", "/relative"] {
            XCTAssertFalse(origin.allows(URL(string: link)), link)
        }
        XCTAssertFalse(origin.allows(nil))
        XCTAssertFalse(RequestOrigin(server: URL(string: "http://mail.test")!).allows(URL(string: "http://mail.test/a")))
        XCTAssertTrue(RequestOrigin(server: URL(string: "http://127.0.0.1:8000")!).allows(URL(string: "http://127.0.0.1:8000/a")))
        XCTAssertFalse(RequestOrigin(server: URL(string: "http://127.0.0.1:8000")!).allows(URL(string: "http://127.0.0.1:8001/a")))
    }

    func testUnsafePlainRequestsAndTransfersNeverReachTransport() async throws {
        Mock.handler = { _ in XCTFail("Unsafe request reached transport"); return [:] }
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "test", password: "fake", http: Mock.session)
        for path in ["https://evil.test/steal", "//evil.test/steal", "http://mail.test/plain", "https://mail.test:444/steal"] {
            do {
                _ = try await client.request("POST", path: path, body: ["password": "fake"], headers: ["X-Wren-Admin": "fake"])
                XCTFail("Accepted \(path)")
            } catch { XCTAssertEqual(error as? JMAPError, .unsafeEndpoint) }
            do {
                _ = try await client.transfer("GET", path: path)
                XCTFail("Accepted \(path)")
            } catch { XCTAssertEqual(error as? JMAPError, .unsafeEndpoint) }
        }
    }

    func testServerAdvertisedEndpointsCannotReceiveCredentialsOffOrigin() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "test", password: "fake", http: Mock.session)
        Mock.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mail.test/jmap/session")
            return ["apiUrl": "https://evil.test/api", "downloadUrl": "https://evil.test/{blobId}",
                    "uploadUrl": "https://evil.test/upload", "eventSourceUrl": "https://evil.test/events",
                    "username": "test", "capabilities": [:], "accounts": [:]]
        }
        try await client.connect()
        Mock.handler = { _ in XCTFail("Endpoint leaked to transport"); return [:] }
        do { _ = try await client.call([]); XCTFail("Unsafe API") }
        catch { XCTAssertEqual(error as? JMAPError, .unsafeEndpoint) }
        do { _ = try await client.upload(Data(), type: "text/plain", account: "a"); XCTFail("Unsafe upload") }
        catch { XCTAssertEqual(error as? JMAPError, .unsafeEndpoint) }
        do { _ = try await client.download(BodyPart(blobId: "b", size: 0, type: "text/plain"), account: "a"); XCTFail("Unsafe download") }
        catch { XCTAssertEqual(error as? JMAPError, .unsafeEndpoint) }
        #if canImport(Darwin)
        do { try await client.listen { _ in }; XCTFail("Unsafe push stream") }
        catch { XCTAssertEqual(error as? JMAPError, .unsafeEndpoint) }
        #endif
    }

    func testRedirectDelegateRejectsOriginChangesAndAllowsSameOrigin() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://mail.test/a")!
        let task = session.dataTask(with: url)
        let delegate = ServerRedirects(server: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        for link in ["https://mail.test/b", "https://evil.test/b", "http://mail.test/b", "https://mail.test:444/b"] {
            let expected = link == "https://mail.test/b"
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: link)!)) { redirected in
                XCTAssertEqual(redirected != nil, expected, link)
            }
        }
        task.cancel()
    }

    func testMalformedAdminCountsDoNotTrap() throws {
        let data = Data(#"{"version":"test","users":{"total":1e100,"active":3.5,"suspended":2}}"#.utf8)
        let overview = try JSONDecoder().decode(AdminOverview.self, from: data)
        XCTAssertEqual(overview.users, 0)
        XCTAssertEqual(overview.activeUsers, 0)
        XCTAssertEqual(overview.suspendedUsers, 2)
    }
}
