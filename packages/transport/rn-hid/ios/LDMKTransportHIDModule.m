#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(LDMKTransportHIDModule, RCTEventEmitter)

RCT_EXTERN_METHOD(startScan:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(stopScan:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(connectDevice:(NSString *)uid
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(disconnectDevice:(NSString *)sessionId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(sendApdu:(NSString *)sessionId
                  apdu:(NSString *)apdu
                  triggersDisconnection:(BOOL)triggersDisconnection
                  abortTimeout:(nonnull NSNumber *)abortTimeout
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

@end
