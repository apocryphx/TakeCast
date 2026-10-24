//
//  ESSetupViewController.m
//  TakeCast
//

#import "ESSetupViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "ESOnboardingViewController.h"
#import "ESPreflight.h"
#import "ESSettings.h"
#import "ESUI.h"

typedef NS_ENUM(NSInteger, ESSetupSection) {
    ESSetupSectionDestination,
    ESSetupSectionVideo,
    ESSetupSectionAudio,
    ESSetupSectionChecks,
    ESSetupSectionCount,
};

static NSString * const ESSetupCellID = @"cell";
static NSString * const ESSetupCheckCellID = @"check";

@interface ESSetupViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@end

@implementation ESSetupViewController {
    ESPreflight *_preflight;
    NSArray<ESPreflightCheck *> *_checks;
    UITableView *_tableView;
    UISwitch *_streamSwitch;
    UITextField *_ingestField;
    UILabel *_destinationFooter;
    UISegmentedControl *_fpsControl;
    UISegmentedControl *_codecControl;
    UISegmentedControl *_micControl;
    BOOL _showsAdvanced;
}

- (instancetype)initWithThermalGovernor:(ESThermalGovernor *)governor dockBridge:(ESDockKitBridge *)dockBridge {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _preflight = [[ESPreflight alloc] initWithThermalGovernor:governor dockBridge:dockBridge];
        // An HEVC choice made earlier stays visible rather than hiding behind the disclosure.
        _showsAdvanced = ESSettings.broadcastUsesHEVC;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Setup";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    __weak typeof(self) weakSelf = self;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:@"Help" image:nil identifier:nil
                          handler:^(UIAction *a) { [weakSelf _showHelp]; }]];

    [self _buildControls];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.cellLayoutMarginsFollowReadableWidth = YES;
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:ESSetupCellID];
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:ESSetupCheckCellID];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tableView];
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    _tableView.tableFooterView = [self _footerView];

    _checks = [_preflight currentChecks];
    _preflight.changeHandler = ^{ [weakSelf _refreshChecks]; };
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_preflight start];
    [self _refreshChecks];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_preflight stop];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

#pragma mark Controls

- (void)_buildControls {
    __weak typeof(self) weakSelf = self;

    _streamSwitch = [[UISwitch alloc] init];
    _streamSwitch.on = ESSettings.streamingEnabled;
    [_streamSwitch addAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf _streamSwitchChanged]; }]
            forControlEvents:UIControlEventValueChanged];

    _ingestField = [[UITextField alloc] init];
    _ingestField.placeholder = @"https://a.upload.youtube.com/http_upload_hls?cid=...";
    _ingestField.text = ESSettings.ingestURL;
    _ingestField.keyboardType = UIKeyboardTypeURL;
    _ingestField.autocorrectionType = UITextAutocorrectionTypeNo;
    _ingestField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _ingestField.spellCheckingType = UITextSpellCheckingTypeNo;
    _ingestField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _ingestField.returnKeyType = UIReturnKeyDone;
    // The URL carries the stream key. Hidden like a password, with an eye to
    // check a paste; outside this field only the host is ever shown.
    _ingestField.secureTextEntry = YES;
    _ingestField.delegate = self;
    [_ingestField addAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf _ingestChanged]; }]
           forControlEvents:UIControlEventEditingChanged];
    UIButton *reveal = [UIButton buttonWithType:UIButtonTypeSystem];
    [reveal setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    reveal.frame = CGRectMake(0, 0, 36, 30);
    [reveal addAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf _toggleReveal:(UIButton *)a.sender]; }]
     forControlEvents:UIControlEventTouchUpInside];
    _ingestField.rightView = reveal;
    _ingestField.rightViewMode = UITextFieldViewModeAlways;

    _fpsControl = [[UISegmentedControl alloc] initWithItems:@[@"24", @"30"]];
    _fpsControl.selectedSegmentIndex = ESSettings.frameRate == 30 ? 1 : 0;
    [_fpsControl addAction:[UIAction actionWithHandler:^(UIAction *a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        ESSettings.frameRate = strongSelf->_fpsControl.selectedSegmentIndex == 1 ? 30 : 24;
    }] forControlEvents:UIControlEventValueChanged];

    // H.264 at 6 Mbps is the proven path, HEVC at 4 Mbps saves uplink power on
    // a weak cell signal.
    _codecControl = [[UISegmentedControl alloc] initWithItems:@[@"H.264", @"HEVC"]];
    _codecControl.selectedSegmentIndex = ESSettings.broadcastUsesHEVC ? 1 : 0;
    [_codecControl addAction:[UIAction actionWithHandler:^(UIAction *a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        ESSettings.broadcastUsesHEVC = strongSelf->_codecControl.selectedSegmentIndex == 1;
    }] forControlEvents:UIControlEventValueChanged];

    _micControl = [[UISegmentedControl alloc] initWithItems:@[@"CARD", @"OMNI"]];
    _micControl.selectedSegmentIndex = ESSettings.directionalMicrophone ? 0 : 1;
    [_micControl addAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf _micChanged]; }]
          forControlEvents:UIControlEventValueChanged];

    _destinationFooter = [[UILabel alloc] init];
    _destinationFooter.numberOfLines = 0;
    _destinationFooter.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _destinationFooter.adjustsFontForContentSizeCategory = YES;
    [self _updateDestinationFooter];
}

- (UIView *)_footerView {
    __weak typeof(self) weakSelf = self;
    UIButton *start = ESPrimaryButton(@"Go to camera", [UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf _finish];
    }]);
    UILabel *note = ESBodyLabel(@"Settings can't be changed while recording.");
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[start, note]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 120)];
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
        [stack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [stack.widthAnchor constraintEqualToConstant:360],
    ]];
    return footer;
}

- (void)_streamSwitchChanged {
    ESSettings.streamingEnabled = _streamSwitch.on;
    [_tableView performBatchUpdates:^{
        NSIndexPath *fieldRow = [NSIndexPath indexPathForRow:1 inSection:ESSetupSectionDestination];
        if (self->_streamSwitch.on) {
            [self->_tableView insertRowsAtIndexPaths:@[fieldRow] withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [self->_ingestField resignFirstResponder];
            [self->_tableView deleteRowsAtIndexPaths:@[fieldRow] withRowAnimation:UITableViewRowAnimationFade];
        }
    } completion:nil];
    if (_streamSwitch.on && ESSettings.ingestURL.length == 0) [_ingestField becomeFirstResponder];
    [self _updateDestinationFooter];
    [self _refreshChecks];
}

- (void)_ingestChanged {
    ESSettings.ingestURL = _ingestField.text ?: @"";
    [self _updateDestinationFooter];
    [self _refreshChecks];
}

- (void)_toggleReveal:(UIButton *)button {
    _ingestField.secureTextEntry = !_ingestField.secureTextEntry;
    [button setImage:[UIImage systemImageNamed:_ingestField.secureTextEntry ? @"eye" : @"eye.slash"]
            forState:UIControlStateNormal];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// The route takes a moment to reconfigure; the Live screen logs what was asked
// for next to what the route reports.
- (void)_micChanged {
    BOOL directional = (_micControl.selectedSegmentIndex == 0);
    ESSettings.directionalMicrophone = directional;
    if (self.microphonePatternChanged) self.microphonePatternChanged(directional);
    [self _refreshChecks];
}

- (void)_updateDestinationFooter {
    NSString *description = ESSettings.destinationDescription;
    if (!_streamSwitch.on) {
        _destinationFooter.text = @"Record only: the 4K copy is saved on this iPhone and nothing is streamed.";
        _destinationFooter.textColor = UIColor.secondaryLabelColor;
    } else if (ESSettings.ingestURL.length == 0) {
        _destinationFooter.text = @"Paste the YouTube HLS ingest URL. It contains your stream key: "
                                  @"keep it private, like a password.";
        _destinationFooter.textColor = UIColor.systemOrangeColor;
    } else if (!ESSettings.ingestHost) {
        _destinationFooter.text = @"invalid URL. You can still record; the stream will be off.";
        _destinationFooter.textColor = UIColor.systemRedColor;
    } else {
        _destinationFooter.text = description;
        _destinationFooter.textColor = UIColor.secondaryLabelColor;
    }
}

- (void)_refreshChecks {
    _checks = [_preflight currentChecks];
    if (!_tableView) return;
    // Reload only the checks, never the destination section: that would take
    // the keyboard away from the URL field mid paste.
    [UIView performWithoutAnimation:^{
        [self->_tableView reloadSections:[NSIndexSet indexSetWithIndex:ESSetupSectionChecks]
                        withRowAnimation:UITableViewRowAnimationNone];
    }];
}

#pragma mark Actions

- (void)_finish {
    [self.view endEditing:YES];
    if (self.finished) self.finished();
}

- (void)_showHelp {
    ESOnboardingViewController *onboarding = [[ESOnboardingViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:onboarding];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) weakSelf = self;
    __weak UINavigationController *weakNav = nav;
    onboarding.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                      primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        [weakNav dismissViewControllerAnimated:YES completion:nil];
    }]];
    onboarding.completion = ^(ESOnboardingChoice choice) {
        [weakNav dismissViewControllerAnimated:YES completion:^{
            if (choice == ESOnboardingChoiceRecordOnly) [weakSelf _selectRecordOnly];
        }];
    };
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)_selectRecordOnly {
    if (!_streamSwitch.on) return;
    _streamSwitch.on = NO;
    [self _streamSwitchChanged];
}

- (void)_performAction:(ESPreflightAction)action {
    switch (action) {
        case ESPreflightActionRequestCapturePermission: {
            __weak typeof(self) weakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL video) {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL audio) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf _refreshChecks]; });
                }];
            }];
            break;
        }
        case ESPreflightActionOpenSettings:
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                                             options:@{} completionHandler:nil];
            break;
        case ESPreflightActionNone:
            break;
    }
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ESSetupSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((ESSetupSection)section) {
        case ESSetupSectionDestination: return _streamSwitch.on ? 2 : 1;
        case ESSetupSectionVideo: return _showsAdvanced ? 3 : 2;
        case ESSetupSectionAudio: return 1;
        case ESSetupSectionChecks: return (NSInteger)_checks.count;
        case ESSetupSectionCount: break;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((ESSetupSection)section) {
        case ESSetupSectionDestination: return @"Destination";
        case ESSetupSectionVideo: return @"Video";
        case ESSetupSectionAudio: return @"Audio";
        case ESSetupSectionChecks: return @"Pre-flight checks";
        case ESSetupSectionCount: break;
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section != ESSetupSectionDestination) return nil;
    UIView *container = [[UIView alloc] init];
    _destinationFooter.translatesAutoresizingMaskIntoConstraints = NO;
    [_destinationFooter removeFromSuperview];
    [container addSubview:_destinationFooter];
    [NSLayoutConstraint activateConstraints:@[
        [_destinationFooter.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [_destinationFooter.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [_destinationFooter.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor],
        [_destinationFooter.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor],
    ]];
    return container;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ((ESSetupSection)section) {
        case ESSetupSectionVideo:
            return _showsAdvanced
                ? @"The 4K recording is always HEVC. HEVC for the stream is smaller and needs less uplink power "
                  @"on a weak signal, but your YouTube setup must accept it. If unsure, keep H.264."
                : nil;
        case ESSetupSectionAudio:
            return @"CARD aims the built-in mic where the lens points. OMNI takes in the whole room. "
                   @"An external microphone is used automatically when connected.";
        case ESSetupSectionChecks:
            return @"None of these blocks recording. REC itself still refuses to start with less than 25 GB free.";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ESSetupSectionChecks) {
        return [self _checkCellForRow:indexPath.row];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ESSetupCellID forIndexPath:indexPath];
    for (UIView *view in cell.contentView.subviews) {
        if (view == _ingestField) [view removeFromSuperview];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];

    switch ((ESSetupSection)indexPath.section) {
        case ESSetupSectionDestination:
            if (indexPath.row == 0) {
                content.text = @"Stream to YouTube";
                cell.accessoryView = _streamSwitch;
            } else {
                content = nil;
                _ingestField.translatesAutoresizingMaskIntoConstraints = NO;
                [cell.contentView addSubview:_ingestField];
                UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
                [NSLayoutConstraint activateConstraints:@[
                    [_ingestField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                    [_ingestField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                    [_ingestField.topAnchor constraintEqualToAnchor:margins.topAnchor],
                    [_ingestField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
                    [_ingestField.heightAnchor constraintGreaterThanOrEqualToConstant:30],
                ]];
            }
            break;
        case ESSetupSectionVideo:
            if (indexPath.row == 0) {
                content.text = @"Frame rate";
                content.secondaryText = @"fps";
                cell.accessoryView = _fpsControl;
                [_fpsControl sizeToFit];
            } else if (indexPath.row == 1) {
                content.text = @"Advanced";
                content.textProperties.color = UIColor.tintColor;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                UIImageView *chevron = [[UIImageView alloc] initWithImage:
                    [UIImage systemImageNamed:_showsAdvanced ? @"chevron.up" : @"chevron.down"]];
                cell.accessoryView = chevron;
            } else {
                content.text = @"Stream codec";
                cell.accessoryView = _codecControl;
                [_codecControl sizeToFit];
            }
            break;
        case ESSetupSectionAudio:
            content.text = @"Microphone pattern";
            cell.accessoryView = _micControl;
            [_micControl sizeToFit];
            break;
        default:
            break;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (UITableViewCell *)_checkCellForRow:(NSInteger)row {
    UITableViewCell *cell = [_tableView dequeueReusableCellWithIdentifier:ESSetupCheckCellID];
    ESPreflightCheck *check = _checks[row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.image = [UIImage systemImageNamed:ESSymbolForPreflightStatus(check.status)];
    content.imageProperties.tintColor = ESColorForPreflightStatus(check.status);
    content.text = [NSString stringWithFormat:@"%@ · %@", check.title, [ESPreflightCheck nameForStatus:check.status]];
    content.secondaryText = check.detail;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    if (check.status == ESPreflightStatusNotReady) {
        // A Not ready must not read like the rest of the list.
        content.textProperties.color = UIColor.systemRedColor;
        content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    }
    cell.contentConfiguration = content;
    cell.backgroundConfiguration = nil;
    if (check.status == ESPreflightStatusNotReady) {
        UIBackgroundConfiguration *background = [UIBackgroundConfiguration listCellConfiguration];
        background.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.12];
        cell.backgroundConfiguration = background;
    }
    if (check.action != ESPreflightActionNone) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        UILabel *actionLabel = [[UILabel alloc] init];
        actionLabel.text = check.action == ESPreflightActionOpenSettings ? @"Open Settings" : @"Allow";
        actionLabel.textColor = UIColor.tintColor;
        actionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [actionLabel sizeToFit];
        cell.accessoryView = actionLabel;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ESSetupSectionVideo) return indexPath.row == 1;
    if (indexPath.section == ESSetupSectionChecks) return _checks[indexPath.row].action != ESPreflightActionNone;
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == ESSetupSectionVideo && indexPath.row == 1) {
        _showsAdvanced = !_showsAdvanced;
        NSIndexPath *codecRow = [NSIndexPath indexPathForRow:2 inSection:ESSetupSectionVideo];
        [tableView performBatchUpdates:^{
            if (self->_showsAdvanced) {
                [tableView insertRowsAtIndexPaths:@[codecRow] withRowAnimation:UITableViewRowAnimationFade];
            } else {
                [tableView deleteRowsAtIndexPaths:@[codecRow] withRowAnimation:UITableViewRowAnimationFade];
            }
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        } completion:^(BOOL finished) {
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:ESSetupSectionVideo]
                     withRowAnimation:UITableViewRowAnimationNone];
        }];
    } else if (indexPath.section == ESSetupSectionChecks) {
        [self _performAction:_checks[indexPath.row].action];
    }
}

@end
