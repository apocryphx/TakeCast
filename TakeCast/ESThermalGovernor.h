//
//  ESThermalGovernor.h
//  TakeCast
//
//  Watches the system thermal state and steps the broadcast ladder:
//  nominal or fair keeps 1080p at 6 Mbps, serious drops to 720p at 3 Mbps,
//  critical stops the broadcast. The archive path never degrades.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ESBroadcastTier) {
    ESBroadcastTierFull,     // 1080p at 6 Mbps
    ESBroadcastTierReduced,  // 720p at 3 Mbps
    ESBroadcastTierOff,      // archive only
};

@class ESThermalGovernor;

@protocol ESThermalGovernorDelegate <NSObject>
// Called on the main queue.
- (void)thermalGovernor:(ESThermalGovernor *)governor
          didChangeTier:(ESBroadcastTier)tier
           thermalState:(NSProcessInfoThermalState)state;
@end

@interface ESThermalGovernor : NSObject

@property (nonatomic, weak, nullable) id<ESThermalGovernorDelegate> delegate;
@property (nonatomic, readonly) ESBroadcastTier currentTier;
@property (nonatomic, readonly) NSProcessInfoThermalState thermalState;

- (void)startObserving;
- (void)stopObserving;

+ (NSString *)nameForThermalState:(NSProcessInfoThermalState)state;
+ (NSString *)nameForTier:(ESBroadcastTier)tier;

@end

NS_ASSUME_NONNULL_END
