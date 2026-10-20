/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXCodeCompatibility.h"

#import <stdatomic.h>

#import "FBXCAXClientProxy.h"
#import "FBConfiguration.h"
#import "FBErrorBuilder.h"
#import "FBLogger.h"
#import "FBRunLoopSpinner.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElementQuery.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCTestManager_ManagerInterface-Protocol.h"

static const NSTimeInterval TESTMANAGERD_VERSION_TIMEOUT_SEC = 20.;

@implementation XCUIElementQuery (FBCompatibility)

- (id<FBXCElementSnapshot>)fb_uniqueSnapshotWithError:(NSError **)error
{
  return (id<FBXCElementSnapshot>)[self uniqueMatchingSnapshotWithError:error];
}

- (XCUIElement *)fb_firstMatch
{
  if (FBConfiguration.useFirstMatch) {
    XCUIElement* match = self.firstMatch;
    return [match exists] ? match : nil;
  }
  return self.fb_allMatches.firstObject;
}

- (NSArray<XCUIElement *> *)fb_allMatches
{
  return FBConfiguration.boundElementsByIndex
    ? self.allElementsBoundByIndex
    : self.allElementsBoundByAccessibilityElement;
}

@end


@implementation XCUIElement (FBCompatibility)

+ (BOOL)fb_supportsNonModalElementsInclusion
{
  static dispatch_once_t hasIncludingNonModalElements;
  static BOOL result;
  dispatch_once(&hasIncludingNonModalElements, ^{
    result = [XCUIApplication.fb_systemApplication.query respondsToSelector:@selector(includingNonModalElements)];
  });
  return result;
}

- (XCUIElementQuery *)fb_query
{
  return FBConfiguration.includeNonModalElements && self.class.fb_supportsNonModalElementsInclusion
    ? self.query.includingNonModalElements
    : self.query;
}

@end

@implementation XCPointerEvent (FBXcodeCompatibility)

+ (BOOL)fb_areKeyEventsSupported
{
  static BOOL isKbInputSupported = NO;
  static dispatch_once_t onceKbInputSupported;
  dispatch_once(&onceKbInputSupported, ^{
    isKbInputSupported = [XCPointerEvent.class respondsToSelector:@selector(keyboardEventForKeyCode:keyPhase:modifierFlags:offset:)];
  });
  return isKbInputSupported;
}

@end

NSInteger FBTestmanagerdVersion(void)
{
  static dispatch_once_t getTestmanagerdVersion;
  static NSInteger testmanagerdVersion;
  dispatch_once(&getTestmanagerdVersion, ^{
    id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
    if ([(NSObject *)proxy respondsToSelector:@selector(_XCT_exchangeProtocolVersion:reply:)]) {
      __block atomic_bool didReply = false;
      __block NSInteger receivedVersion = 0;
      [proxy _XCT_exchangeProtocolVersion:testmanagerdVersion reply:^(unsigned long long code) {
        receivedVersion = (NSInteger) code;
        atomic_store(&didReply, true);
      }];
      // Commands are served from the main thread, so a daemon that never replies
      // must not block it forever. The run loop keeps spinning to deliver the reply
      BOOL isReplied = [[[FBRunLoopSpinner new]
                         timeout:TESTMANAGERD_VERSION_TIMEOUT_SEC]
                        spinUntilTrue:^BOOL{
        return atomic_load(&didReply);
      }];
      if (isReplied) {
        testmanagerdVersion = receivedVersion;
      } else {
        [FBLogger logFmt:@"Did not receive a testmanagerd protocol version reply within %.0f seconds; assuming the newest/full-featured protocol", TESTMANAGERD_VERSION_TIMEOUT_SEC];
        testmanagerdVersion = 0xFFFF;
      }
    } else {
      testmanagerdVersion = 0xFFFF;
    }
  });
  return testmanagerdVersion;
}
