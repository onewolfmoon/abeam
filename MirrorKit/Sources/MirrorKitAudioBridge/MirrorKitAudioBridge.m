#import "include/MirrorKitAudioBridge.h"
#import "RTCAudioDeviceShim.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCVideoDecoderFactory.h>
#import <WebRTC/RTCVideoEncoderFactory.h>

static const double kSampleRate = 48000.0;
static const AVAudioChannelCount kChannelCount = 2;

@interface ScreenAudioDevice () <RTCAudioDevice>
@end

@implementation ScreenAudioDevice {
    NSLock *_lock;
    id<RTCAudioDeviceDelegate> _delegate;
    BOOL _recording;
    AVAudioConverter *_converter;
    AVAudioFormat *_converterInputFormat;
    BOOL _isInitialized;
    BOOL _isPlayoutInitialized;
    BOOL _isPlaying;
    BOOL _isRecordingInitialized;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = [[NSLock alloc] init];
    }
    return self;
}

// Matches SCStreamConfiguration's own capturesAudio defaults, so the only
// real work AVAudioConverter does per buffer is ScreenCaptureKit's native
// sample format -> the 16-bit interleaved PCM deliverRecordedData requires,
// not a sample-rate/channel-count conversion too.
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
    return 0.01;
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
    return 0.01;
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
    [_lock lock];
    _delegate = nil;
    _recording = NO;
    _converter = nil;
    _converterInputFormat = nil;
    [_lock unlock];
    _isInitialized = NO;
    return YES;
}

// No playout: Abeam's peer connection never has a remote audio track to
// render, so these just satisfy the protocol without touching any real
// audio output.
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
    [_lock lock];
    _recording = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)stopRecording {
    [_lock lock];
    _recording = NO;
    _converter = nil;
    _converterInputFormat = nil;
    [_lock unlock];
    return YES;
}

#pragma mark - Sample delivery

- (void)deliverAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDescription) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd) return;
    CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (frameCount <= 0) return;

    id<RTCAudioDeviceDelegate> delegate = nil;
    AVAudioConverter *converter = nil;
    AVAudioFormat *inputFormat = nil;

    // (Re)builds the converter whenever the source format changes instead of
    // assuming ScreenCaptureKit's audio format is fixed for the capture's
    // whole lifetime -- e.g. the Receiver-side output device changing sample
    // rate mid-session.
    [_lock lock];
    if (_recording && _delegate) {
        delegate = _delegate;
        const AudioStreamBasicDescription *cached = _converterInputFormat.streamDescription;
        if (cached != NULL
            && cached->mSampleRate == asbd->mSampleRate
            && cached->mChannelsPerFrame == asbd->mChannelsPerFrame
            && cached->mFormatFlags == asbd->mFormatFlags
            && cached->mBitsPerChannel == asbd->mBitsPerChannel) {
            converter = _converter;
            inputFormat = _converterInputFormat;
        } else {
            AVAudioFormat *newFormat = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
            AVAudioConverter *newConverter =
                newFormat ? [[AVAudioConverter alloc] initFromFormat:newFormat toFormat:[ScreenAudioDevice outputFormat]] : nil;
            if (newFormat && newConverter) {
                _converterInputFormat = newFormat;
                _converter = newConverter;
                converter = newConverter;
                inputFormat = newFormat;
            }
        }
    }
    [_lock unlock];

    if (!delegate || !converter || !inputFormat) return;

    AVAudioPCMBuffer *inputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat
                                                                    frameCapacity:(AVAudioFrameCount)frameCount];
    if (!inputBuffer) return;
    inputBuffer.frameLength = (AVAudioFrameCount)frameCount;
    OSStatus copyStatus =
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, 0, (int32_t)frameCount, inputBuffer.mutableAudioBufferList);
    if (copyStatus != noErr) return;

    // +16 headroom: AVAudioConverter's output frame count for a given input
    // isn't guaranteed exact when resampling, only bounded.
    AVAudioFrameCount outputCapacity = (AVAudioFrameCount)(ceil((double)frameCount * kSampleRate / asbd->mSampleRate) + 16);
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:[ScreenAudioDevice outputFormat]
                                                                     frameCapacity:outputCapacity];
    if (!outputBuffer) return;

    __block BOOL suppliedInput = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [converter
        convertToBuffer:outputBuffer
                  error:&error
        withInputFromBlock:^AVAudioBuffer *_Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
            if (suppliedInput) {
                *outStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            suppliedInput = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return inputBuffer;
        }];
    if (status == AVAudioConverterOutputStatus_Error || error != nil || outputBuffer.frameLength == 0) return;

    AudioTimeStamp timestamp;
    memset(&timestamp, 0, sizeof(timestamp));
    AudioUnitRenderActionFlags flags = 0;
    delegate.deliverRecordedData(&flags, &timestamp, 0, outputBuffer.frameLength, outputBuffer.mutableAudioBufferList, NULL, NULL);
}

@end

RTCPeerConnectionFactory *MirrorKitMakePeerConnectionFactory(id<RTCVideoEncoderFactory> encoderFactory,
                                                              id<RTCVideoDecoderFactory> decoderFactory,
                                                              ScreenAudioDevice *audioDevice) {
    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                       decoderFactory:decoderFactory
                                                          audioDevice:audioDevice];
}
