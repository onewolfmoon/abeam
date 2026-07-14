import ReplayKit
import CoreMedia
import SenderKit
import OSLog

// The extension process ReplayKit launches when the user starts a broadcast
// from the system picker (see Sender/BroadcastPickerView.swift). Runs
// separately from the main app, under a ~50MB memory ceiling, for as long as
// the broadcast is active.
final class SampleHandler: RPBroadcastSampleHandler {
    private let webRTCSender = WebRTCSender()
    private var hasReceivedFirstVideoFrame = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let address = ReceiverAddressStore.address
        Logger.sampleHandler.log("broadcastStarted: address from App Group defaults = '\(address, privacy: .public)'")
        Task {
            do {
                try await webRTCSender.start(receiverAddress: address)
                Logger.sampleHandler.log("broadcastStarted: webRTCSender.start succeeded")
            } catch {
                Logger.sampleHandler.error("broadcastStarted: webRTCSender.start failed: \(String(describing: error), privacy: .public)")
                finishBroadcastWithError(error as NSError)
            }
        }
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        Logger.sampleHandler.log("broadcastFinished")
        webRTCSender.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !hasReceivedFirstVideoFrame {
            hasReceivedFirstVideoFrame = true
            Logger.sampleHandler.log("processSampleBuffer: first video frame received from ReplayKit")
        }
        webRTCSender.deliver(pixelBuffer: pixelBuffer, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

extension Logger {
    static let sampleHandler = Logger(subsystem: "com.wesleymoy.VGASender", category: "SampleHandler")
}
