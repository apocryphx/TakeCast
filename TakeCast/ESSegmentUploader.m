//
//  ESSegmentUploader.m
//  TakeCast
//

#import "ESSegmentUploader.h"

static const NSUInteger ESUploaderQueueCap = 30;
// YouTube HLS ingestion: a playlist must not contain more than five
// outstanding segments.
static const NSUInteger ESPlaylistWindow = 5;
static const NSTimeInterval ESUploaderMaxBackoff = 32.0;
static const NSTimeInterval ESUploadTimeout = 10.0;

@interface ESSegmentEntry : NSObject
@property (nonatomic) uint64_t sequence;        // media sequence number, init segments carry the next media seq
@property (nonatomic) NSString *filename;
@property (nonatomic) NSData *data;
@property (nonatomic) double duration;
@property (nonatomic) BOOL isInit;
@property (nonatomic) BOOL discontinuityBefore; // media entry that follows a new init segment
@property (nonatomic) NSString *mapFilename;    // init segment this media entry belongs to
@end
@implementation ESSegmentEntry
@end

@implementation ESSegmentUploader {
    NSString *_ingestURLString;
    NSURLSession *_urlSession;
    dispatch_queue_t _queue;         // owns all mutable state below
    NSMutableArray<ESSegmentEntry *> *_pending;
    NSMutableArray<ESSegmentEntry *> *_playlistWindow; // recently uploaded media entries
    BOOL _running;
    BOOL _uploading;
    uint64_t _mediaSequence;         // next media sequence number
    uint64_t _initIndex;
    NSString *_currentMapFilename;   // for entries as they are enqueued
    BOOL _pendingDiscontinuity;
    NSUInteger _failureCount;
    NSDate *_lastAckDate;
    uint64_t _uploadedCount;
    uint64_t _droppedCount;
    NSString *_lastFailureDescription;
    double _lastMediaUploadRatio;
    BOOL _finishing;
    BOOL _endListSent;
    void (^_finishCompletion)(void);
}

- (instancetype)initWithIngestURLString:(NSString *)ingestURLString {
    NSString *trimmed = [ingestURLString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return nil;
    NSURLComponents *probe = [NSURLComponents componentsWithString:trimmed];
    if (!probe || !probe.host) return nil;

    self = [super init];
    if (self) {
        _ingestURLString = trimmed;
        _queue = dispatch_queue_create("es.uploader", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableArray array];
        _playlistWindow = [NSMutableArray array];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = ESUploadTimeout;
        config.timeoutIntervalForResource = ESUploadTimeout * 2;
        config.networkServiceType = NSURLNetworkServiceTypeAVStreaming;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

- (void)start {
    dispatch_async(_queue, ^{
        self->_running = YES;
        NSLog(@"[uploader] started for host %@", [NSURLComponents componentsWithString:self->_ingestURLString].host);
        [self _primeConnection];
        [self _pump];
    });
}

// _queue. The first request to the ingest host pays for DNS, TCP, and TLS,
// which took 2.4 s cold and starved the capture path at recording start.
// Pay that cost at uploader start, before any frames exist.
- (void)_primeConnection {
    NSURLComponents *components = [NSURLComponents componentsWithString:_ingestURLString];
    if (!components.host) return;
    NSURLComponents *root = [[NSURLComponents alloc] init];
    root.scheme = components.scheme ?: @"https";
    root.host = components.host;
    root.path = @"/";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:root.URL];
    request.HTTPMethod = @"HEAD";
    NSDate *start = [NSDate date];
    NSURLSessionDataTask *task =
    [_urlSession dataTaskWithRequest:request
                   completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        NSLog(@"[uploader] connection primed in %.2fs (http %ld)",
              -[start timeIntervalSinceNow], (long)((NSHTTPURLResponse *)response).statusCode);
    }];
    [task resume];
}

- (void)stop {
    dispatch_async(_queue, ^{
        self->_running = NO;
        [self->_pending removeAllObjects];
        [self->_urlSession invalidateAndCancel];
        NSLog(@"[uploader] stopped, uploaded %llu, dropped %llu", self->_uploadedCount, self->_droppedCount);
        [self _completeFinish];
    });
}

- (void)finishAndSignalEndWithCompletion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        if (!self->_running || self->_finishing) {
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        self->_finishing = YES;
        self->_finishCompletion = [completion copy];
        NSLog(@"[uploader] finishing, %lu segments still queued", (unsigned long)self->_pending.count);
        [self _pump];
        // A dead network must not wedge shutdown: end regardless after 10 s.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), self->_queue, ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_finishing && !strongSelf->_endListSent) {
                NSLog(@"[uploader] drain timed out, sending end of stream now");
                [strongSelf _sendEndList];
            }
        });
    });
}

// _queue. The goodbye: the last playlist, with EXT-X-ENDLIST appended.
- (void)_sendEndList {
    if (_endListSent) return;
    _endListSent = YES;
    NSString *playlist = [[self _playlistText] stringByAppendingString:@"#EXT-X-ENDLIST\n"];
    NSURL *url = [self _uploadURLForFilename:@"media.m3u8"];
    if (!url || _playlistWindow.count == 0) {
        [self _shutDown];
        return;
    }
    NSLog(@"[uploader] >> POST media.m3u8 with EXT-X-ENDLIST");
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/vnd.apple.mpegurl" forHTTPHeaderField:@"Content-Type"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionUploadTask *task =
    [_urlSession uploadTaskWithRequest:request fromData:[playlist dataUsingEncoding:NSUTF8StringEncoding]
                     completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        NSLog(@"[uploader] << end of stream playlist http %ld%@",
              (long)((NSHTTPURLResponse *)response).statusCode,
              error ? [NSString stringWithFormat:@" error: %@", error.localizedDescription] : @"");
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) dispatch_async(strongSelf->_queue, ^{ [strongSelf _shutDown]; });
    }];
    [task resume];
}

// _queue
- (void)_shutDown {
    _running = NO;
    _finishing = NO;
    [_pending removeAllObjects];
    [_urlSession finishTasksAndInvalidate];
    NSLog(@"[uploader] finished, uploaded %llu, dropped %llu", _uploadedCount, _droppedCount);
    [self _completeFinish];
}

// _queue
- (void)_completeFinish {
    if (_finishCompletion) {
        void (^completion)(void) = _finishCompletion;
        _finishCompletion = nil;
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

#pragma mark - Enqueue

- (void)enqueueSegmentData:(NSData *)data type:(ESSegmentType)type duration:(double)duration {
    NSData *copied = [data copy];
    dispatch_async(_queue, ^{
        if (!self->_running) return;
        ESSegmentEntry *entry = [[ESSegmentEntry alloc] init];
        entry.data = copied;
        entry.duration = duration;
        if (type == ESSegmentTypeInitialization) {
            entry.isInit = YES;
            entry.filename = [NSString stringWithFormat:@"init_%03llu.mp4", self->_initIndex];
            self->_currentMapFilename = entry.filename;
            // A new init after media has flowed means the encoder restarted.
            if (self->_mediaSequence > 0) self->_pendingDiscontinuity = YES;
            self->_initIndex++;
        } else {
            entry.sequence = self->_mediaSequence;
            entry.filename = [NSString stringWithFormat:@"seg_%05llu.%@", self->_mediaSequence,
                              self.usesTransportStream ? @"ts" : @"m4s"];
            entry.mapFilename = self->_currentMapFilename;
            entry.discontinuityBefore = self->_pendingDiscontinuity;
            self->_pendingDiscontinuity = NO;
            self->_mediaSequence++;
        }
        [self->_pending addObject:entry];

        // Bounded queue: shed the oldest media first, never an init segment.
        while (self->_pending.count > ESUploaderQueueCap) {
            ESSegmentEntry *victim = nil;
            for (ESSegmentEntry *candidate in self->_pending) {
                if (!candidate.isInit) { victim = candidate; break; }
            }
            if (!victim) break;
            [self->_pending removeObject:victim];
            self->_droppedCount++;
            NSLog(@"[uploader] queue full, dropped %@", victim.filename);
        }
        [self _pump];
    });
}

#pragma mark - Upload loop

// _queue
- (void)_pump {
    if (!_running || _uploading) return;
    if (_pending.count == 0) {
        if (_finishing) [self _sendEndList];
        return;
    }
    ESSegmentEntry *entry = _pending.firstObject;
    _uploading = YES;

    NSURL *url = [self _uploadURLForFilename:entry.filename];
    if (!url) {
        NSLog(@"[uploader] bad ingest URL, cannot build upload URL");
        _uploading = NO;
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:self.usesTransportStream ? @"video/mp2t" : @"video/mp4"
   forHTTPHeaderField:@"Content-Type"];

    NSLog(@"[uploader] >> %@ %@ (%lu bytes)", request.HTTPMethod, entry.filename,
          (unsigned long)entry.data.length);
    NSDate *requestStart = [NSDate date];
    __weak typeof(self) weakSelf = self;
    NSURLSessionUploadTask *task =
    [_urlSession uploadTaskWithRequest:request fromData:entry.data
                     completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf->_queue, ^{
            [strongSelf _handleResultForEntry:entry response:(NSHTTPURLResponse *)response
                                         body:body elapsed:-[requestStart timeIntervalSinceNow]
                                        error:error];
        });
    }];
    [task resume];
}

static NSString *ESBodyExcerpt(NSData *body) {
    if (body.length == 0) return @"(empty body)";
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) return [NSString stringWithFormat:@"(%lu bytes, not UTF-8)", (unsigned long)body.length];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length > 400) text = [[text substringToIndex:400] stringByAppendingString:@"..."];
    return text.length ? text : @"(blank body)";
}

// _queue
- (void)_handleResultForEntry:(ESSegmentEntry *)entry
                     response:(NSHTTPURLResponse *)response
                         body:(NSData *)body
                      elapsed:(NSTimeInterval)elapsed
                        error:(NSError *)error {
    _uploading = NO;
    if (!_running) return;

    NSLog(@"[uploader] << %@ http %ld in %.2fs, body: %@",
          entry.filename, (long)response.statusCode, elapsed, ESBodyExcerpt(body));

    BOOL success = (error == nil && response.statusCode >= 200 && response.statusCode < 300);
    if (success) {
        [_pending removeObject:entry];
        _failureCount = 0;
        _lastFailureDescription = nil;
        _uploadedCount++;
        _lastAckDate = [NSDate date];
        if (!entry.isInit && entry.duration > 0) {
            _lastMediaUploadRatio = elapsed / entry.duration;
        }
        if (!entry.isInit) {
            [_playlistWindow addObject:entry];
            while (_playlistWindow.count > ESPlaylistWindow) [_playlistWindow removeObjectAtIndex:0];
            [self _uploadPlaylist];
        }
        NSLog(@"[uploader] ack %@ (%lu bytes)", entry.filename, (unsigned long)entry.data.length);
        [self _pump];
        return;
    }

    _failureCount++;
    NSTimeInterval backoff = MIN(ESUploaderMaxBackoff, pow(2.0, (double)(_failureCount - 1)));
    _lastFailureDescription = error
        ? [NSString stringWithFormat:@"%@ (%ld)", error.localizedDescription, (long)error.code]
        : [NSString stringWithFormat:@"http %ld", (long)response.statusCode];
    NSLog(@"[uploader] %@ failed (%@, http %ld), retry in %.0f s",
          entry.filename, error.localizedDescription ?: @"", (long)response.statusCode, backoff);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)), _queue, ^{
        [weakSelf _pump];
    });
}

// _queue. The playlist is advisory state for the ingest server; a failed
// playlist upload is repaired by the next one, so it does not gate the ack.
- (void)_uploadPlaylist {
    if (_playlistWindow.count == 0) return;
    NSString *playlist = [self _playlistText];
    NSURL *url = [self _uploadURLForFilename:@"media.m3u8"];
    if (!url) return;
    NSLog(@"[uploader] >> POST media.m3u8:\n%@", playlist);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/vnd.apple.mpegurl" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionUploadTask *task =
    [_urlSession uploadTaskWithRequest:request fromData:[playlist dataUsingEncoding:NSUTF8StringEncoding]
                     completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSLog(@"[uploader] << media.m3u8 http %ld, body: %@%@",
              (long)http.statusCode, ESBodyExcerpt(body),
              error ? [NSString stringWithFormat:@" error: %@", error.localizedDescription] : @"");
    }];
    [task resume];
}

// _queue
- (NSString *)_playlistText {
    double targetDuration = 2.0;
    for (ESSegmentEntry *entry in _playlistWindow) {
        targetDuration = MAX(targetDuration, entry.duration);
    }
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"#EXTM3U\n"];
    [text appendFormat:@"#EXT-X-VERSION:%d\n", self.usesTransportStream ? 3 : 7];
    [text appendFormat:@"#EXT-X-TARGETDURATION:%.0f\n", ceil(targetDuration)];
    [text appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%llu\n", _playlistWindow.firstObject.sequence];
    NSString *activeMap = nil;
    for (ESSegmentEntry *entry in _playlistWindow) {
        if (entry.discontinuityBefore && entry != _playlistWindow.firstObject) {
            [text appendString:@"#EXT-X-DISCONTINUITY\n"];
        }
        if (entry.mapFilename && ![entry.mapFilename isEqualToString:activeMap]) {
            [text appendFormat:@"#EXT-X-MAP:URI=\"%@\"\n", entry.mapFilename];
            activeMap = entry.mapFilename;
        }
        [text appendFormat:@"#EXTINF:%.3f,\n%@\n", entry.duration, entry.filename];
    }
    return text;
}

- (nullable NSURL *)_uploadURLForFilename:(NSString *)filename {
    NSURLComponents *components = [NSURLComponents componentsWithString:_ingestURLString];
    if (!components) return nil;
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSUInteger fileIndex = NSNotFound;
    for (NSUInteger i = 0; i < items.count; i++) {
        if ([items[i].name isEqualToString:@"file"]) { fileIndex = i; break; }
    }
    NSURLQueryItem *fileItem = [NSURLQueryItem queryItemWithName:@"file" value:filename];
    if (fileIndex == NSNotFound) {
        [items addObject:fileItem];
    } else {
        items[fileIndex] = fileItem;
    }
    components.queryItems = items;
    return components.URL;
}

#pragma mark - Health

- (NSTimeInterval)secondsSinceLastAck {
    __block NSDate *ack = nil;
    dispatch_sync(_queue, ^{ ack = self->_lastAckDate; });
    if (!ack) return -1;
    return [[NSDate date] timeIntervalSinceDate:ack];
}

- (NSString *)lastFailureDescription {
    __block NSString *description = nil;
    dispatch_sync(_queue, ^{ description = self->_lastFailureDescription; });
    return description;
}

- (double)lastMediaUploadRatio {
    __block double ratio = 0;
    dispatch_sync(_queue, ^{ ratio = self->_lastMediaUploadRatio; });
    return ratio;
}

- (NSUInteger)queuedCount {
    __block NSUInteger count = 0;
    dispatch_sync(_queue, ^{ count = self->_pending.count; });
    return count;
}

- (uint64_t)uploadedCount {
    __block uint64_t count = 0;
    dispatch_sync(_queue, ^{ count = self->_uploadedCount; });
    return count;
}

- (uint64_t)droppedCount {
    __block uint64_t count = 0;
    dispatch_sync(_queue, ^{ count = self->_droppedCount; });
    return count;
}

@end
