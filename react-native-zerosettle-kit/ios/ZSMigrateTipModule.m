#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ZSMigrateTipModule, NSObject)

RCT_EXTERN_METHOD(presentMigrateTip:(NSString *)backgroundColorHex userId:(NSString *)userId stripeCustomerId:(NSString *)stripeCustomerId)
RCT_EXTERN_METHOD(dismissMigrateTip)

@end
