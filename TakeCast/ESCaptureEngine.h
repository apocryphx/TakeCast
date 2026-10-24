//
//  ESCaptureEngine.h
//  TakeCast
//
//  Owns the AVCaptureSession. Locks the rear wide camera to 3840x2160 at a
//  user selected 24 or 30 fps and delivers raw sample buffers to its delegate.
//  Timestamps pass through untouched; there is a single session clock.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ESCaptureEngine;

@protocol ESCaptureEngineDelegate <NSObject>
// Called on the capture queues. Retain the buffer if it is kept past the call.
- (void)captureEngine:(ESCaptureEngine *)engine didOutputVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)captureEngine:(ESCaptureEngine *)engine didOutputAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@optional
// Called on the main queue.
- (void)captureEngine:(ESCaptureEngine *)engine audioRouteDidChange:(NSString *)routeName isExternal:(BOOL)isExternal;
- (void)captureEngine:(ESCaptureEngine *)engine didFailWithError:(NSError *)error;
// Called on the main queue. While interrupted the session delivers no buffers
// at all: the archive takes a hole rather than a failure, and nothing else in
// the app would otherwise notice. reason is nil when the interruption ends.
- (void)captureEngine:(ESCaptureEngine *)engine
    didChangeInterruption:(BOOL)interrupted
                   reason:(nullable NSString *)reason;
@end

@interface ESCaptureEngine : NSObject

@property (nonatomic, weak, nullable) id<ESCaptureEngineDelegate> delegate;
@property (nonatomic, readonly) AVCaptureSession *session;
@property (nonatomic, readonly) NSInteger frameRate;
@property (nonatomic, readonly) CGFloat zoomFactor;
@property (nonatomic, readonly) CGFloat upscaleThreshold;
@property (nonatomic, readonly) CGFloat minZoomFactor;
@property (nonatomic, readonly) CGFloat maxZoomFactor;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, getter=isLocked) BOOL locked;
// Focus, exposure, and white balance as the camera currently reports them.
@property (nonatomic, readonly) NSString *cameraModeDescription;
@property (nonatomic, readonly, nullable) NSString *currentAudioRouteName;
// The built-in mic data source and polar pattern actually in force, or the
// route name when the audio is coming from somewhere other than the built-in mic.
@property (nonatomic, readonly) NSString *microphonePatternDescription;
// Directional capture on the built-in mic. YES aims a cardioid at whatever the
// lens is pointed at, NO takes the whole room. Settable live; ignored while an
// external mic is routed. Defaults to YES.
@property (nonatomic, getter=isDirectionalMicrophonePreferred) BOOL directionalMicrophonePreferred;
@property (nonatomic, readonly) BOOL audioRouteIsExternal;
@property (nonatomic, readonly, getter=isInterrupted) BOOL interrupted;
@property (nonatomic, readonly) uint64_t droppedVideoFrameCount;

// Configure the session for 4K at 24 or 30 fps. Call while stopped.
- (BOOL)configureWithFrameRate:(NSInteger)frameRate error:(NSError **)error;

- (void)startRunning;
- (void)stopRunning;

// Zoom, usable live. Ramped moves use a slow on-air rate near 0.75x per second.
- (void)setZoomFactor:(CGFloat)factor ramped:(BOOL)ramped;

// Ceremony locks: exposure, white balance, and focus all locked or all continuous.
- (void)lockExposureWhiteBalanceAndFocus;
- (void)unlockExposureWhiteBalanceAndFocus;

@end

NS_ASSUME_NONNULL_END
