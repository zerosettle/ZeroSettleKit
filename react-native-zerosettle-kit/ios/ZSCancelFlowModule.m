#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ZSCancelFlowModule, NSObject)

RCT_EXTERN_METHOD(getCancelFlowConfig:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(acceptSaveOffer:(NSString *)productId
                  userId:(NSString *)userId
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(submitCancelFlowResponse:(NSDictionary *)responseMap
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(pauseSubscription:(NSString *)productId
                  userId:(NSString *)userId
                  pauseOptionId:(int)pauseOptionId
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(resumeSubscription:(NSString *)productId
                  userId:(NSString *)userId
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(cancelSubscription:(NSString *)productId
                  userId:(NSString *)userId
                  immediate:(BOOL)immediate
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(openCustomerPortal:(NSString *)userId
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
