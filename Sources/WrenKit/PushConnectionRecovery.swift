import Foundation

/// Recovery for the background notification stream, separate from errors loading or changing mail.
/// A dropped stream is expected after sleep, a network change, or the server's periodic stream rotation.
public struct PushConnectionRecovery: Sendable {
    public private(set) var problem: String?
    private var failures = 0
    private var delay: TimeInterval = 2

    public init() {}

    /// Receiving state confirms that push works, even when no mail has changed since the last connection.
    /// Merely fetching the session does not: the event endpoint may still be unavailable.
    public mutating func receivedState() {
        failures = 0
        delay = 2
        problem = nil
    }

    /// Give brief transport interruptions two reconnect attempts before showing a background warning.
    /// Configuration, TLS and server errors remain visible immediately; cancellation is not a failure.
    public mutating func failed(_ error: Error) {
        let urlError = error as? URLError
        guard !(error is CancellationError), urlError?.code != .cancelled else { return }
        failures = min(failures + 1, 3)
        let transient: Bool
        switch urlError?.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            transient = true
        default:
            transient = false
        }
        if !transient || failures >= 3 {
            problem = "Mail updates are unavailable. Wren will keep trying. " + error.localizedDescription
        }
    }

    /// Only a working stream resets the backoff, not a successful session fetch before a failed stream.
    public mutating func nextRetryDelay() -> TimeInterval {
        defer { delay = min(delay * 2, 60) }
        return delay
    }
}
