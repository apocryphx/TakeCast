//
//  ESRecordingsViewController.m
//  TakeCast
//

#import "ESRecordingsViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import "ESPreflight.h"
#import "ESSettings.h"
#import "ESUI.h"

static NSString * const ESRecordingCellID = @"recording";

#pragma mark - Row model

@interface ESRecording : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic) NSString *name;
@property (nonatomic, nullable) NSDate *startDate;
@property (nonatomic) long long size;
@property (nonatomic) BOOL stoppedEarly;
@property (nonatomic) BOOL finalizing;
@end

@implementation ESRecording
@end

#pragma mark - Cell

@interface ESRecordingCell : UITableViewCell
@property (nonatomic, readonly) UIImageView *thumbnail;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UILabel *detailLabel;
@property (nonatomic, readonly) UILabel *badge;
@property (nonatomic, readonly) UIButton *shareButton;
@property (nonatomic, copy, nullable) NSString *recordingName;
@end

@implementation ESRecordingCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _thumbnail = [[UIImageView alloc] init];
        _thumbnail.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnail.clipsToBounds = YES;
        _thumbnail.layer.cornerRadius = 6;
        _thumbnail.backgroundColor = UIColor.tertiarySystemFillColor;
        _thumbnail.tintColor = UIColor.secondaryLabelColor;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.adjustsFontForContentSizeCategory = YES;

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:
                             [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].pointSize
                                                             weight:UIFontWeightRegular];
        _detailLabel.textColor = UIColor.secondaryLabelColor;

        _badge = [[UILabel alloc] init];
        _badge.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _badge.layer.cornerRadius = 5;
        _badge.clipsToBounds = YES;
        _badge.textAlignment = NSTextAlignmentCenter;

        UIButtonConfiguration *config = [UIButtonConfiguration borderlessButtonConfiguration];
        config.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        _shareButton = [UIButton buttonWithConfiguration:config primaryAction:nil];
        _shareButton.accessibilityLabel = @"Share";

        UIStackView *badgeRow = [[UIStackView alloc] initWithArrangedSubviews:@[_badge, [[UIView alloc] init]]];
        badgeRow.axis = UILayoutConstraintAxisHorizontal;
        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel, badgeRow]];
        text.axis = UILayoutConstraintAxisVertical;
        text.spacing = 3;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_thumbnail, text, _shareButton]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 14;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:row];

        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_thumbnail.widthAnchor constraintEqualToConstant:112],
            [_thumbnail.heightAnchor constraintEqualToConstant:63],
            [_badge.heightAnchor constraintEqualToConstant:20],
            [row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];
    }
    return self;
}

- (void)setBadgeText:(NSString *)text color:(UIColor *)color {
    _badge.text = [NSString stringWithFormat:@"  %@  ", text];
    _badge.textColor = color;
    _badge.backgroundColor = [color colorWithAlphaComponent:0.16];
}

@end

#pragma mark - Recordings

@interface ESRecordingsViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation ESRecordingsViewController {
    UITableView *_tableView;
    UILabel *_spaceLabel;
    NSArray<ESRecording *> *_recordings;
    NSCache<NSString *, UIImage *> *_thumbnails;
    NSMutableDictionary<NSString *, NSNumber *> *_durations; // seconds, NaN when unreadable
    NSMutableSet<NSString *> *_loading;
    NSDateFormatter *_nameParser;
    NSDateFormatter *_displayFormatter;
    UIBarButtonItem *_shareSelectedItem;
    UIBarButtonItem *_deleteSelectedItem;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recordings";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    _thumbnails = [[NSCache alloc] init];
    _durations = [NSMutableDictionary dictionary];
    _loading = [NSMutableSet set];
    _nameParser = [[NSDateFormatter alloc] init];
    _nameParser.dateFormat = @"yyyyMMdd-HHmmss";
    _nameParser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    _displayFormatter = [[NSDateFormatter alloc] init];
    _displayFormatter.dateStyle = NSDateFormatterMediumStyle;
    _displayFormatter.timeStyle = NSDateFormatterShortStyle;

    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                      primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    self.navigationItem.rightBarButtonItem = self.editButtonItem;

    _shareSelectedItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:@"Share" image:nil identifier:nil
                          handler:^(UIAction *a) { [weakSelf _shareSelected]; }]];
    _deleteSelectedItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:@"Delete" image:nil identifier:nil
                          handler:^(UIAction *a) { [weakSelf _deleteSelected]; }]];
    _deleteSelectedItem.tintColor = UIColor.systemRedColor;
    self.toolbarItems = @[_shareSelectedItem,
                          [UIBarButtonItem flexibleSpaceItem],
                          _deleteSelectedItem];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.allowsMultipleSelectionDuringEditing = YES;
    _tableView.cellLayoutMarginsFollowReadableWidth = YES;
    [_tableView registerClass:ESRecordingCell.class forCellReuseIdentifier:ESRecordingCellID];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tableView];
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    _spaceLabel = [[UILabel alloc] init];
    _spaceLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _spaceLabel.textColor = UIColor.secondaryLabelColor;
    _spaceLabel.textAlignment = NSTextAlignmentCenter;
    _spaceLabel.frame = CGRectMake(0, 0, 320, 36);
    _tableView.tableHeaderView = _spaceLabel;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_reload)
                                               name:ESRecordingFinalizedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_reload)
                                               name:UIApplicationWillEnterForegroundNotification object:nil];
    [self _reload];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [_tableView setEditing:editing animated:animated];
    [self.navigationController setToolbarHidden:!editing animated:animated];
    [self _updateSelectionActions];
}

#pragma mark Data

- (void)_reload {
    NSString *inProgress = [ESSettings inProgressRecordingName];
    NSMutableArray<ESRecording *> *recordings = [NSMutableArray array];
    long long used = 0;
    for (NSURL *url in [ESSettings recordingURLs]) {
        ESRecording *recording = [[ESRecording alloc] init];
        recording.url = url;
        recording.name = url.lastPathComponent;
        NSString *stamp = [[recording.name stringByDeletingPathExtension]
                           stringByReplacingOccurrencesOfString:@"ESCapture-" withString:@""];
        recording.startDate = [_nameParser dateFromString:stamp];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
        recording.size = attrs ? (long long)attrs.fileSize : 0;
        recording.stoppedEarly = [ESSettings recordingWasStoppedEarly:recording.name];
        recording.finalizing = [recording.name isEqualToString:inProgress];
        used += recording.size;
        [recordings addObject:recording];
    }
    _recordings = recordings;

    long long free = [ESPreflight availableCapacity];
    _spaceLabel.text = free >= 0
        ? [NSString stringWithFormat:@"Recordings use %.1f GB · %.1f GB free on this iPhone", used / 1e9, free / 1e9]
        : [NSString stringWithFormat:@"Recordings use %.1f GB", used / 1e9];

    if (recordings.count == 0) {
        UILabel *empty = ESBodyLabel([NSString stringWithFormat:
            @"No recordings yet.\n\nAfter your first session, each recording appears here in full 4K quality. "
            @"Share it to Photos, Files, AirDrop or another app."]);
        empty.textAlignment = NSTextAlignmentCenter;
        UIView *background = [[UIView alloc] init];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [background addSubview:empty];
        [NSLayoutConstraint activateConstraints:@[
            [empty.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
            [empty.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
            [empty.widthAnchor constraintLessThanOrEqualToConstant:420],
            [empty.leadingAnchor constraintGreaterThanOrEqualToAnchor:background.leadingAnchor constant:24],
        ]];
        _tableView.backgroundView = background;
        if (self.isEditing) [self setEditing:NO animated:NO];
    } else {
        _tableView.backgroundView = nil;
    }
    self.editButtonItem.enabled = recordings.count > 0;
    [_tableView reloadData];
    [self _updateSelectionActions];
}

- (NSString *)_detailForRecording:(ESRecording *)recording {
    NSString *size = recording.size >= 1e9
        ? [NSString stringWithFormat:@"%.2f GB", recording.size / 1e9]
        : [NSString stringWithFormat:@"%.0f MB", recording.size / 1e6];
    NSNumber *duration = _durations[recording.name];
    NSString *length;
    if (!duration) {
        length = @"--:--";
    } else if (isnan(duration.doubleValue) || duration.doubleValue <= 0) {
        // A file cut short can lack the index that states its length.
        length = @"length unknown";
    } else {
        long total = lround(duration.doubleValue);
        length = total >= 3600
            ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total % 3600) / 60, total % 60]
            : [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
    }
    return [NSString stringWithFormat:@"%@ · %@", length, size];
}

// Duration and thumbnail are read off the main queue, once per file.
- (void)_loadDetailsForRecording:(ESRecording *)recording {
    NSString *name = recording.name;
    if (recording.finalizing || [_loading containsObject:name]) return;
    if (_durations[name] && [_thumbnails objectForKey:name]) return;
    [_loading addObject:name];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:recording.url options:nil];
    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
        NSError *error = nil;
        double seconds = NAN;
        if ([asset statusOfValueForKey:@"duration" error:&error] == AVKeyValueStatusLoaded) {
            seconds = CMTimeGetSeconds(asset.duration);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_durations[name] = @(seconds);
            [strongSelf _refreshCellForName:name];
        });
    }];

    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(320, 180);
    generator.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
    generator.requestedTimeToleranceAfter = kCMTimePositiveInfinity;
    [generator generateCGImageAsynchronouslyForTime:CMTimeMakeWithSeconds(1, 600)
                                  completionHandler:^(CGImageRef image, CMTime actual, NSError *error) {
        UIImage *thumbnail = image ? [UIImage imageWithCGImage:image] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_loading removeObject:name];
            if (thumbnail) [strongSelf->_thumbnails setObject:thumbnail forKey:name];
            [strongSelf _refreshCellForName:name];
        });
    }];
}

- (void)_refreshCellForName:(NSString *)name {
    for (ESRecordingCell *cell in _tableView.visibleCells) {
        if (![cell.recordingName isEqualToString:name]) continue;
        NSIndexPath *path = [_tableView indexPathForCell:cell];
        if (path) [self _configureCell:cell withRecording:_recordings[path.row]];
    }
}

#pragma mark Actions

- (void)_play:(ESRecording *)recording {
    AVPlayerViewController *player = [[AVPlayerViewController alloc] init];
    player.player = [AVPlayer playerWithURL:recording.url];
    player.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:player animated:YES completion:^{
        [player.player play];
    }];
}

// The files are handed over in place. The share sheet's own Save Video covers
// Photos, so the app never needs the photo library permission.
- (void)_shareRecordings:(NSArray<ESRecording *> *)recordings from:(id)source {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (ESRecording *recording in recordings) {
        if (!recording.finalizing) [urls addObject:recording.url];
    }
    if (urls.count == 0) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:urls
                                                                        applicationActivities:nil];
    if ([source isKindOfClass:UIBarButtonItem.class]) {
        sheet.popoverPresentationController.barButtonItem = source;
    } else if ([source isKindOfClass:UIView.class]) {
        sheet.popoverPresentationController.sourceView = source;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)_confirmDelete:(NSArray<ESRecording *> *)recordings {
    NSMutableArray<ESRecording *> *deletable = [NSMutableArray array];
    long long bytes = 0;
    for (ESRecording *recording in recordings) {
        if (recording.finalizing) continue;
        [deletable addObject:recording];
        bytes += recording.size;
    }
    if (deletable.count == 0) return;
    NSString *title = deletable.count == 1
        ? @"Delete this recording?"
        : [NSString stringWithFormat:@"Delete %lu recordings?", (unsigned long)deletable.count];
    NSString *message = [NSString stringWithFormat:
        @"This frees %.1f GB and cannot be undone. Copies already shared to Photos or elsewhere are not affected.",
        bytes / 1e9];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        for (ESRecording *recording in deletable) {
            // Re-check at the moment of deletion: never the file being written.
            if ([recording.name isEqualToString:[ESSettings inProgressRecordingName]]) continue;
            if ([NSFileManager.defaultManager removeItemAtURL:recording.url error:nil]) {
                [ESSettings forgetRecording:recording.name];
            }
        }
        [weakSelf _reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray<ESRecording *> *)_selectedRecordings {
    NSMutableArray<ESRecording *> *selected = [NSMutableArray array];
    for (NSIndexPath *path in _tableView.indexPathsForSelectedRows) {
        [selected addObject:_recordings[path.row]];
    }
    return selected;
}

- (void)_shareSelected {
    [self _shareRecordings:[self _selectedRecordings] from:_shareSelectedItem];
}

- (void)_deleteSelected {
    [self _confirmDelete:[self _selectedRecordings]];
}

- (void)_updateSelectionActions {
    BOOL any = _tableView.indexPathsForSelectedRows.count > 0;
    _shareSelectedItem.enabled = any;
    _deleteSelectedItem.enabled = any;
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_recordings.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (_recordings.count == 0) return nil;
    for (ESRecording *recording in _recordings) {
        if (recording.stoppedEarly) {
            return @"Stopped early: the session did not end with STOP (the app was closed, the battery ran out "
                   @"or the phone restarted). The file still plays up to its last few seconds.";
        }
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ESRecordingCell *cell = [tableView dequeueReusableCellWithIdentifier:ESRecordingCellID forIndexPath:indexPath];
    [self _configureCell:cell withRecording:_recordings[indexPath.row]];
    return cell;
}

- (void)_configureCell:(ESRecordingCell *)cell withRecording:(ESRecording *)recording {
    cell.recordingName = recording.name;
    cell.titleLabel.text = recording.startDate ? [_displayFormatter stringFromDate:recording.startDate] : recording.name;
    cell.detailLabel.text = [self _detailForRecording:recording];
    UIImage *thumbnail = [_thumbnails objectForKey:recording.name];
    cell.thumbnail.image = thumbnail ?: [UIImage systemImageNamed:@"film"];
    cell.thumbnail.contentMode = thumbnail ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;

    if (recording.finalizing) {
        [cell setBadgeText:@"Saving..." color:UIColor.systemBlueColor];
    } else if (recording.stoppedEarly) {
        [cell setBadgeText:@"Stopped early" color:UIColor.systemOrangeColor];
    } else {
        [cell setBadgeText:@"Complete" color:UIColor.systemGreenColor];
    }

    cell.shareButton.enabled = !recording.finalizing;
    // Same identifier, so a reused cell swaps its action instead of stacking a second one.
    __weak typeof(self) weakSelf = self;
    __weak ESRecordingCell *weakCell = cell;
    [cell.shareButton addAction:[UIAction actionWithTitle:@"Share" image:nil identifier:@"share" handler:^(UIAction *a) {
        [weakSelf _shareRecordings:@[recording] from:weakCell.shareButton];
    }] forControlEvents:UIControlEventTouchUpInside];

    [self _loadDetailsForRecording:recording];
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return !_recordings[indexPath.row].finalizing;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self _updateSelectionActions];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self _play:_recordings[indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self _updateSelectionActions];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    ESRecording *recording = _recordings[indexPath.row];
    if (recording.finalizing) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
                          handler:^(UIContextualAction *action, UIView *source, void (^done)(BOOL)) {
        [weakSelf _confirmDelete:@[recording]];
        done(NO);
    }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    UIContextualAction *share = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal title:@"Share"
                          handler:^(UIContextualAction *action, UIView *source, void (^done)(BOOL)) {
        [weakSelf _shareRecordings:@[recording] from:source];
        done(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = UIColor.systemBlueColor;
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[delete, share]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

@end
