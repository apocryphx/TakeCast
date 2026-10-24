//
//  ESSetupViewController.h
//  TakeCast
//
//  Every setting that cannot change once REC starts (destination, frame rate,
//  broadcast codec, mic pattern) and the pre-flight checks. Reachable only
//  while stopped. Each change is saved as it is made. Present it inside a
//  navigation controller.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ESThermalGovernor;
@class ESDockKitBridge;

@interface ESSetupViewController : UIViewController

- (instancetype)initWithThermalGovernor:(nullable ESThermalGovernor *)governor
                             dockBridge:(nullable ESDockKitBridge *)dockBridge NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// The mic pattern applies to the engine the moment it changes, not at REC.
@property (nonatomic, copy, nullable) void (^microphonePatternChanged)(BOOL directional);
// Go to camera: settings are already saved; the presenter dismisses.
@property (nonatomic, copy, nullable) void (^finished)(void);

@end

NS_ASSUME_NONNULL_END
