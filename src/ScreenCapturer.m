#import "ScreenCapturer.h"

@interface ScreenCapturer ()

@property (nonatomic, assign) uint32_t windowID;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, assign) BOOL isStopping;
@property (nonatomic, assign) BOOL exitOnStreamFailure;

// handlers
@property (nonatomic, copy, nonnull) void (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

// Frame monitoring and health tracking
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, assign) uint64_t frameCount;
@property (nonatomic, assign) uint32_t restartCount;
@property (nonatomic, assign) uint32_t consecutiveRestartFailures;
@property (nonatomic, assign) NSTimeInterval frameTimeoutSeconds;
@property (nonatomic, strong) NSTimer *watchdogTimer;
@property (nonatomic, strong) NSTimer *metricsTimer;
@property (nonatomic, assign) BOOL isHealthy;
@property (nonatomic, assign) BOOL isRestarting;
@property (nonatomic, assign) NSTimeInterval lastRestartAttemptTime;
@property (nonatomic, assign) uint64_t lastMetricsFrameCount;
@property (nonatomic, assign) NSTimeInterval lastMetricsTime;

@end


@implementation ScreenCapturer

- (instancetype)initWithWindowID:(uint32_t)windowID
                   frameHandler:(void (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler
             exitOnStreamFailure:(BOOL)exitOnStreamFailure {
    if (self = [super init]) {
        _windowID = windowID;
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
        _exitOnStreamFailure = exitOnStreamFailure;
        
        // Initialize frame monitoring
        _frameCount = 0;
        _restartCount = 0;
        _consecutiveRestartFailures = 0;
        _frameTimeoutSeconds = 10.0; // 10 second timeout
        _lastFrameTime = 0;
        _isHealthy = NO; // Will become healthy once frames start flowing
        _isStopping = NO;
        _isRestarting = NO;
        _lastRestartAttemptTime = 0;
        _lastMetricsFrameCount = 0;
        _lastMetricsTime = 0;
        
        NSLog(@"[ScreenCapturer] Initialized for window ID: %u, frame timeout: %.1f seconds, exitOnStreamFailure: %d", 
              windowID, _frameTimeoutSeconds, exitOnStreamFailure);
    }
    return self;
}

- (void)startCapture {
    NSLog(@"[ScreenCapturer] Starting capture for window ID: %u", self.windowID);
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) {
            NSLog(@"[ScreenCapturer] ERROR: Failed to get shareable content: %@", error);
            self.errorHandler(error);
            return;
        }
        
        NSLog(@"[ScreenCapturer] Got shareable content, found %lu windows", (unsigned long)content.windows.count);
        
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        // set max frame rate to 60 FPS
        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        
        NSLog(@"[ScreenCapturer] Stream configuration: minFrameInterval=%lld/%d (%.1f fps), pixelFormat=%u",
              config.minimumFrameInterval.value, config.minimumFrameInterval.timescale,
              (double)config.minimumFrameInterval.timescale / (double)config.minimumFrameInterval.value,
              (unsigned int)config.pixelFormat);

        SCContentFilter *filter = nil;
        {
            SCWindow *selectedWindow = nil;
            for (SCWindow *w in content.windows) {
                if (w.windowID == self.windowID) {
                    selectedWindow = w;
                    break;
                }
            }
            if (!selectedWindow) {
                NSLog(@"[ScreenCapturer] ERROR: Window %u not found in shareable content", self.windowID);
                NSError *noWindowError = [NSError errorWithDomain:@"ScreenCapturerErrorDomain"
                                                            code:2
                                                        userInfo:@{NSLocalizedDescriptionKey : @"Window not available for capture"}];
                self.errorHandler(noWindowError);
                return;
            }
            
            NSLog(@"[ScreenCapturer] Found target window: %.0fx%.0f at (%.0f, %.0f), onScreen=%d, layer=%ld", 
                  selectedWindow.frame.size.width, selectedWindow.frame.size.height,
                  selectedWindow.frame.origin.x, selectedWindow.frame.origin.y,
                  selectedWindow.isOnScreen ? 1 : 0,
                  (long)selectedWindow.windowLayer);
            
            config.width = selectedWindow.frame.size.width;
            config.height = selectedWindow.frame.size.height;
            
            NSLog(@"[ScreenCapturer] Configured capture resolution: %.0fx%.0f", 
                  config.width, config.height);
            if ([SCContentFilter instancesRespondToSelector:@selector(initWithDesktopIndependentWindow:)]) {
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selectedWindow];
                NSLog(@"[ScreenCapturer] Using desktop-independent window filter");
            } else {
                filter = [[SCContentFilter alloc] initWithWindow:selectedWindow excludingWindows:@[]];
                NSLog(@"[ScreenCapturer] Using standard window filter");
            }
        }
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

        NSError *addOutputError = nil;
        [self.stream addStreamOutput:self
                                type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:dispatch_queue_create("libvncserver.examples.mac", NULL)
                               error:&addOutputError];
        if (addOutputError) {
            NSLog(@"[ScreenCapturer] ERROR: Failed to add stream output: %@", addOutputError);
            self.errorHandler(addOutputError);
            return;
        }
        
        NSLog(@"[ScreenCapturer] Added stream output, starting capture...");

        [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
            if (startError) {
                NSLog(@"[ScreenCapturer] ERROR: Failed to start capture: %@", startError);
                self.errorHandler(startError);
            } else {
                NSLog(@"[ScreenCapturer] Capture started successfully");
                self.lastFrameTime = [[NSDate date] timeIntervalSince1970];
                self.isHealthy = YES;
                
                // Start watchdog timer on main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self startWatchdogTimer];
                    [self startMetricsTimer];
                });
            }
        }];
    }];
}

- (void)stopCapture {
    if (!self.stream || self.isStopping) {
        NSLog(@"[ScreenCapturer] stopCapture called but already stopping or no stream");
        return;
    }
    
    NSLog(@"[ScreenCapturer] Stopping capture (frames captured: %llu, restarts: %u)", 
          self.frameCount, self.restartCount);
    
    self.isStopping = YES;
    self.isHealthy = NO;
    
    // Stop timers on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopWatchdogTimer];
        [self stopMetricsTimer];
    });
    
    NSError *removeError = nil;
    [self.stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&removeError];
    if (removeError) {
        NSLog(@"[ScreenCapturer] WARNING: removeStreamOutput error: %@", removeError);
    }
    
    SCStream *stream = [self.stream retain];
    self.stream = nil;
    
    [stream stopCaptureWithCompletionHandler:^(NSError * _Nullable stopError) {
        if (stopError) {
            NSLog(@"[ScreenCapturer] ERROR: Stop capture error: %@", stopError);
        } else {
            NSLog(@"[ScreenCapturer] Capture stopped successfully");
        }
        [stream release];
    }];
}

- (void)dealloc {
    [self stopCapture];
    /* Handlers will be released when the property is deallocated */
    [super dealloc];
}

#pragma mark - Restart Logic

- (void)restartCapture {
    if (self.isRestarting) {
        NSLog(@"[ScreenCapturer] Restart already in progress, skipping");
        return;
    }
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeSinceLastRestart = now - self.lastRestartAttemptTime;
    
    // Exponential backoff: 2^consecutiveFailures seconds, max 60 seconds
    NSTimeInterval minBackoff = MIN(pow(2.0, (double)self.consecutiveRestartFailures), 60.0);
    if (timeSinceLastRestart < minBackoff) {
        NSLog(@"[ScreenCapturer] Restart backoff in effect (%.1fs since last attempt, need %.1fs)", 
              timeSinceLastRestart, minBackoff);
        return;
    }
    
    // Max 10 restart attempts
    if (self.restartCount >= 10) {
        NSLog(@"[ScreenCapturer] CRITICAL: Max restart attempts (%u) reached, giving up", self.restartCount);
        self.isHealthy = NO;
        NSError *maxRestartsError = [NSError errorWithDomain:@"ScreenCapturerErrorDomain"
                                                        code:3
                                                    userInfo:@{NSLocalizedDescriptionKey : @"Max restart attempts reached"}];
        self.errorHandler(maxRestartsError);
        return;
    }
    
    self.isRestarting = YES;
    self.lastRestartAttemptTime = now;
    self.restartCount++;
    
    NSLog(@"[ScreenCapturer] Attempting restart #%u (consecutive failures: %u)", 
          self.restartCount, self.consecutiveRestartFailures);
    
    // Stop current capture
    BOOL wasStoppingBefore = self.isStopping;
    self.isStopping = NO; // Temporarily reset to allow stopCapture to proceed
    
    if (self.stream) {
        NSLog(@"[ScreenCapturer] Stopping existing stream before restart");
        [self stopCapture];
    }
    
    self.isStopping = wasStoppingBefore;
    
    // Wait a moment for ScreenCaptureKit to release resources
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[ScreenCapturer] Starting capture after restart delay");
        self.isRestarting = NO;
        [self startCapture];
    });
}

- (void)logDiagnosticState {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeSinceLastFrame = now - self.lastFrameTime;
    
    NSLog(@"[ScreenCapturer] ==================== DIAGNOSTIC STATE ====================");
    NSLog(@"[ScreenCapturer] Health Status:");
    NSLog(@"[ScreenCapturer]   isHealthy: %d", self.isHealthy);
    NSLog(@"[ScreenCapturer]   isStopping: %d", self.isStopping);
    NSLog(@"[ScreenCapturer]   isRestarting: %d", self.isRestarting);
    NSLog(@"[ScreenCapturer] Frame Statistics:");
    NSLog(@"[ScreenCapturer]   Total frames: %llu", self.frameCount);
    NSLog(@"[ScreenCapturer]   Time since last frame: %.2f seconds", timeSinceLastFrame);
    NSLog(@"[ScreenCapturer]   Last frame timestamp: %.3f", self.lastFrameTime);
    NSLog(@"[ScreenCapturer] Restart Statistics:");
    NSLog(@"[ScreenCapturer]   Total restarts: %u", self.restartCount);
    NSLog(@"[ScreenCapturer]   Consecutive failures: %u", self.consecutiveRestartFailures);
    NSLog(@"[ScreenCapturer] Stream State:");
    NSLog(@"[ScreenCapturer]   Stream object: %@", self.stream ? @"EXISTS" : @"NULL");
    NSLog(@"[ScreenCapturer]   Watchdog timer: %@", self.watchdogTimer ? @"ACTIVE" : @"INACTIVE");
    NSLog(@"[ScreenCapturer]   Metrics timer: %@", self.metricsTimer ? @"ACTIVE" : @"INACTIVE");
    NSLog(@"[ScreenCapturer] Window Info:");
    NSLog(@"[ScreenCapturer]   Target window ID: %u", self.windowID);
    NSLog(@"[ScreenCapturer] ==========================================================");
}

#pragma mark - Watchdog Timer

- (void)startWatchdogTimer {
    [self stopWatchdogTimer];
    
    NSLog(@"[ScreenCapturer] Starting watchdog timer (checking every %.1f seconds)", 
          self.frameTimeoutSeconds);
    
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:self.frameTimeoutSeconds
                                                          target:self
                                                        selector:@selector(checkFrameTimeout)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)stopWatchdogTimer {
    if (self.watchdogTimer) {
        NSLog(@"[ScreenCapturer] Stopping watchdog timer");
        [self.watchdogTimer invalidate];
        self.watchdogTimer = nil;
    }
}

- (void)checkFrameTimeout {
    if (self.isStopping || self.isRestarting) {
        return;
    }
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeSinceLastFrame = now - self.lastFrameTime;
    
    if (timeSinceLastFrame > self.frameTimeoutSeconds) {
        NSLog(@"[ScreenCapturer] ALERT: Frame timeout detected! No frames for %.1f seconds (threshold: %.1f)", 
              timeSinceLastFrame, self.frameTimeoutSeconds);
        NSLog(@"[ScreenCapturer] Total frames received: %llu, restarts so far: %u", 
              self.frameCount, self.restartCount);
        
        self.isHealthy = NO;
        self.consecutiveRestartFailures++;
        
        // Attempt automatic restart
        [self restartCapture];
    }
}

#pragma mark - Metrics Timer

- (void)startMetricsTimer {
    [self stopMetricsTimer];
    
    NSLog(@"[ScreenCapturer] Starting metrics timer (logging every 60 seconds)");
    
    self.lastMetricsTime = [[NSDate date] timeIntervalSince1970];
    self.lastMetricsFrameCount = self.frameCount;
    
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                         target:self
                                                       selector:@selector(logMetrics)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopMetricsTimer {
    if (self.metricsTimer) {
        NSLog(@"[ScreenCapturer] Stopping metrics timer");
        [self.metricsTimer invalidate];
        self.metricsTimer = nil;
    }
}

- (void)logMetrics {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval elapsed = now - self.lastMetricsTime;
    uint64_t framesDelta = self.frameCount - self.lastMetricsFrameCount;
    
    double avgFps = elapsed > 0 ? (double)framesDelta / elapsed : 0.0;
    NSTimeInterval timeSinceLastFrame = now - self.lastFrameTime;
    
    NSLog(@"[ScreenCapturer] METRICS: frames=%llu, fps=%.1f, last_frame=%.1fs ago, restarts=%u, healthy=%d", 
          self.frameCount, avgFps, timeSinceLastFrame, self.restartCount, self.isHealthy);
    
    self.lastMetricsTime = now;
    self.lastMetricsFrameCount = self.frameCount;
}

#pragma mark - SCStreamDelegate methods

- (void) stream:(SCStream *) stream didStopWithError:(NSError *) error {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeSinceLastFrame = now - self.lastFrameTime;
    
    NSLog(@"[ScreenCapturer] ==================== STREAM STOPPED ====================");
    NSLog(@"[ScreenCapturer] DELEGATE: stream didStopWithError called");
    NSLog(@"[ScreenCapturer] Stream state at stop: healthy=%d, frames=%llu, restarts=%u",
          self.isHealthy, self.frameCount, self.restartCount);
    NSLog(@"[ScreenCapturer] Time since last frame: %.2f seconds", timeSinceLastFrame);
    NSLog(@"[ScreenCapturer] Intentional stop: isStopping=%d, isRestarting=%d",
          self.isStopping, self.isRestarting);
    
    // Log full diagnostic state
    [self logDiagnosticState];
    
    // Check if window is still available
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError) {
            NSLog(@"[ScreenCapturer] ERROR: Failed to check window availability: %@", contentError);
        } else {
            BOOL windowFound = NO;
            SCWindow *targetWindow = nil;
            for (SCWindow *w in content.windows) {
                if (w.windowID == self.windowID) {
                    windowFound = YES;
                    targetWindow = w;
                    break;
                }
            }
            
            if (windowFound) {
                NSLog(@"[ScreenCapturer] Window %u STILL EXISTS: %.0fx%.0f, onScreen=%d, layer=%ld",
                      self.windowID,
                      targetWindow.frame.size.width, targetWindow.frame.size.height,
                      targetWindow.isOnScreen ? 1 : 0,
                      (long)targetWindow.windowLayer);
            } else {
                NSLog(@"[ScreenCapturer] Window %u NOT FOUND in shareable content (likely closed/hidden)",
                      self.windowID);
            }
            NSLog(@"[ScreenCapturer] Total available windows: %lu", (unsigned long)content.windows.count);
        }
    }];
    
    if (error && error.code != 0) {
        NSLog(@"[ScreenCapturer] ERROR DETAILS:");
        NSLog(@"[ScreenCapturer]   Domain: %@", error.domain);
        NSLog(@"[ScreenCapturer]   Code: %ld", (long)error.code);
        NSLog(@"[ScreenCapturer]   Description: %@", error.localizedDescription);
        NSLog(@"[ScreenCapturer]   Reason: %@", error.localizedFailureReason ?: @"(none)");
        NSLog(@"[ScreenCapturer]   Recovery: %@", error.localizedRecoverySuggestion ?: @"(none)");
        
        if (error.userInfo) {
            NSLog(@"[ScreenCapturer]   UserInfo: %@", error.userInfo);
        }
        
        self.isHealthy = NO;
        self.errorHandler(error);
    } else {
        NSLog(@"[ScreenCapturer] Stream stopped without error (error is nil or code 0)");
        
        // If we weren't intentionally stopping, this is a problem
        if (!self.isStopping && !self.isRestarting) {
            NSLog(@"[ScreenCapturer] WARNING: Stream stopped unexpectedly without error!");
            NSLog(@"[ScreenCapturer] This indicates a silent ScreenCaptureKit failure");
            NSLog(@"[ScreenCapturer] Possible causes: window closed, window minimized, screen lock, display sleep, permissions revoked");
            self.isHealthy = NO;
            
            if (self.exitOnStreamFailure) {
                NSLog(@"[ScreenCapturer] exitOnStreamFailure=true: Exiting process to allow watchdog recovery");
                // Exit process to allow external watchdog to restart macVNC
                exit(2);
            } else {
                NSLog(@"[ScreenCapturer] exitOnStreamFailure=false: Attempting internal restart");
                self.consecutiveRestartFailures++;
                
                // Attempt internal restart
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self restartCapture];
                });
            }
        }
    }
    NSLog(@"[ScreenCapturer] ========================================================");
}


#pragma mark - SCStreamOutput methods

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeScreen && !self.isStopping) {
        // Update frame tracking
        self.frameCount++;
        self.lastFrameTime = [[NSDate date] timeIntervalSince1970];
        
        // Mark as healthy if we were unhealthy
        if (!self.isHealthy) {
            NSLog(@"[ScreenCapturer] Capture recovered! Frames flowing again");
            self.isHealthy = YES;
            self.consecutiveRestartFailures = 0; // Reset failure counter on successful recovery
        }
        
        // Log every 300th frame (approximately every 5 seconds at 60fps)
        if (self.frameCount % 300 == 0) {
            NSLog(@"[ScreenCapturer] Frame checkpoint: %llu frames delivered", self.frameCount);
        }
        
        // Call the frame handler
        self.frameHandler(sampleBuffer);
    }
}

@end
