//
//  ESSettings.m
//  TakeCast
//

#import "ESSettings.h"

static NSString * const ESDefaultsFrameRateKey = @"ESFrameRate";
static NSString * const ESDefaultsIngestURLKey = @"ESIngestURL";
static NSString * const ESDefaultsBroadcastCodecKey = @"ESBroadcastCodec"; // 0 H.264, 1 HEVC
static NSString * const ESDefaultsMicPatternKey = @"ESMicPattern"; // 0 cardioid, 1 omni
static NSString * const ESDefaultsStreamingEnabledKey = @"ESStreamingEnabled";
static NSString * const ESDefaultsOnboardingKey = @"ESOnboardingCompleted";
static NSString * const ESDefaultsInProgressKey = @"ESRecordingInProgress"; // {name, start}
static NSString * const ESDefaultsStoppedEarlyKey = @"ESRecordingsStoppedEarly"; // [name]

// The archive name prefix stays as the first release wrote it, so existing
// recordings appear in the list next to new ones.
static NSString * const ESArchivePrefix = @"ESCapture-";

NSNotificationName const ESRecordingFinalizedNotification = @"ESRecordingFinalizedNotification";

NSString *ESAppName(void) {
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    return name.length > 0 ? name : @"TakeCast";
}

@implementation ESSettings

+ (NSUserDefaults *)_defaults { return NSUserDefaults.standardUserDefaults; }

+ (NSInteger)frameRate {
    return [[self _defaults] integerForKey:ESDefaultsFrameRateKey] == 30 ? 30 : 24;
}

+ (void)setFrameRate:(NSInteger)frameRate {
    [[self _defaults] setInteger:(frameRate == 30 ? 30 : 24) forKey:ESDefaultsFrameRateKey];
}

+ (BOOL)broadcastUsesHEVC {
    return [[self _defaults] integerForKey:ESDefaultsBroadcastCodecKey] == 1;
}

+ (void)setBroadcastUsesHEVC:(BOOL)hevc {
    [[self _defaults] setInteger:hevc ? 1 : 0 forKey:ESDefaultsBroadcastCodecKey];
}

+ (BOOL)directionalMicrophone {
    return [[self _defaults] integerForKey:ESDefaultsMicPatternKey] != 1;
}

+ (void)setDirectionalMicrophone:(BOOL)directional {
    [[self _defaults] setInteger:directional ? 0 : 1 forKey:ESDefaultsMicPatternKey];
}

+ (NSString *)ingestURL {
    return [[[self _defaults] stringForKey:ESDefaultsIngestURLKey]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

+ (void)setIngestURL:(NSString *)ingestURL {
    [[self _defaults] setObject:ingestURL ?: @"" forKey:ESDefaultsIngestURLKey];
}

+ (BOOL)streamingEnabled {
    id value = [[self _defaults] objectForKey:ESDefaultsStreamingEnabledKey];
    if (!value) return self.ingestURL.length > 0;
    return [value boolValue];
}

+ (void)setStreamingEnabled:(BOOL)enabled {
    [[self _defaults] setBool:enabled forKey:ESDefaultsStreamingEnabledKey];
}

+ (NSString *)effectiveIngestURL {
    return self.streamingEnabled ? self.ingestURL : @"";
}

+ (NSString *)ingestHost {
    NSString *saved = self.ingestURL;
    if (saved.length == 0) return nil;
    return [NSURLComponents componentsWithString:saved].host;
}

+ (NSString *)destinationDescription {
    if (!self.streamingEnabled || self.ingestURL.length == 0) return @"Record only";
    NSString *host = self.ingestHost;
    return host ? [NSString stringWithFormat:@"Stream: %@", host] : @"invalid URL";
}

+ (BOOL)hasCompletedOnboarding {
    return [[self _defaults] boolForKey:ESDefaultsOnboardingKey];
}

+ (void)setHasCompletedOnboarding:(BOOL)completed {
    [[self _defaults] setBool:completed forKey:ESDefaultsOnboardingKey];
}

+ (NSString *)sessionSummary {
    NSString *destination;
    if (self.effectiveIngestURL.length == 0) {
        destination = @"Record only";
    } else {
        // a.upload.youtube.com reads as youtube.com: the operator needs to see
        // where the stream goes, not which ingest node takes it.
        NSArray<NSString *> *labels = [self.ingestHost componentsSeparatedByString:@"."];
        destination = labels.count >= 2
            ? [[labels subarrayWithRange:NSMakeRange(labels.count - 2, 2)] componentsJoinedByString:@"."]
            : (self.ingestHost ?: @"invalid URL");
    }
    return [NSString stringWithFormat:@"%ld fps · %@ · %@ · %@",
            (long)self.frameRate,
            self.broadcastUsesHEVC ? @"HEVC" : @"H.264",
            self.directionalMicrophone ? @"CARD" : @"OMNI",
            destination];
}

#pragma mark Recordings

+ (NSURL *)documentsURL {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                inDomains:NSUserDomainMask].firstObject;
}

+ (NSArray<NSURL *> *)recordingURLs {
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:[self documentsURL]
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
    NSMutableArray<NSURL *> *recordings = [NSMutableArray array];
    for (NSURL *url in contents) {
        if ([url.lastPathComponent hasPrefix:ESArchivePrefix]
            && [url.pathExtension.lowercaseString isEqualToString:@"mov"]) {
            [recordings addObject:url];
        }
    }
    // The name carries yyyyMMdd-HHmmss, so name order is time order.
    [recordings sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [b.lastPathComponent compare:a.lastPathComponent];
    }];
    return recordings;
}

+ (void)markRecordingStartedAtURL:(NSURL *)url {
    [[self _defaults] setObject:@{@"name": url.lastPathComponent, @"start": [NSDate date]}
                         forKey:ESDefaultsInProgressKey];
}

+ (void)markRecordingFinalizedAtURL:(NSURL *)url {
    if ([[self inProgressRecordingName] isEqualToString:url.lastPathComponent]) {
        [[self _defaults] removeObjectForKey:ESDefaultsInProgressKey];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:ESRecordingFinalizedNotification object:url];
}

+ (NSString *)inProgressRecordingName {
    NSDictionary *marker = [[self _defaults] dictionaryForKey:ESDefaultsInProgressKey];
    NSString *name = marker[@"name"];
    return [name isKindOfClass:NSString.class] ? name : nil;
}

+ (NSString *)resolveLeftoverRecordingMarker {
    NSString *name = [self inProgressRecordingName];
    if (!name) return nil;
    NSMutableArray<NSString *> *early = [[[self _defaults] stringArrayForKey:ESDefaultsStoppedEarlyKey] mutableCopy]
                                        ?: [NSMutableArray array];
    if (![early containsObject:name]) [early addObject:name];
    [[self _defaults] setObject:early forKey:ESDefaultsStoppedEarlyKey];
    [[self _defaults] removeObjectForKey:ESDefaultsInProgressKey];
    return name;
}

+ (BOOL)recordingWasStoppedEarly:(NSString *)fileName {
    return [[[self _defaults] stringArrayForKey:ESDefaultsStoppedEarlyKey] containsObject:fileName];
}

+ (void)forgetRecording:(NSString *)fileName {
    NSMutableArray<NSString *> *early = [[[self _defaults] stringArrayForKey:ESDefaultsStoppedEarlyKey] mutableCopy];
    if (![early containsObject:fileName]) return;
    [early removeObject:fileName];
    [[self _defaults] setObject:early forKey:ESDefaultsStoppedEarlyKey];
}

@end
