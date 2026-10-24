//
//  ESGuide.h
//  TakeCast
//
//  The YouTube setup guide. Its text lives in YouTubeGuide.html in the app
//  bundle; this renders it to a PDF the user can read, print or send on, and
//  composes the short hand-off note for whoever sets up YouTube for them.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESGuide : NSObject

// Renders the bundled guide on first use and returns the PDF's location, or
// nil if the guide could not be rendered. Main thread only.
+ (nullable NSURL *)guidePDFURL;

// Plain text for the share sheet: what the person setting up YouTube has to
// create, and what to send back.
+ (NSString *)supportStaffSummary;

+ (NSURL *)youTubeStudioURL;

@end

NS_ASSUME_NONNULL_END
