//
//  ESOnboardingViewController.h
//  TakeCast
//
//  What the app does, what to prepare before the first event, the YouTube
//  warnings, and the hand-off for someone else who sets up YouTube. Shown once
//  on first launch and from Setup > Help, never during a recording. Present it
//  inside a navigation controller.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ESOnboardingChoice) {
    ESOnboardingChoiceSetup,
    ESOnboardingChoiceRecordOnly,
};

@interface ESOnboardingViewController : UIViewController

// Called after the user picks a path. The presenter dismisses.
@property (nonatomic, copy, nullable) void (^completion)(ESOnboardingChoice choice);

@end

NS_ASSUME_NONNULL_END
