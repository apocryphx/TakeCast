//
//  ESGuide.m
//  TakeCast
//

#import "ESGuide.h"
#import <UIKit/UIKit.h>
#import "ESSettings.h"

// US Letter with half inch margins. A4 readers lose a sliver of margin, nothing more.
static const CGRect ESGuidePaperRect = {{0, 0}, {612, 792}};
static const CGFloat ESGuideMargin = 40;

@interface ESGuidePageRenderer : UIPrintPageRenderer
@end

@implementation ESGuidePageRenderer
- (CGRect)paperRect { return ESGuidePaperRect; }
- (CGRect)printableRect { return CGRectInset(ESGuidePaperRect, ESGuideMargin, ESGuideMargin); }
@end

@implementation ESGuide

+ (NSURL *)guidePDFURL {
    NSURL *htmlURL = [NSBundle.mainBundle URLForResource:@"YouTubeGuide" withExtension:@"html"];
    if (!htmlURL) return nil;
    NSString *html = [NSString stringWithContentsOfURL:htmlURL encoding:NSUTF8StringEncoding error:nil];
    if (html.length == 0) return nil;
    html = [html stringByReplacingOccurrencesOfString:@"{{APP}}" withString:ESAppName()];

    // Rendered per app version, so an update that changes the guide replaces it.
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0";
    NSString *name = [NSString stringWithFormat:@"%@ YouTube Setup Guide.pdf", ESAppName()];
    NSURL *folder = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                     URLByAppendingPathComponent:[@"Guide-" stringByAppendingString:version] isDirectory:YES];
    NSURL *pdfURL = [folder URLByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:pdfURL.path]) return pdfURL;
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];

    UIMarkupTextPrintFormatter *formatter = [[UIMarkupTextPrintFormatter alloc] initWithMarkupText:html];
    ESGuidePageRenderer *renderer = [[ESGuidePageRenderer alloc] init];
    [renderer addPrintFormatter:formatter startingAtPageAtIndex:0];

    NSMutableData *data = [NSMutableData data];
    UIGraphicsBeginPDFContextToData(data, ESGuidePaperRect, @{(NSString *)kCGPDFContextTitle: name});
    [renderer prepareForDrawingPages:NSMakeRange(0, renderer.numberOfPages)];
    CGRect bounds = UIGraphicsGetPDFContextBounds();
    for (NSInteger page = 0; page < renderer.numberOfPages; page++) {
        UIGraphicsBeginPDFPage();
        [renderer drawPageAtIndex:page inRect:bounds];
    }
    UIGraphicsEndPDFContext();

    if (data.length == 0 || ![data writeToURL:pdfURL atomically:YES]) return nil;
    return pdfURL;
}

+ (NSString *)supportStaffSummary {
    return [NSString stringWithFormat:
        @"Setting up a YouTube live stream for %@\n"
        @"\n"
        @"I will record and stream an event from my iPhone with %@. Could you set up the YouTube side?\n"
        @"\n"
        @"IMPORTANT: YouTube can take up to 24 hours to enable live streaming the first time. Please do this at least a day before the event.\n"
        @"\n"
        @"1. Use a YouTube channel that is verified (youtube.com/verify) and has live streaming enabled (YouTube Studio > Create > Go live).\n"
        @"2. In YouTube Studio's live control room, open Stream and create a new stream key with the HLS protocol.\n"
        @"3. In the stream settings, turn on Auto-start and Auto-stop, and set visibility to Unlisted (or Private for a test).\n"
        @"4. The ingest URL looks like https://a.upload.youtube.com/http_upload_hls?cid=YOUR-STREAM-KEY&copy=0&file=\n"
        @"5. Send me two things: the ingest URL (privately: AirDrop, a password manager or a direct message, never a group chat or a shared email thread), and the channel's live link (youtube.com/@channel/live) for the guests.\n"
        @"6. If possible, run a short private test stream with me before the day. Rotating the stream key after the event is good practice.\n"
        @"\n"
        @"Note: an unlisted link is not secure. Anyone who has it can watch, so it is not suitable for confidential material.\n",
        ESAppName(), ESAppName()];
}

+ (NSURL *)youTubeStudioURL {
    return [NSURL URLWithString:@"https://studio.youtube.com"];
}

@end
