//
//  ESThermalGovernor.m
//  TakeCast
//

#import "ESThermalGovernor.h"

@implementation ESThermalGovernor {
    BOOL _observing;
    ESBroadcastTier _currentTier;
    NSProcessInfoThermalState _thermalState;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _thermalState = NSProcessInfo.processInfo.thermalState;
        _currentTier = [ESThermalGovernor _tierForThermalState:_thermalState];
    }
    return self;
}

- (void)dealloc {
    [self stopObserving];
}

- (void)startObserving {
    if (_observing) return;
    _observing = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_thermalStateChanged:)
                                                 name:NSProcessInfoThermalStateDidChangeNotification
                                               object:nil];
    // Evaluate the current state immediately so a hot start is not missed.
    [self _applyThermalState:NSProcessInfo.processInfo.thermalState force:YES];
}

- (void)stopObserving {
    if (!_observing) return;
    _observing = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSProcessInfoThermalStateDidChangeNotification
                                                  object:nil];
}

- (void)_thermalStateChanged:(NSNotification *)note {
    [self _applyThermalState:NSProcessInfo.processInfo.thermalState force:NO];
}

- (void)_applyThermalState:(NSProcessInfoThermalState)state force:(BOOL)force {
    dispatch_async(dispatch_get_main_queue(), ^{
        ESBroadcastTier tier = [ESThermalGovernor _tierForThermalState:state];
        BOOL changed = (tier != self->_currentTier) || (state != self->_thermalState);
        self->_thermalState = state;
        if (!changed && !force) return;
        ESBroadcastTier previous = self->_currentTier;
        self->_currentTier = tier;
        NSLog(@"[governor] thermal %@ tier %@ (was %@)",
              [ESThermalGovernor nameForThermalState:state],
              [ESThermalGovernor nameForTier:tier],
              [ESThermalGovernor nameForTier:previous]);
        [self.delegate thermalGovernor:self didChangeTier:tier thermalState:state];
    });
}

+ (ESBroadcastTier)_tierForThermalState:(NSProcessInfoThermalState)state {
    switch (state) {
        case NSProcessInfoThermalStateNominal:
        case NSProcessInfoThermalStateFair:
            return ESBroadcastTierFull;
        case NSProcessInfoThermalStateSerious:
            return ESBroadcastTierReduced;
        case NSProcessInfoThermalStateCritical:
            return ESBroadcastTierOff;
    }
    return ESBroadcastTierFull;
}

+ (NSString *)nameForThermalState:(NSProcessInfoThermalState)state {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

+ (NSString *)nameForTier:(ESBroadcastTier)tier {
    switch (tier) {
        case ESBroadcastTierFull: return @"1080p6M";
        case ESBroadcastTierReduced: return @"720p3M";
        case ESBroadcastTierOff: return @"off";
    }
    return @"unknown";
}

@end
