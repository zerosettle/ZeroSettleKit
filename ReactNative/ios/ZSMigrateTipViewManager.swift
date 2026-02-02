import UIKit

#if canImport(React)
import React

/// React Native view manager that exposes ZSMigrateTipViewContainer to JavaScript.
@objc(ZSMigrateTipViewManager)
final class ZSMigrateTipViewManager: RCTViewManager {
    
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    override func view() -> UIView! {
        return ZSMigrateTipViewContainer()
    }
}

#endif
