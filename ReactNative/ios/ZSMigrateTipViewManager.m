#import <React/RCTViewManager.h>

/// Objective-C bridge to expose ZSMigrateTipViewManager to React Native.
/// This maps the React Native prop "backgroundColorHex" to the Swift property.
@interface RCT_EXTERN_MODULE(ZSMigrateTipViewManager, RCTViewManager)

/// Background color as hex string (e.g., "#111111")
RCT_EXPORT_VIEW_PROPERTY(backgroundColorHex, NSString)

@end
