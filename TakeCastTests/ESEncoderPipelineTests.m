//
//  ESEncoderPipelineTests.m
//  TakeCastTests
//
//  Synthetic-buffer harness for the encode paths. Runs anywhere, no camera.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import "../TakeCast/ESEncoderPipeline.h"

@interface ESEncoderPipelineTests : XCTestCase <ESEncoderPipelineDelegate>
@end

@implementation ESEncoderPipelineTests {
    NSMutableArray<NSData *> *_initSegments;
    NSMutableArray<NSData *> *_mediaSegments;
    XCTestExpectation *_segmentExpectation;
}

- (void)setUp {
    [super setUp];
    _initSegments = [NSMutableArray array];
    _mediaSegments = [NSMutableArray array];
}

- (CMSampleBufferRef)_newSyntheticFrameWithIndex:(int)index
                                           width:(int)width
                                          height:(int)height
                                             fps:(int)fps CF_RETURNS_RETAINED {
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cvResult = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                            (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    XCTAssertEqual(cvResult, kCVReturnSuccess);

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    // Moving gradient so the encoder has real work to do.
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    for (int y = 0; y < height; y++) {
        memset(luma + y * lumaStride, (uint8_t)((y + index * 4) & 0xFF), width);
    }
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    for (int y = 0; y < height / 2; y++) {
        memset(chroma + y * chromaStride, 128, width);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CMVideoFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, fps),
        .presentationTimeStamp = CMTimeMake(index, fps),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL,
                                       format, &timing, &sampleBuffer);
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    return sampleBuffer;
}

// Feeds five seconds of synthetic video through the broadcast configuration and
// expects an fMP4 init segment plus media segments out of the delegate.
- (void)testHLSSegmentOutputFromSyntheticBuffers {
    NSDictionary *config = @{
        ESEncoderConfigNameKey: @"test-broadcast",
        ESEncoderConfigCodecKey: @(kCMVideoCodecType_H264),
        ESEncoderConfigWidthKey: @640,
        ESEncoderConfigHeightKey: @360,
        ESEncoderConfigFrameRateKey: @24,
        ESEncoderConfigAverageBitRateKey: @(1 * 1000 * 1000),
        ESEncoderConfigConstrainDataRateKey: @YES,
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeHLSSegments),
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    NSError *error = nil;
    ESEncoderPipeline *pipeline = [[ESEncoderPipeline alloc] initWithConfiguration:config error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    pipeline.delegate = self;
    XCTAssertTrue([pipeline startWithError:&error], @"%@", error);

    _segmentExpectation = [self expectationWithDescription:@"media segments emitted"];

    const int fps = 24;
    const int frames = fps * 5;
    for (int i = 0; i < frames; i++) {
        CMSampleBufferRef frame = [self _newSyntheticFrameWithIndex:i width:640 height:360 fps:fps];
        [pipeline appendVideoSampleBuffer:frame];
        CFRelease(frame);
        // Pace roughly at realtime so the audio timeout and the writer keep order.
        usleep(1000000 / fps / 2);
    }

    // Segments flow once the two second no-audio timeout starts the writer.
    [self waitForExpectations:@[_segmentExpectation] timeout:20.0];

    XCTestExpectation *finished = [self expectationWithDescription:@"pipeline finished"];
    [pipeline finishWithCompletionHandler:^{
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:10.0];

    XCTAssertGreaterThanOrEqual(_initSegments.count, (NSUInteger)1, @"expected an initialization segment");
    XCTAssertGreaterThanOrEqual(_mediaSegments.count, (NSUInteger)2, @"expected media segments");
    XCTAssertGreaterThan(_initSegments.firstObject.length, (NSUInteger)0);
    XCTAssertGreaterThan(_mediaSegments.firstObject.length, (NSUInteger)1000);
    XCTAssertGreaterThan(pipeline.videoFramesEncoded, (uint64_t)0);
}

// Feeds the archive configuration and verifies a playable fragmented movie
// lands on disk with a nonzero moov and growing size.
- (void)testFragmentedArchiveFromSyntheticBuffers {
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                  URLByAppendingPathComponent:@"ESCaptureTest.mov"];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];

    NSDictionary *config = @{
        ESEncoderConfigNameKey: @"test-archive",
        ESEncoderConfigCodecKey: @(kCMVideoCodecType_HEVC),
        ESEncoderConfigWidthKey: @640,
        ESEncoderConfigHeightKey: @360,
        ESEncoderConfigFrameRateKey: @24,
        ESEncoderConfigAverageBitRateKey: @(2 * 1000 * 1000),
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeFragmentedFile),
        ESEncoderConfigFileURLKey: url,
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    NSError *error = nil;
    ESEncoderPipeline *pipeline = [[ESEncoderPipeline alloc] initWithConfiguration:config error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    XCTAssertTrue([pipeline startWithError:&error], @"%@", error);

    const int fps = 24;
    const int frames = fps * 4;
    for (int i = 0; i < frames; i++) {
        CMSampleBufferRef frame = [self _newSyntheticFrameWithIndex:i width:640 height:360 fps:fps];
        [pipeline appendVideoSampleBuffer:frame];
        CFRelease(frame);
        usleep(1000000 / fps / 2);
    }
    // Allow the no-audio timeout to start the writer, then keep feeding a little.
    for (int i = frames; i < frames + fps; i++) {
        CMSampleBufferRef frame = [self _newSyntheticFrameWithIndex:i width:640 height:360 fps:fps];
        [pipeline appendVideoSampleBuffer:frame];
        CFRelease(frame);
        usleep(1000000 / fps / 2);
    }

    XCTestExpectation *finished = [self expectationWithDescription:@"pipeline finished"];
    [pipeline finishWithCompletionHandler:^{
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:15.0];

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    XCTAssertNotNil(attrs, @"archive file missing");
    XCTAssertGreaterThan([attrs fileSize], (unsigned long long)10000);

    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    XCTestExpectation *loaded = [self expectationWithDescription:@"asset readable"];
    [asset loadValuesAsynchronouslyForKeys:@[@"duration", @"tracks"] completionHandler:^{
        CMTime duration = asset.duration;
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 3.0);
        [loaded fulfill];
    }];
    [self waitForExpectations:@[loaded] timeout:10.0];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

- (CMSampleBufferRef)_newPCMBufferWithIndex:(int)index CF_RETURNS_RETAINED {
    const int frames = 1024;
    const double sampleRate = 48000.0;
    AudioStreamBasicDescription asbd = {
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2,
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 16,
    };
    CMAudioFormatDescriptionRef format = NULL;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &format);

    int16_t samples[1024];
    for (int i = 0; i < frames; i++) {
        double t = (index * frames + i) / sampleRate;
        samples[i] = (int16_t)(sin(2.0 * M_PI * 440.0 * t) * 8000.0);
    }
    CMBlockBufferRef block = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, sizeof(samples), kCFAllocatorDefault,
                                       NULL, 0, sizeof(samples), 0, &block);
    CMBlockBufferReplaceDataBytes(samples, block, 0, sizeof(samples));

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)sampleRate),
        .presentationTimeStamp = CMTimeMake(index * frames, (int32_t)sampleRate),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, format,
                         frames, 1, &timing, 0, NULL, &sampleBuffer);
    CFRelease(block);
    CFRelease(format);
    return sampleBuffer;
}

// Reproduces the app configuration: passthrough H.264 video plus PCM audio that
// the writer encodes to AAC, in HLS segment mode. Isolates the -11875 failure.
- (void)testHLSSegmentOutputWithWriterEncodedAudio {
    NSDictionary *config = @{
        ESEncoderConfigNameKey: @"test-broadcast-audio",
        ESEncoderConfigCodecKey: @(kCMVideoCodecType_H264),
        ESEncoderConfigWidthKey: @640,
        ESEncoderConfigHeightKey: @360,
        ESEncoderConfigFrameRateKey: @24,
        ESEncoderConfigAverageBitRateKey: @(1 * 1000 * 1000),
        ESEncoderConfigConstrainDataRateKey: @YES,
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeHLSSegments),
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    NSError *error = nil;
    ESEncoderPipeline *pipeline = [[ESEncoderPipeline alloc] initWithConfiguration:config error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    pipeline.delegate = self;
    XCTAssertTrue([pipeline startWithError:&error], @"%@", error);

    _segmentExpectation = [self expectationWithDescription:@"media segments emitted"];

    const int fps = 24;
    const int frames = fps * 5;
    int audioIndex = 0;
    for (int i = 0; i < frames; i++) {
        CMSampleBufferRef frame = [self _newSyntheticFrameWithIndex:i width:640 height:360 fps:fps];
        [pipeline appendVideoSampleBuffer:frame];
        CFRelease(frame);
        // Keep the 48 kHz audio clock slightly ahead of the video clock.
        while ((double)audioIndex * 1024.0 / 48000.0 < (double)(i + 1) / fps) {
            CMSampleBufferRef audio = [self _newPCMBufferWithIndex:audioIndex];
            [pipeline appendAudioSampleBuffer:audio];
            CFRelease(audio);
            audioIndex++;
        }
        usleep(1000000 / fps / 2);
    }

    [self waitForExpectations:@[_segmentExpectation] timeout:20.0];

    XCTestExpectation *finished = [self expectationWithDescription:@"pipeline finished"];
    [pipeline finishWithCompletionHandler:^{
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:10.0];

    XCTAssertGreaterThanOrEqual(_initSegments.count, (NSUInteger)1);
    XCTAssertGreaterThanOrEqual(_mediaSegments.count, (NSUInteger)2);
}

// The YouTube-facing configuration: H.264 plus AAC muxed into MPEG-2 TS
// segments. Asserts TS structure and writes the stream out for host-side
// ffprobe validation when run on the simulator.
- (void)testTSSegmentOutputFromSyntheticBuffers {
    NSDictionary *config = @{
        ESEncoderConfigNameKey: @"test-ts",
        ESEncoderConfigCodecKey: @(kCMVideoCodecType_H264),
        ESEncoderConfigWidthKey: @640,
        ESEncoderConfigHeightKey: @360,
        ESEncoderConfigFrameRateKey: @24,
        ESEncoderConfigAverageBitRateKey: @(1 * 1000 * 1000),
        ESEncoderConfigConstrainDataRateKey: @YES,
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeMPEG2TS),
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    NSError *error = nil;
    ESEncoderPipeline *pipeline = [[ESEncoderPipeline alloc] initWithConfiguration:config error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    pipeline.delegate = self;
    XCTAssertTrue([pipeline startWithError:&error], @"%@", error);

    _segmentExpectation = [self expectationWithDescription:@"TS segments emitted"];

    const int fps = 24;
    const int frames = fps * 40;
    int audioIndex = 0;
    for (int i = 0; i < frames; i++) {
        CMSampleBufferRef frame = [self _newSyntheticFrameWithIndex:i width:640 height:360 fps:fps];
        [pipeline appendVideoSampleBuffer:frame];
        CFRelease(frame);
        while ((double)audioIndex * 1024.0 / 48000.0 < (double)(i + 1) / fps) {
            CMSampleBufferRef audio = [self _newPCMBufferWithIndex:audioIndex];
            [pipeline appendAudioSampleBuffer:audio];
            CFRelease(audio);
            audioIndex++;
        }
        usleep(1000000 / fps / 2);
    }

    [self waitForExpectations:@[_segmentExpectation] timeout:20.0];

    XCTestExpectation *finished = [self expectationWithDescription:@"pipeline finished"];
    [pipeline finishWithCompletionHandler:^{
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:10.0];

    XCTAssertGreaterThanOrEqual(_mediaSegments.count, (NSUInteger)2);
    XCTAssertEqual(_initSegments.count, (NSUInteger)0, @"TS mode has no init segment");

    NSMutableData *stream = [NSMutableData data];
    for (NSData *segment in _mediaSegments) {
        XCTAssertEqual(segment.length % 188, (NSUInteger)0, @"segments must be whole TS packets");
        const uint8_t *bytes = segment.bytes;
        XCTAssertEqual(bytes[0], 0x47, @"first packet must carry a sync byte");
        // Spec: the first two packets in a segment are the PAT and the PMT.
        uint16_t firstPID = ((bytes[1] & 0x1F) << 8) | bytes[2];
        uint16_t secondPID = ((bytes[189] & 0x1F) << 8) | bytes[190];
        XCTAssertEqual(firstPID, 0x0000, @"first packet must be the PAT");
        XCTAssertEqual(secondPID, 0x1000, @"second packet must be the PMT");
        [stream appendData:segment];
    }
#if TARGET_OS_SIMULATOR
    // Host-visible paths so the stream can be validated and replayed by tools.
    NSURL *streamURL = [NSURL fileURLWithPath:@"/tmp/ESCaptureTSTest.ts"];
    [NSFileManager.defaultManager createDirectoryAtPath:@"/tmp/es_segments"
                            withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSUInteger i = 0; i < _mediaSegments.count; i++) {
        NSString *path = [NSString stringWithFormat:@"/tmp/es_segments/seg_%05lu.ts", (unsigned long)i];
        [_mediaSegments[i] writeToFile:path atomically:YES];
    }
#else
    NSURL *streamURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                        URLByAppendingPathComponent:@"ESCaptureTSTest.ts"];
#endif
    [stream writeToURL:streamURL atomically:YES];
    NSLog(@"[test-ts] wrote %lu bytes to %@", (unsigned long)stream.length, streamURL.path);
}

// HEVC variant of the TS path: stream type 0x24, VPS/SPS/PPS in band.
- (void)testTSHEVCSegmentOutputFromSyntheticBuffers {
    NSDictionary *config = @{
        ESEncoderConfigNameKey: @"test-ts-hevc",
        ESEncoderConfigCodecKey: @(kCMVideoCodecType_HEVC),
        ESEncoderConfigWidthKey: @640,
        ESEncoderConfigHeightKey: @360,
        ESEncoderConfigFrameRateKey: @24,
        ESEncoderConfigAverageBitRateKey: @(700 * 1000),
        ESEncoderConfigConstrainDataRateKey: @YES,
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeMPEG2TS),
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    NSError *error = nil;
    ESEncoderPipeline *pipeline = [[ESEncoderPipeline alloc] initWithConfiguration:config error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    pipeline.delegate = self;
    XCTAssertTrue([pipeline startWithError:&error], @"%@", error);

    _segmentExpectation = [self expectationWithDescription:@"HEVC TS segments emitted"];

    const int fps = 24;
    const int frames = fps * 5;
    int audioIndex = 0;
    for (int i = 0; i < frames; i++) {
        CMSampleBufferRef frame = [self _newSyntheticFrameWithIndex:i width:640 height:360 fps:fps];
        [pipeline appendVideoSampleBuffer:frame];
        CFRelease(frame);
        while ((double)audioIndex * 1024.0 / 48000.0 < (double)(i + 1) / fps) {
            CMSampleBufferRef audio = [self _newPCMBufferWithIndex:audioIndex];
            [pipeline appendAudioSampleBuffer:audio];
            CFRelease(audio);
            audioIndex++;
        }
        usleep(1000000 / fps / 2);
    }

    [self waitForExpectations:@[_segmentExpectation] timeout:20.0];

    XCTestExpectation *finished = [self expectationWithDescription:@"pipeline finished"];
    [pipeline finishWithCompletionHandler:^{
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:10.0];

    XCTAssertGreaterThanOrEqual(_mediaSegments.count, (NSUInteger)2);
    NSMutableData *stream = [NSMutableData data];
    for (NSData *segment in _mediaSegments) {
        XCTAssertEqual(segment.length % 188, (NSUInteger)0);
        const uint8_t *bytes = segment.bytes;
        XCTAssertEqual(bytes[0], 0x47);
        [stream appendData:segment];
    }
#if TARGET_OS_SIMULATOR
    [stream writeToURL:[NSURL fileURLWithPath:@"/tmp/ESCaptureTSHEVCTest.ts"] atomically:YES];
#endif
}

#pragma mark - ESEncoderPipelineDelegate

- (void)encoderPipeline:(ESEncoderPipeline *)pipeline
   didOutputSegmentData:(NSData *)data
            segmentType:(AVAssetSegmentType)segmentType
               duration:(double)duration {
    @synchronized (self) {
        if (segmentType == AVAssetSegmentTypeInitialization) {
            [_initSegments addObject:data];
        } else {
            [_mediaSegments addObject:data];
            if (_mediaSegments.count == 2) [_segmentExpectation fulfill];
        }
    }
}

@end
