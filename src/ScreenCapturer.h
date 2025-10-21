#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCapturer : NSObject <SCStreamDelegate, SCStreamOutput>

- (instancetype)initWithWindowID:(uint32_t)windowID
                   frameHandler:(nonnull void (^)(CMSampleBufferRef sampleBuffer))frameHandler
                   errorHandler:(nonnull void (^)(NSError *error))errorHandler
             exitOnStreamFailure:(BOOL)exitOnStreamFailure;

- (void)startCapture;
- (void)stopCapture;
- (void)restartCapture;
- (void)logDiagnosticState;

// Health status properties (read-only)
@property (nonatomic, readonly) NSTimeInterval lastFrameTime;
@property (nonatomic, readonly) uint64_t frameCount;
@property (nonatomic, readonly) uint32_t restartCount;
@property (nonatomic, readonly) BOOL isHealthy;

@end

NS_ASSUME_NONNULL_END
