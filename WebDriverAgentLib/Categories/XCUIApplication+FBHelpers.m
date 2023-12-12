/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "XCUIApplication+FBHelpers.h"

#import "FBElementTypeTransformer.h"
#import "FBKeyboard.h"
#import "FBLogger.h"
#import "FBExceptions.h"
#import "FBMacros.h"
#import "FBMathUtils.h"
#import "FBActiveAppDetectionPoint.h"
#import "FBXCodeCompatibility.h"
#import "FBXPath.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCTestDaemonsProxy.h"
#import "FBXCElementSnapshotWrapper+Helpers.h"
#import "FBXCAXClientProxy.h"
#import "FBXMLGenerationOptions.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIElement+FBCaching.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCTestManager_ManagerInterface-Protocol.h"
#import "XCTestPrivateSymbols.h"
#import "XCTRunnerDaemonSession.h"

static NSString* const FBUnknownBundleId = @"unknown";

_Nullable id extractIssueProperty(id issue, NSString *propertyName) {
  SEL selector = NSSelectorFromString(propertyName);
  NSMethodSignature *methodSignature = [issue methodSignatureForSelector:selector];
  if (nil == methodSignature) {
    return nil;
  }
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
  [invocation setSelector:selector];
  [invocation invokeWithTarget:issue];
  id __unsafe_unretained result;
  [invocation getReturnValue:&result];
  return result;
}

NSDictionary<NSString *, NSNumber *> *auditTypeNamesToValues(void) {
  static dispatch_once_t onceToken;
  static NSDictionary *result;
  dispatch_once(&onceToken, ^{
    // https://developer.apple.com/documentation/xctest/xcuiaccessibilityaudittype?language=objc
    result = @{
      @"XCUIAccessibilityAuditTypeAction": @(1UL << 32),
      @"XCUIAccessibilityAuditTypeAll": @(~0UL),
      @"XCUIAccessibilityAuditTypeContrast": @(1UL << 0),
      @"XCUIAccessibilityAuditTypeDynamicType": @(1UL << 16),
      @"XCUIAccessibilityAuditTypeElementDetection": @(1UL << 1),
      @"XCUIAccessibilityAuditTypeHitRegion": @(1UL << 2),
      @"XCUIAccessibilityAuditTypeParentChild": @(1UL << 33),
      @"XCUIAccessibilityAuditTypeSufficientElementDescription": @(1UL << 3),
      @"XCUIAccessibilityAuditTypeTextClipped": @(1UL << 17),
      @"XCUIAccessibilityAuditTypeTrait": @(1UL << 18),
    };
  });
  return result;
}

NSDictionary<NSNumber *, NSString *> *auditTypeValuesToNames(void) {
  static dispatch_once_t onceToken;
  static NSDictionary *result;
  dispatch_once(&onceToken, ^{
    NSMutableDictionary *inverted = [NSMutableDictionary new];
    [auditTypeNamesToValues() enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSNumber *value, BOOL *stop) {
      inverted[value] = key;
    }];
    result = inverted.copy;
  });
  return result;
}


@implementation XCUIApplication (FBHelpers)

- (BOOL)fb_waitForAppElement:(NSTimeInterval)timeout
{
  __block BOOL canDetectAxElement = YES;
  int currentProcessIdentifier = [self.accessibilityElement processIdentifier];
  BOOL result = [[[FBRunLoopSpinner new]
           timeout:timeout]
          spinUntilTrue:^BOOL{
    id<FBXCAccessibilityElement> currentAppElement = FBActiveAppDetectionPoint.sharedInstance.axElement;
    canDetectAxElement = nil != currentAppElement;
    if (!canDetectAxElement) {
      return YES;
    }
    return currentAppElement.processIdentifier == currentProcessIdentifier;
  }];
  return canDetectAxElement
    ? result
    : [self waitForExistenceWithTimeout:timeout];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)fb_appsInfoWithAxElements:(NSArray<id<FBXCAccessibilityElement>> *)axElements
{
  NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  for (id<FBXCAccessibilityElement> axElement in axElements) {
    NSMutableDictionary<NSString *, id> *appInfo = [NSMutableDictionary dictionary];
    pid_t pid = axElement.processIdentifier;
    appInfo[@"pid"] = @(pid);
    __block NSString *bundleId = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [proxy _XCT_requestBundleIDForPID:pid
                                reply:^(NSString *bundleID, NSError *error) {
                                  if (nil == error) {
                                    bundleId = bundleID;
                                  } else {
                                    [FBLogger logFmt:@"Cannot request the bundle ID for process ID %@: %@", @(pid), error.description];
                                  }
                                  dispatch_semaphore_signal(sem);
                                }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    appInfo[@"bundleId"] = bundleId ?: FBUnknownBundleId;
    [result addObject:appInfo.copy];
  }
  return result.copy;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)fb_activeAppsInfo
{
  return [self fb_appsInfoWithAxElements:[FBXCAXClientProxy.sharedClient activeApplications]];
}

- (BOOL)fb_deactivateWithDuration:(NSTimeInterval)duration error:(NSError **)error
{
  if(![[XCUIDevice sharedDevice] fb_goToHomescreenWithError:error]) {
    return NO;
  }
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MAX(duration, .0)]];
  [self fb_activate];
  return YES;
}

- (NSDictionary *)fb_tree
{
  id<FBXCElementSnapshot> snapshot = self.fb_isResolvedFromCache.boolValue
    ? self.lastSnapshot
    : [self fb_snapshotWithAllAttributesAndMaxDepth:nil];
  return [self.class dictionaryForElement:snapshot recursive:YES];
}

- (NSDictionary *)fb_accessibilityTree
{
  id<FBXCElementSnapshot> snapshot = self.fb_isResolvedFromCache.boolValue
    ? self.lastSnapshot
    : [self fb_snapshotWithAllAttributesAndMaxDepth:nil];
  return [self.class accessibilityInfoForElement:snapshot];
}

+ (NSDictionary *)dictionaryForElement:(id<FBXCElementSnapshot>)snapshot recursive:(BOOL)recursive
{
  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];
  info[@"type"] = [FBElementTypeTransformer shortStringWithElementType:snapshot.elementType];
  info[@"rawIdentifier"] = FBValueOrNull([snapshot.identifier isEqual:@""] ? nil : snapshot.identifier);
  FBXCElementSnapshotWrapper *wrappedSnapshot = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
  info[@"name"] = FBValueOrNull(wrappedSnapshot.wdName);
  info[@"value"] = FBValueOrNull(wrappedSnapshot.wdValue);
  info[@"label"] = FBValueOrNull(wrappedSnapshot.wdLabel);
  info[@"rect"] = wrappedSnapshot.wdRect;
  info[@"frame"] = NSStringFromCGRect(wrappedSnapshot.wdFrame);
  info[@"isEnabled"] = [@([wrappedSnapshot isWDEnabled]) stringValue];
  info[@"isVisible"] = [@([wrappedSnapshot isWDVisible]) stringValue];
  info[@"isAccessible"] = [@([wrappedSnapshot isWDAccessible]) stringValue];
  info[@"isFocused"] = [@([wrappedSnapshot isWDFocused]) stringValue];

  if (!recursive) {
    return info.copy;
  }

  NSArray *childElements = snapshot.children;
  if ([childElements count]) {
    info[@"children"] = [[NSMutableArray alloc] init];
    for (id<FBXCElementSnapshot> childSnapshot in childElements) {
      [info[@"children"] addObject:[self dictionaryForElement:childSnapshot recursive:YES]];
    }
  }
  return info;
}

+ (NSDictionary *)accessibilityInfoForElement:(id<FBXCElementSnapshot>)snapshot
{
  FBXCElementSnapshotWrapper *wrappedSnapshot = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
  BOOL isAccessible = [wrappedSnapshot isWDAccessible];
  BOOL isVisible = [wrappedSnapshot isWDVisible];

  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];

  if (isAccessible) {
    if (isVisible) {
      info[@"value"] = FBValueOrNull(wrappedSnapshot.wdValue);
      info[@"label"] = FBValueOrNull(wrappedSnapshot.wdLabel);
    }
  } else {
    NSMutableArray *children = [[NSMutableArray alloc] init];
    for (id<FBXCElementSnapshot> childSnapshot in snapshot.children) {
      NSDictionary *childInfo = [self accessibilityInfoForElement:childSnapshot];
      if ([childInfo count]) {
        [children addObject: childInfo];
      }
    }
    if ([children count]) {
      info[@"children"] = [children copy];
    }
  }
  if ([info count]) {
    info[@"type"] = [FBElementTypeTransformer shortStringWithElementType:snapshot.elementType];
    info[@"rawIdentifier"] = FBValueOrNull([snapshot.identifier isEqual:@""] ? nil : snapshot.identifier);
    info[@"name"] = FBValueOrNull(wrappedSnapshot.wdName);
  } else {
    return nil;
  }
  return info;
}

- (NSString *)fb_xmlRepresentation
{
  return [self fb_xmlRepresentationWithOptions:nil];
}

- (NSString *)fb_xmlRepresentationWithOptions:(FBXMLGenerationOptions *)options
{
  return [FBXPath xmlStringWithRootElement:self options:options];
}

- (NSString *)fb_descriptionRepresentation
{
  NSMutableArray<NSString *> *childrenDescriptions = [NSMutableArray array];
  for (XCUIElement *child in [self.fb_query childrenMatchingType:XCUIElementTypeAny].allElementsBoundByIndex) {
    [childrenDescriptions addObject:child.debugDescription];
  }
  // debugDescription property of XCUIApplication instance shows descendants addresses in memory
  // instead of the actual information about them, however the representation works properly
  // for all descendant elements
  return (0 == childrenDescriptions.count) ? self.debugDescription : [childrenDescriptions componentsJoinedByString:@"\n\n"];
}

- (XCUIElement *)fb_activeElement
{
  return [[[self.fb_query descendantsMatchingType:XCUIElementTypeAny]
           matchingPredicate:[NSPredicate predicateWithFormat:@"hasKeyboardFocus == YES"]]
          fb_firstMatch];
}

#if TARGET_OS_TV
- (XCUIElement *)fb_focusedElement
{
  return [[[self.fb_query descendantsMatchingType:XCUIElementTypeAny]
           matchingPredicate:[NSPredicate predicateWithFormat:@"hasFocus == true"]]
          fb_firstMatch];
}
#endif

- (BOOL)fb_dismissKeyboardWithKeyNames:(nullable NSArray<NSString *> *)keyNames
                                 error:(NSError **)error
{
  BOOL (^isKeyboardInvisible)(void) = ^BOOL(void) {
    return ![FBKeyboard waitUntilVisibleForApplication:self
                                               timeout:0
                                                 error:nil];
  };

  if (isKeyboardInvisible()) {
    // Short circuit if the keyboard is not visible
    return YES;
  }

#if TARGET_OS_TV
  [[XCUIRemote sharedRemote] pressButton:XCUIRemoteButtonMenu];
#else
  NSArray<XCUIElement *> *(^findMatchingKeys)(NSPredicate *) = ^NSArray<XCUIElement *> *(NSPredicate * predicate) {
    NSPredicate *keysPredicate = [NSPredicate predicateWithFormat:@"elementType == %@", @(XCUIElementTypeKey)];
    XCUIElementQuery *parentView = [[self.keyboard descendantsMatchingType:XCUIElementTypeOther]
                                    containingPredicate:keysPredicate];
    return [[parentView childrenMatchingType:XCUIElementTypeAny]
            matchingPredicate:predicate].allElementsBoundByIndex;
  };

  if (nil != keyNames && keyNames.count > 0) {
    NSPredicate *searchPredicate = [NSPredicate predicateWithBlock:^BOOL(id<FBXCElementSnapshot> snapshot, NSDictionary *bindings) {
      if (snapshot.elementType != XCUIElementTypeKey && snapshot.elementType != XCUIElementTypeButton) {
        return NO;
      }

      return (nil != snapshot.identifier && [keyNames containsObject:snapshot.identifier])
        || (nil != snapshot.label && [keyNames containsObject:snapshot.label]);
    }];
    NSArray *matchedKeys = findMatchingKeys(searchPredicate);
    if (matchedKeys.count > 0) {
      for (XCUIElement *matchedKey in matchedKeys) {
        if (!matchedKey.exists) {
          continue;
        }

        [matchedKey tap];
        if (isKeyboardInvisible()) {
          return YES;
        }
      }
    }
  }
  
  if ([UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
    NSPredicate *searchPredicate = [NSPredicate predicateWithFormat:@"elementType IN %@",
                                    @[@(XCUIElementTypeKey), @(XCUIElementTypeButton)]];
    NSArray *matchedKeys = findMatchingKeys(searchPredicate);
    if (matchedKeys.count > 0) {
      [matchedKeys[matchedKeys.count - 1] tap];
    }
  }
#endif
  NSString *errorDescription = @"Did not know how to dismiss the keyboard. Try to dismiss it in the way supported by your application under test.";
  return [[[[FBRunLoopSpinner new]
            timeout:3]
           timeoutErrorMessage:errorDescription]
          spinUntilTrue:isKeyboardInvisible
          error:error];
}

- (NSArray<NSDictionary<NSString *, NSString*> *> *)fb_performAccessibilityAuditWithAuditTypesSet:(NSSet<NSString *> *)auditTypes
                                                                                            error:(NSError **)error;
{
  uint64_t numTypes = 0;
  NSDictionary *namesMap = auditTypeNamesToValues();
  for (NSString *value in auditTypes) {
    NSNumber *typeValue = namesMap[value];
    if (nil == typeValue) {
      NSString *reason = [NSString stringWithFormat:@"Audit type value '%@' is not known. Only the following audit types are supported: %@", value, namesMap.allKeys];
      @throw [NSException exceptionWithName:FBInvalidArgumentException reason:reason userInfo:@{}];
    }
    numTypes |= [typeValue unsignedLongLongValue];
  }
  return [self fb_performAccessibilityAuditWithAuditTypes:numTypes error:error];
}

- (NSArray<NSDictionary<NSString *, NSString*> *> *)fb_performAccessibilityAuditWithAuditTypes:(uint64_t)auditTypes
                                                                                         error:(NSError **)error;
{
  SEL selector = NSSelectorFromString(@"performAccessibilityAuditWithAuditTypes:issueHandler:error:");
  if (![self respondsToSelector:selector]) {
    [[[FBErrorBuilder alloc]
      withDescription:@"Accessibility audit is only supported since iOS 17/Xcode 15"]
     buildError:error];
    return nil;
  }

  NSMutableArray<NSDictionary *> *resultArray = [NSMutableArray array];
  NSMethodSignature *methodSignature = [self methodSignatureForSelector:selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
  [invocation setSelector:selector];
  [invocation setArgument:&auditTypes atIndex:2];
  BOOL (^issueHandler)(id) = ^BOOL(id issue) {
    NSString *auditType = @"";
    NSDictionary *valuesToNamesMap = auditTypeValuesToNames();
    NSNumber *auditTypeValue = [issue valueForKey:@"auditType"];
    if (nil != auditTypeValue) {
      auditType = valuesToNamesMap[auditTypeValue] ?: [auditTypeValue stringValue];
    }
    
    id extractedElement = extractIssueProperty(issue, @"element");
    
    id<FBXCElementSnapshot> elementSnapshot = [extractedElement fb_takeSnapshot];
    NSDictionary *elementAttributes = elementSnapshot ? [self.class dictionaryForElement:elementSnapshot recursive:NO] : @{};
    
    [resultArray addObject:@{
      @"detailedDescription": extractIssueProperty(issue, @"detailedDescription") ?: @"",
      @"compactDescription": extractIssueProperty(issue, @"compactDescription") ?: @"",
      @"auditType": auditType,
      @"element": [extractedElement description] ?: @"",
      @"elementDescription": [extractedElement debugDescription] ?: @"",
      @"elementAttributes": elementAttributes ?: @{},
    }];
    return YES;
  };
  [invocation setArgument:&issueHandler atIndex:3];
  [invocation setArgument:&error atIndex:4];
  [invocation invokeWithTarget:self];
  BOOL isSuccessful;
  [invocation getReturnValue:&isSuccessful];
  return isSuccessful ? resultArray.copy : nil;
}

@end
