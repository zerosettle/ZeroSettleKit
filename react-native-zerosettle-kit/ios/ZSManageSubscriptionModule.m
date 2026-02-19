#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ZSManageSubscriptionModule, NSObject)

RCT_EXTERN_METHOD(presentManageSubscriptionSheet:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(dismissManageSubscriptionSheet)

@end
