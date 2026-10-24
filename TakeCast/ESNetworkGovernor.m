//
//  ESNetworkGovernor.m
//  TakeCast
//

#import "ESNetworkGovernor.h"
#import "ESSegmentUploader.h"

// Proactive policy: viewers do not notice 720p on a laptop, but everyone
// notices buffering. The broadcast joins at the reduced tier, promotes only
// with proven headroom, and demotes on the first sign of saturation while
// the viewer's buffer is still full.
//
// Demote from full when 2 of the last 3 segments used more than 85 percent
// of real time to upload, or delivery visibly lags.
static const double ESDemoteRatio = 0.85;
static const NSTimeInterval ESDemoteAckAge = 5.0;
static const NSUInteger ESDemoteQueueDepth = 2;
// Promote only when the uplink is loafing: 45 s of segments using under 45
// percent of real time (full tier needs roughly double the reduced rate).
static const double ESPromoteRatio = 0.45;
static const NSTimeInterval ESPromoteAckAge = 3.0;
static const int ESPromoteAfterGoodSeconds = 45;
// A demotion raises the bar: no promotion within 90 s of stepping down.
static const NSTimeInterval ESPromoteBackoffAfterDemote = 90.0;
static const NSTimeInterval ESMinSecondsBetweenChanges = 10.0;

@implementation ESNetworkGovernor {
    __weak ESSegmentUploader *_uploader;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    ESBroadcastTier _currentTier;
    uint64_t _lastUploadedCount;   // detects fresh segment completions
    double _recentRatios[3];       // last 3 distinct segment upload ratios
    int _recentRatioCount;
    int _consecutiveGood;
    NSDate *_lastChange;
    NSDate *_lastDemote;
}

- (instancetype)initWithUploader:(ESSegmentUploader *)uploader {
    self = [super init];
    if (self) {
        _uploader = uploader;
        _queue = dispatch_queue_create("es.networkgovernor", DISPATCH_QUEUE_SERIAL);
        _currentTier = ESBroadcastTierReduced; // join low, promote with evidence
        _lastChange = [NSDate date];
    }
    return self;
}

- (ESBroadcastTier)currentTier {
    __block ESBroadcastTier tier;
    dispatch_sync(_queue, ^{ tier = self->_currentTier; });
    return tier;
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_timer) return;
        self->_recentRatioCount = 0;
        self->_consecutiveGood = 0;
        self->_lastUploadedCount = 0;
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf _sample]; });
        dispatch_resume(self->_timer);
        NSLog(@"[netgov] started");
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (self->_timer) {
            dispatch_source_cancel(self->_timer);
            self->_timer = nil;
            NSLog(@"[netgov] stopped");
        }
    });
}

// _queue, once per second
- (void)_sample {
    ESSegmentUploader *uploader = _uploader;
    if (!uploader) return;
    NSTimeInterval ackAge = uploader.secondsSinceLastAck;
    NSUInteger queued = uploader.queuedCount;

    // Record each freshly completed segment's upload ratio.
    uint64_t uploaded = uploader.uploadedCount;
    if (uploaded != _lastUploadedCount) {
        _lastUploadedCount = uploaded;
        double ratio = uploader.lastMediaUploadRatio;
        if (ratio > 0) {
            _recentRatios[2] = _recentRatios[1];
            _recentRatios[1] = _recentRatios[0];
            _recentRatios[0] = ratio;
            if (_recentRatioCount < 3) _recentRatioCount++;
        }
    }
    int slowSegments = 0;
    double worstRatio = 0;
    for (int i = 0; i < _recentRatioCount; i++) {
        if (_recentRatios[i] > ESDemoteRatio) slowSegments++;
        worstRatio = MAX(worstRatio, _recentRatios[i]);
    }
    NSTimeInterval sinceChange = -[_lastChange timeIntervalSinceNow];

    if (_currentTier == ESBroadcastTierFull && sinceChange > ESMinSecondsBetweenChanges) {
        BOOL saturating = (_recentRatioCount >= 2 && slowSegments >= 2);
        BOOL lagging = (ackAge > ESDemoteAckAge) || (queued >= ESDemoteQueueDepth);
        if (saturating || lagging) {
            NSString *reason = [NSString stringWithFormat:
                @"uplink headroom gone (worst ratio %.2f, ack %.0fs, queued %lu)",
                worstRatio, MAX(0, ackAge), (unsigned long)queued];
            _lastDemote = [NSDate date];
            [self _transitionTo:ESBroadcastTierReduced reason:reason];
            return;
        }
    }

    if (_currentTier == ESBroadcastTierReduced) {
        BOOL roomy = (ackAge >= 0) && (ackAge < ESPromoteAckAge) && (queued == 0) &&
                     (_recentRatioCount == 3) && (worstRatio < ESPromoteRatio);
        _consecutiveGood = roomy ? _consecutiveGood + 1 : 0;
        NSTimeInterval sinceDemote = _lastDemote ? -[_lastDemote timeIntervalSinceNow] : DBL_MAX;
        if (_consecutiveGood >= ESPromoteAfterGoodSeconds &&
            sinceChange > ESMinSecondsBetweenChanges &&
            sinceDemote > ESPromoteBackoffAfterDemote) {
            [self _transitionTo:ESBroadcastTierFull
                         reason:[NSString stringWithFormat:
                                 @"uplink has headroom (worst ratio %.2f for %d s)",
                                 worstRatio, ESPromoteAfterGoodSeconds]];
        }
    }
}

// _queue
- (void)_transitionTo:(ESBroadcastTier)tier reason:(NSString *)reason {
    _currentTier = tier;
    _recentRatioCount = 0;
    _consecutiveGood = 0;
    _lastChange = [NSDate date];
    NSLog(@"[netgov] tier %@ (%@)", [ESThermalGovernor nameForTier:tier], reason);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate networkGovernor:self didChangeTier:tier reason:reason];
    });
}

@end
