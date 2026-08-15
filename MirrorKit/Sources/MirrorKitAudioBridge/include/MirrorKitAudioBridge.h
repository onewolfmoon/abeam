#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RTCPeerConnectionFactory;
@protocol RTCVideoEncoderFactory;
@protocol RTCVideoDecoderFactory;

// NS_SWIFT_SENDABLE: deliverAudioSampleBuffer: is called from
// ScreenCaptureSession's audio-capture queue while the RTCAudioDevice lifecycle
// methods run on WebRTC's own ADM thread. The state shared between them is
// behind an internal lock.

/// An audio device that captures system audio output. The default
/// RTCAudioSession captures the microphone.
///
/// This device does not support playback.
NS_SWIFT_SENDABLE
@interface ScreenAudioDevice : NSObject

/// Receives a sample buffer, say, from ScreenCaptureSession.
- (void)deliverAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

// RTCPeerConnectionFactory's `audioDevice:` initializer takes an
// `id<RTCAudioDevice>` parameter, a type Swift can't reference. That makes that
// whole initializer overload invisible to Swift. This wraps and exposes it.
RTCPeerConnectionFactory *
MirrorKitMakePeerConnectionFactory(id<RTCVideoEncoderFactory> encoderFactory,
                                   id<RTCVideoDecoderFactory> decoderFactory,
                                   ScreenAudioDevice *audioDevice);

NS_ASSUME_NONNULL_END
