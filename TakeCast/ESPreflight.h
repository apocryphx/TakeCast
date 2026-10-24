//
//  ESPreflight.h
//  TakeCast
//
//  Gathers the pre-flight checks Setup shows from objects that already exist:
//  capture authorization, free space, battery, the thermal governor, the audio
//  route, the DockKit bridge, the network path and the saved destination. It
//  reads, it never configures, and no check blocks recording.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ESThermalGovernor;
@class ESDockKitBridge;

typedef NS_ENUM(NSInteger, ESPreflightStatus) {
    ESPreflightStatusReady,
    ESPreflightStatusWarning,
    ESPreflightStatusNotReady,
};

typedef NS_ENUM(NSInteger, ESPreflightAction) {
    ESPreflightActionNone,
    ESPreflightActionRequestCapturePermission,
    ESPreflightActionOpenSettings,
};

@interface ESPreflightCheck : NSObject
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) ESPreflightStatus status;
@property (nonatomic, readonly) NSString *detail;
@property (nonatomic, readonly) ESPreflightAction action;
+ (NSString *)nameForStatus:(ESPreflightStatus)status;
@end

@interface ESPreflight : NSObject

- (instancetype)initWithThermalGovernor:(nullable ESThermalGovernor *)governor
                             dockBridge:(nullable ESDockKitBridge *)dockBridge;

// Fires on the main queue when something a check reads has changed.
@property (nonatomic, copy, nullable) void (^changeHandler)(void);

- (void)start;
- (void)stop;

- (NSArray<ESPreflightCheck *> *)currentChecks;

// Free space as the archive sees it, or -1 when unknown.
+ (long long)availableCapacity;

@end

NS_ASSUME_NONNULL_END
