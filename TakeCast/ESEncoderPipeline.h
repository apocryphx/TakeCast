//
//  ESEncoderPipeline.h
//  TakeCast
//
//  One class, two instances, differing only in a configuration dictionary.
//  The archive instance encodes HEVC and muxes a fragmented QuickTime movie
//  to disk. The broadcast instance downscales, encodes H.264, and emits fMP4
//  HLS segments through its delegate. Timestamps pass through untouched.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// Configuration dictionary keys.
extern NSString * const ESEncoderConfigNameKey;              // NSString, for logs
extern NSString * const ESEncoderConfigCodecKey;             // NSNumber, CMVideoCodecType
extern NSString * const ESEncoderConfigWidthKey;             // NSNumber
extern NSString * const ESEncoderConfigHeightKey;            // NSNumber
extern NSString * const ESEncoderConfigFrameRateKey;         // NSNumber
extern NSString * const ESEncoderConfigAverageBitRateKey;    // NSNumber, bits per second
extern NSString * const ESEncoderConfigConstrainDataRateKey; // NSNumber BOOL, near-CBR limits
extern NSString * const ESEncoderConfigOutputModeKey;        // NSNumber, ESEncoderOutputMode
extern NSString * const ESEncoderConfigFileURLKey;           // NSURL, fragmented file mode only
extern NSString * const ESEncoderConfigSegmentSecondsKey;    // NSNumber, default 2

typedef NS_ENUM(NSInteger, ESEncoderOutputMode) {
    ESEncoderOutputModeFragmentedFile,
    ESEncoderOutputModeHLSSegments,   // fMP4, Apple style, init segment plus media
    ESEncoderOutputModeMPEG2TS,       // MPEG-2 TS, what YouTube HLS ingestion requires
};

@class ESEncoderPipeline;

@protocol ESEncoderPipelineDelegate <NSObject>
@optional
// HLS mode only. Called on an internal queue.
- (void)encoderPipeline:(ESEncoderPipeline *)pipeline
   didOutputSegmentData:(NSData *)data
            segmentType:(AVAssetSegmentType)segmentType
               duration:(double)duration;
- (void)encoderPipeline:(ESEncoderPipeline *)pipeline didFailWithError:(NSError *)error;
@end

@interface ESEncoderPipeline : NSObject

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) uint64_t videoFramesEncoded;
@property (nonatomic, weak, nullable) id<ESEncoderPipelineDelegate> delegate;

- (nullable instancetype)initWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                                         error:(NSError **)error;

- (BOOL)startWithError:(NSError **)error;

// Feed raw capture buffers. Safe to call from the capture queues.
// The pipeline downscales internally when the buffer differs from its target size.
- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// Flushes the encoder, finishes the writer, then calls the handler on the main queue.
- (void)finishWithCompletionHandler:(void (^_Nullable)(void))handler;

@end

NS_ASSUME_NONNULL_END
