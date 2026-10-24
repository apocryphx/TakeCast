//
//  ESSettings.h
//  TakeCast
//
//  The session settings that Setup owns and the Live screen reads when REC
//  starts, plus the bookkeeping that tells a finished recording from one that
//  was cut short. Everything persists in NSUserDefaults under the keys the
//  first release already used, so an installed build keeps its choices.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The public product name, read from CFBundleDisplayName so a rename is one
// build setting.
FOUNDATION_EXPORT NSString *ESAppName(void);

// Posted on the main queue once STOP has finalized an archive.
FOUNDATION_EXPORT NSNotificationName const ESRecordingFinalizedNotification;

@interface ESSettings : NSObject

// 24 or 30.
@property (class, nonatomic) NSInteger frameRate;
// NO for H.264 (the proven path), YES for HEVC.
@property (class, nonatomic) BOOL broadcastUsesHEVC;
// YES for the cardioid pattern (CARD), NO for omni.
@property (class, nonatomic) BOOL directionalMicrophone;

// The pasted URL exactly as saved, trimmed. A credential: never log it.
@property (class, nonatomic, copy) NSString *ingestURL;
// The Record only switch. Builds that predate the switch stream whenever a URL
// is saved, so the switch reads as on when it was never set and a URL exists.
@property (class, nonatomic) BOOL streamingEnabled;
// What a session should stream to: the saved URL when streaming is on, else
// the empty string. The only accessor the recording path uses.
@property (class, nonatomic, readonly) NSString *effectiveIngestURL;
// The host of the saved URL, or nil when it does not parse.
@property (class, nonatomic, readonly, nullable) NSString *ingestHost;
// "Stream: <host>", "invalid URL" or "Record only", as the Live screen and
// Setup show it. Never contains the stream key.
@property (class, nonatomic, readonly) NSString *destinationDescription;

@property (class, nonatomic) BOOL hasCompletedOnboarding;

// One short line for the Live screen: "30 fps · H.264 · CARD · youtube.com".
+ (NSString *)sessionSummary;

#pragma mark Recordings

// The app's Documents folder, where archives and the instrument log live.
+ (NSURL *)documentsURL;
// Archive files, newest first.
+ (NSArray<NSURL *> *)recordingURLs;

// Written when REC starts, cleared once STOP has finalized the file. A marker
// still present at launch means that file was cut short.
+ (void)markRecordingStartedAtURL:(NSURL *)url;
+ (void)markRecordingFinalizedAtURL:(NSURL *)url;
// The file currently being written or finalized, if any.
+ (nullable NSString *)inProgressRecordingName;
// Call once at launch, before anything records: moves a leftover marker into
// the stopped-early set. Returns the file name it moved, if any.
+ (nullable NSString *)resolveLeftoverRecordingMarker;
+ (BOOL)recordingWasStoppedEarly:(NSString *)fileName;
+ (void)forgetRecording:(NSString *)fileName;

@end

NS_ASSUME_NONNULL_END
