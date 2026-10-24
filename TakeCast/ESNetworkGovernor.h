//
//  ESNetworkGovernor.h
//  TakeCast
//
//  Watches delivery performance and steps the broadcast ladder when the
//  uplink cannot sustain the current tier. Signal bars are not available
//  and would lie anyway; measured segment delivery is the truth. Steps
//  down fast, steps up slowly, never touches the archive.
//

#import <Foundation/Foundation.h>
#import "ESThermalGovernor.h"

NS_ASSUME_NONNULL_BEGIN

@class ESSegmentUploader, ESNetworkGovernor;

@protocol ESNetworkGovernorDelegate <NSObject>
// Called on the main queue.
- (void)networkGovernor:(ESNetworkGovernor *)governor
          didChangeTier:(ESBroadcastTier)tier
                 reason:(NSString *)reason;
@end

@interface ESNetworkGovernor : NSObject

@property (nonatomic, weak, nullable) id<ESNetworkGovernorDelegate> delegate;
@property (nonatomic, readonly) ESBroadcastTier currentTier;

- (instancetype)initWithUploader:(ESSegmentUploader *)uploader;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
