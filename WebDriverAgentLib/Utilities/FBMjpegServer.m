/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMjpegServer.h"

#import <mach/mach_time.h>
@import UniformTypeIdentifiers;

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "FBImageProcessor.h"
#import "FBImageUtils.h"
#import "XCUIScreen.h"

static const NSUInteger MAX_FPS = 60;
static const NSTimeInterval FRAME_TIMEOUT = 1.;
static const NSTimeInterval FAILURE_BACKOFF_MIN = 1.0;
static const NSTimeInterval FAILURE_BACKOFF_MAX = 10.0;
// A client that does not read its socket would otherwise make every frame queue up in memory
static const NSUInteger MAX_PENDING_FRAMES_PER_CLIENT = 4;
// A client that has not read any frame for this long is considered abandoned and gets disconnected
static const NSTimeInterval STALLED_CLIENT_TIMEOUT = 60.0;
static const long STREAM_HEADER_TAG = 0;
static const long FRAME_TAG = 1;

static NSString *const SERVER_NAME = @"WDA MJPEG Server";
static const char *QUEUE_NAME = "JPEG Screenshots Provider Queue";


@interface FBMjpegServer()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) NSMapTable<GCDAsyncSocket *, NSNumber *> *pendingFrameCounts;
@property (nonatomic, readonly) NSMapTable<GCDAsyncSocket *, NSDate *> *lastFrameWriteDates;
@property (nonatomic, assign) NSUInteger droppedFramesCount;
@property (nonatomic, readonly) FBImageProcessor *imageProcessor;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) NSUInteger consecutiveScreenshotFailures;
@property (nonatomic, strong) NSTimer *firstScreenshotTimer;
@property (nonatomic, strong) NSTimer *screenshotTimer;
// Accessed from the main thread and from the sockets queue
@property (atomic, strong) NSString *firstSession;
// The last frame sent to clients. Accessed from the main thread and from the image processing queue
@property (atomic, strong, nullable) NSData *lastSentScreenshotData;
// The last captured frame before scaling and the settings it was processed with.
// Only accessed from the background queue
@property (nonatomic, strong, nullable) NSData *lastCapturedScreenshotData;
@property (nonatomic, assign) CGFloat lastScalingFactor;
@property (nonatomic, assign) BOOL lastShouldFixOrientation;

@end


@implementation FBMjpegServer

- (instancetype)init
{
  if ((self = [super init])) {
    _consecutiveScreenshotFailures = 0;
    _listeningClients = [NSMutableArray array];
    _pendingFrameCounts = [NSMapTable strongToStrongObjectsMapTable];
    _lastFrameWriteDates = [NSMapTable strongToStrongObjectsMapTable];
    _droppedFramesCount = 0;
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    dispatch_async(_backgroundQueue, ^{
      [self streamScreenshot];
    });
    _imageProcessor = [[FBImageProcessor alloc] init];
    _mainScreenID = [XCUIScreen.mainScreen displayID];

    self.firstScreenshotTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                           target:self
                                                         selector:@selector(sendFirstScreenshot)
                                                         userInfo:nil
                                                          repeats:YES];

    self.screenshotTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
                                                           target:self
                                                         selector:@selector(sendPeriodicScreenshot)
                                                         userInfo:nil
                                                          repeats:YES];
    self.firstSession = @"";
  }
  return self;
}

- (void)sendFirstScreenshot
{
  NSData *screenshotData = self.lastSentScreenshotData;
  // Keep waiting for the first frame if nothing has been captured yet
  if (nil == screenshotData || [self.firstSession isEqualToString:@""]) {
    return;
  }
  [self sendScreenshot:screenshotData];
  self.firstSession = @"";
}

- (void)sendPeriodicScreenshot
{
  NSData *screenshotData = self.lastSentScreenshotData;
  if (nil == screenshotData) {
    return;
  }
  [self sendScreenshot:screenshotData];
}

- (void)dealloc
{
  [self.firstScreenshotTimer invalidate];
  [self.screenshotTimer invalidate];
}

- (void)scheduleNextScreenshotWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  uint64_t timeElapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t nextTickDelta = timerInterval - timeElapsed;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  } else {
    // Try to do our best to keep the FPS at a decent level
    dispatch_async(self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  }
}

- (void)streamScreenshot
{
  NSUInteger framerate = FBConfiguration.mjpegServerFramerate;
  uint64_t timerInterval = (uint64_t)(1.0 / ((0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate) * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
      return;
    }
  }

  NSError *error;
  CGFloat compressionQuality = MAX(FBMinCompressionQuality,
                                   MIN(FBMaxCompressionQuality, FBConfiguration.mjpegServerScreenshotQuality / 100.0));
  NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                           compressionQuality:compressionQuality
                                                                          uti:UTTypeJPEG
                                                                      timeout:FRAME_TIMEOUT
                                                                        error:&error];
  if (nil == screenshotData) {
    [FBLogger logFmt:@"%@", error.description];
    self.consecutiveScreenshotFailures++;
    NSTimeInterval backoffSeconds = MIN(FAILURE_BACKOFF_MAX,
                                        FAILURE_BACKOFF_MIN * (1 << MIN(self.consecutiveScreenshotFailures, 4)));
    uint64_t backoffInterval = (uint64_t)(backoffSeconds * NSEC_PER_SEC);
    [self scheduleNextScreenshotWithInterval:backoffInterval timeStarted:timeStarted];
    return;
  }

  self.consecutiveScreenshotFailures = 0;

  CGFloat scalingFactor = FBConfiguration.mjpegScalingFactor / 100.0;
  BOOL shouldFixOrientation = FBConfiguration.mjpegShouldFixOrientation;
  // Compare with the previous captured frame rather than with the sent one,
  // because the latter differs from the captured data if it has been scaled or rotated
  NSData *lastCapturedScreenshotData = self.lastCapturedScreenshotData;
  if (nil != lastCapturedScreenshotData
      && [screenshotData isEqualToData:lastCapturedScreenshotData]
      && fabs(scalingFactor - self.lastScalingFactor) < DBL_EPSILON
      && shouldFixOrientation == self.lastShouldFixOrientation) {
    [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
    return;
  }
  self.lastCapturedScreenshotData = screenshotData;
  self.lastScalingFactor = scalingFactor;
  self.lastShouldFixOrientation = shouldFixOrientation;

  [self.imageProcessor submitImageData:screenshotData
                         scalingFactor:scalingFactor
                     completionHandler:^(NSData * _Nonnull scaled) {
    self.lastSentScreenshotData = scaled;
    [self sendScreenshot:scaled];
  }];

  [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
}

- (void)sendScreenshot:(NSData *)screenshotData {
  NSString *chunkHeader = [NSString stringWithFormat:@"--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: %@\r\n\r\n", @(screenshotData.length)];
  NSMutableData *chunk = [[chunkHeader dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [chunk appendData:screenshotData];
  [chunk appendData:(id)[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  NSMutableArray<GCDAsyncSocket *> *stalledClients = [NSMutableArray array];
  @synchronized (self.listeningClients) {
    for (GCDAsyncSocket *client in self.listeningClients) {
      NSUInteger pendingFrames = [self.pendingFrameCounts objectForKey:client].unsignedIntegerValue;
      if (pendingFrames >= MAX_PENDING_FRAMES_PER_CLIENT) {
        self.droppedFramesCount++;
        NSDate *lastFrameWriteDate = [self.lastFrameWriteDates objectForKey:client];
        if (nil != lastFrameWriteDate && -[lastFrameWriteDate timeIntervalSinceNow] >= STALLED_CLIENT_TIMEOUT) {
          [stalledClients addObject:client];
        }
        continue;
      }
      [self.pendingFrameCounts setObject:@(pendingFrames + 1) forKey:client];
      [client writeData:chunk withTimeout:-1 tag:FRAME_TAG];
    }
  }
  // Disconnecting outside of the lock, the socket queue may be waiting for it
  for (GCDAsyncSocket *client in stalledClients) {
    [FBLogger logFmt:@"Disconnecting the screenshots broadcast client at %@:%d, it has not read any frame for %.0f seconds (%@ frames dropped in total)",
     client.connectedHost, client.connectedPort, STALLED_CLIENT_TIMEOUT, @(self.droppedFramesCount)];
    [client disconnect];
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"Got screenshots broadcast client connection at %@:%d", newClient.connectedHost, newClient.connectedPort];
  // Start broadcast only after there is any data from the client
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      return;
    }
  }

  [FBLogger logFmt:@"Starting screenshots broadcast for the client at %@:%d", client.connectedHost, client.connectedPort];
  NSString *streamHeader = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\nMax-Age: 0\r\nExpires: 0\r\nCache-Control: no-cache, private\r\nPragma: no-cache\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n", SERVER_NAME];
  [client writeData:(id)[streamHeader dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:STREAM_HEADER_TAG];
  @synchronized (self.listeningClients) {
    [self.listeningClients addObject:client];
    [self.lastFrameWriteDates setObject:[NSDate date] forKey:client];
  }
  // Ask for the last frame to be resent, so the new client does not wait for the screen to change
  self.firstSession = [client description];
}

- (void)didClientWriteData:(GCDAsyncSocket *)client withTag:(long)tag
{
  if (FRAME_TAG != tag) {
    return;
  }
  @synchronized (self.listeningClients) {
    if (![self.listeningClients containsObject:client]) {
      return;
    }
    NSUInteger pendingFrames = [self.pendingFrameCounts objectForKey:client].unsignedIntegerValue;
    if (pendingFrames > 1) {
      [self.pendingFrameCounts setObject:@(pendingFrames - 1) forKey:client];
    } else {
      [self.pendingFrameCounts removeObjectForKey:client];
    }
    [self.lastFrameWriteDates setObject:[NSDate date] forKey:client];
  }
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
    [self.pendingFrameCounts removeObjectForKey:client];
    [self.lastFrameWriteDates removeObjectForKey:client];
  }
  [FBLogger log:@"Disconnected a client from screenshots broadcast"];
}

@end
