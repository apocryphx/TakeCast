//
//  ESOnboardingViewController.m
//  TakeCast
//

#import "ESOnboardingViewController.h"
#import <QuickLook/QuickLook.h>
#import "ESGuide.h"
#import "ESSettings.h"
#import "ESUI.h"

#pragma mark - Hand-off summary

// The second path: the person holding the phone may never see YouTube Studio.
// Show exactly what the helper has to do, and a way to send it.
@interface ESHandOffViewController : UIViewController
@end

@implementation ESHandOffViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"For your helper";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *text = [[UITextView alloc] init];
    text.editable = NO;
    text.text = [ESGuide supportStaffSummary];
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.adjustsFontForContentSizeCategory = YES;
    text.textContainerInset = UIEdgeInsetsMake(16, 0, 16, 0);
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:text];

    UILayoutGuide *guide = self.view.readableContentGuide;
    [NSLayoutConstraint activateConstraints:@[
        [text.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [text.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [text.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                      primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
        [weakSelf _share:action.sender];
    }]];
    self.navigationItem.rightBarButtonItem = share;
}

- (void)_share:(id)sender {
    NSMutableArray *items = [NSMutableArray arrayWithObject:[ESGuide supportStaffSummary]];
    NSURL *pdf = [ESGuide guidePDFURL];
    if (pdf) [items addObject:pdf];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                        applicationActivities:nil];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Onboarding

@interface ESOnboardingViewController () <QLPreviewControllerDataSource>
@end

@interface ESHelpHeroView : UIView
@end

@implementation ESHelpHeroView {
    CAGradientLayer *_gradient;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 22;
        self.clipsToBounds = YES;
        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)[UIColor.systemIndigoColor colorWithAlphaComponent:0.96].CGColor,
                             (id)[UIColor.systemTealColor colorWithAlphaComponent:0.96].CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        [self.layer insertSublayer:_gradient atIndex:0];

        UIView *badge = [[UIView alloc] init];
        badge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        badge.layer.cornerRadius = 27;
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"video.fill"]];
        icon.tintColor = UIColor.whiteColor;
        icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:25 weight:UIImageSymbolWeightBold];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [badge addSubview:icon];

        UILabel *title = [[UILabel alloc] init];
        title.text = @"You have the important part.";
        title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        title.textColor = UIColor.whiteColor;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *detail = [[UILabel alloc] init];
        detail.text = @"TakeCast keeps a 4K copy safe while your audience watches live.";
        detail.numberOfLines = 0;
        detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        detail.adjustsFontForContentSizeCategory = YES;
        detail.textColor = [UIColor colorWithWhite:1 alpha:0.82];
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:badge];
        [self addSubview:title];
        [self addSubview:detail];
        [NSLayoutConstraint activateConstraints:@[
            [badge.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [badge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [badge.widthAnchor constraintEqualToConstant:54],
            [badge.heightAnchor constraintEqualToConstant:54],
            [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
            [title.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:14],
            [title.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:24],
            [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [detail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
            [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradient.frame = self.bounds;
}

@end

@implementation ESOnboardingViewController {
    NSURL *_guideURL;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.backButtonTitle = @"Back";
    __weak typeof(self) weakSelf = self;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UILayoutGuide *readable = self.view.readableContentGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.leadingAnchor constraintEqualToAnchor:readable.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:readable.trailingAnchor],
    ]];

    // The title rides in the navigation bar: landscape has no height to spare.
    NSString *app = ESAppName();
    self.title = [NSString stringWithFormat:@"Welcome to %@", app];

    // 1. What it does
    ESHelpHeroView *hero = [[ESHelpHeroView alloc] initWithFrame:CGRectZero];
    [hero.heightAnchor constraintEqualToConstant:126].active = YES;
    [stack addArrangedSubview:hero];
    [stack setCustomSpacing:24 afterView:hero];
    [stack addArrangedSubview:ESHeadingLabel([NSString stringWithFormat:@"What %@ does", app])];
    [stack addArrangedSubview:[self _rowWithSymbol:@"lock.shield" text:
        @"Records your event in 4K and keeps that copy safe, whatever happens to the stream."]];
    [stack addArrangedSubview:[self _rowWithSymbol:@"dot.radiowaves.left.and.right" text:
        @"Streams to YouTube so family, friends and colleagues can watch live."]];
    [stack addArrangedSubview:[self _rowWithSymbol:@"thermometer.medium" text:
        @"Adapts the stream to the network and to heat, and supports DockKit gimbals."]];
    [stack setCustomSpacing:24 afterView:stack.arrangedSubviews.lastObject];

    // 2. Before the first event
    [stack addArrangedSubview:ESHeadingLabel(@"Before your first event")];
    [stack addArrangedSubview:[self _rowWithSymbol:@"checkmark.circle" text:
        @"A YouTube account with a verified channel."]];
    [stack addArrangedSubview:[self _rowWithSymbol:@"checkmark.circle" text:
        @"Live streaming enabled on that channel."]];

    UILabel *warning = [[UILabel alloc] init];
    warning.numberOfLines = 0;
    warning.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    warning.adjustsFontForContentSizeCategory = YES;
    warning.text = @"YouTube can take up to 24 hours to enable live streaming the first time. "
                   @"Do this at least a day before your event.";
    [stack addArrangedSubview:ESCalloutView(warning, UIColor.systemOrangeColor)];

    [stack addArrangedSubview:[self _rowWithSymbol:@"checkmark.circle" text:
        @"Run a private test stream first, using a separate unlisted stream key."]];
    [stack addArrangedSubview:[self _rowWithSymbol:@"checkmark.circle" text:
        @"Share your channel's live link (youtube.com/@yourchannel/live), not a link to one broadcast."]];

    [stack addArrangedSubview:ESLinkButton(@"Someone else is setting up YouTube for me",
                                           @"person.2", [UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf.navigationController pushViewController:[[ESHandOffViewController alloc] init] animated:YES];
    }])];
    [stack addArrangedSubview:ESLinkButton(@"Open YouTube setup guide (PDF)", @"doc.richtext",
                                           [UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf _openGuide];
    }])];
    [stack addArrangedSubview:ESLinkButton(@"Open YouTube Studio", @"safari",
                                           [UIAction actionWithHandler:^(UIAction *a) {
        [UIApplication.sharedApplication openURL:[ESGuide youTubeStudioURL] options:@{} completionHandler:nil];
    }])];
    [stack setCustomSpacing:24 afterView:stack.arrangedSubviews.lastObject];

    // Cautions, stated plainly.
    [stack addArrangedSubview:ESHeadingLabel(@"Good to know")];
    [stack addArrangedSubview:[self _rowWithSymbol:@"eye" text:
        @"An unlisted link is not private: anyone who has it can watch. Do not use it for confidential material."]];
    [stack addArrangedSubview:[self _rowWithSymbol:@"hand.raised" text:
        @"Do not stream or record unpublished data, patient information, or anything an institution's "
        @"recording or confidentiality rules cover. Some networks block YouTube."]];
    [stack addArrangedSubview:[self _rowWithSymbol:@"person.wave.2" text:
        @"Tell people in the room that they are being recorded. For children's events, keep the stream "
        @"unlisted and share the link only with the intended viewers."]];
    [stack setCustomSpacing:28 afterView:stack.arrangedSubviews.lastObject];

    // 4. The way out
    [stack addArrangedSubview:ESPrimaryButton(@"Continue to Setup", [UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf _finishWithChoice:ESOnboardingChoiceSetup];
    }])];
    [stack addArrangedSubview:ESSecondaryButton(@"Record without streaming", [UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf _finishWithChoice:ESOnboardingChoiceRecordOnly];
    }])];
}

- (UIView *)_rowWithSymbol:(NSString *)symbol text:(NSString *)text {
    UIColor *tint = [self _tintForSymbol:symbol];
    UIView *badge = [[UIView alloc] init];
    badge.backgroundColor = [tint colorWithAlphaComponent:0.16];
    badge.layer.cornerRadius = 19;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = tint;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:38],
        [badge.heightAnchor constraintEqualToConstant:38],
        [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
    ]];

    UILabel *label = ESBodyLabel(text);
    label.textColor = UIColor.labelColor;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, label]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    return row;
}

- (UIColor *)_tintForSymbol:(NSString *)symbol {
    if ([symbol containsString:@"checkmark"]) return UIColor.systemGreenColor;
    if ([symbol containsString:@"radiowaves"]) return UIColor.systemPinkColor;
    if ([symbol containsString:@"thermometer"]) return UIColor.systemOrangeColor;
    if ([symbol containsString:@"hand"]) return UIColor.systemRedColor;
    if ([symbol containsString:@"eye"]) return UIColor.systemIndigoColor;
    if ([symbol containsString:@"person"]) return UIColor.systemTealColor;
    return UIColor.systemBlueColor;
}

- (void)_finishWithChoice:(ESOnboardingChoice)choice {
    ESSettings.hasCompletedOnboarding = YES;
    if (self.completion) self.completion(choice);
}

- (void)_openGuide {
    _guideURL = [ESGuide guidePDFURL];
    if (!_guideURL) return;
    QLPreviewController *preview = [[QLPreviewController alloc] init];
    preview.dataSource = self;
    [self presentViewController:preview animated:YES completion:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return _guideURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return _guideURL;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }

@end
