//
//  SceneDelegate.m
//  TakeCast
//
//  Created by Kolja Wawrowsky on 8/2/26.
//

#import "SceneDelegate.h"
#import "ESHomeViewController.h"

@interface ESGradientPanel : UIView
- (instancetype)initWithColors:(NSArray<UIColor *> *)colors;
@end

@implementation ESGradientPanel {
    CAGradientLayer *_gradient;
}

- (instancetype)initWithColors:(NSArray<UIColor *> *)colors {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)colors[0].CGColor, (id)colors[1].CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        _gradient.cornerRadius = 26;
        [self.layer insertSublayer:_gradient atIndex:0];
        self.layer.cornerRadius = 26;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradient.frame = self.bounds;
}

@end

@interface SceneDelegate () <UISplitViewControllerDelegate>

@end

@implementation SceneDelegate

- (UIView *)_featureCardWithTitle:(NSString *)title
                            detail:(NSString *)detail
                            symbol:(NSString *)symbol
                             color:(UIColor *)color {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [color colorWithAlphaComponent:0.13];
    card.layer.cornerRadius = 22;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *iconBadge = [[UIView alloc] init];
    iconBadge.backgroundColor = [color colorWithAlphaComponent:0.18];
    iconBadge.layer.cornerRadius = 18;
    iconBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconBadge];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = color;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBadge addSubview:icon];

    UILabel *headline = [[UILabel alloc] init];
    headline.text = title;
    headline.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    headline.adjustsFontForContentSizeCategory = YES;
    headline.numberOfLines = 0;
    headline.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:headline];

    UILabel *body = [[UILabel alloc] init];
    body.text = detail;
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    body.textColor = UIColor.secondaryLabelColor;
    body.adjustsFontForContentSizeCategory = YES;
    body.numberOfLines = 0;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:body];

    [NSLayoutConstraint activateConstraints:@[
        [iconBadge.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [iconBadge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [iconBadge.widthAnchor constraintEqualToConstant:36],
        [iconBadge.heightAnchor constraintEqualToConstant:36],
        [icon.centerXAnchor constraintEqualToAnchor:iconBadge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBadge.centerYAnchor],
        [headline.topAnchor constraintEqualToAnchor:iconBadge.bottomAnchor constant:14],
        [headline.leadingAnchor constraintEqualToAnchor:iconBadge.leadingAnchor],
        [headline.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [body.topAnchor constraintEqualToAnchor:headline.bottomAnchor constant:5],
        [body.leadingAnchor constraintEqualToAnchor:headline.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:headline.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:150],
    ]];
    return card;
}

- (UIViewController *)_welcomeDetailViewController {
    UIViewController *detail = [[UIViewController alloc] init];
    detail.title = @"TakeCast";
    detail.view.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:1.00 alpha:1.0];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.alwaysBounceVertical = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [detail.view addSubview:scroll];

    UIStackView *content = [[UIStackView alloc] init];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 18;
    content.alignment = UIStackViewAlignmentFill;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    ESGradientPanel *hero = [[ESGradientPanel alloc] initWithColors:@[
        [UIColor colorWithRed:0.20 green:0.13 blue:0.55 alpha:1.0],
        [UIColor colorWithRed:0.03 green:0.49 blue:0.57 alpha:1.0],
    ]];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    [content addArrangedSubview:hero];
    [hero.heightAnchor constraintGreaterThanOrEqualToConstant:176].active = YES;

    UIStackView *heroContent = [[UIStackView alloc] init];
    heroContent.axis = UILayoutConstraintAxisVertical;
    heroContent.spacing = 7;
    heroContent.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:heroContent];

    UILabel *heroEyebrow = [[UILabel alloc] init];
    heroEyebrow.text = @"TAKECAST";
    heroEyebrow.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    heroEyebrow.textColor = [UIColor colorWithWhite:1 alpha:0.66];
    heroEyebrow.adjustsFontForContentSizeCategory = YES;
    [heroContent addArrangedSubview:heroEyebrow];

    UILabel *heroTitle = [[UILabel alloc] init];
    heroTitle.text = @"4K capture.\nLive connection.";
    heroTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    heroTitle.textColor = UIColor.whiteColor;
    heroTitle.numberOfLines = 0;
    heroTitle.adjustsFontForContentSizeCategory = YES;
    [heroContent addArrangedSubview:heroTitle];

    UILabel *heroBody = [[UILabel alloc] init];
    heroBody.text = @"Record the original on your iPhone while YouTube carries the live moment to everyone else.";
    heroBody.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    heroBody.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    heroBody.numberOfLines = 0;
    heroBody.adjustsFontForContentSizeCategory = YES;
    [heroContent addArrangedSubview:heroBody];

    [NSLayoutConstraint activateConstraints:@[
        [heroContent.topAnchor constraintEqualToAnchor:hero.topAnchor constant:24],
        [heroContent.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:26],
        [heroContent.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-26],
        [heroContent.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-24],
    ]];

    UILabel *sectionTitle = [[UILabel alloc] init];
    sectionTitle.text = @"Made for real events";
    sectionTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    sectionTitle.adjustsFontForContentSizeCategory = YES;
    [content addArrangedSubview:sectionTitle];

    UIStackView *firstRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self _featureCardWithTitle:@"4K local recording"
                             detail:@"A full-quality archive remains on your iPhone."
                             symbol:@"record.circle.fill"
                              color:[UIColor colorWithRed:0.94 green:0.18 blue:0.38 alpha:1.0]],
        [self _featureCardWithTitle:@"YouTube Live"
                             detail:@"Send a live HLS broadcast to your prepared stream."
                             symbol:@"dot.radiowaves.left.and.right"
                              color:[UIColor colorWithRed:0.20 green:0.45 blue:0.95 alpha:1.0]],
    ]];
    firstRow.axis = UILayoutConstraintAxisHorizontal;
    firstRow.spacing = 14;
    firstRow.distribution = UIStackViewDistributionFillEqually;
    [content addArrangedSubview:firstRow];

    UIStackView *secondRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self _featureCardWithTitle:@"Pre-flight confidence"
                             detail:@"Check storage, connection, and temperature before REC."
                             symbol:@"checkmark.shield.fill"
                              color:[UIColor colorWithRed:0.94 green:0.56 blue:0.04 alpha:1.0]],
        [self _featureCardWithTitle:@"Review and share"
                             detail:@"Watch, export, and clear recordings when the event ends."
                             symbol:@"film.stack.fill"
                              color:[UIColor colorWithRed:0.00 green:0.62 blue:0.55 alpha:1.0]],
    ]];
    secondRow.axis = UILayoutConstraintAxisHorizontal;
    secondRow.spacing = 14;
    secondRow.distribution = UIStackViewDistributionFillEqually;
    [content addArrangedSubview:secondRow];

    UILabel *note = [[UILabel alloc] init];
    note.text = @"Best practice: run an Unlisted YouTube test at the venue before the real event.";
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    note.numberOfLines = 0;
    note.adjustsFontForContentSizeCategory = YES;
    [content addArrangedSubview:note];

    UILayoutGuide *safe = detail.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:28],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:32],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-32],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-64],
    ]];
    return detail;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];

    ESHomeViewController *home = [[ESHomeViewController alloc] init];
    UINavigationController *menu = [[UINavigationController alloc] initWithRootViewController:home];
    [menu setNavigationBarHidden:YES animated:NO];
    // A split view has a distinct compact column. Give ordinary iPhones their
    // own card dashboard instead of collapsing to the wide-screen welcome pane.
    ESHomeViewController *compactHome = [[ESHomeViewController alloc] init];
    UINavigationController *compactMenu = [[UINavigationController alloc] initWithRootViewController:compactHome];
    [compactMenu setNavigationBarHidden:YES animated:NO];
    UINavigationController *detail = [[UINavigationController alloc]
                                    initWithRootViewController:[self _welcomeDetailViewController]];
    UISplitViewController *split = [[UISplitViewController alloc]
                                    initWithStyle:UISplitViewControllerStyleDoubleColumn];
    split.delegate = self;
    [split setViewController:menu forColumn:UISplitViewControllerColumnPrimary];
    [split setViewController:detail forColumn:UISplitViewControllerColumnSecondary];
    [split setViewController:compactMenu forColumn:UISplitViewControllerColumnCompact];
    // Automatic behavior may choose an overlay on the Duo. Tile keeps the
    // menu and detail in distinct columns, so the menu never obscures setup,
    // recordings, or the guide.
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredPrimaryColumnWidthFraction = 0.36;
    split.minimumPrimaryColumnWidth = 310;
    split.maximumPrimaryColumnWidth = 390;
    self.window.rootViewController = split;
    [self.window makeKeyAndVisible];
}

- (void)splitViewController:(UISplitViewController *)splitViewController
     willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    NSLog(@"[TakeCast][SplitNavigation] willChange display=%ld preferred=%ld behavior=%ld collapsed=%@ primaryWidth=%.0f",
          (long)displayMode,
          (long)splitViewController.preferredDisplayMode,
          (long)splitViewController.splitBehavior,
          splitViewController.isCollapsed ? @"YES" : @"NO",
          splitViewController.primaryColumnWidth);
}

- (void)splitViewControllerDidCollapse:(UISplitViewController *)splitViewController {
    NSLog(@"[TakeCast][SplitNavigation] didCollapse display=%ld behavior=%ld",
          (long)splitViewController.displayMode,
          (long)splitViewController.splitBehavior);
}

- (void)splitViewControllerDidExpand:(UISplitViewController *)splitViewController {
    NSLog(@"[TakeCast][SplitNavigation] didExpand display=%ld behavior=%ld primaryWidth=%.0f",
          (long)splitViewController.displayMode,
          (long)splitViewController.splitBehavior,
          splitViewController.primaryColumnWidth);
}

- (UISplitViewControllerDisplayMode)splitViewController:(UISplitViewController *)splitViewController
         displayModeForExpandingToProposedDisplayMode:(UISplitViewControllerDisplayMode)proposedDisplayMode {
    // The compact Duo may propose an overlay even though our menu is a true
    // master column. Keep it tiled: an item selection must replace Secondary,
    // never open a modal over an obscured detail.
    if (proposedDisplayMode == UISplitViewControllerDisplayModeOneOverSecondary) {
        NSLog(@"[TakeCast][SplitNavigation] replacing overlay proposal with OneBesideSecondary");
        return UISplitViewControllerDisplayModeOneBesideSecondary;
    }
    return proposedDisplayMode;
}

- (UISplitViewControllerDisplayMode)targetDisplayModeForActionInSplitViewController:(UISplitViewController *)splitViewController {
    NSLog(@"[TakeCast][SplitNavigation] action target OneBesideSecondary display=%ld behavior=%ld",
          (long)splitViewController.displayMode,
          (long)splitViewController.splitBehavior);
    return UISplitViewControllerDisplayModeOneBesideSecondary;
}


- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
}


@end
