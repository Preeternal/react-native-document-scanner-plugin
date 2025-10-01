#import "DocumentScanner.h"
#import <VisionKit/VisionKit.h>

// Universal for different modes (framework/static)
#if __has_include(<DocumentScanner/DocumentScanner-Swift.h>)
#import <DocumentScanner/DocumentScanner-Swift.h>
#elif __has_include("DocumentScanner-Swift.h")
#import "DocumentScanner-Swift.h"
#else
#warning "DocumentScanner-Swift.h not found at build time"
#endif

@interface DocumentScanner ()
@property (nonatomic, strong) DocumentScannerImpl *impl;
@end

@implementation DocumentScanner
RCT_EXPORT_MODULE()

- (instancetype)init
{
  self = [super init];
  if (self) {
    _impl = [DocumentScannerImpl new];
  }
  return self;
}

- (void)handleScanWithOptions:(NSDictionary *)options
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject
{
  [self.impl scanDocument:options resolve:resolve reject:reject];
}

#if RCT_NEW_ARCH_ENABLED
- (void)scanDocument:(JS::NativeDocumentScanner::ScanDocumentOptions &)options
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  NSMutableDictionary *dict = [NSMutableDictionary new];
  if (options.responseType() != nil) {
    dict[@"responseType"] = options.responseType();
  }
  if (options.croppedImageQuality().has_value()) {
    dict[@"croppedImageQuality"] = @(options.croppedImageQuality().value());
  }
  if (options.maxNumDocuments().has_value()) {
    dict[@"maxNumDocuments"] = @(options.maxNumDocuments().value());
  }
  [self handleScanWithOptions:dict resolve:resolve reject:reject];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeDocumentScannerSpecJSI>(params);
}
#else
RCT_EXPORT_METHOD(scanDocument:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [self handleScanWithOptions:options resolve:resolve reject:reject];
}
#endif
@end
