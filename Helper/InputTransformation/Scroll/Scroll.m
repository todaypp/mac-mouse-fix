//
// --------------------------------------------------------------------------
// ScrollControl.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "Scroll.h"
#import "DeviceManager.h"
#import "TouchSimulator.h"
#import "ScrollModifiers.h"
#import "Config.h"
#import "ScrollUtility.h"
#import "VectorUtility.h"
#import "HelperUtility.h"
#import "WannabePrefixHeader.h"
#import "ScrollAnalyzer.h"
#import "ScrollConfigObjC.h"
#import <Cocoa/Cocoa.h>
#import "Queue.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import "SubPixelator.h"
#import "GestureScrollSimulator.h"
#import "SharedUtility.h"
#import "ScrollModifiers.h"
#import "Actions.h"
#import "EventUtility.h"

@import IOKit;
#import "MFIOKitImports.h"
#import "IOUtility.h"

@implementation Scroll

#pragma mark - Variables - static

static CFMachPortRef _eventTap;
static CGEventSourceRef _eventSource;

static dispatch_queue_t _scrollQueue;

static PixelatedVectorAnimator *_animator;

static AXUIElementRef _systemWideAXUIElement; // TODO: should probably move this to Config or some sort of OverrideManager class
+ (AXUIElementRef) systemWideAXUIElement {
    return _systemWideAXUIElement;
}

#pragma mark - Variables - dynamic

static MFScrollModificationResult _modifications;
static ScrollConfig *_scrollConfig;
static MFScrollAnimationCurveParameters *_animationParams;
static ScrollAnalysisResult _lastScrollAnalysisResult;
static CFTimeInterval _lastScrollAnalysisResultTimeStamp;

#pragma mark - Public functions

+ (void)load_Manual {
    
    /// Setup dispatch queue
    ///  For multithreading while still retaining control over execution order.
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1);
    _scrollQueue = dispatch_queue_create("com.nuebling.mac-mouse-fix.helper.scroll", attr);
    
    /// Create AXUIElement for getting app under mouse pointer
    _systemWideAXUIElement = AXUIElementCreateSystemWide();
    /// Create Event source
    if (_eventSource == nil) {
        _eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    }
    
    /// Create/enable scrollwheel input callback
    if (_eventTap == nil) {
        CGEventMask mask = CGEventMaskBit(kCGEventScrollWheel);
        _eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, eventTapCallback, NULL);
        DDLogDebug(@"_eventTap: %@", _eventTap);
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(runLoopSource);
        CGEventTapEnable(_eventTap, false); // Not sure if this does anything
    }
    
    /// Create animator
    _animator = [[PixelatedVectorAnimator alloc] init];
    
    /// Create initial config instance
    _scrollConfig = [[ScrollConfig alloc] init];
}

+ (void)resetState {
    /// Untested
    
    [_animator stop];
    [GestureScrollSimulator stopMomentumScroll];
    [ScrollAnalyzer resetState];
}

+ (void)decide {
    /// Whether to enable or enable scrolling interception
    ///     Call this whenever a value which the decision depends on changes
    
    BOOL disableAll = ![DeviceManager devicesAreAttached];
    
    if (disableAll) {
        /// Disable scroll interception
        if (_eventTap) {
            CGEventTapEnable(_eventTap, false);
        }
    } else {
        /// Enable scroll interception
        CGEventTapEnable(_eventTap, true);
    }
    
    /// Are there other things we should enable/disable here?
    ///     ScrollModifiers.reactToModiferChange() comes to mind
}

#pragma mark - Event tap

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    
    /// Handle eventTapDisabled messages
    
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        
        if (type == kCGEventTapDisabledByUserInput) {
            DDLogInfo(@"ScrollControl eventTap was disabled by timeout. Re-enabling");
            CGEventTapEnable(_eventTap, true);
        } else if (type == kCGEventTapDisabledByUserInput) {
            DDLogInfo(@"ScrollControl eventTap was disabled by user input.");
        }
        
        return event;
    }
    
    /// Testing
    
//    IOHIDDeviceRef sendingDev = CGEventGetSendingDevice(event);

    /// Return non-scrollwheel events unaltered
    
    int64_t isPixelBased     = CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
    int64_t scrollPhase      = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    int64_t scrollDeltaAxis1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t scrollDeltaAxis2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    bool isDiagonal = scrollDeltaAxis1 != 0 && scrollDeltaAxis2 != 0;
    if (isPixelBased != 0
        || scrollPhase != 0 /// Not entirely sure if testing for 'scrollPhase' here makes sense
        || isDiagonal) {
        
        return event;
    }
    
    /// Get timestamp
    ///     Get timestamp here instead of _scrollQueue for accurate timing
    
    CFTimeInterval tickTime = CGEventGetTimestampInSeconds(event);
    
    /// Create copy of event
    
    CGEventRef eventCopy = CGEventCreateCopy(event); /// Create a copy, because the original event will become invalid and unusable in the new queue.
    
    /// Enqueue heavy processing
    ///  Executing heavy stuff on a different thread to prevent the eventTap from timing out. We wrote this before knowing that you can just re-enable the eventTap when it times out. But this doesn't hurt.
    
    dispatch_async(_scrollQueue, ^{
        heavyProcessing(eventCopy, scrollDeltaAxis1, scrollDeltaAxis2, tickTime);
    });
    
    return nil;
}

#pragma mark - Main event processing

static void heavyProcessing(CGEventRef event, int64_t scrollDeltaAxis1, int64_t scrollDeltaAxis2, CFTimeInterval tickTime) {
    
    /// Get HIDEvent
    HIDEvent *hidEvent = CGEventGetHIDEvent(event);
    
    /// Debug
    DDLogInfo(@"Scroll event: %@", hidEvent.description);
    
    /// Get sending device
    IOHIDDeviceRef sendingDev = CGEventGetSendingDevice(event);
    
    /// Debug
    assert(sendingDev != NULL);
    
    /// Print info on sendingDev
    if (sendingDev != NULL) {
        
        CFStringRef name = IOHIDDeviceGetProperty(sendingDev, CFSTR(kIOHIDProductKey));
        CFStringRef manufacturer = IOHIDDeviceGetProperty(sendingDev, CFSTR(kIOHIDManufacturerKey));
        
        DDLogInfo(@"Device sending scroll: %@ %@", manufacturer, name);
    }
    
    /// Get axis
    
    MFAxis inputAxis = [ScrollUtility axisForVerticalDelta:scrollDeltaAxis1 horizontalDelta:scrollDeltaAxis2];
    
    /// Get scrollDelta
    
    int64_t scrollDelta = 0;
    
    if (inputAxis == kMFAxisVertical) {
        scrollDelta = scrollDeltaAxis1;
    } else if (inputAxis == kMFAxisHorizontal) {
        scrollDelta = scrollDeltaAxis2;
    } else {
        NSCAssert(NO, @"Invalid scroll axis");
    }
    
    /// Run preliminary scrollAnalysis
    ///     To check if this is the first consecutive scrollTick
    ///
    ///     @note We check the _modifications.effectMod before updating _modifications. Not totally sure this makes sense?
    
    MFDirection scrollDirection = [ScrollUtility directionForInputAxis:inputAxis inputDelta:scrollDelta invertSetting:[_scrollConfig scrollInvertWithEvent:event] horizontalModifier:(_modifications.effectMod == kMFScrollEffectModificationHorizontalScroll)];
    
    BOOL firstConsecutive = [ScrollAnalyzer peekIsFirstConsecutiveTickWithTickOccuringAt:tickTime withDirection:scrollDirection withConfig:_scrollConfig];
    
    /// Update stuff
    ///     on the first scrollTick
    
    if (firstConsecutive) {
        /// Checking which app is under the mouse pointer and the other stuff we do here is really slow, so we only do it when necessary
        
        /// Update application Overrides
        
        [ScrollUtility updateMouseDidMoveWithEvent:event];
        if (!ScrollUtility.mouseDidMove) {
            [ScrollUtility updateFrontMostAppDidChange];
            /// Only checking this if mouse didn't move, because of || in (mouseMoved || frontMostAppChanged). For optimization. Not sure if significant.
        }
        
        if (ScrollUtility.mouseDidMove || ScrollUtility.frontMostAppDidChange) {
            /// Set app overrides
            [Config applyOverridesForAppUnderMousePointer_Force:NO]; /// Calls [self resetState]
        }
        
        /// Update modfications
        
        _modifications = [ScrollModifiers currentModificationsWithEvent:event];
        
        /// Update scrollConfig
        
        _scrollConfig = [ScrollConfig copyOfConfig];
        
#pragma mark Override config
        
        /// Override scrollConfig based on modifications
        
        /// inputModifications
        
        if (_modifications.inputMod == kMFScrollInputModificationQuick) {
            
            /// Set quick acceleration curve
            _scrollConfig.accelerationCurve = _scrollConfig.quickAccelerationCurve;
            
            /// Set animationCurve
            _scrollConfig.animationCurvePreset = kMFScrollAnimationCurvePresetQuickScroll;
            
            /// Make fast scroll easy to trigger
            _scrollConfig.consecutiveScrollSwipeMaxInterval *= 1.2;
            _scrollConfig.consecutiveScrollTickIntervalMax *= 1.2;
            
            /// Amp up fast scroll
            _scrollConfig.fastScrollThreshold_inSwipes = 2;
            _scrollConfig.fastScrollSpeedup = 20;
            
        } else if (_modifications.inputMod == kMFScrollInputModificationPrecise) {
            
            /// Set slow acceleration curve
            _scrollConfig.accelerationCurve = _scrollConfig.preciseAccelerationCurve;
            
            /// Set animationCurve
            
            _scrollConfig.animationCurvePreset = kMFScrollAnimationCurvePresetPreciseScroll;
            
            /// Turn off fast scroll
            _scrollConfig.fastScrollThreshold_inSwipes = 69; /// This is the haha sex number
            _scrollConfig.fastScrollExponentialBase = 1.0;
            _scrollConfig.fastScrollSpeedup = 0.0;
            
        } else if (_modifications.inputMod == kMFScrollInputModificationNone) {
            
            /// We do the actual handling of this case below after we handle the effectModifications.
            ///     That's because our standardAccelerationCurve depends on the animationCurve, and the animationCurve can change depending on the effectModifications
            ///     We also can't handle all the effectModifications before all inputModifications, because the animationCurves that the effectModifications prescribe should override the animationCurves that the inputModifications prescribe (if an effectModification and an inputModification are active at the same time)
            
        } else {
            assert(false);
        }
        
        /// effectModifications
        
        if (_modifications.effectMod == kMFScrollEffectModificationHorizontalScroll) {
            

        } else if (_modifications.effectMod == kMFScrollEffectModificationZoom) {
            
            _scrollConfig.smoothEnabled = YES;
            /// Override animation curve
            _scrollConfig.animationCurvePreset = kMFScrollAnimationCurvePresetTouchDriver;
            
        } else if (_modifications.effectMod == kMFScrollEffectModificationRotate) {
            
            _scrollConfig.smoothEnabled = YES;
            /// Override animation curve
            _scrollConfig.animationCurvePreset = kMFScrollAnimationCurvePresetTouchDriver;
            
        } else if (_modifications.effectMod == kMFScrollEffectModificationCommandTab) {
            
            _scrollConfig.smoothEnabled = NO;
            
        } else if (_modifications.effectMod == kMFScrollEffectModificationThreeFingerSwipeHorizontal) {
            
            _scrollConfig.smoothEnabled = YES;
            /// Override animation curve
            _scrollConfig.animationCurvePreset = kMFScrollAnimationCurvePresetTouchDriverLinear;
            
        } else if (_modifications.effectMod == kMFScrollEffectModificationFourFingerPinch) {
            
            _scrollConfig.smoothEnabled = YES;
            /// Override animation curve
            _scrollConfig.animationCurvePreset = kMFScrollAnimationCurvePresetTouchDriverLinear;
            
        } else if (_modifications.effectMod == kMFScrollEffectModificationNone) {
        } else {
            assert(false);
        }
        
        /// Input modifications (pt2)
        
        if (_modifications.inputMod == kMFScrollInputModificationNone) {
        
            /// Get display under mouse pointer
            CGDirectDisplayID displayUnderMousePointer;
            [HelperUtility displayUnderMousePointer:&displayUnderMousePointer withEvent:event];
            
            /// Get display height/width
            size_t displayDimension;
            if (scrollDirection == kMFDirectionLeft || scrollDirection == kMFDirectionRight) {
                displayDimension = CGDisplayPixelsWide(displayUnderMousePointer);
            } else if (scrollDirection == kMFDirectionUp || scrollDirection == kMFDirectionDown) {
                displayDimension = CGDisplayPixelsHigh(displayUnderMousePointer);
            } else assert(false);
            
            /// Calculate accelerationCurve
            _scrollConfig.accelerationCurve = [_scrollConfig standardAccelerationCurveWithScreenSize:displayDimension];
        }
        
        
    } /// End `if (firstConsecutive) {`
    
    ///
    /// Get effective direction
    ///  -> With user settings etc. applied
    
    scrollDirection = [ScrollUtility directionForInputAxis:inputAxis inputDelta:scrollDelta invertSetting:[_scrollConfig scrollInvertWithEvent:event] horizontalModifier:(_modifications.effectMod == kMFScrollEffectModificationHorizontalScroll)]; /// Why do we need to get the scrollDirection again? We already calculated it during the "preliminary scrollAnalysis". Can it ever change betweent he 2 times we calculate it?
    
    /// Run full scrollAnalysis
    ScrollAnalysisResult scrollAnalysisResult = [ScrollAnalyzer updateWithTickOccuringAt:tickTime withDirection:scrollDirection withConfig:_scrollConfig];

    
    /// Store scrollAnalysisResult
    ///     So that command tab output code can access it. Not sure if good solution
    _lastScrollAnalysisResult = scrollAnalysisResult;
    _lastScrollAnalysisResultTimeStamp = CACurrentMediaTime();
    
    /// Make scrollDelta positive, now that we have scrollDirection stored
    scrollDelta = llabs(scrollDelta);
    
    ///
    /// Acceleration (Get pxToScrollForThisTick)
    ///
    
    /// @discussion See the RawAccel guide for more info on acceleration curves https://github.com/a1xd/rawaccel/blob/master/doc/Guide.md
    ///     -> Edit: Their whole shtick is to make the outputSpeed(inputSpeed) curve smooth. This is relatively hard and I don't think this would be noticable for scrolling. Instead we simply define a sens(inputSpeed) curve using a Bezier curve.
    
    int64_t pxToScrollForThisTick;
    
    if (_scrollConfig.useAppleAcceleration) {
        
        pxToScrollForThisTick = scrollDelta;
        
    } else {
        
        /// Get scroll speed
        double timeBetweenTicks = scrollAnalysisResult.timeBetweenTicks;
        timeBetweenTicks = CLIP(timeBetweenTicks, 0, _scrollConfig.consecutiveScrollTickIntervalMax);
        /// ^ Shouldn't we clip between consecutiveScrollTickIntervalMin (instead of 0) and consecutiveScrollTickIntervalMax?
        ///     Also I think scrollAnalyzer should only produce these values and we should put an assert here instead
        
        double scrollSpeed = 1/timeBetweenTicks; /// In tick/s

        /// Evaluate acceleration curve
        double pxForThisTickDouble = [_scrollConfig.accelerationCurve evaluateAt:scrollSpeed]; /// In px/s
        pxToScrollForThisTick = pxForThisTickDouble; /// We could use a SubPixelator balance out the rounding errors, but I don't think that'll be noticable
        
        /// Debug
        DDLogDebug(@"Acceleration curve f(%f) = %lld", scrollSpeed, pxToScrollForThisTick);
        
        /// Validate
        if (pxToScrollForThisTick <= 0) {
            DDLogError(@"pxForThisTick is smaller equal 0. This is invalid. Exiting. scrollSpeed: %f, pxForThisTick: %lld", scrollSpeed, pxToScrollForThisTick);
            assert(false);
        }
    }
    
    ///
    /// Apply fast scroll to pxToScrollForThisTick
    ///
    
    /// Get fast scroll config
    int64_t fsThreshold = _scrollConfig.fastScrollThreshold_inSwipes;
    double fsFactor = _scrollConfig.fastScrollFactor;
    double fsBase = _scrollConfig.fastScrollExponentialBase;
    double fsSpeedup = _scrollConfig.fastScrollSpeedup;
    
    /// Evaluate fast scroll
    double fastScrollThresholdDelta = (scrollAnalysisResult.consecutiveScrollSwipeCounter+1) - fsThreshold; /// +1 cause consecutiveScrollSwipeCounter starts counting at 0, and fsThreshold at 1
    if (fastScrollThresholdDelta >= 0) {
        pxToScrollForThisTick *= fsFactor * pow(fsBase, (fastScrollThresholdDelta+1)*fsSpeedup); /// +1 so fsSpeedup is always a factor
    }
    
    /// Debug
    
    DDLogDebug(@"consecTicks: %lld, consecSwipes: %lld, consecSwipesFree: %f, fsThresholdDelta: %f", scrollAnalysisResult.consecutiveScrollTickCounter, scrollAnalysisResult.DEBUG_consecutiveScrollSwipeCounterRaw, scrollAnalysisResult.consecutiveScrollSwipeCounter, fastScrollThresholdDelta);
    
    DDLogDebug(@"timeBetweenTicks: %f, timeBetweenTicksRaw: %f, diff: %f, ticks: %lld", scrollAnalysisResult.timeBetweenTicks, scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, scrollAnalysisResult.timeBetweenTicks - scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, scrollAnalysisResult.consecutiveScrollTickCounter);
    
    ///
    /// Send scroll events
    ///
    
    if (pxToScrollForThisTick == 0) {
        
        DDLogWarn(@"pxToScrollForThisTick is 0");
        
    } else if (!_scrollConfig.smoothEnabled) {
        
        /// Send scroll event directly - without the animator. Will scroll all of pxToScrollForThisTick at once.
        
        sendScroll(pxToScrollForThisTick, scrollDirection, NO, kMFAnimationCallbackPhaseNone, kMFMomentumHintNone);
        
    } else {
        /// Send scroll events through animator, spread out over time.
        
        /// Start animation
        
        [_animator startWithParams:^NSDictionary<NSString *,id> * _Nonnull(Vector valueLeftVec, BOOL isRunning, Curve *animationCurve) {
            
            /// Validate
            assert(valueLeftVec.x == 0 || valueLeftVec.y == 0);
            
            /// Link to main screen
            ///     This used to be above in the `isFirstConsecutive` section. Maybe it fits better there?
            if (ScrollUtility.mouseDidMove && !isRunning) {
                /// Update animator to currently used display
                [_animator linkToMainScreen_Unsafe];
            }
            
            /// Declare result dict (animator start params)
            NSMutableDictionary *p = [NSMutableDictionary dictionary];
            
            /// Extract 1d valueLeft
            double distanceLeft = magnitudeOfVector(valueLeftVec);
            
            /// Get px that the animator still wants to scroll
            double pxLeftToScroll;
            if (!isRunning || scrollAnalysisResult.scrollDirectionDidChange) {
                
                /// Reset pxLeftToScroll
                pxLeftToScroll = 0;
                [_animator resetSubPixelator_Unsafe];
                
            } else if ([animationCurve isKindOfClass:SimpleBezierHybridCurve.class]) {
                SimpleBezierHybridCurve *c = (SimpleBezierHybridCurve *)animationCurve;
                pxLeftToScroll = [c baseDistanceLeftWithDistanceLeft: distanceLeft]; /// If we feed valueLeft instead of baseValueLeft back into the animator, it will lead to unwanted acceleration
            } else {
                pxLeftToScroll = distanceLeft;
            }
            
            /// Calculate distance to scroll
            double delta = pxToScrollForThisTick + pxLeftToScroll;
            
            /// Create curve
            MFScrollAnimationCurveParameters *cParams = _scrollConfig.animationCurveParams;
            BezierHybridCurve *c = [[BezierHybridCurve alloc]
                                    initWithBaseCurve:cParams.baseCurve
                                    minDuration:((double)cParams.msPerStep) / 1000.0
                                    distance:delta
                                    dragCoefficient:cParams.dragCoefficient
                                    dragExponent:cParams.dragExponent
                                    stopSpeed:cParams.stopSpeed
                                    distanceEpsilon:0.2];
            
            /// Get values from curve
            
            double deltaFromCurve = c.distance;
            double durationFromCurve = c.duration;
            
            /// Validate distanceFromCurve
            
            assert(fabs(deltaFromCurve - delta) < 3);
            
            /// Fill return dict
            
            p[@"duration"] = @(durationFromCurve);
            p[@"vector"] = nsValueFromVector(vectorFromDeltaAndDirection(deltaFromCurve, scrollDirection));
            p[@"curve"] = c;
            
            /// Debug
            
            DDLogDebug(@"\nDuration pre-animator: %f base: %f", c.duration, c.baseDuration);
            
            static double scrollDeltaSum = 0;
            scrollDeltaSum += labs(pxToScrollForThisTick);
            DDLogDebug(@"Delta sum pre-animator: %f", scrollDeltaSum);
            
            /// Return
            return p;
            
        } integerCallback:^(Vector distanceDeltaVec, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint) {
            
            /// This will be called each frame
            
            /// Extract 1d delta from vec
            double distanceDelta = magnitudeOfVector(distanceDeltaVec);
            
            /// Validate
            
            assert(distanceDeltaVec.x == 0 || distanceDeltaVec.y == 0);
            
            if (distanceDelta == 0) {
                assert(animationPhase == kMFAnimationCallbackPhaseEnd);
            }
            
            /// Debug
            
            static double scrollDeltaSummm = 0;
            scrollDeltaSummm += distanceDelta;
//            DDLogDebug(@"Delta sum in-animator: %f", scrollDeltaSummm);
            DDLogDebug(@"in-animator - delta %f, animationPhase: %d, momentumHint: %d", distanceDelta, animationPhase, momentumHint);
            
            /// Send scroll
            sendScroll(distanceDelta, scrollDirection, YES, animationPhase, momentumHint);
            
        }];
    }
    
    CFRelease(event);
}

static void sendScroll(int64_t px, MFDirection scrollDirection, BOOL gesture, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint) {
    
    /// Get x and y deltas
    
    int64_t dx = 0;
    int64_t dy = 0;
    
    if (scrollDirection == kMFDirectionUp) {
        dy = px;
    } else if (scrollDirection == kMFDirectionDown) {
        dy = -px;
    } else if (scrollDirection == kMFDirectionLeft) {
        dx = -px;
    } else if (scrollDirection == kMFDirectionRight) {
        dx = px;
    } else if (scrollDirection == kMFDirectionNone) {
        
    } else {
        assert(false);
    }
    
    /// Get params for sending event
    
    MFScrollOutputType outputType;
    
    if (!gesture) {
        outputType = kMFScrollOutputTypeLineScroll;
    } else {
        outputType = kMFScrollOutputTypeGestureScroll;
    }
    
    if (_modifications.effectMod == kMFScrollEffectModificationZoom) {
        outputType = kMFScrollOutputTypeZoom;
    } else if (_modifications.effectMod == kMFScrollEffectModificationRotate) {
        outputType = kMFScrollOutputTypeRotation;
    } else if (_modifications.effectMod == kMFScrollEffectModificationFourFingerPinch) {
        outputType = kMFScrollOutputTypeFourFingerPinch;
    } else if (_modifications.effectMod == kMFScrollEffectModificationCommandTab) {
        outputType = kMFScrollOutputTypeCommandTab;
    } else if (_modifications.effectMod == kMFScrollEffectModificationThreeFingerSwipeHorizontal) {
        outputType = kMFScrollOutputTypeThreeFingerSwipeHorizontal;
    } /// kMFScrollEffectModificationHorizontalScroll is handled above when determining scroll direction
    
    /// Send event
    
    sendOutputEvents(dx, dy, outputType, animationPhase, momentumHint);
}

/// Define output types

typedef enum {
    kMFScrollOutputTypeGestureScroll,
    kMFScrollOutputTypeFourFingerPinch,
    kMFScrollOutputTypeThreeFingerSwipeHorizontal,
    kMFScrollOutputTypeZoom,
    kMFScrollOutputTypeRotation,
    kMFScrollOutputTypeCommandTab,
    kMFScrollOutputTypeLineScroll,
} MFScrollOutputType;

/// Output

static void sendOutputEvents(int64_t dx, int64_t dy, MFScrollOutputType outputType, MFAnimationCallbackPhase animatorPhase, MFMomentumHint momentumHint) {
    
    /// Init eventPhase
    
    IOHIDEventPhaseBits eventPhase = kIOHIDEventPhaseUndefined;
    if (animatorPhase != kMFAnimationCallbackPhaseNone) {
        eventPhase = [VectorAnimator IOHIDPhaseWithAnimationCallbackPhase:animatorPhase];
    }
    
    /// Validate
    
    if (dx+dy == 0) {
        assert(eventPhase == kIOHIDEventPhaseEnded);
    }
    
    /// Send events based on outputType
    
    if (outputType == kMFScrollOutputTypeGestureScroll) {
        
        /// --- GestureScroll ---
        
        if (!_scrollConfig.animationCurveParams.sendMomentumScrolls) {
            
            /// Post event
            [GestureScrollSimulator postGestureScrollEventWithDeltaX:dx deltaY:dy phase:eventPhase];
            
            /// Suppress momentumScroll
            if (eventPhase == kIOHIDEventPhaseEnded) {
                DDLogDebug(@"THAT CALL where displayLinkkk is stopped from Scroll.m");
                [GestureScrollSimulator stopMomentumScroll];
            }
            
        } else { /// sendMomentumScrolls == true
            
            /// Validate
            assert(momentumHint != kMFMomentumHintNone);
            
            /// Store lastMomentumHint
            static MFMomentumHint lastMomentumHint = kMFMomentumHintNone;
            
            /// Get eventPhase and momentumPhase
            
            if (momentumHint == kMFMomentumHintGesture) { /// momentumHint is gesture
                
                if (lastMomentumHint == kMFMomentumHintMomentum) {
                    
                    /// Send momentum end event
                    [GestureScrollSimulator postMomentumScrollDirectlyWithDeltaX:0 deltaY:0 momentumPhase:kCGMomentumScrollPhaseEnd];
                    
                    /// Set eventPhase to start
                    eventPhase = kIOHIDEventPhaseBegan;
                    
                    /// Debug
                    DDLogDebug(@"\nHybrid event - momentum: (0, 0, %d) JJJ", kCGMomentumScrollPhaseEnd);
                }
                
                /// Send normal gesture scroll
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:dx deltaY:dy phase:eventPhase autoMomentumScroll:NO];
                
                /// Debug
                DDLogDebug(@"\nHybrid event - gesture: (%lld, %lld, %d)", dx, dy, eventPhase);
                
            } else { /// momentumHint is momentum
                
                CGMomentumScrollPhase momentumPhase = kCGMomentumScrollPhaseNone;
                
                if (lastMomentumHint == kMFMomentumHintGesture) {
                    /// Momentum begins
                    
                    /// Send gesture end event
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseEnded autoMomentumScroll:NO];
                    
                    /// Get momentum phase
                    momentumPhase = kCGMomentumScrollPhaseBegin;
                    
                    /// Debug
                    DDLogDebug(@"\nHybrid event - gesture: (0, 0, %d) HHH", kIOHIDEventPhaseEnded);
                    
                } else if (lastMomentumHint == kMFMomentumHintMomentum) {
                    /// Momentum continues
                    
                    /// Get momentum phase
                    if (animatorPhase == kMFAnimationCallbackPhaseContinue) {
                        momentumPhase = kCGMomentumScrollPhaseContinue;
                    } else if (animatorPhase == kMFAnimationCallbackPhaseEnd) {
                        momentumPhase = kCGMomentumScrollPhaseEnd;
                    } else {
//                        assert(false);
                        DDLogDebug(@"\nHybrid event - Assert fail >:(");
                    }
                } else {
                    assert(false);
                }

                /// Send momentum event
                [GestureScrollSimulator postMomentumScrollDirectlyWithDeltaX:dx deltaY:dy momentumPhase:momentumPhase];
                
                
                /// Debug
                DDLogDebug(@"\nHybrid event - momentum: (%lld, %lld, %d)", dx, dy, momentumPhase);
            }
            
            /// Update lastMomentumHint
            lastMomentumHint = momentumHint;
            if (animatorPhase == kMFAnimationCallbackPhaseEnd)
                lastMomentumHint = kMFMomentumHintNone;
        }
        
    } else if (outputType == kMFScrollOutputTypeZoom) {
        
        /// --- Zoom ---
        
        double eventDelta = (dx + dy)/800.0; /// This works because, if dx != 0 -> dy == 0, and the other way around.
        
        [TouchSimulator postMagnificationEventWithMagnification:eventDelta phase:eventPhase];
        
        
    } else if (outputType == kMFScrollOutputTypeRotation) {
        
        /// --- Rotation ---
        
        double eventDelta = (dx + dy)/8.0; /// This works because, if dx != 0 -> dy == 0, and the other way around.
        
        [TouchSimulator postRotationEventWithRotation:eventDelta phase:eventPhase];
        
    } else if (outputType == kMFScrollOutputTypeFourFingerPinch
               || outputType == kMFScrollOutputTypeThreeFingerSwipeHorizontal) {
        
        /// --- FourFingerPinch or ThreeFingerSwipeHorizontal ---
        
        MFDockSwipeType type;
        double eventDelta;
        
        if (outputType == kMFScrollOutputTypeFourFingerPinch) {
            type = kMFDockSwipeTypePinch;
            eventDelta = -(dx + dy)/600.0;
            /// ^ Launchpad feels a lot less sensitive than Show Desktop, but to improve this we'd have to somehow detect which of both is active atm. Negate delta to mirror the way that zooming works
        } else if (outputType == kMFScrollOutputTypeThreeFingerSwipeHorizontal) {
            type = kMFDockSwipeTypeHorizontal;
            eventDelta = -(dx + dy)/600.0;
        } else {
            assert(false);
        }
        
        [TouchSimulator postDockSwipeEventWithDelta:eventDelta type:type phase:eventPhase];
        
        if (eventPhase == kIOHIDEventPhaseEnded) {
            
            /// v Dock swipes will sometimes get stuck when the computer is slow. This can be solved by sending several "end" events in a row with a delay (see "stuck bug" in ModifiedDrag)
            ///     Edit: Even with sending the event again after 0.2 seconds, the stuck bug still happens a bunch here for some reason. Event though this almost completely eliminates the bug in ModifiedDrag.
            ///         Hopefully, sending it again after 0.5 seconds works... Edit: Yes, seems to work better but still sometimes happens
            ///   Edit2: I don't experience the stuck bug anymore here. I'm on an M1 now, maybe that's it.
            ///     TODO: I should probably move the "sending several end events" code to the postDockSwipeEventWithDelta: function, because otherwise there might be interference when the scroll engine and the drag engine try to send those 'end' events at the same time. We also need further safety measures if several sources try to use postDockSwipeEventWithDelta: at the same time.
            ///     TODO: We should probably change the "sending several end events" code in ModifiedDrag over to using timers that we can invalidate like here - We should do this to avoid too many 'end' events being sent from old timers.
            
            static NSTimer *timer1 = nil;
            static NSTimer *timer2 = nil;
            
            [timer1 invalidate];
            [timer2 invalidate];
            
            double zero = 0.0;
            
            IOHIDEventPhaseBits iohidPhase = kIOHIDEventPhaseEnded;
            
            SEL selector = @selector(postDockSwipeEventWithDelta:type:phase:);
            NSMethodSignature *signature = [TouchSimulator methodSignatureForSelector:selector];
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = TouchSimulator.class;
            invocation.selector = selector;
            [invocation setArgument:&zero atIndex:2];
            [invocation setArgument:&type atIndex:3];
            [invocation setArgument:&iohidPhase atIndex:4];
            
            timer1 = [NSTimer scheduledTimerWithTimeInterval:0.2 invocation:invocation repeats:NO];
            timer2 = [NSTimer scheduledTimerWithTimeInterval:0.5 invocation:invocation repeats:NO];
            
        }
        
    } else if (outputType == kMFScrollOutputTypeCommandTab) {
        
        /// --- CommandTab ---
        
        
        double d = -(dx + dy);
        
        if (d == 0) return;
        
        /// Get state
        
        static bool appSwitcherWasOpenedByCurrentConsecutiveTicks = false; /// Use this to make first swipe only create one selection change
        bool isFirstConsecutive = _lastScrollAnalysisResult.consecutiveScrollTickCounter == 0; /// When commandTab is active, we only get one call of this function per Tick (animator is disabled), that's why we can do this
        
        /// Open app switcher
        
        if (!_appSwitcherIsOpen) {
            sendKeyEvent(55, kCGEventFlagMaskCommand, true);
            sendKeyEvent(48, kCGEventFlagMaskCommand, true);
            sendKeyEvent(48, kCGEventFlagMaskCommand, false);
            _appSwitcherIsOpen = YES;
            appSwitcherWasOpenedByCurrentConsecutiveTicks = true;
        } else {
            if (isFirstConsecutive)
                appSwitcherWasOpenedByCurrentConsecutiveTicks = false;
        }
        
        /// Select apps
        
        if (!appSwitcherWasOpenedByCurrentConsecutiveTicks) {
            
            if (d > 0) {
                sendKeyEvent(48, kCGEventFlagMaskCommand, true);
                sendKeyEvent(48, kCGEventFlagMaskCommand, false);
            } else {
                sendKeyEvent(48, kCGEventFlagMaskCommand | kCGEventFlagMaskShift, true);
                sendKeyEvent(48, kCGEventFlagMaskCommand | kCGEventFlagMaskShift, false);
            }
        }
        
    } else if (outputType == kMFScrollOutputTypeLineScroll) {
        
        /// --- LineScroll ---
        
        /// We ignore the phases here
        
        if (dx+dy == 0) return;
        
        CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 0);
        
        int64_t dyLine;
        int64_t dxLine;
        
        /// Make line deltas 1/10 of pixel deltas
        ///     See CGEventSource pixelsPerLine - it's 10
        //      TODO: Subpixelate line delta (instead of rounding)
        dyLine = round(dy / 10);
        dxLine = round(dx / 10);
        
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, dyLine);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, dy);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, dy);
        
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, dxLine);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, dx);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, dx);
        
        CGEventPost(kCGSessionEventTap, event);
        
    } else {
        assert(false);
    }
    
}

/// Output - Helper funcs

static BOOL _appSwitcherIsOpen = NO;

+ (void)appSwitcherModificationHasBeenDeactivated {
    /// AppSwitcherModification is aka CommandTab. Should rename to AppSwitcher.
    if (_appSwitcherIsOpen) { /// Not sure if this check is necessary. Should only be called when the appSwitcher is open.
        sendKeyEvent(55, 0, false);
        _appSwitcherIsOpen = NO;
    }
}

void sendKeyEvent(CGKeyCode keyCode, CGEventFlags flags, bool keyDown) {
    
    CGEventTapLocation tapLoc = kCGSessionEventTap;
    
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keyCode, keyDown);
    CGEventSetFlags(event, flags);
    
    CGEventPost(tapLoc, event);
    CFRelease(event);
}

@end
