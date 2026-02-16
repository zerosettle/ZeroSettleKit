#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ZSSaveTheSaleModule, NSObject)

RCT_EXTERN_METHOD(presentSaveTheSaleSheet:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(dismissSaveTheSaleSheet)

@end
