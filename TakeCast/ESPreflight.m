//
//  ESPreflight.m
//  TakeCast
//

#import "ESPreflight.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import "ESSettings.h"
#import "ESThermalGovernor.h"
#import "TakeCast-Swift.h" // ESDockKitBridge

// The Live screen refuses REC below this, so Setup calls it Not ready.
static const long long ESPreflightMinimumFreeBytes = 25LL * 1000 * 1000 * 1000;
// 4K HEVC at 40 Mbps plus audio comes to roughly 18 GB an hour.
static const double ESPreflightBytesPerHour = 18e9;
static const double ESPreflightComfortHours = 3.0;

@interface ESPreflightCheck ()
@property (nonatomic, readwrite) NSString *title;
@property (nonatomic, readwrite) ESPreflightStatus status;
@property (nonatomic, readwrite) NSString *detail;
@property (nonatomic, readwrite) ESPreflightAction action;
@end

@implementation ESPreflightCheck

+ (instancetype)checkWithTitle:(NSString *)title status:(ESPreflightStatus)status
                        detail:(NSString *)detail action:(ESPreflightAction)action {
    ESPreflightCheck *check = [[ESPreflightCheck alloc] init];
    check.title = title;
    check.status = status;
    check.detail = detail;
    check.action = action;
    return check;
}

+ (instancetype)checkWithTitle:(NSString *)title status:(ESPreflightStatus)status detail:(NSString *)detail {
    return [self checkWithTitle:title status:status detail:detail action:ESPreflightActionNone];
}

+ (NSString *)nameForStatus:(ESPreflightStatus)status {
    switch (status) {
        case ESPreflightStatusReady: return @"Ready";
        case ESPreflightStatusWarning: return @"Warning";
        case ESPreflightStatusNotReady: return @"Not ready";
    }
    return @"";
}

@end

@implementation ESPreflight {
    __weak ESThermalGovernor *_governor;
    __weak ESDockKitBridge *_dockBridge;
    nw_path_monitor_t _pathMonitor;
    nw_path_status_t _pathStatus;
    BOOL _pathKnown;
    BOOL _pathWiFi;
    BOOL _pathCellular;
    BOOL _pathWired;
    NSArray<id<NSObject>> *_observers;
}

- (instancetype)initWithThermalGovernor:(ESThermalGovernor *)governor dockBridge:(ESDockKitBridge *)dockBridge {
    self = [super init];
    if (self) {
        _governor = governor;
        _dockBridge = dockBridge;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (_pathMonitor) return;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;

    __weak typeof(self) weakSelf = self;
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_pathKnown = YES;
        strongSelf->_pathStatus = nw_path_get_status(path);
        strongSelf->_pathWiFi = nw_path_uses_interface_type(path, nw_interface_type_wifi);
        strongSelf->_pathCellular = nw_path_uses_interface_type(path, nw_interface_type_cellular);
        strongSelf->_pathWired = nw_path_uses_interface_type(path, nw_interface_type_wired);
        [strongSelf _notify];
    });
    nw_path_monitor_start(_pathMonitor);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    void (^changed)(NSNotification *) = ^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf _notify]; });
    };
    _observers = @[
        [center addObserverForName:UIDeviceBatteryLevelDidChangeNotification object:nil queue:nil usingBlock:changed],
        [center addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:nil usingBlock:changed],
        [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:changed],
        [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:changed],
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:changed],
    ];
}

- (void)stop {
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
    for (id<NSObject> observer in _observers) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
    _observers = nil;
}

- (void)_notify {
    if (self.changeHandler) self.changeHandler();
}

- (NSArray<ESPreflightCheck *> *)currentChecks {
    return @[
        [self _permissionCheck],
        [self _storageCheck],
        [self _powerCheck],
        [self _thermalCheck],
        [self _microphoneCheck],
        [self _gimbalCheck],
        [self _networkCheck],
        [self _destinationCheck],
    ];
}

#pragma mark Checks

- (ESPreflightCheck *)_permissionCheck {
    NSString *title = @"Camera and microphone";
    AVAuthorizationStatus video = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    AVAuthorizationStatus audio = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (video == AVAuthorizationStatusDenied || video == AVAuthorizationStatusRestricted) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusNotReady
                                         detail:@"Camera access is off. Turn it on in Settings."
                                         action:ESPreflightActionOpenSettings];
    }
    if (video == AVAuthorizationStatusNotDetermined || audio == AVAuthorizationStatusNotDetermined) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                         detail:@"Not asked yet. Allow access now so REC starts without a prompt."
                                         action:ESPreflightActionRequestCapturePermission];
    }
    if (audio == AVAuthorizationStatusDenied || audio == AVAuthorizationStatusRestricted) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                         detail:@"Microphone access is off: video will record without sound."
                                         action:ESPreflightActionOpenSettings];
    }
    return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady detail:@"Access granted"];
}

+ (long long)availableCapacity {
    NSDictionary *values = [[ESSettings documentsURL]
        resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil];
    NSNumber *capacity = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
    return capacity ? capacity.longLongValue : -1;
}

- (ESPreflightCheck *)_storageCheck {
    NSString *title = @"Storage";
    long long free = [ESPreflight availableCapacity];
    if (free < 0) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                         detail:@"Free space unknown"];
    }
    double hours = free / ESPreflightBytesPerHour;
    NSString *detail = [NSString stringWithFormat:@"%.1f GB free, about %.1f h of 4K", free / 1e9, hours];
    if (free < ESPreflightMinimumFreeBytes) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusNotReady
                                         detail:[detail stringByAppendingString:@". REC needs at least 25 GB free."]];
    }
    if (hours < ESPreflightComfortHours) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                         detail:[detail stringByAppendingString:@". Free space for a long event."]];
    }
    return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady detail:detail];
}

- (ESPreflightCheck *)_powerCheck {
    NSString *title = @"Power";
    UIDevice *device = UIDevice.currentDevice;
    float level = device.batteryLevel;
    NSString *percent = level >= 0 ? [NSString stringWithFormat:@"%.0f%%", level * 100.0] : @"level unknown";
    switch (device.batteryState) {
        case UIDeviceBatteryStateCharging:
        case UIDeviceBatteryStateFull:
            return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                             detail:[NSString stringWithFormat:@"Plugged in, %@", percent]];
        case UIDeviceBatteryStateUnplugged:
            if (level >= 0.5) {
                return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                                 detail:[NSString stringWithFormat:@"On battery, %@. Plug in for anything longer than a short talk.", percent]];
            }
            return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusNotReady
                                             detail:[NSString stringWithFormat:@"On battery, %@. 4K recording and streaming drain it fast: plug in.", percent]];
        default:
            return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                             detail:@"Battery state unknown"];
    }
}

- (ESPreflightCheck *)_thermalCheck {
    NSString *title = @"Temperature";
    NSProcessInfoThermalState state = _governor ? _governor.thermalState : NSProcessInfo.processInfo.thermalState;
    NSString *name = [ESThermalGovernor nameForThermalState:state];
    switch (state) {
        case NSProcessInfoThermalStateNominal:
            return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady detail:@"Normal"];
        case NSProcessInfoThermalStateFair:
            return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                             detail:@"Warm. Keep the phone out of the sun and dim the screen."];
        default:
            return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusNotReady
                                             detail:[NSString stringWithFormat:@"%@: the stream will be lowered or stopped. Let the phone cool down.", name]];
    }
}

- (ESPreflightCheck *)_microphoneCheck {
    NSString *title = @"Microphone";
    AVAudioSession *session = AVAudioSession.sharedInstance;
    AVAudioSessionPortDescription *input = session.currentRoute.inputs.firstObject;
    if (!input) {
        // Before the session is set up for recording the current route may
        // carry no input; the built-in mic is what REC will use.
        for (AVAudioSessionPortDescription *port in session.availableInputs) {
            if (![port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) { input = port; break; }
        }
    }
    if (!input || [input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                         detail:[NSString stringWithFormat:@"Built-in microphone, %@",
                                                 ESSettings.directionalMicrophone ? @"aimed with the lens (CARD)" : @"whole room (OMNI)"]];
    }
    return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                     detail:[NSString stringWithFormat:@"External: %@", input.portName]];
}

- (ESPreflightCheck *)_gimbalCheck {
    NSString *title = @"Gimbal";
    ESDockKitBridge *bridge = _dockBridge;
    if (!bridge.docked) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                         detail:@"No gimbal (not needed)"];
    }
    NSString *name = bridge.accessoryName.length > 0 ? bridge.accessoryName : @"DockKit gimbal";
    if (bridge.batteryLow) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning
                                         detail:[NSString stringWithFormat:@"%@ docked, battery low", name]];
    }
    NSString *battery = bridge.batteryLevel >= 0
        ? [NSString stringWithFormat:@", battery %.0f%%", bridge.batteryLevel * 100.0] : @"";
    return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                     detail:[NSString stringWithFormat:@"%@ docked%@", name, battery]];
}

- (ESPreflightCheck *)_networkCheck {
    NSString *title = @"Network";
    BOOL streaming = ESSettings.effectiveIngestURL.length > 0;
    if (!_pathKnown) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusWarning detail:@"Checking..."];
    }
    if (_pathStatus != nw_path_status_satisfied) {
        return streaming
            ? [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusNotReady
                                        detail:@"No connection. The recording works, but nothing will stream."]
            : [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                        detail:@"No connection (not needed to record only)"];
    }
    if (_pathWiFi) {
        // An associated Wi-Fi wins over cellular even when it is the weaker of
        // the two, and iOS will not step back on its own.
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                         detail:streaming ? @"Wi-Fi. If venue Wi-Fi is weak, turn it off to stream over cellular."
                                                          : @"Wi-Fi"];
    }
    if (_pathCellular) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady detail:@"Cellular"];
    }
    return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                     detail:_pathWired ? @"Wired" : @"Connected"];
}

- (ESPreflightCheck *)_destinationCheck {
    NSString *title = @"Stream destination";
    if (ESSettings.effectiveIngestURL.length == 0) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                         detail:@"Record only, no stream"];
    }
    NSString *host = ESSettings.ingestHost;
    if (!host) {
        return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusNotReady
                                         detail:@"URL not understood. You can still record; the stream will be off."];
    }
    return [ESPreflightCheck checkWithTitle:title status:ESPreflightStatusReady
                                     detail:[NSString stringWithFormat:@"Stream: %@", host]];
}

@end
