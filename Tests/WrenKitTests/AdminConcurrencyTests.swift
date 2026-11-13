import Foundation
import XCTest
@testable import WrenKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hold replies until after Lock, so timing is deterministic and needs no live account.
final class AdminConcurrencyTests: XCTestCase {
    private func setup() -> (AdminClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedReply.self]
        let session = URLSession(configuration: config)
        return (AdminClient(client: JMAPClient(server: URL(string: "https://mail.test")!, username: "test", password: "fake", http: session)), session)
    }

    private var challenge: AdminChallenge {
        AdminChallenge(secret: "fake", role: "owner", steps: [.totp], emailTo: nil, expiresAt: .now.addingTimeInterval(60))
    }

    func testLockDiscardsAnInFlightUnlock() async throws {
        let (admin, session) = setup()
        defer { session.invalidateAndCancel() }
        let started = expectation(description: "verify started")
        let pending = HeldReply()
        DelayedReply.handler = { request in
            if request.request.url?.path == "/jmap/admin/unlock/verify" {
                pending.set(request)
                started.fulfill()
            } else { request.reply(["locked": true]) }
        }
        let challenge = challenge
        let verify = Task { try await admin.verify(challenge, step: .totp, code: "123456") }
        await fulfillment(of: [started], timeout: 3)
        await admin.lock()
        pending.reply(["token": "too-late", "expiresAt": .number(Date.now.addingTimeInterval(600).timeIntervalSince1970 * 1000)])
        do { _ = try await verify.value; XCTFail("Lock was undone by a late response") }
        catch { XCTAssertEqual(error as? AdminError, .locked) }
        let unlocked = await admin.isUnlocked
        XCTAssertFalse(unlocked)
    }

    func testLockDiscardsAdminDataAlreadyInFlight() async throws {
        let (admin, session) = setup()
        defer { session.invalidateAndCancel() }
        DelayedReply.handler = { $0.reply(["token": "fake"]) }
        _ = try await admin.verify(challenge, step: .totp, code: "123456")
        let started = expectation(description: "read started")
        let pending = HeldReply()
        DelayedReply.handler = { request in
            if request.request.url?.path == "/api/admin/users" {
                pending.set(request)
                started.fulfill()
            } else { request.reply(["locked": true]) }
        }
        let read = Task { try await admin.get("/users", as: JSON.self) }
        await fulfillment(of: [started], timeout: 3)
        await admin.lock()
        pending.reply(["users": []])
        do { _ = try await read.value; XCTFail("Returned private data after Lock") }
        catch { XCTAssertEqual(error as? AdminError, .locked) }
    }
}

private final class HeldReply: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: DelayedReply?
    func set(_ value: DelayedReply) { lock.lock(); defer { lock.unlock() }; pending = value }
    func reply(_ json: JSON) {
        lock.lock(); let value = pending; pending = nil; lock.unlock()
        value?.reply(json)
    }
}

private final class DelayedReply: URLProtocol {
    nonisolated(unsafe) static var handler: (DelayedReply) -> Void = { _ in }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler(self) }
    override func stopLoading() {}
    func reply(_ json: JSON) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(json))
        client?.urlProtocolDidFinishLoading(self)
    }
}
