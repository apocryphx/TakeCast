//
//  ESSettingsTests.m
//  TakeCastTests
//

#import <XCTest/XCTest.h>
#import "../TakeCast/ESSettings.h"

static NSArray<NSString *> *ESSettingsTestKeys(void) {
    return @[@"ESFrameRate", @"ESIngestURL", @"ESBroadcastCodec", @"ESMicPattern",
             @"ESStreamingEnabled", @"ESRecordingInProgress", @"ESRecordingsStoppedEarly"];
}

@interface ESSettingsTests : XCTestCase
@end

@implementation ESSettingsTests {
    NSDictionary<NSString *, id> *_saved;
}

- (void)setUp {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (NSString *key in ESSettingsTestKeys()) {
        id value = [defaults objectForKey:key];
        if (value) saved[key] = value;
        [defaults removeObjectForKey:key];
    }
    _saved = saved;
}

- (void)tearDown {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in ESSettingsTestKeys()) {
        [defaults removeObjectForKey:key];
        if (_saved[key]) [defaults setObject:_saved[key] forKey:key];
    }
}

// The first release's defaults: 24 fps, H.264, cardioid, record only.
- (void)testDefaultsMatchTheFirstRelease {
    XCTAssertEqual(ESSettings.frameRate, 24);
    XCTAssertFalse(ESSettings.broadcastUsesHEVC);
    XCTAssertTrue(ESSettings.directionalMicrophone);
    XCTAssertEqualObjects(ESSettings.effectiveIngestURL, @"");
    XCTAssertEqualObjects([ESSettings sessionSummary], @"24 fps · H.264 · CARD · Record only");
}

// A build that predates the Record only switch streamed whenever a URL was
// saved. An upgrade must keep doing so until the user says otherwise.
- (void)testSavedURLWithoutSwitchStillStreams {
    [NSUserDefaults.standardUserDefaults setObject:@" https://a.upload.youtube.com/http_upload_hls?cid=k&copy=0&file= "
                                            forKey:@"ESIngestURL"];
    XCTAssertTrue(ESSettings.streamingEnabled);
    XCTAssertEqualObjects(ESSettings.effectiveIngestURL,
                          @"https://a.upload.youtube.com/http_upload_hls?cid=k&copy=0&file=");
    XCTAssertEqualObjects(ESSettings.destinationDescription, @"Stream: a.upload.youtube.com");
    XCTAssertEqualObjects([ESSettings sessionSummary], @"24 fps · H.264 · CARD · youtube.com");

    ESSettings.streamingEnabled = NO;
    XCTAssertEqualObjects(ESSettings.effectiveIngestURL, @"");
    XCTAssertEqualObjects(ESSettings.destinationDescription, @"Record only");
}

- (void)testDescriptionsNeverContainTheStreamKey {
    ESSettings.ingestURL = @"https://a.upload.youtube.com/http_upload_hls?cid=secret-key&copy=0&file=";
    ESSettings.streamingEnabled = YES;
    XCTAssertFalse([ESSettings.destinationDescription containsString:@"secret-key"]);
    XCTAssertFalse([[ESSettings sessionSummary] containsString:@"secret-key"]);
}

- (void)testInvalidURLIsReportedNotHidden {
    ESSettings.ingestURL = @"not a url";
    ESSettings.streamingEnabled = YES;
    XCTAssertNil(ESSettings.ingestHost);
    XCTAssertEqualObjects(ESSettings.destinationDescription, @"invalid URL");
}

- (void)testCodecAndMicUseTheExistingEncoding {
    ESSettings.frameRate = 30;
    ESSettings.broadcastUsesHEVC = YES;
    ESSettings.directionalMicrophone = NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    XCTAssertEqual([defaults integerForKey:@"ESFrameRate"], 30);
    XCTAssertEqual([defaults integerForKey:@"ESBroadcastCodec"], 1);
    XCTAssertEqual([defaults integerForKey:@"ESMicPattern"], 1);
}

- (void)testFinalizedRecordingIsNotStoppedEarly {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/ESCapture-20261024-120000.mov"];
    [ESSettings markRecordingStartedAtURL:url];
    XCTAssertEqualObjects([ESSettings inProgressRecordingName], url.lastPathComponent);
    [ESSettings markRecordingFinalizedAtURL:url];
    XCTAssertNil([ESSettings inProgressRecordingName]);
    XCTAssertNil([ESSettings resolveLeftoverRecordingMarker]);
    XCTAssertFalse([ESSettings recordingWasStoppedEarly:url.lastPathComponent]);
}

- (void)testLeftoverMarkerBecomesStoppedEarly {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/ESCapture-20261024-130000.mov"];
    [ESSettings markRecordingStartedAtURL:url];
    // The app dies here; the next launch resolves the marker.
    XCTAssertEqualObjects([ESSettings resolveLeftoverRecordingMarker], url.lastPathComponent);
    XCTAssertNil([ESSettings inProgressRecordingName]);
    XCTAssertTrue([ESSettings recordingWasStoppedEarly:url.lastPathComponent]);
    [ESSettings forgetRecording:url.lastPathComponent];
    XCTAssertFalse([ESSettings recordingWasStoppedEarly:url.lastPathComponent]);
}

@end
