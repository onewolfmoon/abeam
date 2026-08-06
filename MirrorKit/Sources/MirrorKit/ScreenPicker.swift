@preconcurrency import ScreenCaptureKit

public enum ScreenPickerError: Error, Sendable {
    case cancelled
    case failed(String)
}

// Wraps the system content-sharing picker (Control Center-style: user picks
// a window or a whole display) so callers get one async call instead of
// juggling SCContentSharingPickerObserver's callback-based API, plus an
// AsyncStream for in-place swaps of an already-active share.
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
    private var updateContinuation: AsyncStream<SCContentFilter>.Continuation?
    private var isObserving = false

    override public init() {
        super.init()
        // multipleWindows/multipleApplications/singleApplication can all
        // hand back a filter spanning several composited windows —
        // ScreenCaptureSession builds one fixed-size stream from one
        // filter and has no notion of a multi-window layout, so those
        // modes are excluded rather than left to produce a filter this
        // pipeline can't render sensibly. allowsChangingSelectedContent
        // stays enabled: filterUpdates() below is what makes that flow
        // (Control Center's "Windows..." reconfigure of an active share)
        // actually work instead of silently no-opping.
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = true
        SCContentSharingPicker.shared.defaultConfiguration = configuration
    }

    // Presents the system picker and suspends until the user picks
    // something, cancels, or the picker fails to start. Leaves the picker
    // observing afterward (see filterUpdates()) instead of removing itself
    // once this resolves — Control Center's "Windows..." control on an
    // active share re-invokes the same observer callback later, with a
    // non-nil stream, and that needs to still be listened for.
    public func pickContent() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        if !isObserving {
            picker.add(self)
            isObserving = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
    }

    // Filter updates for the share pickContent() started, delivered when
    // the user reconfigures it in place (e.g. Control Center's
    // "Windows..." control) rather than starting a new one. Call this
    // once, right after pickContent() resolves, to observe swaps for that
    // session.
    public func filterUpdates() -> AsyncStream<SCContentFilter> {
        AsyncStream { continuation in
            self.updateContinuation = continuation
        }
    }

    // Stops observing the picker and ends filterUpdates()'s stream. Call
    // once the active share (if any) has been torn down, since a picked-
    // but-never-started or now-stopped share has nothing left to swap.
    public func stopObserving() {
        guard isObserving else { return }
        SCContentSharingPicker.shared.remove(self)
        isObserving = false
        updateContinuation?.finish()
        updateContinuation = nil
    }

    nonisolated public func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { await self.handleUpdate(filter) }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { await self.resume(throwing: ScreenPickerError.cancelled) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { await self.resume(throwing: ScreenPickerError.failed(error.localizedDescription)) }
    }

    // A pending continuation means this is the initial pick still being
    // awaited by pickContent(); once that's resolved, any further update
    // is a live swap of the already-active share.
    private func handleUpdate(_ filter: SCContentFilter) {
        if let continuation {
            continuation.resume(returning: filter)
            self.continuation = nil
        } else {
            updateContinuation?.yield(filter)
        }
    }

    private func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
