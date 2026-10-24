//
//  ESCaptureEngine.m
//  TakeCast
//

#import "ESCaptureEngine.h"
#import <UIKit/UIKit.h>

static const CGFloat ESZoomRampRate = 0.75; // zoom factors per second, slow on-air move
static const CGFloat ESZoomUIMin = 1.0;
static const CGFloat ESZoomUIMax = 2.0;

@interface ESCaptureEngine () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@end

@implementation ESCaptureEngine {
    AVCaptureSession *_session;
    AVCaptureDevice *_camera;
    AVCaptureDeviceInput *_cameraInput;
    AVCaptureDeviceInput *_audioInput;
    AVCaptureVideoDataOutput *_videoOutput;
    AVCaptureAudioDataOutput *_audioOutput;
    dispatch_queue_t _videoQueue;
    dispatch_queue_t _audioQueue;
    dispatch_queue_t _sessionQueue;
    NSInteger _frameRate;
    BOOL _configured;
    BOOL _locked;
    uint64_t _droppedVideoFrameCount;
    NSString *_currentAudioRouteName;
    BOOL _audioRouteIsExternal;
    BOOL _interrupted;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = [[AVCaptureSession alloc] init];
        // We own the audio session. Left to itself the capture session picks a
        // mic data source and polar pattern to suit the rear camera without
        // ever saying which, and overwrites anything we choose.
        _session.automaticallyConfiguresApplicationAudioSession = NO;
        _directionalMicrophonePreferred = YES;
        // High QoS so system work (TLS handshakes, uploads) cannot starve
        // frame delivery. Default QoS capture queues drop frames under load.
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _videoQueue = dispatch_queue_create("es.capture.video", attr);
        _audioQueue = dispatch_queue_create("es.capture.audio", attr);
        // startRunning and stopRunning block for camera hardware spin-up;
        // they must never run on the main thread.
        dispatch_queue_attr_t sessionAttr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _sessionQueue = dispatch_queue_create("es.capture.session", sessionAttr);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_audioRouteChanged:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_audioSessionInterrupted:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sessionRuntimeError:)
                                                     name:AVCaptureSessionRuntimeErrorNotification
                                                   object:_session];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sessionWasInterrupted:)
                                                     name:AVCaptureSessionWasInterruptedNotification
                                                   object:_session];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sessionInterruptionEnded:)
                                                     name:AVCaptureSessionInterruptionEndedNotification
                                                   object:_session];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Configuration

- (BOOL)configureWithFrameRate:(NSInteger)frameRate error:(NSError **)error {
    NSAssert(!_session.isRunning, @"configure must be called while stopped");
    NSAssert(frameRate == 24 || frameRate == 30, @"frame rate must be 24 or 30");
    _frameRate = frameRate;

    [self _configureAudioSession];

    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                 mediaType:AVMediaTypeVideo
                                                                  position:AVCaptureDevicePositionBack];
    if (!camera) {
        if (error) *error = [NSError errorWithDomain:@"ESCapture" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"No rear wide camera available"}];
        return NO;
    }

    AVCaptureDeviceFormat *format = [self _formatFor4KOnDevice:camera frameRate:frameRate];
    if (!format) {
        if (error) *error = [NSError errorWithDomain:@"ESCapture" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"No 3840x2160 format supports the selected frame rate"}];
        return NO;
    }

    [_session beginConfiguration];
    _session.sessionPreset = AVCaptureSessionPresetInputPriority;

    for (AVCaptureInput *input in [_session.inputs copy]) [_session removeInput:input];
    for (AVCaptureOutput *output in [_session.outputs copy]) [_session removeOutput:output];

    NSError *inputError = nil;
    AVCaptureDeviceInput *cameraInput = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&inputError];
    if (!cameraInput || ![_session canAddInput:cameraInput]) {
        [_session commitConfiguration];
        if (error) *error = inputError ?: [NSError errorWithDomain:@"ESCapture" code:3
                                                          userInfo:@{NSLocalizedDescriptionKey: @"Cannot add camera input"}];
        return NO;
    }
    [_session addInput:cameraInput];
    _camera = camera;
    _cameraInput = cameraInput;

    AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (mic) {
        AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:mic error:nil];
        if (audioInput && [_session canAddInput:audioInput]) {
            [_session addInput:audioInput];
            _audioInput = audioInput;
        }
    }
    if (!_audioInput) NSLog(@"[engine] warning: no audio input available");

    _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    _videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    // The archive must not lose frames. Prefer backpressure over silent discard.
    _videoOutput.alwaysDiscardsLateVideoFrames = NO;
    [_videoOutput setSampleBufferDelegate:self queue:_videoQueue];
    if (![_session canAddOutput:_videoOutput]) {
        [_session commitConfiguration];
        if (error) *error = [NSError errorWithDomain:@"ESCapture" code:4
                                            userInfo:@{NSLocalizedDescriptionKey: @"Cannot add video data output"}];
        return NO;
    }
    [_session addOutput:_videoOutput];

    _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [_audioOutput setSampleBufferDelegate:self queue:_audioQueue];
    if ([_session canAddOutput:_audioOutput]) [_session addOutput:_audioOutput];

    // Lock the device format and frame duration on the session clock.
    NSError *lockError = nil;
    if ([camera lockForConfiguration:&lockError]) {
        camera.activeFormat = format;
        CMTime frameDuration = CMTimeMake(1, (int32_t)frameRate);
        camera.activeVideoMinFrameDuration = frameDuration;
        camera.activeVideoMaxFrameDuration = frameDuration;
        camera.videoZoomFactor = ESZoomUIMin;
        // Assert the continuous modes rather than inheriting whatever the
        // device is left in. Changing activeFormat resets these, and a session
        // that started with focus locked is a ruined recording nobody notices
        // until playback.
        if ([camera isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            camera.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        }
        if ([camera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            camera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        }
        if ([camera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
            camera.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        }
        [camera unlockForConfiguration];
        // The camera is demonstrably unlocked now, so the flag must agree. It
        // used to survive a stop and start, leaving the LOCK button lit over a
        // camera that had been reset underneath it.
        _locked = NO;
    } else {
        [_session commitConfiguration];
        if (error) *error = lockError;
        return NO;
    }

    AVCaptureConnection *videoConnection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    CGFloat rotation = [self _captureRotationAngleForConnection:videoConnection];
    if ([videoConnection isVideoRotationAngleSupported:rotation]) {
        videoConnection.videoRotationAngle = rotation;
    }

    [_session commitConfiguration];
    _configured = YES;

    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    NSLog(@"[engine] configured %dx%d at %ld fps, upscale threshold %.2fx, rotation %.0f, audio route %@, %@",
          dims.width, dims.height, (long)frameRate,
          (double)format.videoZoomFactorUpscaleThreshold, (double)rotation,
          _currentAudioRouteName ?: @"none", [self cameraModeDescription]);
    [self _logAudioTopology];
    return YES;
}

- (AVCaptureDeviceFormat *)_formatFor4KOnDevice:(AVCaptureDevice *)device frameRate:(NSInteger)fps {
    AVCaptureDeviceFormat *best = nil;
    Float64 bestMaxRate = 0;
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dims.width != 3840 || dims.height != 2160) continue;
        // Stay on 8 bit 420 for a predictable SDR pipeline in v1.
        FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        if (subtype != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            subtype != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) continue;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (range.minFrameRate <= fps && fps <= range.maxFrameRate) {
                // Prefer the tightest format that covers the target rate.
                if (!best || range.maxFrameRate < bestMaxRate) {
                    best = format;
                    bestMaxRate = range.maxFrameRate;
                }
            }
        }
    }
    return best;
}

// The rear sensor's native buffer orientation matches landscape with the home
// indicator on the right. Rotate 180 when the interface is the other way up.
- (CGFloat)_captureRotationAngleForConnection:(AVCaptureConnection *)connection {
    UIInterfaceOrientation orientation = UIInterfaceOrientationLandscapeRight;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            orientation = ((UIWindowScene *)scene).effectiveGeometry.interfaceOrientation;
            break;
        }
    }
    return (orientation == UIInterfaceOrientationLandscapeLeft) ? 180.0 : 0.0;
}

#pragma mark - Audio session

- (void)_configureAudioSession {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [audioSession setCategory:AVAudioSessionCategoryRecord
                         mode:AVAudioSessionModeVideoRecording
                      options:0
                        error:&err];
    if (err) NSLog(@"[engine] audio session category error: %@", err);
    [audioSession setPreferredSampleRate:48000 error:nil];
    [self _preferExternalAudioInput];
    [self _activateAudioSession];
    [self _refreshAudioRouteInfo];
}

- (void)_activateAudioSession {
    NSError *err = nil;
    if (![[AVAudioSession sharedInstance] setActive:YES error:&err]) {
        NSLog(@"[engine] audio session activate error: %@", err);
    }
    [self _applyPreferredMicrophonePattern];
}

- (void)_audioSessionInterrupted:(NSNotification *)note {
    AVAudioSessionInterruptionType type =
        [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type != AVAudioSessionInterruptionTypeEnded) return;
    // Now that the capture session no longer configures the audio session for
    // us, nothing else brings it back after a call or Siri. Left alone, audio
    // simply stops arriving and the recording keeps rolling in silence.
    NSLog(@"[engine] audio session interruption ended, reactivating");
    [self _activateAudioSession];
    [self _refreshAudioRouteInfo];
}

- (void)_preferExternalAudioInput {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    AVAudioSessionPortDescription *usbPort = nil;
    for (AVAudioSessionPortDescription *port in audioSession.availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortUSBAudio]) {
            usbPort = port;
            break;
        }
    }
    NSError *err = nil;
    [audioSession setPreferredInput:usbPort error:&err];
    if (err) NSLog(@"[engine] setPreferredInput error: %@", err);
}

// Every mic the session can see, every data source on it, and the polar
// patterns that source offers. This is what the capture session used to decide
// for us without saying so; logging it makes the pattern we now choose, and the
// hardware that has to honour it, auditable from the instrument log alone.
- (void)_logAudioTopology {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSMutableSet<NSString *> *activeUIDs = [NSMutableSet set];
    for (AVAudioSessionPortDescription *input in audioSession.currentRoute.inputs) {
        [activeUIDs addObject:input.UID];
    }
    for (AVAudioSessionPortDescription *port in audioSession.availableInputs) {
        NSLog(@"[audio] port %@ type %@%@", port.portName, port.portType,
              [activeUIDs containsObject:port.UID] ? @" ACTIVE" : @"");
        for (AVAudioSessionDataSourceDescription *source in port.dataSources) {
            NSLog(@"[audio]   source %@ location %@ orientation %@ patterns [%@] selected %@ preferred %@%@",
                  source.dataSourceName,
                  source.location ?: @"unknown",
                  source.orientation ?: @"unknown",
                  [source.supportedPolarPatterns componentsJoinedByString:@" "] ?: @"none",
                  source.selectedPolarPattern ?: @"none",
                  source.preferredPolarPattern ?: @"none",
                  [source.dataSourceID isEqual:port.selectedDataSource.dataSourceID] ? @" SELECTED" : @"");
        }
    }
    NSLog(@"[audio] capture session configures the audio session: %d",
          _session.automaticallyConfiguresApplicationAudioSession);
    if (!_audioInput) return;
    NSLog(@"[audio] capture input stereo %d ambisonics %d mode %ld wind %d/%d zoom %d/%d",
          [_audioInput isMultichannelAudioModeSupported:AVCaptureMultichannelAudioModeStereo],
          [_audioInput isMultichannelAudioModeSupported:AVCaptureMultichannelAudioModeFirstOrderAmbisonics],
          (long)_audioInput.multichannelAudioMode,
          _audioInput.windNoiseRemovalSupported, _audioInput.windNoiseRemovalEnabled,
          _audioInput.audioZoomSupported, _audioInput.audioZoomEnabled);
}

// Point the built-in mic where the lens points. Cardioid rejects what is behind
// the phone, which during a ceremony is the audience. Subcardioid is the
// fallback on hardware that offers no true cardioid on the back source.
- (void)_applyPreferredMicrophonePattern {
    AVAudioSessionPortDescription *builtIn = nil;
    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            builtIn = port;
            break;
        }
    }
    AVAudioSessionDataSourceDescription *back = nil;
    for (AVAudioSessionDataSourceDescription *source in builtIn.dataSources) {
        if ([source.orientation isEqualToString:AVAudioSessionOrientationBack]) {
            back = source;
            break;
        }
    }
    if (!back) {
        NSLog(@"[engine] no back-facing built-in mic source; leaving the pattern alone");
        return;
    }

    NSArray<AVAudioSessionPolarPattern> *available = back.supportedPolarPatterns;
    NSString *pattern = nil;
    if (_directionalMicrophonePreferred) {
        if ([available containsObject:AVAudioSessionPolarPatternCardioid]) {
            pattern = AVAudioSessionPolarPatternCardioid;
        } else if ([available containsObject:AVAudioSessionPolarPatternSubcardioid]) {
            pattern = AVAudioSessionPolarPatternSubcardioid;
        }
    } else if ([available containsObject:AVAudioSessionPolarPatternOmnidirectional]) {
        pattern = AVAudioSessionPolarPatternOmnidirectional;
    }
    // Re-applying a preference that already holds would reconfigure the route,
    // and the route change notification lands us straight back in here.
    BOOL patternChanged = pattern && ![pattern isEqualToString:back.preferredPolarPattern];
    BOOL sourceChanged = ![back.dataSourceID isEqual:builtIn.preferredDataSource.dataSourceID];
    if (!patternChanged && !sourceChanged) return;

    NSError *err = nil;
    // Order matters: the pattern belongs to the data source, and the route only
    // picks it up once that source is made preferred on the port.
    if (patternChanged && ![back setPreferredPolarPattern:pattern error:&err]) {
        NSLog(@"[engine] setPreferredPolarPattern %@ error: %@", pattern, err);
    }
    if (sourceChanged && ![builtIn setPreferredDataSource:back error:&err]) {
        NSLog(@"[engine] setPreferredDataSource %@ error: %@", back.dataSourceName, err);
    }
}

- (void)setDirectionalMicrophonePreferred:(BOOL)preferred {
    if (_directionalMicrophonePreferred == preferred) return;
    _directionalMicrophonePreferred = preferred;
    [self _applyPreferredMicrophonePattern];
}

- (NSString *)microphonePatternDescription {
    AVAudioSessionPortDescription *input = [AVAudioSession sharedInstance].currentRoute.inputs.firstObject;
    if (!input) return @"none";
    if (![input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) return input.portName;
    AVAudioSessionDataSourceDescription *source = input.selectedDataSource;
    if (!source) return @"builtin";
    return [[NSString stringWithFormat:@"%@ %@",
             source.orientation ?: source.dataSourceName,
             source.selectedPolarPattern ?: @"default"] lowercaseString];
}

- (void)_refreshAudioRouteInfo {
    AVAudioSessionPortDescription *input = [AVAudioSession sharedInstance].currentRoute.inputs.firstObject;
    _currentAudioRouteName = input.portName;
    _audioRouteIsExternal = [input.portType isEqualToString:AVAudioSessionPortUSBAudio];
}

- (void)_audioRouteChanged:(NSNotification *)note {
    // On device arrival or departure, re-apply the USB preference, then report.
    [self _preferExternalAudioInput];
    [self _applyPreferredMicrophonePattern];
    [self _refreshAudioRouteInfo];
    NSLog(@"[engine] audio route changed: %@ external=%d", _currentAudioRouteName, _audioRouteIsExternal);
    [self _logAudioTopology];
    NSString *name = _currentAudioRouteName ?: @"none";
    BOOL external = _audioRouteIsExternal;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<ESCaptureEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(captureEngine:audioRouteDidChange:isExternal:)]) {
            [delegate captureEngine:self audioRouteDidChange:name isExternal:external];
        }
    });
}

static NSString *ESNameForInterruptionReason(AVCaptureSessionInterruptionReason reason) {
    switch (reason) {
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
            return @"app in background";
        case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
            return @"audio device taken";
        case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
            return @"camera taken";
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
            return @"multiple foreground apps";
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableDueToSystemPressure:
            return @"system pressure";
        case AVCaptureSessionInterruptionReasonSensitiveContentMitigationActivated:
            return @"sensitive content mitigation";
    }
    return [NSString stringWithFormat:@"reason %ld", (long)reason];
}

// Observation only. The session stops and restarts itself; all we do is make
// sure the hole it leaves is visible on screen and in the log, because nothing
// else in the app can tell the difference between interrupted and idle.
- (void)_sessionWasInterrupted:(NSNotification *)note {
    AVCaptureSessionInterruptionReason reason =
        (AVCaptureSessionInterruptionReason)[note.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
    NSString *name = ESNameForInterruptionReason(reason);
    _interrupted = YES;
    NSLog(@"[engine] session interrupted: %@", name);
    [self _notifyInterruption:YES reason:name];
}

- (void)_sessionInterruptionEnded:(NSNotification *)note {
    _interrupted = NO;
    NSLog(@"[engine] session interruption ended");
    [self _notifyInterruption:NO reason:nil];
}

- (void)_notifyInterruption:(BOOL)interrupted reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        id<ESCaptureEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(captureEngine:didChangeInterruption:reason:)]) {
            [delegate captureEngine:self didChangeInterruption:interrupted reason:reason];
        }
    });
}

- (void)_sessionRuntimeError:(NSNotification *)note {
    NSError *error = note.userInfo[AVCaptureSessionErrorKey];
    NSLog(@"[engine] session runtime error: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        id<ESCaptureEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(captureEngine:didFailWithError:)]) {
            [delegate captureEngine:self didFailWithError:error];
        }
    });
}

#pragma mark - Run state

- (void)startRunning {
    NSAssert(_configured, @"configure before starting");
    _droppedVideoFrameCount = 0;
    dispatch_async(_sessionQueue, ^{
        if (self->_session.isRunning) return;
        // Belt and braces alongside the interruption handler: the session is
        // ours to activate now, and a dead audio session is silent, not loud.
        [self _activateAudioSession];
        [self->_session startRunning];
        NSLog(@"[engine] session running");
    });
}

- (void)stopRunning {
    dispatch_async(_sessionQueue, ^{
        if (!self->_session.isRunning) return;
        [self->_session stopRunning];
        NSLog(@"[engine] session stopped, dropped video frames: %llu", self->_droppedVideoFrameCount);
    });
}

- (BOOL)isRunning {
    return _session.isRunning;
}

#pragma mark - Zoom

- (void)setZoomFactor:(CGFloat)factor ramped:(BOOL)ramped {
    if (!_camera) return;
    CGFloat clamped = MAX(ESZoomUIMin, MIN(ESZoomUIMax, factor));
    NSError *err = nil;
    if ([_camera lockForConfiguration:&err]) {
        if (ramped) {
            [_camera rampToVideoZoomFactor:clamped withRate:ESZoomRampRate];
        } else {
            _camera.videoZoomFactor = clamped;
        }
        [_camera unlockForConfiguration];
    } else {
        NSLog(@"[engine] zoom lock error: %@", err);
    }
}

- (CGFloat)zoomFactor {
    return _camera ? _camera.videoZoomFactor : 1.0;
}

- (CGFloat)upscaleThreshold {
    return _camera ? _camera.activeFormat.videoZoomFactorUpscaleThreshold : ESZoomUIMax;
}

- (CGFloat)minZoomFactor {
    return ESZoomUIMin;
}

- (CGFloat)maxZoomFactor {
    return ESZoomUIMax;
}

#pragma mark - Ceremony locks

- (void)lockExposureWhiteBalanceAndFocus {
    if (!_camera) return;
    NSError *err = nil;
    if ([_camera lockForConfiguration:&err]) {
        if ([_camera isExposureModeSupported:AVCaptureExposureModeLocked]) {
            _camera.exposureMode = AVCaptureExposureModeLocked;
        }
        if ([_camera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
            _camera.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
        }
        if ([_camera isFocusModeSupported:AVCaptureFocusModeLocked]) {
            _camera.focusMode = AVCaptureFocusModeLocked;
        }
        [_camera unlockForConfiguration];
        _locked = YES;
        NSLog(@"[engine] exposure, white balance, focus locked");
    } else {
        NSLog(@"[engine] lock error: %@", err);
    }
}

- (void)unlockExposureWhiteBalanceAndFocus {
    if (!_camera) return;
    NSError *err = nil;
    if ([_camera lockForConfiguration:&err]) {
        if ([_camera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            _camera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        }
        if ([_camera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
            _camera.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        }
        if ([_camera isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            _camera.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        }
        [_camera unlockForConfiguration];
        _locked = NO;
        NSLog(@"[engine] exposure, white balance, focus continuous");
    } else {
        NSLog(@"[engine] unlock error: %@", err);
    }
}

- (BOOL)isLocked {
    return _locked;
}

// What the camera actually reports, not what we believe we set. Used by the
// instrument log so a focus complaint can be read off the record instead of
// reproduced.
- (NSString *)cameraModeDescription {
    if (!_camera) return @"no camera";
    NSString *focus;
    switch (_camera.focusMode) {
        case AVCaptureFocusModeLocked: focus = @"locked"; break;
        case AVCaptureFocusModeAutoFocus: focus = @"auto once"; break;
        case AVCaptureFocusModeContinuousAutoFocus: focus = @"continuous"; break;
        default: focus = @"unknown"; break;
    }
    NSString *exposure;
    switch (_camera.exposureMode) {
        case AVCaptureExposureModeLocked: exposure = @"locked"; break;
        case AVCaptureExposureModeAutoExpose: exposure = @"auto once"; break;
        case AVCaptureExposureModeContinuousAutoExposure: exposure = @"continuous"; break;
        case AVCaptureExposureModeCustom: exposure = @"custom"; break;
        default: exposure = @"unknown"; break;
    }
    NSString *balance;
    switch (_camera.whiteBalanceMode) {
        case AVCaptureWhiteBalanceModeLocked: balance = @"locked"; break;
        case AVCaptureWhiteBalanceModeAutoWhiteBalance: balance = @"auto once"; break;
        case AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance: balance = @"continuous"; break;
        default: balance = @"unknown"; break;
    }
    return [NSString stringWithFormat:@"focus %@ exp %@ wb %@ adjusting %d",
            focus, exposure, balance, _camera.isAdjustingFocus];
}

#pragma mark - Sample buffer delegates

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<ESCaptureEngineDelegate> delegate = self.delegate;
    if (!delegate) return;
    if (output == _videoOutput) {
        [delegate captureEngine:self didOutputVideoSampleBuffer:sampleBuffer];
    } else if (output == _audioOutput) {
        [delegate captureEngine:self didOutputAudioSampleBuffer:sampleBuffer];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (output == _videoOutput) {
        _droppedVideoFrameCount++;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        NSLog(@"[engine] dropped video frame %llu at %.3f", _droppedVideoFrameCount, CMTimeGetSeconds(pts));
    }
}

@end
