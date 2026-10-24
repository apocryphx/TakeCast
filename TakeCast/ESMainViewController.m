//
//  ESMainViewController.m
//  TakeCast
//

#import "ESMainViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "ESCaptureEngine.h"
#import "ESEncoderPipeline.h"
#import "ESSegmentUploader.h"
#import "ESThermalGovernor.h"
#import "ESNetworkGovernor.h"
#import "TakeCast-Swift.h" // ESDockKitBridge, the one Swift file
#import "ESSettings.h"
#import "ESOnboardingViewController.h"
#import "ESSetupViewController.h"
#import "ESRecordingsViewController.h"

static const long long ESMinimumFreeBytes = 25LL * 1000 * 1000 * 1000; // 25 GB
static const double ESLevelSnapDegrees = 0.5;
// Zoom applied per gimbal wheel event. Apple's sample uses a fixed 0.2, but
// this wheel emits roughly 38 events per sweep, which at 0.2 would cross the
// whole 1.0x to 2.0x range seven times over. 0.025 puts one sweep at about the
// full range. Tune against the wheel, not against arithmetic.
static const CGFloat ESDockZoomStep = 0.025;

#pragma mark - Status lamp

@interface ESStatusLamp : UIView
@property (nonatomic, readonly) UILabel *label;
- (void)setDotColor:(UIColor *)color;
@end

@implementation ESStatusLamp {
    UIView *_dot;
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.layer.cornerRadius = 6;
        _dot = [[UIView alloc] initWithFrame:CGRectZero];
        _dot.layer.cornerRadius = 5;
        _dot.backgroundColor = UIColor.grayColor;
        [self addSubview:_dot];
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textColor = UIColor.whiteColor;
        [self addSubview:_label];
    }
    return self;
}

- (UILabel *)label { return _label; }

- (void)layoutSubviews {
    [super layoutSubviews];
    _dot.frame = CGRectMake(8, (self.bounds.size.height - 10) / 2, 10, 10);
    _label.frame = CGRectMake(24, 0, self.bounds.size.width - 30, self.bounds.size.height);
}

- (void)setDotColor:(UIColor *)color {
    _dot.backgroundColor = color;
}

@end

#pragma mark - Pill label

// A label that carries its own backing, so it reads against the live preview
// and against the bare background of the idle screen alike. The status lamps
// have always done this; these were the two labels left sitting on whatever
// happened to be behind them.
@interface ESPillLabel : UILabel
@end

@implementation ESPillLabel

static const CGFloat ESPillInsetX = 8;
static const CGFloat ESPillInsetY = 3;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.layer.cornerRadius = 6;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(ESPillInsetY, ESPillInsetX,
                                                                      ESPillInsetY, ESPillInsetX))];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize fit = [super sizeThatFits:size];
    return CGSizeMake(fit.width + ESPillInsetX * 2, fit.height + ESPillInsetY * 2);
}

@end

#pragma mark - Bubble level

@interface ESLevelView : UIView
- (void)setTiltRadians:(double)tilt;
@end

@implementation ESLevelView {
    CALayer *_referenceLine;
    CALayer *_horizonLine;
    CALayer *_bubble;
    double _tilt;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;

        _referenceLine = [CALayer layer];
        _referenceLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        [self.layer addSublayer:_referenceLine];

        _horizonLine = [CALayer layer];
        _horizonLine.backgroundColor = UIColor.whiteColor.CGColor;
        [self.layer addSublayer:_horizonLine];

        _bubble = [CALayer layer];
        _bubble.backgroundColor = UIColor.clearColor.CGColor;
        _bubble.borderColor = UIColor.whiteColor.CGColor;
        _bubble.borderWidth = 1.5;
        _bubble.cornerRadius = 7;
        [self.layer addSublayer:_bubble];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _referenceLine.frame = CGRectMake(0, h / 2 - 0.5, w, 1);
    _horizonLine.bounds = CGRectMake(0, 0, w * 0.7, 1.5);
    _horizonLine.position = CGPointMake(w / 2, h / 2);
    _bubble.bounds = CGRectMake(0, 0, 14, 14);
    _bubble.position = CGPointMake(w / 2, h / 2);
    [CATransaction commit];
}

- (void)setTiltRadians:(double)tilt {
    _tilt = tilt;
    double degrees = tilt * 180.0 / M_PI;
    BOOL level = fabs(degrees) < ESLevelSnapDegrees;
    UIColor *color = level ? UIColor.systemGreenColor : UIColor.whiteColor;
    double bubbleOffset = level ? 0 : MAX(-1.0, MIN(1.0, degrees / 5.0)) * (self.bounds.size.width * 0.28);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _horizonLine.transform = CATransform3DMakeRotation(level ? 0 : -tilt, 0, 0, 1);
    _horizonLine.backgroundColor = color.CGColor;
    _bubble.borderColor = color.CGColor;
    _bubble.position = CGPointMake(self.bounds.size.width / 2 + bubbleOffset, self.bounds.size.height / 2);
    [CATransaction commit];
}

@end

#pragma mark - Main view controller

@interface ESMainViewController () <ESCaptureEngineDelegate, ESEncoderPipelineDelegate,
                                    ESThermalGovernorDelegate, ESNetworkGovernorDelegate,
                                    ESDockKitBridgeDelegate>

// Read from capture queues while running, swapped on the main queue.
@property (atomic, strong, nullable) ESEncoderPipeline *archivePipeline;
@property (atomic, strong, nullable) ESEncoderPipeline *broadcastPipeline;

@end

@implementation ESMainViewController {
    ESCaptureEngine *_engine;
    ESSegmentUploader *_uploader;
    ESThermalGovernor *_governor;
    ESNetworkGovernor *_networkGovernor;
    ESDockKitBridge *_dockBridge;
    CMMotionManager *_motionManager;
    ESBroadcastTier _thermalTier;
    ESBroadcastTier _networkTier;
    ESBroadcastTier _appliedTier;
    BOOL _appliedTierValid;

    AVCaptureVideoPreviewLayer *_previewLayer;
    ESStatusLamp *_recLamp;
    ESStatusLamp *_liveLamp;
    ESStatusLamp *_thermLamp;
    ESStatusLamp *_dockLamp;
    ESStatusLamp *_tierLamp;
    ESLevelView *_levelView;
    UIButton *_startStopButton;
    UIButton *_lockButton;
    UIButton *_setupButton;
    UIButton *_recordingsButton;
    UISlider *_zoomSlider;
    ESPillLabel *_zoomLabel;
    ESPillLabel *_summaryLabel;
    ESPillLabel *_messageLabel;
    NSTimer *_hudTimer;

    BOOL _sessionActive;
    NSDate *_recordStartDate;
    NSDate *_interruptionStartDate;
    NSURL *_archiveURL;
    NSUInteger _hudTickCount;
    BOOL _didRunLaunchFlow;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Only ever visible before the preview layer has a session to draw. Black on
    // black left the idle screen unreadable; light grey gives the controls
    // something to sit against.
    self.view.backgroundColor = UIColor.lightGrayColor;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;

    // Stamp the binary into its own instrument record. A log that cannot name
    // the build that wrote it costs more than the line it takes to say so.
    [self _appendLog:[NSString stringWithFormat:@"BUILD compiled %s %s", __DATE__, __TIME__]];
    // A marker left by the previous run means its recording never reached a
    // finalized STOP. Say so once, here, before anything records again.
    NSString *stoppedEarly = [ESSettings resolveLeftoverRecordingMarker];
    if (stoppedEarly) [self _appendLog:[NSString stringWithFormat:@"STOPPED EARLY %@", stoppedEarly]];

    _engine = [[ESCaptureEngine alloc] init];
    _engine.delegate = self;
    _governor = [[ESThermalGovernor alloc] init];
    _governor.delegate = self;
    // A DockKit gimbal pans by itself the moment a camera app is docked. Watch
    // for one so the LOCK control can hold the frame, and so the handle can
    // drive REC and zoom. Harmless when the camera sits on a dumb tripod.
    _dockBridge = [[ESDockKitBridge alloc] init];
    _dockBridge.delegate = self;
    [_dockBridge start];
    _motionManager = [[CMMotionManager alloc] init];

    _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_engine.session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view.layer addSublayer:_previewLayer];

    _levelView = [[ESLevelView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_levelView];

    _recLamp = [[ESStatusLamp alloc] initWithFrame:CGRectZero];
    _liveLamp = [[ESStatusLamp alloc] initWithFrame:CGRectZero];
    _thermLamp = [[ESStatusLamp alloc] initWithFrame:CGRectZero];
    _dockLamp = [[ESStatusLamp alloc] initWithFrame:CGRectZero];
    // Which tier the broadcast runs at and which governor put it there: the one
    // reading that tells heat from the network without opening the log.
    _tierLamp = [[ESStatusLamp alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_recLamp];
    [self.view addSubview:_liveLamp];
    [self.view addSubview:_thermLamp];
    [self.view addSubview:_tierLamp];
    [self.view addSubview:_dockLamp];

    _messageLabel = [[ESPillLabel alloc] initWithFrame:CGRectZero];
    _messageLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _messageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    // An empty pill is just a smudge on the preview. Nothing to say, nothing to draw.
    _messageLabel.hidden = YES;
    [self.view addSubview:_messageLabel];

    _startStopButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _startStopButton.backgroundColor = UIColor.systemRedColor;
    _startStopButton.layer.cornerRadius = 32;
    [_startStopButton setTitle:@"REC" forState:UIControlStateNormal];
    _startStopButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_startStopButton addTarget:self action:@selector(_startStopTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_startStopButton];

    _lockButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_lockButton setTitle:@"AUTO" forState:UIControlStateNormal];
    _lockButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    _lockButton.tintColor = UIColor.whiteColor;
    _lockButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _lockButton.layer.cornerRadius = 6;
    [_lockButton addTarget:self action:@selector(_lockTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_lockButton];

    // The mic pattern is a session setting chosen in Setup, but the engine
    // takes it as soon as it is known so the route has settled by REC.
    _engine.directionalMicrophonePreferred = ESSettings.directionalMicrophone;

    _zoomSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _zoomSlider.minimumValue = 1.0;
    _zoomSlider.maximumValue = 2.0;
    _zoomSlider.value = 1.0;
    _zoomSlider.transform = CGAffineTransformMakeRotation(-M_PI_2);
    [_zoomSlider addTarget:self action:@selector(_zoomChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_zoomSlider];

    _zoomLabel = [[ESPillLabel alloc] initWithFrame:CGRectZero];
    _zoomLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _zoomLabel.textColor = UIColor.whiteColor;
    _zoomLabel.textAlignment = NSTextAlignmentCenter;
    _zoomLabel.text = @"1.0x";
    [self.view addSubview:_zoomLabel];

    _summaryLabel = [[ESPillLabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _summaryLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    [self.view addSubview:_summaryLabel];

    __weak typeof(self) weakControls = self;
    _setupButton = [self _barButtonWithTitle:@"Setup" symbol:@"slider.horizontal.3"
                                     handler:^{ [weakControls _showSetup]; }];
    _recordingsButton = [self _barButtonWithTitle:@"Recordings" symbol:@"film.stack"
                                          handler:^{ [weakControls _showRecordings]; }];
    [self.view addSubview:_setupButton];
    [self.view addSubview:_recordingsButton];
    [self _updateSessionSummary];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(_previewTapped)];
    [self.view addGestureRecognizer:tap];

    [self _updateIdleLamps];
    [self _startMotionUpdates];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat w = bounds.size.width;
    CGFloat h = bounds.size.height;
    CGFloat topInset = MAX(12, self.view.safeAreaInsets.top + 4);
    CGFloat leftInset = MAX(16, self.view.safeAreaInsets.left + 8);
    CGFloat rightInset = MAX(16, self.view.safeAreaInsets.right + 8);
    CGFloat bottomInset = MAX(12, self.view.safeAreaInsets.bottom + 4);

    _previewLayer.frame = bounds;
    _levelView.frame = CGRectMake(w / 2 - 160, h / 2 - 60, 320, 120);

    // Lamps run left to right at fixed widths and wrap to a second row when
    // a narrow screen runs out of room before the lock button, rather than
    // shrinking or hiding one.
    _lockButton.frame = CGRectMake(w - rightInset - 64, topInset, 64, 28);
    CGFloat lampRight = w - rightInset - 72;
    CGFloat x = leftInset;
    CGFloat y = topInset;
    NSArray<ESStatusLamp *> *lamps = @[_recLamp, _liveLamp, _thermLamp, _tierLamp, _dockLamp];
    NSArray<NSNumber *> *widths = @[@214, @120, @140, @150, @190];
    for (NSUInteger i = 0; i < lamps.count; i++) {
        CGFloat width = widths[i].doubleValue;
        if (x > leftInset && x + width > lampRight) {
            x = leftInset;
            y += 34;
        }
        lamps[i].frame = CGRectMake(x, y, width, 28);
        x += width + 8;
    }
    // The pill hugs the text rather than spanning the screen, so a short message
    // does not paint a bar across the preview.
    CGFloat messageMax = w - leftInset - rightInset - 72;
    CGFloat messageWidth = [_messageLabel sizeThatFits:CGSizeMake(messageMax, CGFLOAT_MAX)].width;
    _messageLabel.frame = CGRectMake(leftInset, y + 34, MIN(messageMax, messageWidth), 22);

    _startStopButton.frame = CGRectMake(w - rightInset - 64, h - bottomInset - 64, 64, 64);
    CGSize setupSize = [_setupButton sizeThatFits:CGSizeMake(200, 36)];
    CGSize recordingsSize = [_recordingsButton sizeThatFits:CGSizeMake(200, 36)];
    _setupButton.frame = CGRectMake(leftInset, h - bottomInset - 36, setupSize.width, 36);
    _recordingsButton.frame = CGRectMake(CGRectGetMaxX(_setupButton.frame) + 8, h - bottomInset - 36,
                                         recordingsSize.width, 36);
    CGFloat summaryMax = w - leftInset - rightInset - 80;
    CGFloat summaryWidth = [_summaryLabel sizeThatFits:CGSizeMake(summaryMax, CGFLOAT_MAX)].width;
    _summaryLabel.frame = CGRectMake(leftInset, h - bottomInset - 36 - 30, MIN(summaryMax, summaryWidth), 22);

    // The slider is rotated; position it by center with its pre-rotation length.
    CGFloat sliderLength = MIN(240, h * 0.45);
    _zoomSlider.bounds = CGRectMake(0, 0, sliderLength, 32);
    _zoomSlider.center = CGPointMake(w - rightInset - 24, h / 2);
    _zoomLabel.frame = CGRectMake(w - rightInset - 54, h / 2 - sliderLength / 2 - 30, 60, 24);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

#pragma mark - Motion / bubble level

- (void)_startMotionUpdates {
    if (!_motionManager.isDeviceMotionAvailable) return;
    _motionManager.deviceMotionUpdateInterval = 1.0 / 15.0;
    __weak typeof(self) weakSelf = self;
    [_motionManager startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                                        withHandler:^(CMDeviceMotion *motion, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !motion) return;
        [strongSelf _updateLevelWithGravity:motion.gravity];
    }];
}

- (void)_updateLevelWithGravity:(CMAcceleration)gravity {
    if (_levelView.hidden) return;
    // In landscape the gravity vector lies along the device x axis when level.
    // Fold the angle to the nearest landscape rest so both orientations work.
    double theta = atan2(gravity.y, gravity.x);
    double tilt = theta;
    if (tilt > M_PI_2) tilt -= M_PI;
    else if (tilt < -M_PI_2) tilt += M_PI;
    [_levelView setTiltRadians:tilt];
}

- (void)_previewTapped {
    _levelView.hidden = !_levelView.hidden;
}

#pragma mark - Controls

// The route takes a moment to reconfigure, so log what was asked for next to
// what the route reports rather than assuming the two already agree.
- (void)_applyMicrophonePattern:(BOOL)directional {
    _engine.directionalMicrophonePreferred = directional;
    [self _appendLog:[NSString stringWithFormat:@"MIC %@ requested, route reports %@",
                      directional ? @"directional" : @"omnidirectional",
                      _engine.microphonePatternDescription]];
    [self _updateSessionSummary];
}

- (void)_zoomChanged {
    [_engine setZoomFactor:_zoomSlider.value ramped:YES];
}

// LOCK means the frame is held. Exposure, white balance, and focus stop
// hunting, and a docked gimbal stops panning: a ceremony shot that drifts off
// the couple is the same failure whichever of the two caused it.
- (void)_lockTapped {
    if (_engine.isLocked) {
        [_engine unlockExposureWhiteBalanceAndFocus];
    } else {
        [_engine lockExposureWhiteBalanceAndFocus];
    }
    // Tapping LOCK commands the gimbal as well as the optics. This is the only
    // place that does so on the operator's behalf, which is what leaves the
    // gimbal's own tracking button free to override it afterwards.
    [_dockBridge setTrackingEnabled:!_engine.isLocked];
    [self _syncLockControlToEngine];
}

// The button reflects what the camera reports, never what we assumed we set.
// Configuring a session resets the camera's modes, so the two can part company
// unless something puts them back together. Deliberately does not touch gimbal
// tracking: starting a recording must not undo a tracking button press.
- (void)_syncLockControlToEngine {
    BOOL locked = _engine.isLocked;
    [_lockButton setTitle:locked ? @"LOCK" : @"AUTO" forState:UIControlStateNormal];
    _lockButton.tintColor = locked ? UIColor.systemYellowColor : UIColor.whiteColor;
    [self _appendLog:[NSString stringWithFormat:@"LOCK %@, camera reports %@",
                      locked ? @"on" : @"off", _engine.cameraModeDescription]];
    [self _updateDockLamp];
}

- (UIButton *)_barButtonWithTitle:(NSString *)title symbol:(NSString *)symbol handler:(void (^)(void))handler {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:symbol];
    config.imagePadding = 6;
    config.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    config.baseForegroundColor = UIColor.whiteColor;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *updated = [attributes mutableCopy];
        updated[NSFontAttributeName] = [UIFont boldSystemFontOfSize:13];
        return updated;
    };
    config.background.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    config.background.cornerRadius = 6;
    config.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 12);
    return [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        handler();
    }]];
}

- (void)_updateSessionSummary {
    _summaryLabel.text = [ESSettings sessionSummary];
    [self.view setNeedsLayout];
}

// Session settings and the recordings list only exist between sessions.
- (void)_updateIdleControls {
    _setupButton.hidden = _sessionActive;
    _recordingsButton.hidden = _sessionActive;
}

#pragma mark - Launch flow and other screens

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_didRunLaunchFlow) return;
    _didRunLaunchFlow = YES;
    if (!ESSettings.hasCompletedOnboarding) {
        [self _showOnboarding];
    } else {
        [self _explainIfCameraDenied];
    }
}

- (void)_showOnboarding {
    if (_sessionActive) return;
    ESOnboardingViewController *onboarding = [[ESOnboardingViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:onboarding];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) weakSelf = self;
    onboarding.completion = ^(ESOnboardingChoice choice) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (choice == ESOnboardingChoiceRecordOnly) {
            ESSettings.streamingEnabled = NO;
            [strongSelf _updateSessionSummary];
            [strongSelf dismissViewControllerAnimated:YES completion:^{
                [weakSelf _explainIfCameraDenied];
            }];
        } else {
            // Straight on into Setup, without flashing the Live screen in between.
            [nav setViewControllers:@[[strongSelf _newSetupController]] animated:YES];
        }
    };
    [self presentViewController:nav animated:YES completion:nil];
}

- (ESSetupViewController *)_newSetupController {
    ESSetupViewController *setup = [[ESSetupViewController alloc] initWithThermalGovernor:_governor
                                                                               dockBridge:_dockBridge];
    __weak typeof(self) weakSelf = self;
    setup.microphonePatternChanged = ^(BOOL directional) {
        [weakSelf _applyMicrophonePattern:directional];
    };
    setup.finished = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf _updateSessionSummary];
        [strongSelf dismissViewControllerAnimated:YES completion:^{
            [weakSelf _explainIfCameraDenied];
        }];
    };
    return setup;
}

- (void)_showSetup {
    if (_sessionActive || self.presentedViewController) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[self _newSetupController]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)_showRecordings {
    if (_sessionActive || self.presentedViewController) return;
    UINavigationController *nav = [[UINavigationController alloc]
                                   initWithRootViewController:[[ESRecordingsViewController alloc] init]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

// The preview only draws once REC starts the session, so a denied camera
// otherwise looks like nothing more than a grey screen.
- (void)_explainIfCameraDenied {
    AVAuthorizationStatus video = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (video == AVAuthorizationStatusDenied || video == AVAuthorizationStatusRestricted) {
        [self _showMessage:[NSString stringWithFormat:@"Camera access is off, so %@ cannot record. Open Setup to fix it.",
                            ESAppName()]];
    }
}

#pragma mark - Start / stop

- (void)_startStopTapped {
    if (_sessionActive) {
        [self _stopSession];
    } else {
        [self _preflightAndStart];
    }
}

- (void)_preflightAndStart {
    long long freeBytes = [self _availableCapacity];
    if (freeBytes >= 0 && freeBytes < ESMinimumFreeBytes) {
        NSString *text = [NSString stringWithFormat:
                          @"Only %.1f GB free. %@ refuses to start with less than 25 GB. 4K at 40 Mbps needs roughly 18 GB per hour.",
                          freeBytes / 1e9, ESAppName()];
        [self _showAlertWithTitle:@"Not enough storage" message:text];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self _requestCaptureAuthorizationThen:^(BOOL granted) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!granted) {
            [strongSelf _showAlertWithTitle:@"Camera access needed"
                                    message:[NSString stringWithFormat:@"Enable camera and microphone access for %@ in Settings.", ESAppName()]];
            return;
        }
        [strongSelf _startSession];
    }];
}

- (void)_requestCaptureAuthorizationThen:(void (^)(BOOL granted))completion {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL videoGranted) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL audioGranted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(videoGranted); // audio denial degrades, video denial blocks
            });
        }];
    }];
}

- (void)_startSession {
    NSInteger fps = ESSettings.frameRate;
    NSError *error = nil;
    if (![_engine configureWithFrameRate:fps error:&error]) {
        [self _showAlertWithTitle:@"Camera configuration failed"
                          message:error.localizedDescription ?: @"Unknown error"];
        return;
    }

    // Configuring reset the camera to continuous focus, exposure, and white
    // balance, so put the LOCK control back in step with it.
    [self _syncLockControlToEngine];

    CGFloat rotation = [self _interfaceRotationAngle];
    if ([_previewLayer.connection isVideoRotationAngleSupported:rotation]) {
        _previewLayer.connection.videoRotationAngle = rotation;
    }

    _archiveURL = [self _newArchiveURL];
    NSDictionary *archiveConfig = @{
        ESEncoderConfigNameKey: @"archive",
        ESEncoderConfigCodecKey: @(kCMVideoCodecType_HEVC),
        ESEncoderConfigWidthKey: @3840,
        ESEncoderConfigHeightKey: @2160,
        ESEncoderConfigFrameRateKey: @(fps),
        ESEncoderConfigAverageBitRateKey: @(40 * 1000 * 1000),
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeFragmentedFile),
        ESEncoderConfigFileURLKey: _archiveURL,
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    ESEncoderPipeline *archive = [[ESEncoderPipeline alloc] initWithConfiguration:archiveConfig error:&error];
    if (!archive || ![archive startWithError:&error]) {
        [self _showAlertWithTitle:@"Archive encoder failed"
                          message:error.localizedDescription ?: @"Unknown error"];
        return;
    }
    archive.delegate = self;
    self.archivePipeline = archive;
    [ESSettings markRecordingStartedAtURL:_archiveURL];

    NSString *ingest = ESSettings.effectiveIngestURL;
    if (ingest.length > 0) {
        _uploader = [[ESSegmentUploader alloc] initWithIngestURLString:ingest];
        if (_uploader) {
            _uploader.usesTransportStream = YES; // YouTube HLS ingestion requires M2TS
            [_uploader start];
        } else {
            [self _showMessage:@"Ingest URL not understood, archive only"];
        }
    } else {
        _uploader = nil;
    }

    _sessionActive = YES;
    _recordStartDate = [NSDate date];
    _hudTickCount = 0;
    _thermalTier = ESBroadcastTierFull;
    // Join low: the broadcast starts at 720p and earns 1080p with proven
    // headroom. Old screens will not see the difference; a buffering wheel
    // reads as an error to everyone.
    _networkTier = _uploader ? ESBroadcastTierReduced : ESBroadcastTierFull;
    _appliedTierValid = NO;
    if (_uploader) {
        _networkGovernor = [[ESNetworkGovernor alloc] initWithUploader:_uploader];
        _networkGovernor.delegate = self;
        [_networkGovernor start];
    }
    [_governor startObserving]; // fires the initial tier, which builds the broadcast pipeline
    [_engine startRunning];
    [self _logInstrumentStatus];

    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self _updateIdleControls];
    [self _updateSessionSummary];
    [_startStopButton setTitle:@"STOP" forState:UIControlStateNormal];
    _startStopButton.backgroundColor = [UIColor colorWithRed:0.35 green:0 blue:0 alpha:1];
    _zoomSlider.value = 1.0;

    _hudTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                               selector:@selector(_updateHUD) userInfo:nil repeats:YES];
    NSLog(@"[main] session started, archive %@", _archiveURL.lastPathComponent);
    [self _showMessage:[NSString stringWithFormat:@"Recording to %@, audio: %@",
                        _archiveURL.lastPathComponent, _engine.currentAudioRouteName ?: @"built in"]];
}

- (void)_stopSession {
    if (!_sessionActive) return;
    [self _logInstrumentStatus];
    _sessionActive = NO;
    [_hudTimer invalidate];
    _hudTimer = nil;

    [_engine stopRunning];
    [_governor stopObserving];
    [_networkGovernor stop];
    _networkGovernor = nil;

    // The broadcast finishes first so its final segment reaches the queue,
    // then the uploader drains and says goodbye with EXT-X-ENDLIST. The
    // uploader ivar stays set until the finish completes: the final segment
    // arrives through the pipeline delegate, which delivers to _uploader.
    ESEncoderPipeline *broadcast = self.broadcastPipeline;
    self.broadcastPipeline = nil;
    ESSegmentUploader *uploader = _uploader;
    __weak typeof(self) weakStopSelf = self;
    void (^streamEnded)(void) = uploader ? ^{
        typeof(self) strongSelf = weakStopSelf;
        [strongSelf _showMessage:@"Stream ended cleanly"];
    } : nil;
    if (broadcast) {
        [broadcast finishWithCompletionHandler:^{
            typeof(self) strongSelf = weakStopSelf;
            if (strongSelf) strongSelf->_uploader = nil;
            [uploader finishAndSignalEndWithCompletion:streamEnded];
        }];
    } else {
        _uploader = nil;
        [uploader finishAndSignalEndWithCompletion:streamEnded];
    }

    ESEncoderPipeline *archive = self.archivePipeline;
    self.archivePipeline = nil;
    NSURL *archiveURL = _archiveURL;
    __weak typeof(self) weakSelf = self;
    [archive finishWithCompletionHandler:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [ESSettings markRecordingFinalizedAtURL:archiveURL];
        long long size = [strongSelf _fileSizeAtURL:archiveURL];
        [strongSelf _appendLog:[NSString stringWithFormat:@"Saved %@ (%.2f GB)",
                                archiveURL.lastPathComponent, size / 1e9]];
        [strongSelf _showMessage:@"Recording saved. Open Recordings"];
        [strongSelf _offerRecordingsAfterSaveWithSize:size];
    }];

    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self _updateIdleControls];
    [_startStopButton setTitle:@"REC" forState:UIControlStateNormal];
    _startStopButton.backgroundColor = UIColor.systemRedColor;
    [self _updateIdleLamps];
    NSLog(@"[main] session stopped");
}

- (void)_offerRecordingsAfterSaveWithSize:(long long)size {
    if (_sessionActive || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Recording saved"
                         message:[NSString stringWithFormat:@"%.2f GB in full 4K quality. Share it to Photos, Files or AirDrop from Recordings.", size / 1e9]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Open Recordings" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { [weakSelf _showRecordings]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    alert.preferredAction = alert.actions.firstObject;
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Thermal governor

- (void)thermalGovernor:(ESThermalGovernor *)governor
          didChangeTier:(ESBroadcastTier)tier
           thermalState:(NSProcessInfoThermalState)state {
    [self _updateThermLampForState:state];
    if (!_sessionActive) return;
    _thermalTier = tier;
    [self _applyEffectiveTier];
}

- (void)networkGovernor:(ESNetworkGovernor *)governor
          didChangeTier:(ESBroadcastTier)tier
                 reason:(NSString *)reason {
    if (!_sessionActive) return;
    _networkTier = tier;
    [self _showMessage:[NSString stringWithFormat:@"Network: %@ (%@)",
                        [ESThermalGovernor nameForTier:tier], reason]];
    [self _applyEffectiveTier];
}

// Two governors, one broadcast: the worse verdict wins. The archive is
// beyond the reach of both.
- (void)_applyEffectiveTier {
    ESBroadcastTier effective = MAX(_thermalTier, _networkTier);
    [self _updateTierLamp];
    if (_appliedTierValid && effective == _appliedTier) return;
    _appliedTier = effective;
    _appliedTierValid = YES;
    [self _applyBroadcastTier:effective];
}

- (void)_applyBroadcastTier:(ESBroadcastTier)tier {
    ESEncoderPipeline *old = self.broadcastPipeline;
    self.broadcastPipeline = nil;
    if (old) [old finishWithCompletionHandler:nil];

    if (tier == ESBroadcastTierOff || !_uploader) {
        if (tier == ESBroadcastTierOff) {
            [self _showMessage:@"Thermal critical: broadcast stopped, archive continues"];
        }
        return;
    }

    NSInteger fps = _engine.frameRate;
    BOOL reduced = (tier == ESBroadcastTierReduced);
    BOOL hevc = ESSettings.broadcastUsesHEVC;
    // HEVC carries the same quality in roughly two thirds of the bits, which
    // is uplink power saved on a weak cell signal.
    NSInteger bitRate = hevc ? (reduced ? 2 : 4) * 1000 * 1000
                             : (reduced ? 3 : 6) * 1000 * 1000;
    NSDictionary *config = @{
        ESEncoderConfigNameKey: [NSString stringWithFormat:@"broadcast%@%@",
                                 reduced ? @"720" : @"1080", hevc ? @"hevc" : @"h264"],
        ESEncoderConfigCodecKey: @(hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264),
        ESEncoderConfigWidthKey: reduced ? @1280 : @1920,
        ESEncoderConfigHeightKey: reduced ? @720 : @1080,
        ESEncoderConfigFrameRateKey: @(fps),
        ESEncoderConfigAverageBitRateKey: @(bitRate),
        ESEncoderConfigConstrainDataRateKey: @YES,
        ESEncoderConfigOutputModeKey: @(ESEncoderOutputModeMPEG2TS),
        ESEncoderConfigSegmentSecondsKey: @2,
    };
    NSError *error = nil;
    ESEncoderPipeline *pipeline = [[ESEncoderPipeline alloc] initWithConfiguration:config error:&error];
    if (!pipeline || ![pipeline startWithError:&error]) {
        NSLog(@"[main] broadcast pipeline failed to start: %@", error);
        [self _showMessage:@"Broadcast encoder failed, archive continues"];
        return;
    }
    pipeline.delegate = self;
    self.broadcastPipeline = pipeline;
}

#pragma mark - Capture engine delegate (capture queues)

- (void)captureEngine:(ESCaptureEngine *)engine didOutputVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.archivePipeline appendVideoSampleBuffer:sampleBuffer];
    [self.broadcastPipeline appendVideoSampleBuffer:sampleBuffer];
}

- (void)captureEngine:(ESCaptureEngine *)engine didOutputAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.archivePipeline appendAudioSampleBuffer:sampleBuffer];
    [self.broadcastPipeline appendAudioSampleBuffer:sampleBuffer];
}

// The session stops and restarts itself, so there is nothing to fix here. The
// point is that the gap stops being invisible: the lamp says so at the time and
// the instrument log says so afterwards, which is the only way a hole in the
// archive is ever explained.
- (void)captureEngine:(ESCaptureEngine *)engine
    didChangeInterruption:(BOOL)interrupted
                   reason:(NSString *)reason {
    if (interrupted) {
        _interruptionStartDate = [NSDate date];
        [self _appendLog:[NSString stringWithFormat:@"INTERRUPTED %@", reason ?: @"unknown"]];
        [self _showMessage:[NSString stringWithFormat:@"Capture interrupted: %@", reason ?: @"unknown"]];
    } else {
        NSTimeInterval away = _interruptionStartDate ? -[_interruptionStartDate timeIntervalSinceNow] : 0;
        _interruptionStartDate = nil;
        [self _appendLog:[NSString stringWithFormat:@"RESUMED after %.1f s", away]];
        [self _showMessage:[NSString stringWithFormat:@"Capture resumed, %.1f s missing", away]];
    }
    if (_sessionActive) [self _updateHUD];
}

- (void)captureEngine:(ESCaptureEngine *)engine audioRouteDidChange:(NSString *)routeName isExternal:(BOOL)isExternal {
    NSString *kind = isExternal ? @"USB" : @"built in";
    [self _showMessage:[NSString stringWithFormat:@"Audio: %@ (%@)", routeName, kind]];
}

- (void)captureEngine:(ESCaptureEngine *)engine didFailWithError:(NSError *)error {
    [self _showMessage:[NSString stringWithFormat:@"Capture error: %@", error.localizedDescription]];
}

#pragma mark - Encoder pipeline delegate

- (void)encoderPipeline:(ESEncoderPipeline *)pipeline
   didOutputSegmentData:(NSData *)data
            segmentType:(AVAssetSegmentType)segmentType
               duration:(double)duration {
    ESSegmentType type = (segmentType == AVAssetSegmentTypeInitialization)
        ? ESSegmentTypeInitialization : ESSegmentTypeMedia;
    [_uploader enqueueSegmentData:data type:type duration:duration];
}

- (void)encoderPipeline:(ESEncoderPipeline *)pipeline didFailWithError:(NSError *)error {
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    NSString *detail = [NSString stringWithFormat:@"%@ [%@ %ld%@]",
                        error.localizedDescription, error.domain, (long)error.code,
                        underlying ? [NSString stringWithFormat:@", %@ %ld",
                                      underlying.domain, (long)underlying.code] : @""];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([pipeline.name isEqualToString:@"archive"]) {
            [self _showMessage:[NSString stringWithFormat:@"ARCHIVE ENCODER FAILED: %@", detail]];
        } else {
            [self _showMessage:[NSString stringWithFormat:@"Broadcast failed (%@), archive continues", detail]];
        }
    });
}

#pragma mark - DockKit bridge delegate (main queue)

- (void)dockKitBridgeDidChangeDockedState:(ESDockKitBridge *)bridge {
    // Only a dock transition reaches here; pressing the gimbal's tracking
    // button never does. DockKit resets a freshly docked accessory to system
    // tracking, so a camera lifted off and put back during a locked ceremony
    // shot would otherwise start panning on its own. Restore what LOCK asked
    // for, and leave every deliberate button press alone.
    if (bridge.docked && _engine.isLocked && bridge.systemTrackingEnabled) {
        [bridge setTrackingEnabled:NO];
    }
    [self _updateDockLamp];
}

- (void)dockKitBridgeDidUpdateBattery:(ESDockKitBridge *)bridge {
    [self _updateDockLamp];
}

- (void)dockKitBridgeDidChangeTrackingState:(ESDockKitBridge *)bridge {
    [self _updateDockLamp];
}

// The gimbal handle is a REC remote. It runs the same path as the on screen
// button, storage preflight and permission checks included, so there is no
// second way to start a session that could behave differently.
- (void)dockKitBridgeDidPressShutter:(ESDockKitBridge *)bridge {
    [self _startStopTapped];
}

// Only the SIGN of the factor carries meaning. Apple's DockKit sample reads it
// as "factor > 0 ? increase : decrease" and throws the magnitude away, and this
// wheel bears that out: the Flow 2 Pro sends 0.01 turning one way and 0.00
// turning the other. Treating the value as an absolute zoom pinned the camera
// at 1.0x, and treating 0.00 as an idle tick would have dropped every zoom out.
- (void)dockKitBridge:(ESDockKitBridge *)bridge didRequestZoomFactor:(CGFloat)factor {
    CGFloat previous = _engine.zoomFactor;
    CGFloat step = (factor > 0) ? ESDockZoomStep : -ESDockZoomStep;
    // The wheel has no idea the archive degrades past 2x.
    CGFloat clamped = MAX(_engine.minZoomFactor, MIN(_engine.maxZoomFactor, previous + step));
    // Apply directly. The wheel is the ramp; the operator's hand sets the pace.
    [_engine setZoomFactor:clamped ramped:NO];
    // Never move the slider under a finger that is dragging it.
    if (!_zoomSlider.isTracking) _zoomSlider.value = clamped;
    [self _appendLog:[NSString stringWithFormat:@"DOCKZOOM raw %+.4f step %+.3f from %.3f to %.3f engine %.3f",
                      factor, step, previous, clamped, _engine.zoomFactor]];
}

- (void)dockKitBridge:(ESDockKitBridge *)bridge didReportMessage:(NSString *)message {
    [self _showMessage:message];
}

// Log only. A wheel produces a torrent, and the HUD message line is the
// operator's, not the instrument's.
- (void)dockKitBridge:(ESDockKitBridge *)bridge didTraceEvent:(NSString *)text {
    [self _appendLog:[NSString stringWithFormat:@"DOCKEVT %@", text]];
}

- (void)_updateDockLamp {
    if (!_dockBridge.docked) {
        _dockLamp.label.text = @"DOCK none";
        [_dockLamp setDotColor:UIColor.grayColor];
        return;
    }
    // HELD is the state that matters during a ceremony: the gimbal is docked
    // and has agreed to stay still.
    NSString *tracking = _dockBridge.systemTrackingEnabled ? @"TRK" : @"HELD";
    double level = _dockBridge.batteryLevel;
    _dockLamp.label.text = (level >= 0)
        ? [NSString stringWithFormat:@"DOCK %.0f%% %@", level * 100.0, tracking]
        : [NSString stringWithFormat:@"DOCK %@", tracking];
    UIColor *color = _dockBridge.batteryLow ? UIColor.systemRedColor
                   : (level < 0) ? UIColor.systemOrangeColor
                                 : UIColor.systemGreenColor;
    [_dockLamp setDotColor:color];
}

#pragma mark - HUD

- (void)_updateHUD {
    if (!_sessionActive) return;

    _hudTickCount++;
    if (_hudTickCount % 30 == 0) [self _logInstrumentStatus];

    NSTimeInterval elapsed = -[_recordStartDate timeIntervalSinceNow];
    long long size = [self _fileSizeAtURL:_archiveURL];
    int hours = (int)elapsed / 3600;
    int minutes = ((int)elapsed % 3600) / 60;
    int seconds = (int)elapsed % 60;
    _recLamp.label.text = [NSString stringWithFormat:@"REC %02d:%02d:%02d  %.2f GB",
                           hours, minutes, seconds, size / 1e9];
    BOOL writing = size > 0;
    [_recLamp setDotColor:writing ? UIColor.systemRedColor : UIColor.systemOrangeColor];
    // An interrupted session delivers nothing, so a lamp still counting up a
    // healthy REC is the one reading that would actively mislead.
    if (_engine.isInterrupted) {
        _recLamp.label.text = @"REC INTERRUPTED";
        [_recLamp setDotColor:UIColor.systemYellowColor];
    }

    if (_uploader) {
        NSString *failure = _uploader.lastFailureDescription;
        NSString *failureMessage = failure ? [NSString stringWithFormat:@"Upload failing: %@", failure] : nil;
        if (failureMessage && ![failureMessage isEqualToString:_messageLabel.text]) {
            [self _showMessage:failureMessage];
        }
        NSTimeInterval ackAge = _uploader.secondsSinceLastAck;
        if (ackAge < 0) {
            _liveLamp.label.text = @"LIVE ...";
            [_liveLamp setDotColor:UIColor.systemOrangeColor];
        } else {
            _liveLamp.label.text = [NSString stringWithFormat:@"LIVE %.0fs", ackAge];
            UIColor *color = (ackAge < 6) ? UIColor.systemGreenColor
                           : (ackAge < 15) ? UIColor.systemOrangeColor : UIColor.systemRedColor;
            [_liveLamp setDotColor:color];
        }
    } else {
        _liveLamp.label.text = @"LIVE off";
        [_liveLamp setDotColor:UIColor.grayColor];
    }

    CGFloat zoom = _engine.zoomFactor;
    _zoomLabel.text = [NSString stringWithFormat:@"%.1fx", zoom];
    _zoomLabel.textColor = (zoom > _engine.upscaleThreshold + 0.01)
        ? UIColor.systemOrangeColor : UIColor.whiteColor;
    if (zoom > _engine.upscaleThreshold + 0.01) {
        [self _showMessage:[NSString stringWithFormat:@"Zoom %.1fx exceeds the upscale threshold %.1fx",
                            zoom, _engine.upscaleThreshold]];
    }
}

- (void)_updateTierLamp {
    if (!_sessionActive) {
        _tierLamp.label.text = @"BCAST idle";
        [_tierLamp setDotColor:UIColor.grayColor];
        return;
    }
    if (!_uploader) {
        _tierLamp.label.text = @"BCAST off";
        [_tierLamp setDotColor:UIColor.grayColor];
        return;
    }
    ESBroadcastTier effective = MAX(_thermalTier, _networkTier);
    NSString *tier = (effective == ESBroadcastTierFull) ? @"1080p"
                   : (effective == ESBroadcastTierReduced) ? @"720p" : @"off";
    // Name the governor holding the stream below full. Heat wins a tie, since
    // the network verdict cannot lift it.
    NSString *source = @"";
    if (effective != ESBroadcastTierFull) {
        source = (_thermalTier >= _networkTier) ? @" therm" : @" net";
    }
    _tierLamp.label.text = [NSString stringWithFormat:@"BCAST %@%@", tier, source];
    UIColor *color = (effective == ESBroadcastTierFull) ? UIColor.systemGreenColor
                   : (effective == ESBroadcastTierReduced) ? UIColor.systemYellowColor : UIColor.systemRedColor;
    [_tierLamp setDotColor:color];
}

- (void)_updateIdleLamps {
    [self _updateTierLamp];
    _recLamp.label.text = @"REC idle";
    [_recLamp setDotColor:UIColor.grayColor];
    _liveLamp.label.text = @"LIVE off";
    [_liveLamp setDotColor:UIColor.grayColor];
    [self _updateThermLampForState:_governor.thermalState];
    [self _updateDockLamp];
    _zoomLabel.text = @"1.0x";
}

- (void)_updateThermLampForState:(NSProcessInfoThermalState)state {
    _thermLamp.label.text = [NSString stringWithFormat:@"THERM %@",
                             [ESThermalGovernor nameForThermalState:state]];
    UIColor *color;
    switch (state) {
        case NSProcessInfoThermalStateNominal: color = UIColor.systemGreenColor; break;
        case NSProcessInfoThermalStateFair: color = UIColor.systemYellowColor; break;
        case NSProcessInfoThermalStateSerious: color = UIColor.systemOrangeColor; break;
        case NSProcessInfoThermalStateCritical: color = UIColor.systemRedColor; break;
        default: color = UIColor.grayColor; break;
    }
    [_thermLamp setDotColor:color];
}

- (void)_showMessage:(NSString *)message {
    _messageLabel.text = message;
    _messageLabel.hidden = (message.length == 0);
    // The pill is sized to the text, so a new message needs a new frame.
    [self.view setNeedsLayout];
    [self _appendLog:message];
}

- (NSString *)_batteryDescription {
    UIDevice *device = UIDevice.currentDevice;
    float level = device.batteryLevel;
    NSString *state;
    switch (device.batteryState) {
        case UIDeviceBatteryStateCharging: state = @"charging"; break;
        case UIDeviceBatteryStateFull: state = @"full"; break;
        case UIDeviceBatteryStateUnplugged: state = @"unplugged"; break;
        default: state = @"unknown"; break;
    }
    if (level < 0) return state;
    return [NSString stringWithFormat:@"%.0f%% %@", level * 100.0, state];
}

// One instrument line: everything a soak test needs to profile drain and heat.
- (void)_logInstrumentStatus {
    NSTimeInterval elapsed = _recordStartDate ? -[_recordStartDate timeIntervalSinceNow] : 0;
    long long size = [self _fileSizeAtURL:_archiveURL];
    NSTimeInterval ackAge = _uploader ? _uploader.secondsSinceLastAck : -1;
    NSString *line = [NSString stringWithFormat:
        @"STAT rec %02d:%02d:%02d file %.2f GB ack %@ ratio %.2f tier %@ therm %@ batt %@ dock %@ radio %@ zoom %.1fx cam [%@] mic %@ dropped %llu queued %lu uploaded %llu",
        (int)elapsed / 3600, ((int)elapsed % 3600) / 60, (int)elapsed % 60,
        size / 1e9,
        (ackAge < 0) ? @"none" : [NSString stringWithFormat:@"%.0fs", ackAge],
        _uploader ? _uploader.lastMediaUploadRatio : 0,
        _appliedTierValid ? [ESThermalGovernor nameForTier:_appliedTier] : @"n/a",
        [ESThermalGovernor nameForThermalState:_governor.thermalState],
        [self _batteryDescription],
        _dockBridge.statusDescription,
        [self _radioTechnology],
        _engine.zoomFactor,
        _engine.cameraModeDescription,
        _engine.microphonePatternDescription,
        _engine.droppedVideoFrameCount,
        (unsigned long)(_uploader ? _uploader.queuedCount : 0),
        _uploader ? _uploader.uploadedCount : 0];
    [self _appendLog:line];
}

- (NSString *)_radioTechnology {
    static CTTelephonyNetworkInfo *info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ info = [[CTTelephonyNetworkInfo alloc] init]; });
    NSString *tech = info.serviceCurrentRadioAccessTechnology.allValues.firstObject;
    if (!tech) return @"none";
    return [tech stringByReplacingOccurrencesOfString:@"CTRadioAccessTechnology" withString:@""];
}

- (void)_appendLog:(NSString *)message {
    NSLog(@"[main] %@", message);
    // Instrument record: append to a log file reachable from the Files app.
    static NSDateFormatter *timeFormatter;
    static dispatch_queue_t logQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeFormatter = [[NSDateFormatter alloc] init];
        timeFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        timeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        logQueue = dispatch_queue_create("es.main.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                      [timeFormatter stringFromDate:[NSDate date]], message];
    NSURL *logURL = [[ESSettings documentsURL] URLByAppendingPathComponent:@"ESCapture-log.txt"];
    dispatch_async(logQueue, ^{
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
        if (!handle) {
            [NSFileManager.defaultManager createFileAtPath:logURL.path contents:nil attributes:nil];
            handle = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
        }
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

- (void)_showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Files and storage

- (NSURL *)_newArchiveURL {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *name = [NSString stringWithFormat:@"ESCapture-%@.mov",
                      [formatter stringFromDate:[NSDate date]]];
    return [[ESSettings documentsURL] URLByAppendingPathComponent:name];
}

- (long long)_fileSizeAtURL:(NSURL *)url {
    if (!url) return 0;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    return attrs ? [attrs fileSize] : 0;
}

- (long long)_availableCapacity {
    NSError *error = nil;
    NSDictionary *values = [[ESSettings documentsURL]
        resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:&error];
    NSNumber *capacity = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
    return capacity ? capacity.longLongValue : -1;
}

- (CGFloat)_interfaceRotationAngle {
    UIInterfaceOrientation orientation = self.view.window.windowScene.effectiveGeometry.interfaceOrientation;
    return (orientation == UIInterfaceOrientationLandscapeLeft) ? 180.0 : 0.0;
}

@end
