import Network
import Testing

@testable import ReceiverProtocol

/// Tests for `ReceiverConnection.WireError`'s user-facing error copy,
/// including its mapping of the underlying `NWError` into a message that
/// makes sense on screen instead of a raw network error code.
struct WireErrorTests {

    @Test func notConnectedDescription() {
        let error: ReceiverConnection.WireError = .notConnected
        #expect(error.errorDescription == "Not connected to the Screen.")
    }

    @Test func timedOutDescription() {
        let error: ReceiverConnection.WireError = .timedOut
        #expect(error.errorDescription == "Connecting to the Screen timed out.")
    }

    @Test func invalidResponseDescription() {
        let error: ReceiverConnection.WireError = .invalidResponse
        #expect(
            error.errorDescription == "Received an unexpected response from the Screen."
        )
    }

    @Test func connectFailedWithConnectionRefused() {
        let error: ReceiverConnection.WireError = .connectFailed(.posix(.ECONNREFUSED))
        #expect(
            error.errorDescription
                == "The Screen refused the connection. Make sure Blittie Screen is running there."
        )
    }

    @Test(arguments: [
        POSIXErrorCode.EHOSTUNREACH, .ENETUNREACH, .ENETDOWN,
    ])
    func connectFailedWithUnreachableNetwork(_ code: POSIXErrorCode) {
        let error: ReceiverConnection.WireError = .connectFailed(.posix(code))
        #expect(error.errorDescription == "Couldn't reach that address on the network.")
    }

    @Test func sendFailedWithTimeout() {
        let error: ReceiverConnection.WireError = .sendFailed(.posix(.ETIMEDOUT))
        #expect(error.errorDescription == "The connection timed out.")
    }

    @Test func sendFailedWithDNSFailure() {
        let error: ReceiverConnection.WireError = .sendFailed(.dns(0))
        #expect(error.errorDescription == "Couldn't resolve that hostname.")
    }

    @Test func connectFailedWithUnrecognizedPosixErrorFallsBackToGenericMessage() {
        let error: ReceiverConnection.WireError = .connectFailed(.posix(.ECONNRESET))
        #expect(error.errorDescription == "Couldn't connect to the Screen.")
    }
}
