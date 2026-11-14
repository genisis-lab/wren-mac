import Foundation
import XCTest
@testable import WrenKit

final class PushConnectionRecoveryTests: XCTestCase {
    func testBriefTimeoutsStayQuietButPersistentOutageIsVisible() {
        var recovery = PushConnectionRecovery()
        for _ in 0..<2 {
            recovery.failed(URLError(.timedOut))
            XCTAssertNil(recovery.problem)
        }
        recovery.failed(URLError(.timedOut))
        XCTAssertNotNil(recovery.problem)
        recovery.receivedState()
        XCTAssertNil(recovery.problem)
        recovery.failed(URLError(.timedOut))
        XCTAssertNil(recovery.problem)
    }

    func testRepeatedHealthyStreamRotationsDoNotAccumulateFailures() {
        var recovery = PushConnectionRecovery()
        for _ in 0..<100 {
            recovery.receivedState()
            recovery.failed(URLError(.networkConnectionLost))
            XCTAssertNil(recovery.problem)
            XCTAssertEqual(recovery.nextRetryDelay(), 2)
        }
    }

    func testFailedStreamsBackOffEvenIfSessionEndpointWorks() {
        var recovery = PushConnectionRecovery()
        for expected in [2.0, 4, 8, 16, 32, 60, 60] {
            recovery.failed(URLError(.cannotConnectToHost))
            XCTAssertEqual(recovery.nextRetryDelay(), expected)
        }
        XCTAssertNotNil(recovery.problem)
        recovery.receivedState()
        XCTAssertEqual(recovery.nextRetryDelay(), 2)
        XCTAssertNil(recovery.problem)
    }

    func testConfigurationAndSecurityErrorsAreNotSuppressed() {
        for error: Error in [JMAPError.unsafeEndpoint, JMAPError.badResponse,
                             JMAPError.http(503, nil), URLError(.serverCertificateUntrusted)] {
            var recovery = PushConnectionRecovery()
            recovery.failed(error)
            XCTAssertTrue(recovery.problem?.contains(error.localizedDescription) == true)
        }
    }

    func testCancellationDoesNotCreateOrClearWarnings() {
        var recovery = PushConnectionRecovery()
        for _ in 0..<5 {
            recovery.failed(CancellationError())
            recovery.failed(URLError(.cancelled))
        }
        recovery.failed(URLError(.networkConnectionLost))
        XCTAssertNil(recovery.problem)
        recovery.failed(JMAPError.badResponse)
        let problem = recovery.problem
        recovery.failed(CancellationError())
        XCTAssertEqual(recovery.problem, problem)
    }

    #if canImport(Darwin)
    /// Actual URLSession timeouts followed by a working SSE connection with the same mailbox state.
    func testRealStreamTimeoutAndUnchangedStateRecovery() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "push-server", withExtension: "py", subdirectory: "Fixtures/Push"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = folder.appendingPathComponent("address.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", fixture.path, address.path]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: address.path) { break }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let server = try XCTUnwrap(URL(string: String(contentsOf: address, encoding: .utf8)))
        let configuration = URLSessionConfiguration.ephemeral
        // Accelerate the fixture's silent stream; production retains its heartbeat-based idle timeout.
        configuration.timeoutIntervalForResource = 0.5
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let stalled = JMAPClient(server: server, username: "stalled", password: "fixture", http: http)
        let healthy = JMAPClient(server: server, username: "healthy", password: "fixture", http: http)
        let observation = PushObservation()
        try await healthy.listen { await observation.receive($0) }
        for attempt in 1...3 {
            do {
                try await stalled.listen { _ in XCTFail("Silent stream delivered a state") }
                XCTFail("Silent stream did not time out")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                await observation.fail(error)
            }
            let warning = await observation.warning
            XCTAssertEqual(warning != nil, attempt == 3)
        }
        // The mailbox state has not changed. Reconnecting still clears the background error.
        try await healthy.listen { await observation.receive($0) }
        let states = await observation.states
        let warning = await observation.warning
        XCTAssertEqual(states, [["account": "unchanged"], ["account": "unchanged"]])
        XCTAssertNil(warning)
    }
    #endif
}

private actor PushObservation {
    private var recovery = PushConnectionRecovery()
    private(set) var states: [[String: String]] = []
    var warning: String? { recovery.problem }

    func receive(_ state: [String: String]) {
        recovery.receivedState()
        states.append(state)
    }

    func fail(_ error: Error) { recovery.failed(error) }
}
