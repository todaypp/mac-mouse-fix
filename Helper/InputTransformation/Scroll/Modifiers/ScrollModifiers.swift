//
// --------------------------------------------------------------------------
// ScrollModifiersSwift.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under MIT
// --------------------------------------------------------------------------
//

import Cocoa
import CocoaLumberjackSwift

@objc class ScrollModifiers: NSObject {

    static var activeModifications: Dictionary<AnyHashable, Any> = [:];
    
    @objc public static func currentScrollModifications(event: CGEvent) -> MFScrollModificationResult {
        
        /// Debug
        
//        DDLogDebug("ScrollMods being evaluated...")
        
        /// Declare and init result
        
        let emptyResult = MFScrollModificationResult.init(inputModification: kMFScrollInputModificationNone,
                                                          effectModification: kMFScrollEffectModificationNone)
        var result = emptyResult
        
        /// Get currently active scroll remaps
        
        var modifyingDeviceID: NSNumber? = nil;
        let activeModifiers = ModifierManager.getActiveModifiers(forDevice: &modifyingDeviceID, filterButton: nil, event: event)
        let baseRemaps = TransformationManager.remaps();
        
        /// Debug
//        DDLogDebug("activeFlags in ScrollModifers: \(SharedUtility.binaryRepresentation((activeModifiers[kMFModificationPreconditionKeyKeyboard] as? NSNumber)?.uint32Value ?? 0))") /// This is unbelievably slow for some reason
        
        self.activeModifications = RemapsOverrider.effectiveRemapsMethod()(baseRemaps, activeModifiers);
        
        guard let modifiedScrollDictUntyped = activeModifications[kMFTriggerScroll] else {
            return result; /// There are no active scroll modifications
        }
        let modifiedScrollDict = modifiedScrollDictUntyped as! Dictionary<AnyHashable, Any>
        
        /// Input modification
        
        if let inputModification = modifiedScrollDict[kMFModifiedScrollDictKeyInputModificationType] as? String {
                
            switch inputModification {
                
            case kMFModifiedScrollInputModificationTypePrecisionScroll:
                result.inputModification = kMFScrollInputModificationPrecise
            case kMFModifiedScrollInputModificationTypeQuickScroll:
                result.inputModification = kMFScrollInputModificationQuick
            default:
                fatalError("Unknown modifiedSrollDict type found in remaps")
            }
        }
        
        /// Effect modification
        
        if let effectModification = modifiedScrollDict[kMFModifiedScrollDictKeyEffectModificationType] as? String {
            
            switch effectModification {
                
            case kMFModifiedScrollEffectModificationTypeZoom:
                result.effectModification = kMFScrollEffectModificationZoom
            case kMFModifiedScrollEffectModificationTypeHorizontalScroll:
                result.effectModification = kMFScrollEffectModificationHorizontalScroll
            case kMFModifiedScrollEffectModificationTypeRotate:
                result.effectModification = kMFScrollEffectModificationRotate
            case kMFModifiedScrollEffectModificationTypeFourFingerPinch:
                result.effectModification = kMFScrollEffectModificationFourFingerPinch
            case kMFModifiedScrollEffectModificationTypeCommandTab:
                result.effectModification = kMFScrollEffectModificationCommandTab
            case kMFModifiedScrollEffectModificationTypeThreeFingerSwipeHorizontal:
                result.effectModification = kMFScrollEffectModificationThreeFingerSwipeHorizontal
            case kMFModifiedScrollEffectModificationTypeAddModeFeedback:
                
                var payload = modifiedScrollDict
                payload.removeValue(forKey: kMFModifiedScrollDictKeyEffectModificationType)
                var devID: NSNumber? = nil
                payload[kMFRemapsKeyModificationPrecondition] = NSMutableDictionary(dictionary: ModifierManager .getActiveModifiers(forDevice: &devID, filterButton: nil, event: event, despiteAddMode: true))
                /// ^ Need to cast to mutable, otherwise Swift will make it immutable and mainApp will crash trying to build this payload into its remapArray
                TransformationManager.concludeAddMode(withPayload: payload)
                
            default:
                fatalError("Unknown modifiedSrollDict type found in remaps")
            }
        }
        
        /// Feedback
        let resultIsEmpty = result.inputModification == emptyResult.inputModification && result.effectModification == emptyResult.effectModification
        if !resultIsEmpty {
            ModifierManager.handleModifiersHaveHadEffect(withDevice: modifyingDeviceID, activeModifiers: activeModifiers)
            ModifiedDrag.modifiedScrollHasBeenUsed()
        }
        
        /// Debiug
        
//        DDLogDebug("ScrollMods: \(result.input), \(result.effect)")
        
        ///  Return
        
        return result
    
    }
    
    @objc public static func reactToModiferChange(activeModifications: Dictionary<AnyHashable, Any>) {
        /// This is called on every button press. Might be good to optimize this if it has any noticable performance impact.
        
        /// Deactivate app switcher - if appropriate
        
        let effectModKeyPath = "\(kMFTriggerScroll).\(kMFModifiedScrollDictKeyEffectModificationType)"
        
        let switcherActiveLastScroll = (self.activeModifications as NSDictionary).value(forKeyPath: effectModKeyPath) as? String == kMFModifiedScrollEffectModificationTypeCommandTab
        let switcherActiveNow = (activeModifications as NSDictionary).value(forKeyPath: effectModKeyPath) as? String == kMFModifiedScrollEffectModificationTypeCommandTab
        
        if (switcherActiveLastScroll && !switcherActiveNow) {
            /// AppSwitcher has been deactivated - notify Scroll.m
            
            Scroll.appSwitcherModificationHasBeenDeactivated();
            self.activeModifications = activeModifications;
        }
    }
}
