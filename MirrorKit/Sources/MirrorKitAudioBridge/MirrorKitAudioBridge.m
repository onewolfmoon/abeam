#import "include/MirrorKitAudioBridge.h"
#import "RTCAudioDeviceShim.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCVideoDecoderFactory.h>
#import <WebRTC/RTCVideoEncoderFactory.h>
#import <mach/mach_time.h>

// TODO: Use preferredInputSampleRate from RTCAudioDevice.
static const double kSampleRate = 48000.0;
// Mono. The vendored WebRTC build has a custom RTCAudioDevice path that
// silently drops roughly half of stereo-delivered audio before it reaches the
// RTP encoder. This is probably because it was only ever designed to work with
// mono microphones.
//
// TODO: Use inputNumberOfChannels from RTCAudioDevice.
static const AVAudioChannelCount kChannelCount = 1;
// WebRTC's own native audio-processing frame size.
//
// TODO: Use preferredInputIOBufferDuration.
static const NSTimeInterval kTickInterval = 0.01;

// enum so these are true compile-time constants usable as a stack array bound
// below.
//
// TODO: Should these just be `#define`s?
enum {
    kBytesPerFrame = sizeof(int16_t) * 1, // 1 == kChannelCount
    // TODO: Should this be frameCount from RTCAudioDevice?
    kFramesPerTick = 480, // kSampleRate * kTickInterval
    kBytesPerTick = kFramesPerTick * kBytesPerFrame,
};

static const NSUInteger kMaxPendingBytes = kBytesPerTick * 50; // 500ms

@interface ScreenAudioDevice () <RTCAudioDevice>
@end

@implementation ScreenAudioDevice {
    NSLock *_lock;
    id<RTCAudioDeviceDelegate> _delegate;
    BOOL _recording;
    AVAudioConverter *_converter;
    AVAudioFormat *_converterInputFormat;
    // Ring buffer filled by ScreenCaptureKit's callback and drained at
    // `_tickTimer` pace.
    NSMutableData *_pendingAudio;
    dispatch_queue_t _tickQueue;
    dispatch_source_t _tickTimer;
    // Timestamp must not be 0, so it's timed here.
    Float64 _sampleTime;
    BOOL _isInitialized;
    BOOL _isPlayoutInitialized;
    BOOL _isPlaying;
    BOOL _isRecordingInitialized;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = [[NSLock alloc] init];
        _pendingAudio = [NSMutableData data];
        // QOS_CLASS_USER_INTERACTIVE, like Core Audio.
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _tickQueue = dispatch_queue_create(
            "MirrorKitAudioBridge.ScreenAudioDevice.tick", attr);
    }
    return self;
}

/// Describes the output format matching SCStreamConfiguration's own
/// capturesAudio defaults.
+ (AVAudioFormat *)outputFormat {
    static AVAudioFormat *format;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                sampleRate:kSampleRate
                                                  channels:kChannelCount
                                               interleaved:YES];
    });
    return format;
}

#pragma mark - RTCAudioDevice

- (double)deviceInputSampleRate {
    return kSampleRate;
}
- (NSTimeInterval)inputIOBufferDuration {
    return kTickInterval;
}
- (NSInteger)inputNumberOfChannels {
    return kChannelCount;
}
- (NSTimeInterval)inputLatency {
    return 0;
}
- (double)deviceOutputSampleRate {
    return kSampleRate;
}
- (NSTimeInterval)outputIOBufferDuration {
    return kTickInterval;
}
- (NSInteger)outputNumberOfChannels {
    return kChannelCount;
}
- (NSTimeInterval)outputLatency {
    return 0;
}

- (BOOL)isInitialized {
    return _isInitialized;
}
- (BOOL)isPlayoutInitialized {
    return _isPlayoutInitialized;
}
- (BOOL)isPlaying {
    return _isPlaying;
}
- (BOOL)isRecordingInitialized {
    return _isRecordingInitialized;
}
- (BOOL)isRecording {
    [_lock lock];
    BOOL result = _recording;
    [_lock unlock];
    return result;
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    [_lock lock];
    _delegate = delegate;
    [_lock unlock];
    _isInitialized = YES;
    return YES;
}

- (BOOL)terminateDevice {
    [self stopRecording];
    [_lock lock];
    _delegate = nil;
    [_lock unlock];
    _isInitialized = NO;
    return YES;
}

// Plackback is stubbed.
- (BOOL)initializePlayout {
    _isPlayoutInitialized = YES;
    return YES;
}
- (BOOL)startPlayout {
    _isPlaying = YES;
    return YES;
}
- (BOOL)stopPlayout {
    _isPlaying = NO;
    return YES;
}

- (BOOL)initializeRecording {
    _isRecordingInitialized = YES;
    return YES;
}

- (BOOL)startRecording {
    // WebRTC's ADM may call startRecording more than once per session, so
    // cancel any timer from a previous startRecording first.
    if (_tickTimer) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }

    [_lock lock];
    _recording = YES;
    _pendingAudio.length = 0;
    [_lock unlock];

    _sampleTime = 0;

    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _tickQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kTickInterval * NSEC_PER_SEC),
                              (uint64_t)(kTickInterval * NSEC_PER_SEC * 0.1));
    __weak ScreenAudioDevice *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
      [weakSelf tick];
    });
    _tickTimer = timer;
    dispatch_resume(timer);
    return YES;
}

- (BOOL)stopRecording {
    if (_tickTimer) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }
    [_lock lock];
    _recording = NO;
    _converter = nil;
    _converterInputFormat = nil;
    _pendingAudio.length = 0;
    [_lock unlock];
    return YES;
}

// TODO: Verify that this is necessary. It took enough work and debugging to get
// audio working that I never went back to check whether I could just dump
// ScreenCaptureKit audio into the WebRTC connection and let it figure it out.

/// Delivers a unit of audio. Running this on a timer smooths out the rate of
/// delivered audio.
- (void)tick {
    uint8_t tickBytes[kBytesPerTick];
    id<RTCAudioDeviceDelegate> delegate = nil;

    [_lock lock];
    if (_recording && _delegate) {
        delegate = _delegate;
        NSUInteger available =
            MIN(_pendingAudio.length, (NSUInteger)kBytesPerTick);
        if (available > 0) {
            memcpy(tickBytes, _pendingAudio.bytes, available);
        }
        if (available < kBytesPerTick) {
            // Genuine underrun (source didn't keep up), not the burstiness this
            // exists to smooth over -- pad with silence so WebRTC's timeline
            // keeps moving forward at a steady rate instead of seeing a gap.
            memset(tickBytes + available, 0, kBytesPerTick - available);
        }
        [_pendingAudio replaceBytesInRange:NSMakeRange(0, available)
                                 withBytes:NULL
                                    length:0];
    }
    [_lock unlock];

    if (!delegate)
        return;

    AudioBuffer audioBuffer = {
        .mNumberChannels = kChannelCount,
        .mDataByteSize = (UInt32)kBytesPerTick,
        .mData = tickBytes,
    };
    AudioBufferList bufferList = {.mNumberBuffers = 1,
                                  .mBuffers = {audioBuffer}};
    AudioTimeStamp timestamp;
    memset(&timestamp, 0, sizeof(timestamp));
    timestamp.mSampleTime = _sampleTime;
    timestamp.mHostTime = mach_absolute_time();
    timestamp.mFlags =
        kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    _sampleTime += kFramesPerTick;
    AudioUnitRenderActionFlags flags = 0;
    delegate.deliverRecordedData(&flags, &timestamp, 0, kFramesPerTick,
                                 &bufferList, NULL, NULL);
}

#pragma mark - Sample delivery

- (void)deliverAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef formatDescription =
        CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDescription)
        return;
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd)
        return;
    CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (frameCount <= 0)
        return;

    id<RTCAudioDeviceDelegate> delegate = nil;
    AVAudioConverter *converter = nil;
    AVAudioFormat *inputFormat = nil;

    // (Re)builds the converter whenever the source format changes.
    [_lock lock];
    if (_recording && _delegate) {
        delegate = _delegate;
        const AudioStreamBasicDescription *cached =
            _converterInputFormat.streamDescription;
        if (cached != NULL && cached->mSampleRate == asbd->mSampleRate &&
            cached->mChannelsPerFrame == asbd->mChannelsPerFrame &&
            cached->mFormatFlags == asbd->mFormatFlags &&
            cached->mBitsPerChannel == asbd->mBitsPerChannel) {
            converter = _converter;
            inputFormat = _converterInputFormat;
        } else {
            AVAudioFormat *newFormat =
                [[AVAudioFormat alloc] initWithStreamDescription:asbd];
            AVAudioConverter *newConverter =
                newFormat ? [[AVAudioConverter alloc]
                                initFromFormat:newFormat
                                      toFormat:[ScreenAudioDevice outputFormat]]
                          : nil;
            if (newFormat && newConverter) {
                _converterInputFormat = newFormat;
                _converter = newConverter;
                converter = newConverter;
                inputFormat = newFormat;
            }
        }
    }
    [_lock unlock];

    if (!delegate || !converter || !inputFormat)
        return;

    AVAudioPCMBuffer *inputBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:inputFormat
            frameCapacity:(AVAudioFrameCount)frameCount];
    if (!inputBuffer)
        return;
    inputBuffer.frameLength = (AVAudioFrameCount)frameCount;
    OSStatus copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, 0, (int32_t)frameCount,
        inputBuffer.mutableAudioBufferList);
    if (copyStatus != noErr)
        return;

    // +16 headroom: AVAudioConverter's output frame count for a given input
    // isn't guaranteed exact when resampling, only bounded.
    AVAudioFrameCount outputCapacity =
        (AVAudioFrameCount)(ceil((double)frameCount * kSampleRate /
                                 asbd->mSampleRate) +
                            16);
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:[ScreenAudioDevice outputFormat]
            frameCapacity:outputCapacity];
    if (!outputBuffer)
        return;

    __block BOOL suppliedInput = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status =
        [converter convertToBuffer:outputBuffer
                             error:&error
                withInputFromBlock:^AVAudioBuffer *_Nullable(
                    AVAudioPacketCount inNumberOfPackets,
                    AVAudioConverterInputStatus *outStatus) {
                  if (suppliedInput) {
                      *outStatus = AVAudioConverterInputStatus_NoDataNow;
                      return nil;
                  }
                  suppliedInput = YES;
                  *outStatus = AVAudioConverterInputStatus_HaveData;
                  return inputBuffer;
                }];
    if (status == AVAudioConverterOutputStatus_Error || error != nil ||
        outputBuffer.frameLength == 0)
        return;

    // Appended here, not delivered directly -- `tick` drains this on its own
    // steady clock. See its doc comment for why.
    const AudioBufferList *converted = outputBuffer.audioBufferList;
    if (converted->mNumberBuffers == 0)
        return;
    const AudioBuffer *buffer = &converted->mBuffers[0];
    [_lock lock];
    if (_recording) {
        [_pendingAudio appendBytes:buffer->mData length:buffer->mDataByteSize];
        if (_pendingAudio.length > kMaxPendingBytes) {
            NSUInteger excess = _pendingAudio.length - kMaxPendingBytes;
            [_pendingAudio replaceBytesInRange:NSMakeRange(0, excess)
                                     withBytes:NULL
                                        length:0];
        }
    }
    [_lock unlock];
}

@end

RTCPeerConnectionFactory *
MirrorKitMakePeerConnectionFactory(id<RTCVideoEncoderFactory> encoderFactory,
                                   id<RTCVideoDecoderFactory> decoderFactory,
                                   ScreenAudioDevice *audioDevice) {
    return
        [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                  decoderFactory:decoderFactory
                                                     audioDevice:audioDevice];
}
