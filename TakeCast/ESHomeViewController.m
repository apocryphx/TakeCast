//
//  ESHomeViewController.m
//  TakeCast
//

#import "ESHomeViewController.h"
#import "ESMainViewController.h"
#import "ESRecordingsViewController.h"
#import "ESSetupViewController.h"
#import "ESSettings.h"
#import "ESPreflight.h"
#import "ESGuide.h"
#import <QuickLook/QuickLook.h>

@interface ESHomeViewController () <QLPreviewControllerDataSource>
@end

@interface ESHomeActionCard : UIButton
- (instancetype)initWithColors:(NSArray<UIColor *> *)colors;
@end

@implementation ESHomeActionCard {
    CAGradientLayer *_gradient;
}

- (instancetype)initWithColors:(NSArray<UIColor *> *)colors {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)colors[0].CGColor, (id)colors[1].CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        _gradient.cornerRadius = 24;
        [self.layer insertSublayer:_gradient atIndex:0];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradient.frame = self.bounds;
}

@end

static NSString *ESSizeClassDescription(UIUserInterfaceSizeClass sizeClass) {
    switch (sizeClass) {
        case UIUserInterfaceSizeClassCompact: return @"compact";
        case UIUserInterfaceSizeClassRegular: return @"regular";
        default: return @"unspecified";
    }
}

@implementation ESHomeViewController {
    CAGradientLayer *_backgroundGradient;
    UILabel *_readinessLabel;
    ESPreflight *_preflight;
    NSURL *_guideURL;
    QLPreviewController *_guidePreviewController;
    CGSize _lastLoggedLayoutSize;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _preflight = [[ESPreflight alloc] initWithThermalGovernor:nil dockBridge:nil];
    __weak typeof(self) weakSelf = self;
    _preflight.changeHandler = ^{ [weakSelf _updateReadiness]; };
    [self registerForTraitChanges:@[
        UITraitHorizontalSizeClass.class,
        UITraitVerticalSizeClass.class,
    ]
                        withTarget:self
                             action:@selector(_homeTraitsDidChange:previousTraitCollection:)];
    [self _logLayoutEvent:@"viewDidLoad" previousTraits:nil targetSize:CGSizeZero];
    [self _rebuildHomeLayout];
}

- (void)_homeTraitsDidChange:(__unused id<UITraitEnvironment>)environment
       previousTraitCollection:(UITraitCollection *)previousTraitCollection {
    BOOL changed = previousTraitCollection.horizontalSizeClass != self.traitCollection.horizontalSizeClass ||
                   previousTraitCollection.verticalSizeClass != self.traitCollection.verticalSizeClass;
    [self _logLayoutEvent:changed ? @"registered trait change (rebuild)"
                             : @"registered trait change (no size-class change)"
             previousTraits:previousTraitCollection
                 targetSize:CGSizeZero];
    if (!self.isViewLoaded || !changed) {
        return;
    }
    [self _rebuildHomeLayout];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self _logLayoutEvent:@"viewWillTransitionToSize" previousTraits:nil targetSize:size];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf _logLayoutEvent:@"transition completed" previousTraits:nil targetSize:size];
        // A split pane can retain compact/compact traits across a physical
        // rotation. Re-evaluate the final window geometry after the transition.
        [weakSelf _rebuildHomeLayout];
    }];
}

- (CGSize)_layoutWindowSize {
    CGSize size = self.view.window.bounds.size;
    return CGSizeEqualToSize(size, CGSizeZero) ? self.view.bounds.size : size;
}

- (BOOL)_usesLandscapeSplitSidebar {
    if (!self.splitViewController) return NO;
    CGSize windowSize = [self _layoutWindowSize];
    return windowSize.width > windowSize.height;
}

- (BOOL)_usesSidebarLayout {
    return self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular ||
           [self _usesLandscapeSplitSidebar];
}

- (void)_rebuildHomeLayout {
    [_backgroundGradient removeFromSuperlayer];
    for (UIView *subview in self.view.subviews) {
        [subview removeFromSuperview];
    }

    BOOL sidebarLayout = [self _usesSidebarLayout];
    CGSize windowSize = [self _layoutWindowSize];
    // UISplitViewController may override its narrow primary pane to compact
    // width even while the app itself is in landscape. Window geometry is the
    // reliable signal for the short iPhone landscape sidebar.
    BOOL denseSidebar = [self _usesLandscapeSplitSidebar] && windowSize.height < 600;
    [self _logLayoutEvent:denseSidebar ? @"rebuild dense sidebar" : @"rebuild standard layout"
            previousTraits:nil
                targetSize:CGSizeZero];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.08 blue:0.24 alpha:1.0];

    _backgroundGradient = [CAGradientLayer layer];
    _backgroundGradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.13 green:0.09 blue:0.31 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.18 green:0.13 blue:0.42 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.06 green:0.28 blue:0.39 alpha:1.0].CGColor,
    ];
    _backgroundGradient.startPoint = CGPointMake(0.05, 0.0);
    _backgroundGradient.endPoint = CGPointMake(0.95, 1.0);
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    UILabel *eyebrow = [[UILabel alloc] init];
    eyebrow.text = @"4K CAPTURE CONTROL";
    eyebrow.font = [UIFont systemFontOfSize:(denseSidebar ? 9 : (sidebarLayout ? 10 : 12)) weight:UIFontWeightBold];
    eyebrow.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    eyebrow.adjustsFontForContentSizeCategory = YES;
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"TakeCast";
    title.font = [UIFont systemFontOfSize:(denseSidebar ? 26 : (sidebarLayout ? 32 : 42)) weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.adjustsFontForContentSizeCategory = YES;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"Record in 4K. Stream to YouTube when you’re ready.";
    subtitle.numberOfLines = 0;
    subtitle.font = sidebarLayout ? [UIFont systemFontOfSize:(denseSidebar ? 13 : 15) weight:UIFontWeightRegular]
                                 : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    subtitle.adjustsFontForContentSizeCategory = YES;
    subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.76];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;

    _readinessLabel = [[UILabel alloc] init];
    _readinessLabel.font = [UIFont systemFontOfSize:(denseSidebar ? 9 : (sidebarLayout ? 10 : 12)) weight:UIFontWeightBold];
    _readinessLabel.textColor = UIColor.whiteColor;
    _readinessLabel.layer.cornerRadius = 12;
    _readinessLabel.clipsToBounds = YES;
    _readinessLabel.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    [self _updateReadiness];

    UIButton *record = [self _cardWithTitle:@"Open camera"
                                   subtitle:@"Ready in landscape"
                                    symbol:@"record.circle.fill"
                                     colors:@[[UIColor colorWithRed:1.00 green:0.29 blue:0.35 alpha:1.0],
                                              [UIColor colorWithRed:0.91 green:0.12 blue:0.47 alpha:1.0]]
                                    compact:sidebarLayout
                                      dense:denseSidebar
                                      action:^{ [weakSelf _showCamera]; }];
    UIButton *setup = [self _cardWithTitle:@"Set up"
                                  subtitle:@"Destination, video and pre-flight"
                                   symbol:@"slider.horizontal.3"
                                    colors:@[[UIColor colorWithRed:0.18 green:0.55 blue:1.00 alpha:1.0],
                                             [UIColor colorWithRed:0.30 green:0.30 blue:0.94 alpha:1.0]]
                                   compact:sidebarLayout
                                     dense:denseSidebar
                                     action:^{ [weakSelf _showSetup]; }];
    UIButton *review = [self _cardWithTitle:@"Review recordings"
                                   subtitle:@"Watch, share or free up space"
                                    symbol:@"film.stack.fill"
                                     colors:@[[UIColor colorWithRed:0.04 green:0.72 blue:0.63 alpha:1.0],
                                              [UIColor colorWithRed:0.02 green:0.48 blue:0.56 alpha:1.0]]
                                    compact:sidebarLayout
                                      dense:denseSidebar
                                      action:^{ [weakSelf _showRecordings]; }];
    UIButton *guide = [self _cardWithTitle:@"YouTube Live guide"
                                  subtitle:@"Enable Live and connect TakeCast"
                                   symbol:@"play.rectangle.on.rectangle.fill"
                                    colors:@[[UIColor colorWithRed:0.95 green:0.55 blue:0.08 alpha:1.0],
                                             [UIColor colorWithRed:0.88 green:0.28 blue:0.12 alpha:1.0]]
                                   compact:sidebarLayout
                                     dense:denseSidebar
                                     action:^{ [weakSelf _showYouTubeGuide]; }];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[record, setup, review, guide]];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = denseSidebar ? 6 : 14;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    // Four cards fit comfortably on current iPhones. The scroll view keeps the
    // complete menu reachable with larger accessibility text or smaller screens.
    UIScrollView *actionsScroll = [[UIScrollView alloc] init];
    actionsScroll.alwaysBounceVertical = YES;
    actionsScroll.showsVerticalScrollIndicator = NO;
    actionsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [actionsScroll addSubview:actions];

    [self.view addSubview:eyebrow];
    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:_readinessLabel];
    [self.view addSubview:actionsScroll];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [eyebrow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:(denseSidebar ? 12 : (sidebarLayout ? 22 : 30))],
        [eyebrow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:(denseSidebar ? 16 : (sidebarLayout ? 20 : 28))],
        [eyebrow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:(denseSidebar ? -16 : (sidebarLayout ? -20 : -28))],
        [title.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:(denseSidebar ? 2 : (sidebarLayout ? 5 : 7))],
        [title.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [subtitle.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],
        [_readinessLabel.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:(denseSidebar ? 8 : 15)],
        [_readinessLabel.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [_readinessLabel.heightAnchor constraintEqualToConstant:(denseSidebar ? 22 : (sidebarLayout ? 24 : 26))],
        [actionsScroll.topAnchor constraintEqualToAnchor:_readinessLabel.bottomAnchor constant:(denseSidebar ? 12 : (sidebarLayout ? 30 : 66))],
        [actionsScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [actionsScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [actionsScroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:(denseSidebar ? -10 : -20)],
        [actions.topAnchor constraintEqualToAnchor:actionsScroll.contentLayoutGuide.topAnchor],
        [actions.bottomAnchor constraintEqualToAnchor:actionsScroll.contentLayoutGuide.bottomAnchor],
        [actions.leadingAnchor constraintEqualToAnchor:actionsScroll.contentLayoutGuide.leadingAnchor constant:(denseSidebar ? 16 : 20)],
        [actions.trailingAnchor constraintEqualToAnchor:actionsScroll.contentLayoutGuide.trailingAnchor constant:(denseSidebar ? -16 : -20)],
        [actions.widthAnchor constraintEqualToAnchor:actionsScroll.frameLayoutGuide.widthAnchor constant:(denseSidebar ? -32 : -40)],
        [record.heightAnchor constraintEqualToConstant:(denseSidebar ? 56 : (sidebarLayout ? 84 : 116))],
        [setup.heightAnchor constraintEqualToConstant:(denseSidebar ? 50 : (sidebarLayout ? 70 : 96))],
        [review.heightAnchor constraintEqualToConstant:(denseSidebar ? 50 : (sidebarLayout ? 70 : 96))],
        [guide.heightAnchor constraintEqualToConstant:(denseSidebar ? 48 : (sidebarLayout ? 66 : 82))],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;
    if (!CGSizeEqualToSize(_lastLoggedLayoutSize, self.view.bounds.size)) {
        _lastLoggedLayoutSize = self.view.bounds.size;
        [self _logLayoutEvent:@"viewDidLayoutSubviews (bounds changed)"
                previousTraits:nil
                    targetSize:CGSizeZero];
    }
}

- (void)_logLayoutEvent:(NSString *)event
          previousTraits:(UITraitCollection *)previousTraits
              targetSize:(CGSize)targetSize {
    UISplitViewController *split = self.splitViewController;
    NSString *previous = previousTraits
        ? [NSString stringWithFormat:@"H=%@ V=%@", ESSizeClassDescription(previousTraits.horizontalSizeClass), ESSizeClassDescription(previousTraits.verticalSizeClass)]
        : @"none";
    NSLog(@"[TakeCast][HomeLayout] %@ controller=%p target=%@ bounds=%@ traits=H=%@ V=%@ previous=%@ split=%@ displayMode=%ld",
          event,
          self,
          NSStringFromCGSize(targetSize),
          NSStringFromCGRect(self.view.bounds),
          ESSizeClassDescription(self.traitCollection.horizontalSizeClass),
          ESSizeClassDescription(self.traitCollection.verticalSizeClass),
          previous,
          split ? @"yes" : @"no",
          (long)(split ? split.displayMode : UISplitViewControllerDisplayModeAutomatic));
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_preflight start];
    [self _updateReadiness];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_preflight stop];
}

- (void)_updateReadiness {
    ESPreflightStatus worst = ESPreflightStatusReady;
    NSSet<NSString *> *readinessChecks = [NSSet setWithArray:@[@"Storage", @"Temperature", @"Network"]];
    for (ESPreflightCheck *check in [_preflight currentChecks]) {
        if (![readinessChecks containsObject:check.title]) continue;
        if (check.status > worst) worst = check.status;
    }

    switch (worst) {
        case ESPreflightStatusReady:
            _readinessLabel.text = ESSettings.effectiveIngestURL.length > 0 && ESSettings.ingestHost.length > 0
                ? @"  ●  READY TO RECORD & BROADCAST  "
                : @"  ●  READY TO RECORD  ";
            _readinessLabel.backgroundColor = [UIColor colorWithRed:0.08 green:0.62 blue:0.39 alpha:0.82];
            break;
        case ESPreflightStatusWarning:
            _readinessLabel.text = @"  ●  CHECK SETUP  ";
            _readinessLabel.backgroundColor = [UIColor colorWithRed:0.86 green:0.47 blue:0.05 alpha:0.88];
            break;
        case ESPreflightStatusNotReady:
            _readinessLabel.text = @"  ●  NOT READY · Review in Setup  ";
            _readinessLabel.backgroundColor = [UIColor colorWithRed:0.82 green:0.16 blue:0.22 alpha:0.90];
            break;
    }
}

- (void)_showYouTubeGuide {
    [self _logNavigationEvent:@"select guide"];
    _guideURL = [ESGuide guidePDFURL];
    if (!_guideURL) return;

    QLPreviewController *preview = [[QLPreviewController alloc] init];
    _guidePreviewController = preview;
    preview.dataSource = self;
    preview.title = @"YouTube Live guide";
    preview.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(_shareYouTubeGuide:)];

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:preview];
    if ([self _showNavigationControllerInDetail:navigation]) return;

    [self _logNavigationEvent:@"present guide modally"];
    preview.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(_dismissYouTubeGuide)];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)_dismissYouTubeGuide {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_shareYouTubeGuide:(UIBarButtonItem *)sender {
    if (!_guideURL) return;
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[_guideURL] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    // The guide is either full screen or the visible secondary pane. In both
    // cases the guide's navigation controller is the correct presenter.
    UIViewController *presenter = _guidePreviewController.navigationController ?: self.presentedViewController ?: self;
    [presenter presentViewController:share animated:YES completion:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return _guideURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return _guideURL;
}

- (UIButton *)_cardWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                      symbol:(NSString *)symbol
                       colors:(NSArray<UIColor *> *)colors
                     compact:(BOOL)compact
                       dense:(BOOL)dense
                        action:(dispatch_block_t)action {
    ESHomeActionCard *button = [[ESHomeActionCard alloc] initWithColors:colors];
    button.accessibilityLabel = title;
    button.layer.cornerRadius = 24;
    button.clipsToBounds = YES;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.22;
    button.layer.shadowRadius = 14;
    button.layer.shadowOffset = CGSizeMake(0, 8);

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.96];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:(dense ? 21 : (compact ? 26 : 35)) weight:UIImageSymbolWeightSemibold];
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *headline = [[UILabel alloc] init];
    headline.text = title;
    headline.font = [UIFont systemFontOfSize:(dense ? 15 : (compact ? 17 : 21)) weight:UIFontWeightBold];
    headline.textColor = UIColor.whiteColor;
    headline.adjustsFontForContentSizeCategory = YES;
    headline.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detail = [[UILabel alloc] init];
    detail.text = subtitle;
    detail.font = compact ? [UIFont systemFontOfSize:(dense ? 11 : 13) weight:UIFontWeightRegular]
                          : [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detail.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    detail.adjustsFontForContentSizeCategory = YES;
    detail.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    arrow.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:(dense ? 11 : (compact ? 13 : 16)) weight:UIImageSymbolWeightBold];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;

    [button addSubview:icon];
    [button addSubview:headline];
    [button addSubview:detail];
    [button addSubview:arrow];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:(dense ? 14 : (compact ? 16 : 22))],
        [icon.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:(dense ? 28 : (compact ? 34 : 44))],
        [icon.heightAnchor constraintEqualToConstant:(dense ? 28 : (compact ? 34 : 44))],
        [headline.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:(dense ? 9 : (compact ? 12 : 16))],
        [headline.trailingAnchor constraintLessThanOrEqualToAnchor:arrow.leadingAnchor constant:-12],
        [headline.centerYAnchor constraintEqualToAnchor:button.centerYAnchor constant:(dense ? -7 : (compact ? -9 : -12))],
        [detail.leadingAnchor constraintEqualToAnchor:headline.leadingAnchor],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:arrow.leadingAnchor constant:-12],
        [detail.topAnchor constraintEqualToAnchor:headline.bottomAnchor constant:(dense ? 1 : 3)],
        [arrow.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:(dense ? -14 : (compact ? -16 : -22))],
        [arrow.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
    ]];

    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull unused) { action(); }]
          forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)_showSetup {
    [self _logNavigationEvent:@"select setup"];
    ESSetupViewController *setup = [[ESSetupViewController alloc] initWithThermalGovernor:nil dockBridge:nil];
    __weak typeof(self) weakSelf = self;
    setup.finished = ^{
        if ([weakSelf _usesDetailLayout]) {
            [weakSelf _showCamera];
        } else {
            [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf _showCamera]; }];
        }
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:setup];
    if ([self _showNavigationControllerInDetail:nav]) return;

    [self _logNavigationEvent:@"present setup modally"];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    // Setup is a destination from Home as well as the route into the camera.
    // Load its Help item first, then place a close control beside it so the
    // operator can return to the dashboard without opening the camera.
    [setup loadViewIfNeeded];
    __weak UINavigationController *weakNav = nav;
    UIBarButtonItem *close = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                      primaryAction:[UIAction actionWithHandler:^(UIAction *unused) {
        [weakNav dismissViewControllerAnimated:YES completion:nil];
    }]];
    setup.navigationItem.leftBarButtonItems = @[close, setup.navigationItem.leftBarButtonItem];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)_showRecordings {
    [self _logNavigationEvent:@"select recordings"];
    UINavigationController *nav = [[UINavigationController alloc]
                                   initWithRootViewController:[[ESRecordingsViewController alloc] init]];
    if ([self _showNavigationControllerInDetail:nav]) return;

    [self _logNavigationEvent:@"present recordings modally"];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (BOOL)_usesDetailLayout {
    UISplitViewController *split = self.splitViewController;
    // Route a selection into the secondary column only when UIKit has actually
    // tiled the two columns. Geometry and per-pane traits are not sufficient:
    // both can look wide while the split view is collapsed or presenting a
    // primary overlay.
    return split != nil &&
           !split.isCollapsed &&
           split.displayMode == UISplitViewControllerDisplayModeOneBesideSecondary;
}

- (BOOL)_showNavigationControllerInDetail:(UINavigationController *)navigation {
    if (![self _usesDetailLayout]) {
        [self _logNavigationEvent:@"detail route unavailable"];
        return NO;
    }
    UISplitViewController *split = self.splitViewController;
    [self _logNavigationEvent:@"replace secondary detail"];
    [split setViewController:navigation forColumn:UISplitViewControllerColumnSecondary];
    [split showDetailViewController:navigation sender:self];
    return YES;
}

- (void)_showCamera {
    [self _logNavigationEvent:@"present camera full screen"];
    ESMainViewController *camera = [[ESMainViewController alloc] init];
    camera.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:camera animated:YES completion:nil];
}

- (void)_logNavigationEvent:(NSString *)event {
    UISplitViewController *split = self.splitViewController;
    NSLog(@"[TakeCast][HomeNavigation] %@ controller=%p split=%@ display=%ld preferred=%ld behavior=%ld collapsed=%@ detailRoute=%@ presented=%@",
          event,
          self,
          split ? @"YES" : @"NO",
          (long)(split ? split.displayMode : UISplitViewControllerDisplayModeAutomatic),
          (long)(split ? split.preferredDisplayMode : UISplitViewControllerDisplayModeAutomatic),
          (long)(split ? split.splitBehavior : UISplitViewControllerSplitBehaviorAutomatic),
          split.isCollapsed ? @"YES" : @"NO",
          [self _usesDetailLayout] ? @"YES" : @"NO",
          self.presentedViewController ? NSStringFromClass(self.presentedViewController.class) : @"none");
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

@end
