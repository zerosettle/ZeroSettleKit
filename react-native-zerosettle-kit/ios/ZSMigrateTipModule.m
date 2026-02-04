#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ZSMigrateTipModule, NSObject)

RCT_EXTERN_METHOD(presentMigrateTip:(NSString *)backgroundColorHex)
RCT_EXTERN_METHOD(dismissMigrateTip)

@end
