//
//  ESRecordingsViewController.h
//  TakeCast
//
//  The app's own list of its archives, including ones that ended early, with
//  play, share and delete. Reachable from the Live screen while stopped and
//  offered after STOP, never while recording. Sharing hands the file in place
//  to the system share sheet; nothing here moves, alters or deletes a
//  recording unless the user confirms a delete. Present it inside a
//  navigation controller.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESRecordingsViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
