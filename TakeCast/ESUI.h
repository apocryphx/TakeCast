//
//  ESUI.h
//  TakeCast
//
//  The handful of controls the Onboarding, Setup and Recordings screens share,
//  so the three read as one app.
//

#import <UIKit/UIKit.h>
#import "ESPreflight.h"

NS_ASSUME_NONNULL_BEGIN

UILabel *ESHeadingLabel(NSString *text);
UILabel *ESBodyLabel(NSString *text);
// A filled, full width button for the screen's one main action.
UIButton *ESPrimaryButton(NSString *title, UIAction *action);
// A tinted button for the alternatives.
UIButton *ESSecondaryButton(NSString *title, UIAction *action);
// A borderless text button with an SF Symbol, for links.
UIButton *ESLinkButton(NSString *title, NSString *symbolName, UIAction *action);
// A rounded, tinted panel that wraps a view, for the warning that must not be missed.
UIView *ESCalloutView(UIView *content, UIColor *tint);

UIColor *ESColorForPreflightStatus(ESPreflightStatus status);
NSString *ESSymbolForPreflightStatus(ESPreflightStatus status);

NS_ASSUME_NONNULL_END
