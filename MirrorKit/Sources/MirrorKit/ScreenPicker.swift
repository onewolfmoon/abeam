#if canImport(ScreenCaptureKit)
    @preconcurrency import ScreenCaptureKit

    public enum ScreenPickerError: Error, Sendable {
        case cancelled
        case failed(String)
    }

    /// A wrapper for the system content-sharing picker. This allows callers to
    /// get one async call instead of juggling SCContentSharingPickerObserver's
    /// callback-based API with AsyncStream for swapping what window is shared.
    ///
    /// This class is an actor because the observer callbacks below land on
    /// whatever queue the system picker happens to use.
    @available(iOS 27, *)
    public actor ScreenPicker: NSObject, SCContentSharingPickerObserver {
        private var continuation: CheckedContinuation<SCContentFilter, Error>?
        private var updateContinuation: AsyncStream<SCContentFilter>.Continuation?
        private var isObserving = false

        override public init() {
            super.init()
            var configuration = SCContentSharingPickerConfiguration()
            #if os(macOS)
                configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
                configuration.allowsChangingSelectedContent = true
            #endif
            SCContentSharingPicker.shared.defaultConfiguration = configuration
        }

        /// Presents the system picker and suspends until the user picks
        /// something, cancels, or the picker fails to start. This method leaves
        /// the picker observing afterward to support swapping what content's
        /// being shared.
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

        /// Filters updates for the share pickContent() started. These are
        /// delivered when the user changes what content is being shared.
        ///
        /// Call this once, right after pickContent() resolves, to observe swaps
        /// for that session.
        public func filterUpdates() -> AsyncStream<SCContentFilter> {
            AsyncStream { continuation in
                self.updateContinuation = continuation
            }
        }

        /// Stops observing the picker and ends filterUpdates()'s stream.
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

        nonisolated public func contentSharingPicker(
            _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
        ) {
            Task { await self.resume(throwing: ScreenPickerError.cancelled) }
        }

        nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
            Task {
                await self.resume(throwing: ScreenPickerError.failed(error.localizedDescription))
            }
        }

        private func handleUpdate(_ filter: SCContentFilter) {
            // A pending continuation means this is the initial pick still being
            // awaited by pickContent(); once that's resolved, any further update
            // is a live swap of the already-active share.
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
#endif
