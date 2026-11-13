#if canImport(Darwin)
import Foundation
import XCTest
@testable import WrenKit

final class RedirectIntegrationTests: XCTestCase {
    /// Exercise URLSession itself: checking the delegate alone would miss a request path that forgot to install it.
    func testRealRedirectsAcrossEveryAuthenticatedTransport() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "redirect-server", withExtension: "py", subdirectory: "Fixtures/Security"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ports = folder.appendingPathComponent("ports.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", fixture.path, ports.path]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var config: [String: String]?
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: ports), let value = try? JSONDecoder().decode([String: String].self, from: data) { config = value; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let server = try XCTUnwrap(config?["source"].flatMap(URL.init(string:)))
        let client = JMAPClient(server: server, username: "test", password: "fake")
        let headers = ["X-Wren-Admin": "fake-admin"]
        let blocked = try await client.request("POST", path: "/cross", body: ["password": "fake"], headers: headers)
        XCTAssertEqual(blocked.status, 307)
        let allowed = try await client.request("POST", path: "/same", body: ["password": "fake"], headers: headers)
        XCTAssertEqual(allowed.status, 200)
        let received = try JSONDecoder().decode(JSON.self, from: allowed.data)
        XCTAssertEqual(received["auth"]?.string, "Basic " + Data("test:fake".utf8).base64EncodedString())
        XCTAssertEqual(received["admin"]?.string, "fake-admin")
        XCTAssertEqual(received["method"]?.string, "POST")
        XCTAssertTrue(received["body"]?.string?.contains("fake") == true)

        let upload = folder.appendingPathComponent("upload.txt")
        try Data("fake-private-export".utf8).write(to: upload)
        for file in [nil, upload] as [URL?] {
            do {
                let reply = try await client.transfer(file == nil ? "GET" : "POST", path: "/cross", upload: file, headers: headers)
                defer { try? FileManager.default.removeItem(at: reply.file) }
                XCTAssertEqual(reply.status, 307)
            } catch let error as URLError {
                // URLSession download tasks can report a refused redirect as badServerResponse.
                XCTAssertEqual(error.code, .badServerResponse)
            }
        }
        try await client.connect()
        do { _ = try await client.call([]); XCTFail("Followed API redirect") }
        catch { XCTAssertEqual(error as? JMAPError, .http(307, nil)) }
        do { _ = try await client.upload(Data("private".utf8), type: "text/plain", account: "a"); XCTFail("Followed upload redirect") }
        catch { XCTAssertEqual(error as? JMAPError, .http(307, nil)) }
        do { _ = try await client.download(BodyPart(blobId: "b", size: 0, type: "text/plain"), account: "a"); XCTFail("Followed download redirect") }
        catch { XCTAssertEqual(error as? JMAPError, .http(307, nil)) }
        do { try await client.listen { _ in }; XCTFail("Followed stream redirect") }
        catch { XCTAssertEqual(error as? JMAPError, .http(307, nil)) }
        let hits = try await client.request("GET", path: "/hits")
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: hits.data)["count"]?.int, 0)
    }
}
#endif
