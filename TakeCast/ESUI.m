//
//  ESUI.m
//  TakeCast
//

#import "ESUI.h"

UILabel *ESHeadingLabel(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    UIFontDescriptor *descriptor = [[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleTitle3]
                                    fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    label.font = [UIFont fontWithDescriptor:descriptor size:0];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

UILabel *ESBodyLabel(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    label.numberOfLines = 0;
    return label;
}

UIButton *ESPrimaryButton(NSString *title, UIAction *action) {
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.buttonSize = UIButtonConfigurationSizeLarge;
    return [UIButton buttonWithConfiguration:config primaryAction:action];
}

UIButton *ESSecondaryButton(NSString *title, UIAction *action) {
    UIButtonConfiguration *config = [UIButtonConfiguration tintedButtonConfiguration];
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.buttonSize = UIButtonConfigurationSizeLarge;
    return [UIButton buttonWithConfiguration:config primaryAction:action];
}

UIButton *ESLinkButton(NSString *title, NSString *symbolName, UIAction *action) {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:symbolName];
    config.imagePadding = 8;
    config.contentInsets = NSDirectionalEdgeInsetsMake(6, 0, 6, 0);
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:action];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    return button;
}

UIView *ESCalloutView(UIView *content, UIColor *tint) {
    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = [tint colorWithAlphaComponent:0.18];
    panel.layer.cornerRadius = 12;
    panel.layer.borderColor = [tint colorWithAlphaComponent:0.6].CGColor;
    panel.layer.borderWidth = 1;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-12],
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
    ]];
    return panel;
}

UIColor *ESColorForPreflightStatus(ESPreflightStatus status) {
    switch (status) {
        case ESPreflightStatusReady: return UIColor.systemGreenColor;
        case ESPreflightStatusWarning: return UIColor.systemOrangeColor;
        case ESPreflightStatusNotReady: return UIColor.systemRedColor;
    }
    return UIColor.grayColor;
}

NSString *ESSymbolForPreflightStatus(ESPreflightStatus status) {
    switch (status) {
        case ESPreflightStatusReady: return @"checkmark.circle.fill";
        case ESPreflightStatusWarning: return @"exclamationmark.triangle.fill";
        case ESPreflightStatusNotReady: return @"xmark.octagon.fill";
    }
    return @"circle";
}
