#import "ScreenCapturer.h"

@interface ScreenCapturer ()

@property (nonatomic, assign) uint32_t windowID;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, assign) BOOL isStopping;

// handlers
@property (nonatomic, copy, nonnull) void (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

@end


@implementation ScreenCapturer

- (instancetype)initWithWindowID:(uint32_t)windowID
                   frameHandler:(void (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler {
    if (self = [super init]) {
        _windowID = windowID;
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
    }
    return self;
}

- (void)startCapture {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) {
            self.errorHandler(error);
            return;
        }
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        // set max frame rate to 60 FPS
        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.pixelFormat = kCVPixelFormatType_32BGRA;

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
                NSError *noWindowError = [NSError errorWithDomain:@"ScreenCapturerErrorDomain"
                                                            code:2
                                                        userInfo:@{NSLocalizedDescriptionKey : @"Window not available for capture"}];
                self.errorHandler(noWindowError);
                return;
            }
            config.width = selectedWindow.frame.size.width;
            config.height = selectedWindow.frame.size.height;
            if ([SCContentFilter instancesRespondToSelector:@selector(initWithDesktopIndependentWindow:)]) {
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selectedWindow];
            } else {
                filter = [[SCContentFilter alloc] initWithWindow:selectedWindow excludingWindows:@[]];
            }
        }
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

        NSError *addOutputError = nil;
        [self.stream addStreamOutput:self
                                type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:dispatch_queue_create("libvncserver.examples.mac", NULL)
                               error:&addOutputError];
        if (addOutputError) {
            self.errorHandler(addOutputError);
            return;
        }

        [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
            if (startError) {
                self.errorHandler(startError);
            }
        }];
    }];
}

- (void)stopCapture {
    if (!self.stream || self.isStopping) {
        return;
    }
    self.isStopping = YES;
    
    NSError *removeError = nil;
    [self.stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&removeError];
    if (removeError) {
        NSLog(@"Warning: removeStreamOutput error: %@", removeError);
    }
    
    SCStream *stream = [self.stream retain];
    self.stream = nil;
    
    [stream stopCaptureWithCompletionHandler:^(NSError * _Nullable stopError) {
        if (stopError) {
            NSLog(@"Stop capture error: %@", stopError);
        }
        [stream release];
    }];
}

- (void)dealloc {
    [self stopCapture];
    /* Handlers will be released when the property is deallocated */
    [super dealloc];
}


/*
  SCStreamDelegate methods
*/

- (void) stream:(SCStream *) stream didStopWithError:(NSError *) error {
    if (error && error.code != 0) {
        self.errorHandler(error);
    }
}


/*
  SCStreamOutput methods
*/

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeScreen && !self.isStopping) {
        self.frameHandler(sampleBuffer);
    }
}

@end
