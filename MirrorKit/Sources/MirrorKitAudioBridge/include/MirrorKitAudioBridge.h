#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RTCPeerConnectionFactory;
@protocol RTCVideoEncoderFactory;
@protocol RTCVideoDecoderFactory;

// Feeds ScreenCaptureKit's captured system/app audio into WebRTC as the
// local peer connection's recording input, instead of the real microphone
// WebRTC's default ADM would otherwise open via RTCAudioSession. Playout is
// stubbed out entirely -- Abeam is sendOnly, same as its video path, so
// nothing ever asks this device to render remote audio. See
// MirrorKitAudioBridge.m for why this has to be Objective-C.
// NS_SWIFT_SENDABLE: genuinely thread-safe -- deliverAudioSampleBuffer: is
// called from ScreenCaptureSession's audio-capture queue while the
// RTCAudioDevice lifecycle methods run on WebRTC's own ADM thread, and the
// state shared between them is behind an internal lock (see the .m).
NS_SWIFT_SENDABLE
@interface ScreenAudioDevice : NSObject

// Called directly from ScreenCaptureSession's own audio-capture queue (see
// WebRTCMirrorSession) -- not hopped through Swift concurrency, since doing
// so for every ~10-20ms audio chunk would add latency for no benefit.
- (void)deliverAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

// RTCPeerConnectionFactory's audioDevice: initializer takes an
// id<RTCAudioDevice> parameter, a type Swift can't reference (see above),
// which makes that whole initializer overload invisible to Swift too. This
// wraps it in a plain function using only Swift-visible types.
RTCPeerConnectionFactory *MirrorKitMakePeerConnectionFactory(
    id<RTCVideoEncoderFactory> encoderFactory,
    id<RTCVideoDecoderFactory> decoderFactory,
    ScreenAudioDevice *audioDevice);

NS_ASSUME_NONNULL_END
