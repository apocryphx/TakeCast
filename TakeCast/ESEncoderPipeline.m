//
//  ESEncoderPipeline.m
//  TakeCast
//

#import "ESEncoderPipeline.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

NSString * const ESEncoderConfigNameKey = @"name";
NSString * const ESEncoderConfigCodecKey = @"codec";
NSString * const ESEncoderConfigWidthKey = @"width";
NSString * const ESEncoderConfigHeightKey = @"height";
NSString * const ESEncoderConfigFrameRateKey = @"frameRate";
NSString * const ESEncoderConfigAverageBitRateKey = @"averageBitRate";
NSString * const ESEncoderConfigConstrainDataRateKey = @"constrainDataRate";
NSString * const ESEncoderConfigOutputModeKey = @"outputMode";
NSString * const ESEncoderConfigFileURLKey = @"fileURL";
NSString * const ESEncoderConfigSegmentSecondsKey = @"segmentSeconds";

static const NSUInteger ESPendingAudioCap = 256;
static const NSUInteger ESPendingVideoCap = 64;

typedef NS_ENUM(NSInteger, ESPipelineState) {
    ESPipelineStateIdle,
    ESPipelineStateRunning,
    ESPipelineStateFinishing,
    ESPipelineStateFinished,
    ESPipelineStateFailed,
};

@interface ESEncoderPipeline () <AVAssetWriterDelegate>
@end

@implementation ESEncoderPipeline {
    // Configuration
    NSString *_name;
    CMVideoCodecType _codec;
    int32_t _width;
    int32_t _height;
    NSInteger _frameRate;
    NSInteger _averageBitRate;
    BOOL _constrainDataRate;
    ESEncoderOutputMode _outputMode;
    NSURL *_fileURL;
    double _segmentSeconds;

    // Encode and mux state, owned by _writerQueue unless noted
    dispatch_queue_t _writerQueue;
    VTCompressionSessionRef _vtSession;    // created on start, invalidated on finish
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;
    CMFormatDescriptionRef _videoFormat;   // retained
    CMFormatDescriptionRef _audioFormat;   // retained
    NSMutableArray *_pendingVideo;         // CMSampleBufferRef boxed as id
    NSMutableArray *_pendingAudio;
    CMTime _firstVideoPTS;
    BOOL _audioTimeoutFired;
    ESPipelineState _state;
    _Atomic(BOOL) _accepting;              // read on capture queues
    uint64_t _framesEncoded;
    uint64_t _segmentIndex;

    // Downscale, used only when input dimensions differ from target
    CIContext *_ciContext;
    CVPixelBufferPoolRef _scalePool;

    // AAC conversion, HLS and TS modes. The segment writer requires that all
    // inputs be passthrough, so PCM is AAC encoded here before muxing.
    AudioConverterRef _audioConverter;
    AudioStreamBasicDescription _pcmASBD;
    AudioStreamBasicDescription _aacASBD;
    NSMutableData *_pcmFIFO;
    CMTime _audioAnchorPTS;
    uint64_t _aacPacketsProduced;
    UInt32 _aacPrimingFrames;
    UInt32 _maxAACPacketSize;

    // MPEG-2 TS muxing, TS mode only
    NSMutableData *_tsSegment;
    CMTime _tsBasePTS;
    CMTime _tsSegmentStartPTS;
    CMTime _tsLastVideoPTS;
    uint8_t _ccPAT, _ccPMT, _ccSDT, _ccVideo, _ccAudio;
    NSArray<NSData *> *_parameterSets; // H.264: SPS, PPS. HEVC: VPS, SPS, PPS.
    int _nalLengthSize;
}

- (instancetype)initWithConfiguration:(NSDictionary<NSString *, id> *)configuration error:(NSError **)error {
    self = [super init];
    if (self) {
        _name = configuration[ESEncoderConfigNameKey] ?: @"encoder";
        _codec = [configuration[ESEncoderConfigCodecKey] intValue];
        _width = [configuration[ESEncoderConfigWidthKey] intValue];
        _height = [configuration[ESEncoderConfigHeightKey] intValue];
        _frameRate = [configuration[ESEncoderConfigFrameRateKey] integerValue];
        _averageBitRate = [configuration[ESEncoderConfigAverageBitRateKey] integerValue];
        _constrainDataRate = [configuration[ESEncoderConfigConstrainDataRateKey] boolValue];
        _outputMode = [configuration[ESEncoderConfigOutputModeKey] integerValue];
        _fileURL = configuration[ESEncoderConfigFileURLKey];
        _segmentSeconds = [configuration[ESEncoderConfigSegmentSecondsKey] doubleValue];
        if (_segmentSeconds <= 0) _segmentSeconds = 2.0;

        if (_width <= 0 || _height <= 0 || _frameRate <= 0 || _averageBitRate <= 0 ||
            (_outputMode == ESEncoderOutputModeFragmentedFile && !_fileURL)) {
            if (error) *error = [NSError errorWithDomain:@"ESEncoder" code:1
                                                userInfo:@{NSLocalizedDescriptionKey: @"Invalid encoder configuration"}];
            return nil;
        }

        NSString *queueName = [NSString stringWithFormat:@"es.encoder.%@", _name];
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _writerQueue = dispatch_queue_create(queueName.UTF8String, attr);
        _pendingVideo = [NSMutableArray array];
        _pendingAudio = [NSMutableArray array];
        _firstVideoPTS = kCMTimeInvalid;
        _tsBasePTS = kCMTimeInvalid;
        _tsSegmentStartPTS = kCMTimeInvalid;
        _tsLastVideoPTS = kCMTimeInvalid;
        _state = ESPipelineStateIdle;
        atomic_store(&_accepting, NO);
    }
    return self;
}

- (void)dealloc {
    if (_vtSession) {
        VTCompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    if (_videoFormat) CFRelease(_videoFormat);
    if (_audioFormat) CFRelease(_audioFormat);
    if (_scalePool) CVPixelBufferPoolRelease(_scalePool);
}

- (NSString *)name { return _name; }
- (BOOL)isRunning { return atomic_load(&_accepting); }
- (uint64_t)videoFramesEncoded { return _framesEncoded; }

#pragma mark - Start

- (BOOL)startWithError:(NSError **)error {
    NSAssert(_state == ESPipelineStateIdle, @"pipeline can only start once");

    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                                 _width, _height, _codec,
                                                 NULL, NULL, NULL,
                                                 ESCompressionOutputCallback,
                                                 (__bridge void *)self,
                                                 &_vtSession);
    if (status != noErr || !_vtSession) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                                            userInfo:@{NSLocalizedDescriptionKey: @"VTCompressionSessionCreate failed"}];
        return NO;
    }

    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(_frameRate));
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(_averageBitRate));
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         (__bridge CFTypeRef)@(_segmentSeconds));
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFTypeRef)@((NSInteger)(_frameRate * _segmentSeconds)));
    if (_outputMode == ESEncoderOutputModeMPEG2TS &&
        _codec != kCMVideoCodecType_H264 && _codec != kCMVideoCodecType_HEVC) {
        if (error) *error = [NSError errorWithDomain:@"ESEncoder" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"TS mode requires H.264 or HEVC"}];
        return NO;
    }
    if (_codec == kCMVideoCodecType_HEVC) {
        VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
    } else if (_codec == kCMVideoCodecType_H264) {
        VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    }
    if (_constrainDataRate) {
        // Near-CBR: cap the one second window a little above the average rate.
        NSInteger bytesPerSecond = (NSInteger)((_averageBitRate / 8.0) * 1.1);
        NSArray *limits = @[@(bytesPerSecond), @1.0];
        VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)limits);
    }
    VTCompressionSessionPrepareToEncodeFrames(_vtSession);

    _state = ESPipelineStateRunning;
    atomic_store(&_accepting, YES);
    NSLog(@"[%@] started %dx%d at %ld fps, %ld bps, mode %ld",
          _name, _width, _height, (long)_frameRate, (long)_averageBitRate, (long)_outputMode);
    return YES;
}

#pragma mark - Video path

- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!atomic_load(&_accepting)) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);

    CVPixelBufferRef toEncode = pixelBuffer;
    BOOL scaled = NO;
    if ((int32_t)CVPixelBufferGetWidth(pixelBuffer) != _width ||
        (int32_t)CVPixelBufferGetHeight(pixelBuffer) != _height) {
        toEncode = [self _scaledBufferFrom:pixelBuffer];
        if (!toEncode) return; // pool exhausted, shed this broadcast frame
        scaled = YES;
    }

    VTEncodeInfoFlags flags = 0;
    OSStatus status = VTCompressionSessionEncodeFrame(_vtSession, toEncode, pts, duration,
                                                      NULL, NULL, &flags);
    if (scaled) CVPixelBufferRelease(toEncode);
    if (status != noErr) {
        NSLog(@"[%@] encode frame error %d", _name, (int)status);
    }
}

- (nullable CVPixelBufferRef)_scaledBufferFrom:(CVPixelBufferRef)source CF_RETURNS_RETAINED {
    if (!_ciContext) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        // No color management: buffers pass through with their own colorimetry.
        NSDictionary *options = @{kCIContextWorkingColorSpace: [NSNull null],
                                  kCIContextOutputColorSpace: [NSNull null]};
        _ciContext = device ? [CIContext contextWithMTLDevice:device options:options]
                            : [CIContext contextWithOptions:options];
    }
    if (!_scalePool) {
        NSDictionary *poolAttrs = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @4};
        NSDictionary *bufferAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(_width),
            (id)kCVPixelBufferHeightKey: @(_height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttrs,
                                (__bridge CFDictionaryRef)bufferAttrs,
                                &_scalePool);
    }
    if (!_scalePool) return NULL;

    CVPixelBufferRef output = NULL;
    NSDictionary *aux = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @12};
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _scalePool,
                                                                          (__bridge CFDictionaryRef)aux, &output);
    if (result != kCVReturnSuccess || !output) return NULL;

    CVBufferPropagateAttachments(source, output);

    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    CGFloat scale = (CGFloat)_width / (CGFloat)CVPixelBufferGetWidth(source);
    CIFilter *lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [lanczos setValue:image forKey:kCIInputImageKey];
    [lanczos setValue:@(scale) forKey:kCIInputScaleKey];
    [lanczos setValue:@1.0 forKey:kCIInputAspectRatioKey];
    CIImage *scaledImage = lanczos.outputImage;
    [_ciContext render:scaledImage toCVPixelBuffer:output];
    return output;
}

static void ESCompressionOutputCallback(void *refCon, void *frameRefCon,
                                        OSStatus status, VTEncodeInfoFlags infoFlags,
                                        CMSampleBufferRef sampleBuffer) {
    ESEncoderPipeline *self = (__bridge ESEncoderPipeline *)refCon;
    if (status != noErr) {
        NSLog(@"[encoder] compression callback error %d", (int)status);
        return;
    }
    if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    if (infoFlags & kVTEncodeInfo_FrameDropped) return;
    CFRetain(sampleBuffer);
    dispatch_async(self->_writerQueue, ^{
        [self _handleEncodedVideoSample:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

// _writerQueue
- (void)_handleEncodedVideoSample:(CMSampleBufferRef)sampleBuffer {
    if (_state == ESPipelineStateFailed || _state == ESPipelineStateFinished) return;

    if (_outputMode == ESEncoderOutputModeMPEG2TS) {
        [self _muxVideoSampleTS:sampleBuffer];
        return;
    }

    if (!_videoFormat) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (!format) return;
        _videoFormat = (CMFormatDescriptionRef)CFRetain(format);
        _firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        // If no audio shows up shortly, start without it rather than never starting.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), _writerQueue, ^{
            if (!self->_writer && self->_state == ESPipelineStateRunning) {
                self->_audioTimeoutFired = YES;
                NSLog(@"[%@] no audio within 2 s, starting writer without audio", self->_name);
                [self _startWriterIfReady];
            }
        });
    }

    if (!_writer) {
        if (_pendingVideo.count < ESPendingVideoCap) {
            [_pendingVideo addObject:(__bridge id)sampleBuffer];
        }
        [self _startWriterIfReady];
        return;
    }
    [self _appendToWriter:sampleBuffer isVideo:YES];
}

#pragma mark - Audio path

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!atomic_load(&_accepting)) return;
    CFRetain(sampleBuffer);
    dispatch_async(_writerQueue, ^{
        [self _handleAudioSample:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

// _writerQueue
- (void)_handleAudioSample:(CMSampleBufferRef)sampleBuffer {
    if (_state == ESPipelineStateFailed || _state == ESPipelineStateFinished) return;

    if (_outputMode == ESEncoderOutputModeHLSSegments ||
        _outputMode == ESEncoderOutputModeMPEG2TS) {
        // Both broadcast containers take pre-compressed audio, so PCM is AAC
        // encoded here. HLS packets re-enter as sample buffers, TS packets go
        // straight into the transport stream.
        [self _convertAndForwardPCM:sampleBuffer];
        return;
    }

    if (!_audioFormat) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (format) _audioFormat = (CMFormatDescriptionRef)CFRetain(format);
    }
    [self _enqueueAudioSample:sampleBuffer];
}

// _writerQueue. Common tail for both PCM (archive) and AAC (broadcast) audio.
- (void)_enqueueAudioSample:(CMSampleBufferRef)sampleBuffer {
    if (!_writer) {
        if (_pendingAudio.count >= ESPendingAudioCap) [_pendingAudio removeObjectAtIndex:0];
        [_pendingAudio addObject:(__bridge id)sampleBuffer];
        [self _startWriterIfReady];
        return;
    }
    if (_audioInput) [self _appendToWriter:sampleBuffer isVideo:NO];
}

#pragma mark - AAC conversion (HLS mode)

typedef struct {
    const void *data;
    UInt32 byteCount;
    UInt32 bytesPerFrame;
    UInt32 channels;
    BOOL consumed;
} ESConverterFeed;

static OSStatus ESConverterInputProc(AudioConverterRef converter, UInt32 *ioNumberDataPackets,
                                     AudioBufferList *ioData,
                                     AudioStreamPacketDescription * _Nullable *outDataPacketDescription,
                                     void *inUserData) {
    ESConverterFeed *feed = (ESConverterFeed *)inUserData;
    if (feed->consumed) {
        *ioNumberDataPackets = 0;
        return kAudioConverterErr_UnspecifiedError; // no more input this pass
    }
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = (void *)feed->data;
    ioData->mBuffers[0].mDataByteSize = feed->byteCount;
    ioData->mBuffers[0].mNumberChannels = feed->channels;
    *ioNumberDataPackets = feed->byteCount / feed->bytesPerFrame;
    feed->consumed = YES;
    return noErr;
}

// _writerQueue
- (BOOL)_setupAudioConverterWithSourceASBD:(const AudioStreamBasicDescription *)source {
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    _pcmASBD = *source;
    AudioStreamBasicDescription dest = {0};
    dest.mSampleRate = source->mSampleRate;
    dest.mFormatID = kAudioFormatMPEG4AAC;
    dest.mChannelsPerFrame = MIN(2, MAX(1, source->mChannelsPerFrame));
    dest.mFramesPerPacket = 1024;
    OSStatus status = AudioConverterNew(source, &dest, &_audioConverter);
    if (status != noErr || !_audioConverter) {
        NSLog(@"[%@] AudioConverterNew failed %d", _name, (int)status);
        return NO;
    }
    _aacASBD = dest;
    UInt32 bitRate = 128000;
    AudioConverterSetProperty(_audioConverter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
    UInt32 size = sizeof(_maxAACPacketSize);
    _maxAACPacketSize = 0;
    AudioConverterGetProperty(_audioConverter, kAudioConverterPropertyMaximumOutputPacketSize,
                              &size, &_maxAACPacketSize);
    if (_maxAACPacketSize == 0) _maxAACPacketSize = 8192;
    _pcmFIFO = [NSMutableData data];
    _audioAnchorPTS = kCMTimeInvalid;
    _aacPacketsProduced = 0;
    _aacPrimingFrames = 0;
    NSLog(@"[%@] AAC converter ready, %d Hz %u ch", _name,
          (int)dest.mSampleRate, (unsigned)dest.mChannelsPerFrame);
    return YES;
}

// _writerQueue
- (void)_convertAndForwardPCM:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = format
        ? CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)format) : NULL;
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) return;

    // Route changes can alter the source format; rebuild the converter and
    // re-anchor on the incoming clock. Timestamps stay on the session clock.
    if (!_audioConverter ||
        _pcmASBD.mSampleRate != asbd->mSampleRate ||
        _pcmASBD.mChannelsPerFrame != asbd->mChannelsPerFrame ||
        _pcmASBD.mBytesPerFrame != asbd->mBytesPerFrame ||
        _pcmASBD.mFormatFlags != asbd->mFormatFlags) {
        if (![self _setupAudioConverterWithSourceASBD:asbd]) return;
    }
    if (CMTIME_IS_INVALID(_audioAnchorPTS)) {
        _audioAnchorPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return;
    size_t length = CMBlockBufferGetDataLength(block);
    NSUInteger offset = _pcmFIFO.length;
    [_pcmFIFO increaseLengthBy:length];
    CMBlockBufferCopyDataBytes(block, 0, length, (uint8_t *)_pcmFIFO.mutableBytes + offset);

    const UInt32 bytesPerFrame = _pcmASBD.mBytesPerFrame;
    const UInt32 packetBytes = 1024 * bytesPerFrame;
    while (_pcmFIFO.length >= packetBytes) {
        ESConverterFeed feed = {
            .data = _pcmFIFO.bytes,
            .byteCount = packetBytes,
            .bytesPerFrame = bytesPerFrame,
            .channels = _pcmASBD.mChannelsPerFrame,
            .consumed = NO,
        };
        NSMutableData *packet = [NSMutableData dataWithLength:_maxAACPacketSize];
        AudioBufferList outputList = {
            .mNumberBuffers = 1,
            .mBuffers = {{
                .mNumberChannels = _aacASBD.mChannelsPerFrame,
                .mDataByteSize = _maxAACPacketSize,
                .mData = packet.mutableBytes,
            }},
        };
        AudioStreamPacketDescription packetDescription = {0};
        UInt32 packetCount = 1;
        OSStatus status = AudioConverterFillComplexBuffer(_audioConverter, ESConverterInputProc,
                                                          &feed, &packetCount, &outputList,
                                                          &packetDescription);
        [_pcmFIFO replaceBytesInRange:NSMakeRange(0, packetBytes) withBytes:NULL length:0];
        if ((status != noErr && packetCount == 0) || outputList.mBuffers[0].mDataByteSize == 0) {
            if (status != noErr && status != kAudioConverterErr_UnspecifiedError) {
                NSLog(@"[%@] AAC convert error %d", _name, (int)status);
            }
            continue;
        }

        if (!_audioFormat) {
            [self _createAACFormatDescription];
            if (!_audioFormat) continue;
        }

        // Sample accurate mapping onto the session clock. Priming shifts the
        // packet timeline back so decoded audio lines up with the source PCM.
        int64_t frames = (int64_t)_aacPacketsProduced * 1024 - (int64_t)_aacPrimingFrames;
        CMTime pts = CMTimeAdd(_audioAnchorPTS, CMTimeMake(frames, (int32_t)_aacASBD.mSampleRate));
        _aacPacketsProduced++;

        if (_outputMode == ESEncoderOutputModeMPEG2TS) {
            [self _muxAudioTSPacket:packet.bytes
                             length:outputList.mBuffers[0].mDataByteSize
                                pts:pts];
            continue;
        }

        UInt32 aacBytes = outputList.mBuffers[0].mDataByteSize;
        packetDescription.mStartOffset = 0;
        packetDescription.mDataByteSize = aacBytes;
        CMBlockBufferRef aacBlock = NULL;
        if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, aacBytes, kCFAllocatorDefault,
                                               NULL, 0, aacBytes, 0, &aacBlock) != kCMBlockBufferNoErr) {
            continue;
        }
        CMBlockBufferReplaceDataBytes(packet.bytes, aacBlock, 0, aacBytes);
        CMSampleBufferRef aacSample = NULL;
        OSStatus wrapStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            kCFAllocatorDefault, aacBlock, (CMAudioFormatDescriptionRef)_audioFormat,
            1, pts, &packetDescription, &aacSample);
        CFRelease(aacBlock);
        if (wrapStatus != noErr || !aacSample) continue;
        [self _enqueueAudioSample:aacSample];
        CFRelease(aacSample);
    }
}

// _writerQueue. Cookie and priming are only reliable once the converter has run.
- (void)_createAACFormatDescription {
    AudioConverterPrimeInfo primeInfo = {0};
    UInt32 size = sizeof(primeInfo);
    if (AudioConverterGetProperty(_audioConverter, kAudioConverterPrimeInfo, &size, &primeInfo) == noErr) {
        _aacPrimingFrames = primeInfo.leadingFrames;
    }
    if (_aacPrimingFrames == 0) _aacPrimingFrames = 2112; // AAC-LC default

    void *cookie = NULL;
    UInt32 cookieSize = 0;
    if (AudioConverterGetPropertyInfo(_audioConverter, kAudioConverterCompressionMagicCookie,
                                      &cookieSize, NULL) == noErr && cookieSize > 0) {
        cookie = malloc(cookieSize);
        if (AudioConverterGetProperty(_audioConverter, kAudioConverterCompressionMagicCookie,
                                      &cookieSize, cookie) != noErr) {
            free(cookie);
            cookie = NULL;
            cookieSize = 0;
        }
    }
    CMAudioFormatDescriptionRef aacFormat = NULL;
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &_aacASBD, 0, NULL,
                                                     cookieSize, cookie, NULL, &aacFormat);
    if (cookie) free(cookie);
    if (status == noErr && aacFormat) {
        _audioFormat = aacFormat; // retained, gates writer start
        NSLog(@"[%@] AAC format ready, priming %u frames", _name, (unsigned)_aacPrimingFrames);
    } else {
        NSLog(@"[%@] AAC format description failed %d", _name, (int)status);
    }
}

#pragma mark - MPEG-2 TS muxing (TS mode)

// YouTube HLS ingestion requires M2TS segments with a PAT and PMT as the
// first two packets. AVFoundation writes no transport streams, so this is
// the hand-rolled packaging layer: Annex-B video, ADTS audio, PES, TS.

static const uint16_t ESTSPIDPMT = 0x1000;
static const uint16_t ESTSPIDVideo = 0x0100;
static const uint16_t ESTSPIDAudio = 0x0101;

static uint32_t ESCRC32MPEG(const uint8_t *data, size_t length) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04C11DB7 : (crc << 1);
        }
    }
    return crc;
}

// One PSI section in its own packet, stuffed with 0xFF.
static void ESTSWriteSection(NSMutableData *segment, uint16_t pid, uint8_t *continuity,
                             const uint8_t *section, size_t sectionLength) {
    uint8_t packet[188];
    memset(packet, 0xFF, sizeof(packet));
    packet[0] = 0x47;
    packet[1] = 0x40 | ((pid >> 8) & 0x1F);
    packet[2] = pid & 0xFF;
    packet[3] = 0x10 | *continuity;
    packet[4] = 0x00; // pointer_field
    memcpy(packet + 5, section, sectionLength);
    *continuity = (*continuity + 1) & 0x0F;
    [segment appendBytes:packet length:188];
}

static void ESTSAppendCRC(uint8_t *section, size_t bodyLength) {
    uint32_t crc = ESCRC32MPEG(section, bodyLength);
    section[bodyLength] = (crc >> 24) & 0xFF;
    section[bodyLength + 1] = (crc >> 16) & 0xFF;
    section[bodyLength + 2] = (crc >> 8) & 0xFF;
    section[bodyLength + 3] = crc & 0xFF;
}

// A complete PES packet split into 188 byte TS packets. The first packet can
// carry a PCR; the last is padded with adaptation field stuffing.
static void ESTSWritePES(NSMutableData *segment, uint16_t pid, uint8_t *continuity,
                         NSData *pes, BOOL withPCR, uint64_t pcrBase90) {
    const uint8_t *bytes = pes.bytes;
    size_t remaining = pes.length;
    BOOL first = YES;
    while (remaining > 0) {
        uint8_t packet[188];
        memset(packet, 0xFF, sizeof(packet));
        packet[0] = 0x47;
        packet[1] = (first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
        packet[2] = pid & 0xFF;
        BOOL pcrHere = first && withPCR;
        size_t chunk;
        size_t headerLength;
        if (pcrHere || remaining < 184) {
            size_t contentLength = pcrHere ? 7 : 0;   // flags plus 6 byte PCR
            size_t minHeader = 4 + 1 + contentLength; // header, af length byte, af content
            chunk = MIN(remaining, 188 - minHeader);
            size_t stuffing = (188 - minHeader) - chunk;
            size_t afLength = contentLength + stuffing;
            packet[3] = 0x30 | *continuity;
            packet[4] = (uint8_t)afLength;
            if (afLength > 0) {
                packet[5] = pcrHere ? 0x10 : 0x00;
                if (pcrHere) {
                    uint64_t base = pcrBase90 & 0x1FFFFFFFFULL;
                    packet[6] = (base >> 25) & 0xFF;
                    packet[7] = (base >> 17) & 0xFF;
                    packet[8] = (base >> 9) & 0xFF;
                    packet[9] = (base >> 1) & 0xFF;
                    packet[10] = (uint8_t)(((base & 1) << 7) | 0x7E);
                    packet[11] = 0x00;
                }
            }
            headerLength = 4 + 1 + afLength;
        } else {
            chunk = 184;
            headerLength = 4;
            packet[3] = 0x10 | *continuity;
        }
        memcpy(packet + headerLength, bytes, chunk);
        bytes += chunk;
        remaining -= chunk;
        *continuity = (*continuity + 1) & 0x0F;
        [segment appendBytes:packet length:188];
        first = NO;
    }
}

static void ESAppendTimestamp(uint8_t *out, uint8_t prefix, uint64_t value90) {
    uint64_t v = value90 & 0x1FFFFFFFFULL;
    out[0] = (uint8_t)(prefix | ((v >> 29) & 0x0E) | 0x01);
    out[1] = (uint8_t)(v >> 22);
    out[2] = (uint8_t)(0x01 | ((v >> 14) & 0xFE));
    out[3] = (uint8_t)(v >> 7);
    out[4] = (uint8_t)(0x01 | ((v << 1) & 0xFE));
}

// Video carries PTS plus DTS (equal in this no-reorder stream); strict ingest
// demuxers require explicit DTS on H.264. Audio carries PTS only.
static NSData *ESMakePES(uint8_t streamID, NSData *payload, uint64_t pts90, BOOL withDTS) {
    size_t timestampBytes = withDTS ? 10 : 5;
    NSMutableData *pes = [NSMutableData dataWithCapacity:payload.length + 9 + timestampBytes];
    size_t bodyLength = 3 + timestampBytes + payload.length;
    size_t lengthField = (bodyLength > 0xFFFF) ? 0 : bodyLength; // 0 = unbounded, video only
    uint8_t header[19];
    header[0] = 0x00; header[1] = 0x00; header[2] = 0x01; header[3] = streamID;
    header[4] = (uint8_t)(lengthField >> 8);
    header[5] = (uint8_t)(lengthField & 0xFF);
    header[6] = 0x80;
    header[7] = withDTS ? 0xC0 : 0x80;
    header[8] = (uint8_t)timestampBytes;
    if (withDTS) {
        ESAppendTimestamp(header + 9, 0x30, pts90);
        ESAppendTimestamp(header + 14, 0x10, pts90);
    } else {
        ESAppendTimestamp(header + 9, 0x20, pts90);
    }
    [pes appendBytes:header length:9 + timestampBytes];
    [pes appendData:payload];
    return pes;
}

// _writerQueue
- (void)_writePATAndPMT {
    // PAT: one program, PMT on ESTSPIDPMT.
    // Body is 12 bytes; the CRC occupies the final 4 of the 16 byte section.
    uint8_t pat[16] = {
        0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
        0x00, 0x01,
        (uint8_t)(0xE0 | ((ESTSPIDPMT >> 8) & 0x1F)), (uint8_t)(ESTSPIDPMT & 0xFF),
    };
    ESTSAppendCRC(pat, 12);
    ESTSWriteSection(_tsSegment, 0x0000, &_ccPAT, pat, sizeof(pat));

    // PMT: video on the video PID (also the PCR PID), ADTS AAC on the audio PID.
    // Body is 22 bytes; the CRC occupies the final 4 of the 26 byte section.
    uint8_t videoStreamType = (_codec == kCMVideoCodecType_HEVC) ? 0x24 : 0x1B;
    uint8_t pmt[26] = {
        0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00,
        (uint8_t)(0xE0 | ((ESTSPIDVideo >> 8) & 0x1F)), (uint8_t)(ESTSPIDVideo & 0xFF),
        0xF0, 0x00,
        videoStreamType, (uint8_t)(0xE0 | ((ESTSPIDVideo >> 8) & 0x1F)), (uint8_t)(ESTSPIDVideo & 0xFF), 0xF0, 0x00,
        0x0F, (uint8_t)(0xE0 | ((ESTSPIDAudio >> 8) & 0x1F)), (uint8_t)(ESTSPIDAudio & 0xFF), 0xF0, 0x00,
    };
    ESTSAppendCRC(pmt, 22);
    ESTSWriteSection(_tsSegment, ESTSPIDPMT, &_ccPMT, pmt, sizeof(pmt));

    // Minimal SDT naming the single service. Some ingest demuxers expect it.
    static const char *provider = "ESCapture";
    static const char *service = "ESCapture";
    uint8_t providerLength = (uint8_t)strlen(provider);
    uint8_t serviceLength = (uint8_t)strlen(service);
    uint8_t descriptorLength = 1 + 1 + providerLength + 1 + serviceLength; // type, lens, names
    uint8_t loopLength = 2 + 1 + 2 + 2 + descriptorLength;
    uint8_t sectionLength = (uint8_t)(8 + loopLength + 4); // after the length field, through CRC
    uint8_t sdt[64];
    size_t i = 0;
    sdt[i++] = 0x42; // table_id: SDT, actual transport stream
    sdt[i++] = 0xF0 | ((sectionLength >> 8) & 0x0F);
    sdt[i++] = sectionLength & 0xFF;
    sdt[i++] = 0x00; sdt[i++] = 0x01; // transport_stream_id
    sdt[i++] = 0xC1;                  // version 0, current
    sdt[i++] = 0x00; sdt[i++] = 0x00; // section 0 of 0
    sdt[i++] = 0xFF; sdt[i++] = 0x01; // original_network_id
    sdt[i++] = 0xFF;                  // reserved
    sdt[i++] = 0x00; sdt[i++] = 0x01; // service_id
    sdt[i++] = 0xFC;                  // no EIT
    sdt[i++] = 0x80 | ((descriptorLength + 2) >> 8 & 0x0F); // running, not scrambled
    sdt[i++] = (uint8_t)(descriptorLength + 2);
    sdt[i++] = 0x48;                  // service_descriptor
    sdt[i++] = descriptorLength;
    sdt[i++] = 0x01;                  // digital television service
    sdt[i++] = providerLength;
    memcpy(sdt + i, provider, providerLength); i += providerLength;
    sdt[i++] = serviceLength;
    memcpy(sdt + i, service, serviceLength); i += serviceLength;
    ESTSAppendCRC(sdt, i);
    ESTSWriteSection(_tsSegment, 0x0011, &_ccSDT, sdt, i + 4);
}

- (uint64_t)_ts90kFromPTS:(CMTime)pts {
    CMTime rebased = CMTimeSubtract(pts, _tsBasePTS);
    return (uint64_t)llround(CMTimeGetSeconds(rebased) * 90000.0);
}

// _writerQueue
- (void)_muxVideoSampleTS:(CMSampleBufferRef)sampleBuffer {
    BOOL keyframe = [self _isSyncSample:sampleBuffer];
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!_tsSegment && !keyframe) return; // segments must start on a keyframe

    if (!_tsSegment && CMTIME_IS_INVALID(_tsBasePTS)) {
        // Rebase the 90 kHz clock so PCR starts small and positive.
        _tsBasePTS = CMTimeSubtract(pts, CMTimeMake(90000, 90000));
    }
    if (_tsSegment && keyframe) [self _emitTSSegmentEndingAt:pts];
    if (!_tsSegment) {
        _tsSegment = [NSMutableData dataWithCapacity:(NSUInteger)(_averageBitRate / 4)];
        _tsSegmentStartPTS = pts;
        [self _writePATAndPMT];
    }

    NSData *accessUnit = [self _annexBAccessUnitFromSampleBuffer:sampleBuffer keyframe:keyframe];
    if (!accessUnit) return;
    uint64_t pts90 = [self _ts90kFromPTS:pts];
    uint64_t pcr90 = (pts90 > 36000) ? pts90 - 36000 : 0; // PCR leads PTS by 400 ms
    NSData *pes = ESMakePES(0xE0, accessUnit, pts90, YES);
    ESTSWritePES(_tsSegment, ESTSPIDVideo, &_ccVideo, pes, YES, pcr90);
    _tsLastVideoPTS = pts;
    _framesEncoded++;
}

// _writerQueue
- (void)_muxAudioTSPacket:(const void *)bytes length:(UInt32)length pts:(CMTime)pts {
    if (!_tsSegment) return; // audio before the first video keyframe is dropped
    NSUInteger sampleRate = (NSUInteger)_aacASBD.mSampleRate;
    static const NSUInteger rates[] = {96000, 88200, 64000, 48000, 44100, 32000,
                                       24000, 22050, 16000, 12000, 11025, 8000};
    uint8_t rateIndex = 3; // 48 kHz
    for (uint8_t i = 0; i < 12; i++) {
        if (rates[i] == sampleRate) { rateIndex = i; break; }
    }
    uint8_t channels = (uint8_t)_aacASBD.mChannelsPerFrame;
    size_t frameLength = length + 7;
    uint8_t adts[7] = {
        0xFF, 0xF1,
        (uint8_t)((0 << 6) | (rateIndex << 2) | ((channels >> 2) & 0x01)), // AAC-LC profile
        (uint8_t)(((channels & 0x03) << 6) | ((frameLength >> 11) & 0x03)),
        (uint8_t)((frameLength >> 3) & 0xFF),
        (uint8_t)(((frameLength & 0x07) << 5) | 0x1F),
        0xFC,
    };
    NSMutableData *adtsFrame = [NSMutableData dataWithCapacity:frameLength];
    [adtsFrame appendBytes:adts length:7];
    [adtsFrame appendBytes:bytes length:length];
    NSData *pes = ESMakePES(0xC0, adtsFrame, [self _ts90kFromPTS:pts], NO);
    ESTSWritePES(_tsSegment, ESTSPIDAudio, &_ccAudio, pes, NO, 0);
}

// _writerQueue
- (BOOL)_cacheParameterSetsFromFormat:(CMFormatDescriptionRef)format {
    NSMutableArray<NSData *> *sets = [NSMutableArray array];
    int nalLengthSize = 4;
    size_t count = 0;
    const uint8_t *bytes = NULL;
    size_t size = 0;
    if (_codec == kCMVideoCodecType_HEVC) {
        if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &bytes, &size,
                                                               &count, &nalLengthSize) != noErr) {
            return NO;
        }
        [sets addObject:[NSData dataWithBytes:bytes length:size]];
        for (size_t i = 1; i < count; i++) {
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &bytes, &size,
                                                                   NULL, NULL) == noErr) {
                [sets addObject:[NSData dataWithBytes:bytes length:size]];
            }
        }
    } else {
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &bytes, &size,
                                                               &count, &nalLengthSize) != noErr) {
            return NO;
        }
        [sets addObject:[NSData dataWithBytes:bytes length:size]];
        for (size_t i = 1; i < count; i++) {
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &bytes, &size,
                                                                   NULL, NULL) == noErr) {
                [sets addObject:[NSData dataWithBytes:bytes length:size]];
            }
        }
    }
    if (sets.count < 2) return NO;
    _parameterSets = sets;
    _nalLengthSize = nalLengthSize;
    return YES;
}

- (NSData *)_annexBAccessUnitFromSampleBuffer:(CMSampleBufferRef)sampleBuffer keyframe:(BOOL)keyframe {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!_parameterSets && format) {
        if (![self _cacheParameterSetsFromFormat:format]) return nil;
    }
    if (!_parameterSets) return nil;

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return nil;
    size_t totalLength = CMBlockBufferGetDataLength(block);
    NSMutableData *avcc = [NSMutableData dataWithLength:totalLength];
    if (CMBlockBufferCopyDataBytes(block, 0, totalLength, avcc.mutableBytes) != kCMBlockBufferNoErr) {
        return nil;
    }

    static const uint8_t startCode[4] = {0x00, 0x00, 0x00, 0x01};
    static const uint8_t audH264[2] = {0x09, 0xF0};
    static const uint8_t audHEVC[3] = {0x46, 0x01, 0x50};
    NSMutableData *annexB = [NSMutableData dataWithCapacity:totalLength + 128];
    [annexB appendBytes:startCode length:4];
    if (_codec == kCMVideoCodecType_HEVC) {
        [annexB appendBytes:audHEVC length:sizeof(audHEVC)];
    } else {
        [annexB appendBytes:audH264 length:sizeof(audH264)];
    }
    if (keyframe) {
        for (NSData *parameterSet in _parameterSets) {
            [annexB appendBytes:startCode length:4];
            [annexB appendData:parameterSet];
        }
    }
    const uint8_t *cursor = avcc.bytes;
    size_t offset = 0;
    while (offset + _nalLengthSize <= totalLength) {
        uint32_t nalLength = 0;
        for (int i = 0; i < _nalLengthSize; i++) {
            nalLength = (nalLength << 8) | cursor[offset + i];
        }
        offset += _nalLengthSize;
        if (nalLength == 0 || offset + nalLength > totalLength) break;
        [annexB appendBytes:startCode length:4];
        [annexB appendBytes:cursor + offset length:nalLength];
        offset += nalLength;
    }
    return annexB;
}

// _writerQueue
- (void)_emitTSSegmentEndingAt:(CMTime)endPTS {
    if (!_tsSegment || _tsSegment.length == 0) {
        _tsSegment = nil;
        return;
    }
    double duration = CMTimeGetSeconds(CMTimeSubtract(endPTS, _tsSegmentStartPTS));
    if (duration <= 0 || duration > 10) duration = _segmentSeconds;
    NSData *data = [_tsSegment copy];
    _tsSegment = nil;
    _segmentIndex++;
    NSLog(@"[%@] TS segment %llu bytes %lu duration %.3f",
          _name, _segmentIndex, (unsigned long)data.length, duration);
    id<ESEncoderPipelineDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(encoderPipeline:didOutputSegmentData:segmentType:duration:)]) {
        [delegate encoderPipeline:self didOutputSegmentData:data
                      segmentType:AVAssetSegmentTypeSeparable duration:duration];
    }
}

#pragma mark - Writer

// _writerQueue. The writer is created lazily because the compressed video format
// description and the audio format are only known once media flows.
- (void)_startWriterIfReady {
    if (_writer || _state != ESPipelineStateRunning) return;
    if (!_videoFormat) return;
    if (!_audioFormat && !_audioTimeoutFired) return;

    NSError *error = nil;
    AVAssetWriter *writer = nil;
    if (_outputMode == ESEncoderOutputModeFragmentedFile) {
        writer = [[AVAssetWriter alloc] initWithURL:_fileURL fileType:AVFileTypeQuickTimeMovie error:&error];
        if (!writer) { [self _failWithError:error]; return; }
        // Fragmented movie: a crash loses at most the final fragment.
        writer.movieFragmentInterval = CMTimeMakeWithSeconds(_segmentSeconds, 1000);
    } else {
        UTType *type = [UTType typeWithIdentifier:AVFileTypeMPEG4];
        writer = [[AVAssetWriter alloc] initWithContentType:type];
        writer.outputFileTypeProfile = AVFileTypeProfileMPEG4AppleHLS;
        // Passthrough of both tracks is only supported with manual segmenting.
        // Segments are cut in _appendToWriter on each keyframe, which the
        // compression session emits every _segmentSeconds.
        writer.preferredOutputSegmentInterval = kCMTimeIndefinite;
        writer.delegate = self;
    }

    // Passthrough video: the VTCompressionSession already produced the bitstream.
    AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                        outputSettings:nil
                                                                      sourceFormatHint:_videoFormat];
    videoInput.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:videoInput]) {
        [self _failWithError:[NSError errorWithDomain:@"ESEncoder" code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Cannot add video input"}]];
        return;
    }
    [writer addInput:videoInput];

    AVAssetWriterInput *audioInput = nil;
    if (_audioFormat) {
        if (_outputMode == ESEncoderOutputModeHLSSegments) {
            // Audio arrives as AAC from the converter; the segment writer
            // requires passthrough on every input.
            audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                            outputSettings:nil
                                                          sourceFormatHint:_audioFormat];
        } else {
            const AudioStreamBasicDescription *asbd =
                CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)_audioFormat);
            NSInteger channels = asbd ? MIN(2, MAX(1, (NSInteger)asbd->mChannelsPerFrame)) : 1;
            NSDictionary *aacSettings = @{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @48000,
                AVNumberOfChannelsKey: @(channels),
                AVEncoderBitRateKey: @128000,
            };
            audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                            outputSettings:aacSettings];
        }
        audioInput.expectsMediaDataInRealTime = YES;
        if ([writer canAddInput:audioInput]) {
            [writer addInput:audioInput];
        } else {
            NSLog(@"[%@] cannot add audio input, continuing without audio", _name);
            audioInput = nil;
        }
    }

    if (![writer startWriting]) {
        [self _failWithError:writer.error];
        return;
    }
    [writer startSessionAtSourceTime:_firstVideoPTS];

    _writer = writer;
    _videoInput = videoInput;
    _audioInput = audioInput;
    NSLog(@"[%@] writer started at %.3f, audio %@", _name,
          CMTimeGetSeconds(_firstVideoPTS), audioInput ? @"yes" : @"no");

    NSArray *pendingVideo = [_pendingVideo copy];
    NSArray *pendingAudio = [_pendingAudio copy];
    [_pendingVideo removeAllObjects];
    [_pendingAudio removeAllObjects];
    for (id boxed in pendingVideo) {
        [self _appendToWriter:(__bridge CMSampleBufferRef)boxed isVideo:YES];
    }
    if (_audioInput) {
        for (id boxed in pendingAudio) {
            [self _appendToWriter:(__bridge CMSampleBufferRef)boxed isVideo:NO];
        }
    }
}

// _writerQueue
- (void)_appendToWriter:(CMSampleBufferRef)sampleBuffer isVideo:(BOOL)isVideo {
    AVAssetWriterInput *input = isVideo ? _videoInput : _audioInput;
    if (!input || !_writer) return;
    // The segment writer rejects samples earlier than initialSegmentStartTime.
    // Buffered audio from before the first video frame is dropped, not trimmed.
    if (!isVideo && _outputMode == ESEncoderOutputModeHLSSegments) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (CMTimeCompare(pts, _firstVideoPTS) < 0) return;
    }
    if (_writer.status != AVAssetWriterStatusWriting) {
        if (_writer.status == AVAssetWriterStatusFailed) [self _failWithError:_writer.error];
        return;
    }
    if (!input.readyForMoreMediaData) {
        if (_outputMode == ESEncoderOutputModeFragmentedFile) {
            // The archive path never sheds media. Brief backpressure wait off the
            // capture queues; the writer catches up within a fragment.
            int spins = 0;
            while (!input.readyForMoreMediaData && _writer.status == AVAssetWriterStatusWriting && spins < 250) {
                usleep(2000);
                spins++;
            }
            if (!input.readyForMoreMediaData) {
                NSLog(@"[%@] writer input stalled, sample lost", _name);
                return;
            }
        } else {
            return; // broadcast sheds under pressure
        }
    }
    // Manual segmenting: close the running segment right before each new
    // keyframe so every segment starts on a sync sample.
    if (isVideo && _outputMode == ESEncoderOutputModeHLSSegments && _framesEncoded > 0 &&
        [self _isSyncSample:sampleBuffer]) {
        [_writer flushSegment];
    }
    if (![input appendSampleBuffer:sampleBuffer]) {
        NSLog(@"[%@] append failed: %@", _name, _writer.error);
        if (_writer.status == AVAssetWriterStatusFailed) [self _failWithError:_writer.error];
        return;
    }
    if (isVideo) _framesEncoded++;
}

- (BOOL)_isSyncSample:(CMSampleBufferRef)sampleBuffer {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return YES;
    CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
    CFTypeRef notSync = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
    return (notSync == NULL) || !CFBooleanGetValue(notSync);
}

// _writerQueue
- (void)_failWithError:(NSError *)error {
    if (_state == ESPipelineStateFailed) return;
    _state = ESPipelineStateFailed;
    atomic_store(&_accepting, NO);
    NSLog(@"[%@] FAILED: %@", _name, error);
    id<ESEncoderPipelineDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(encoderPipeline:didFailWithError:)]) {
        [delegate encoderPipeline:self didFailWithError:error];
    }
}

#pragma mark - AVAssetWriterDelegate (HLS mode)

- (void)assetWriter:(AVAssetWriter *)writer
didOutputSegmentData:(NSData *)segmentData
        segmentType:(AVAssetSegmentType)segmentType
      segmentReport:(nullable AVAssetSegmentReport *)segmentReport {
    double duration = _segmentSeconds;
    for (AVAssetSegmentTrackReport *track in segmentReport.trackReports) {
        if ([track.mediaType isEqualToString:AVMediaTypeVideo] && CMTIME_IS_NUMERIC(track.duration)) {
            duration = CMTimeGetSeconds(track.duration);
            break;
        }
    }
    _segmentIndex++;
    NSLog(@"[%@] segment %llu type %ld bytes %lu duration %.3f",
          _name, _segmentIndex, (long)segmentType, (unsigned long)segmentData.length, duration);
    id<ESEncoderPipelineDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(encoderPipeline:didOutputSegmentData:segmentType:duration:)]) {
        [delegate encoderPipeline:self didOutputSegmentData:segmentData segmentType:segmentType duration:duration];
    }
}

#pragma mark - Finish

- (void)finishWithCompletionHandler:(void (^)(void))handler {
    atomic_store(&_accepting, NO);
    dispatch_async(_writerQueue, ^{
        if (self->_state != ESPipelineStateRunning && self->_state != ESPipelineStateFailed) {
            if (handler) dispatch_async(dispatch_get_main_queue(), handler);
            return;
        }
        if (self->_state == ESPipelineStateRunning) self->_state = ESPipelineStateFinishing;
        if (self->_vtSession) {
            VTCompressionSessionCompleteFrames(self->_vtSession, kCMTimeInvalid);
        }
        // Flushed frames land on this queue behind us; finish after they drain.
        dispatch_async(self->_writerQueue, ^{
            [self _finishWriterWithHandler:handler];
        });
    });
}

// _writerQueue
- (void)_finishWriterWithHandler:(void (^)(void))handler {
    if (_vtSession) {
        VTCompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    [_pendingVideo removeAllObjects];
    [_pendingAudio removeAllObjects];

    if (_outputMode == ESEncoderOutputModeMPEG2TS) {
        if (_tsSegment && CMTIME_IS_VALID(_tsLastVideoPTS)) {
            CMTime tail = CMTimeAdd(_tsLastVideoPTS, CMTimeMake(1, (int32_t)_frameRate));
            [self _emitTSSegmentEndingAt:tail];
        }
        _tsSegment = nil;
        _state = ESPipelineStateFinished;
        NSLog(@"[%@] finished, %llu video frames, %llu TS segments", _name, _framesEncoded, _segmentIndex);
        if (handler) dispatch_async(dispatch_get_main_queue(), handler);
        return;
    }

    AVAssetWriter *writer = _writer;
    if (writer && writer.status == AVAssetWriterStatusWriting) {
        [_videoInput markAsFinished];
        [_audioInput markAsFinished];
        NSString *name = _name;
        uint64_t frames = _framesEncoded;
        [writer finishWritingWithCompletionHandler:^{
            NSLog(@"[%@] finished, status %ld, %llu video frames", name, (long)writer.status, frames);
            if (handler) dispatch_async(dispatch_get_main_queue(), handler);
        }];
        _state = ESPipelineStateFinished;
        return;
    }
    if (writer && writer.status == AVAssetWriterStatusFailed) {
        NSLog(@"[%@] writer already failed: %@", _name, writer.error);
    }
    _state = ESPipelineStateFinished;
    NSLog(@"[%@] finished without active writer", _name);
    if (handler) dispatch_async(dispatch_get_main_queue(), handler);
}

@end
