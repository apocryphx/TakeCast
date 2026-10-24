//
//  ESSegmentUploader.h
//  TakeCast
//
//  Plain NSURLSession delivery of fMP4 HLS segments to a YouTube HLS ingest
//  URL. Monotonic sequence, bounded queue, exponential backoff, drop-oldest
//  under sustained failure. Network trouble never touches the archive path.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ESSegmentType) {
    ESSegmentTypeInitialization,
    ESSegmentTypeMedia,
};

@interface ESSegmentUploader : NSObject

// The ingest URL as pasted by the user, for example:
// https://a.upload.youtube.com/http_upload_hls?cid=xxxx-xxxx-xxxx-xxxx&copy=0&file=
- (nullable instancetype)initWithIngestURLString:(NSString *)ingestURLString;

// Set before start when segments are MPEG-2 TS rather than fMP4: filenames
// use .ts, the playlist declares version 3 and carries no EXT-X-MAP.
@property (atomic) BOOL usesTransportStream;

- (void)start;

// Immediate abort: cancels in-flight work and clears the queue.
- (void)stop;

// Graceful end: drains queued segments (bounded wait), then uploads a final
// playlist carrying EXT-X-ENDLIST so the ingest endpoint knows the stream
// completed rather than died. Completion fires on the main queue.
- (void)finishAndSignalEndWithCompletion:(void (^_Nullable)(void))completion;

// Thread safe. An initialization segment received mid-stream marks a
// discontinuity; the playlist switches maps for the following media segments.
- (void)enqueueSegmentData:(NSData *)data type:(ESSegmentType)type duration:(double)duration;

// Single health metric. Negative when nothing has been acknowledged yet.
@property (atomic, readonly) NSTimeInterval secondsSinceLastAck;

// Most recent upload failure, nil after a success. For the HUD and the log.
@property (atomic, readonly, nullable) NSString *lastFailureDescription;

// Upload time of the last media segment divided by its duration. Above 1.0
// means the uplink is slower than real time. Zero until the first upload.
@property (atomic, readonly) double lastMediaUploadRatio;

@property (atomic, readonly) NSUInteger queuedCount;
@property (atomic, readonly) uint64_t uploadedCount;
@property (atomic, readonly) uint64_t droppedCount;

@end

NS_ASSUME_NONNULL_END
