#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ZSMigrateTipModule, NSObject)

RCT_EXTERN_METHOD(presentMigrateTip:(NSString *)backgroundColorHex userId:(NSString *)userId)
RCT_EXTERN_METHOD(dismissMigrateTip)

@end
