@preconcurrency import ScreenCaptureKit

public enum ScreenPickerError: Error, Sendable {
    case cancelled
    case failed(String)
}

// Wraps the system content-sharing picker (Control Center-style: user picks
// a window, an app, or a whole display) so callers get one async call
// instead of juggling SCContentSharingPickerObserver's callback-based API.
// An actor, not a plain class, because the observer callbacks below land on
// whatever queue the system picker happens to use, not necessarily the
// caller's — matching ReceiverConnection's nonisolated-callback-hops-into-
// actor-state pattern elsewhere in this codebase.
//
// iOS 27 minimum: SCContentSharingPicker isn't available on iOS before then
// (see MirrorKit's Package.swift comment).
@available(iOS 27, *)
public actor ScreenPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter, Error>?

    override public init() {
        super.init()
    }

    // Presents the system picker and suspends until the user picks
    // something, cancels, or the picker fails to start.
    public func pickContent() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        picker.add(self)
        defer { picker.remove(self) }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
    }

    nonisolated public func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { await self.resume(returning: filter) }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { await self.resume(throwing: ScreenPickerError.cancelled) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { await self.resume(throwing: ScreenPickerError.failed(error.localizedDescription)) }
    }

    private func resume(returning filter: SCContentFilter) {
        continuation?.resume(returning: filter)
        continuation = nil
    }

    private func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
