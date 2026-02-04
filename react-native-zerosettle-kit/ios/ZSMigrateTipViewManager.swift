import Foundation
import React

@objc(ZSMigrateTipViewManager)
final class ZSMigrateTipViewManager: RCTViewManager {
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    override func view() -> UIView! {
        return ZSMigrateTipViewContainer()
    }
}
