#import <AudioUnit/AudioUnit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Mirrors WebRTC's own RTCAudioDevice.h declarations (RTCAudioDeviceDelegate/
// RTCAudioDevice protocols + block typedefs) by selector shape, rather than
// importing WebRTC's copy directly: the vendored macOS slice of
// stasel/WebRTC 150.0.0 doesn't ship RTCAudioDevice.h at all -- confirmed
// present in the ios-arm64/ios-simulator/maccatalyst slices of
// WebRTC.xcframework, absent from macos-x86_64_arm64 -- even though the
// underlying library binary implements the feature there too (`strings` on
// WebRTC.framework/Versions/A/WebRTC shows
// initWithEncoderFactory:decoderFactory:audioDevice:, RTCAudioDeviceDelegate,
// and deliverRecordedData symbols present on macOS same as iOS). Since
// Objective-C protocol conformance is a per-translation-unit nominal check,
// not a cross-module identity token the way Swift's is, redeclaring the same
// protocol shape under the same names here satisfies the real
// -initWithEncoderFactory:decoderFactory:audioDevice: call identically on
// every platform, without depending on which slices happen to ship the
// actual header.
typedef OSStatus (^RTCAudioDeviceGetPlayoutDataBlock)(AudioUnitRenderActionFlags *actionFlags,
                                                       const AudioTimeStamp *timestamp,
                                                       NSInteger inputBusNumber,
                                                       UInt32 frameCount,
                                                       AudioBufferList *outputData);

typedef OSStatus (^RTCAudioDeviceRenderRecordedDataBlock)(AudioUnitRenderActionFlags *actionFlags,
                                                           const AudioTimeStamp *timestamp,
                                                           NSInteger inputBusNumber,
                                                           UInt32 frameCount,
                                                           AudioBufferList *inputData,
                                                           void *_Nullable renderContext);

typedef OSStatus (^RTCAudioDeviceDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    const AudioBufferList *_Nullable inputData,
    void *_Nullable renderContext,
    RTCAudioDeviceRenderRecordedDataBlock _Nullable renderBlock);

@protocol RTCAudioDeviceDelegate <NSObject>

@property(readonly, nonnull) RTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) RTCAudioDeviceGetPlayoutDataBlock getPlayoutData;

- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;

@end

@protocol RTCAudioDevice <NSObject>

@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;

@property(readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;

@property(readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property(readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;

@property(readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property(readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;

@end

NS_ASSUME_NONNULL_END
