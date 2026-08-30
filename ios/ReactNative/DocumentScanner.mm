#import "DocumentScanner.h"
#import <React/RCTUtils.h>
#import <UIKit/UIKit.h>
#import <VisionKit/VisionKit.h>

// Keep the RN adapter independent of Swift's generated header. CocoaPods and
// SwiftPM expose that header differently, while the Objective-C ABI is stable.
@interface DocumentScannerImpl : NSObject
- (void)scanDocument:(NSDictionary *)options
    presentingViewController:(UIViewController *)presentingViewController
                    resolve:(RCTPromiseResolveBlock)resolve
                     reject:(RCTPromiseRejectBlock)reject;
- (void)extractBarcodesFromImages:(NSDictionary *)options
                          resolve:(RCTPromiseResolveBlock)resolve
                           reject:(RCTPromiseRejectBlock)reject;
- (void)extractTextFromImages:(NSDictionary *)options
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject;
- (void)analyzeScannedImages:(NSDictionary *)options
                     resolve:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject;
- (void)invalidate;
@end

@interface DocumentScanner ()
@property (nonatomic, strong) DocumentScannerImpl *impl;
@end

@implementation DocumentScanner

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
  [self.impl scanDocument:options
      presentingViewController:RCTPresentedViewController()
                      resolve:resolve
                       reject:reject];
}

- (void)handleBarcodeExtractionWithOptions:(NSDictionary *)options
                                   resolve:(RCTPromiseResolveBlock)resolve
                                    reject:(RCTPromiseRejectBlock)reject
{
  [self.impl extractBarcodesFromImages:options resolve:resolve reject:reject];
}

- (void)handleTextExtractionWithOptions:(NSDictionary *)options
                                resolve:(RCTPromiseResolveBlock)resolve
                                 reject:(RCTPromiseRejectBlock)reject
{
  [self.impl extractTextFromImages:options resolve:resolve reject:reject];
}

- (void)handleAnalyzeWithOptions:(NSDictionary *)options
                         resolve:(RCTPromiseResolveBlock)resolve
                          reject:(RCTPromiseRejectBlock)reject
{
  [self.impl analyzeScannedImages:options resolve:resolve reject:reject];
}

- (void)invalidate
{
  [self.impl invalidate];
}

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

- (void)extractBarcodesFromImages:
            (JS::NativeDocumentScanner::ExtractBarcodesFromImagesRequest &)options
                          resolve:(RCTPromiseResolveBlock)resolve
                           reject:(RCTPromiseRejectBlock)reject
{
  NSMutableDictionary *dict = [NSMutableDictionary new];

  auto images = options.images();
  NSMutableArray<NSString *> *mappedImages = [NSMutableArray arrayWithCapacity:images.size()];
  for (const auto &image : images) {
    if (image != nil) {
      [mappedImages addObject:image];
    }
  }
  dict[@"images"] = mappedImages;

  if (options.barcodeFormats().has_value()) {
    auto formats = options.barcodeFormats().value();
    NSMutableArray<NSString *> *mappedFormats = [NSMutableArray arrayWithCapacity:formats.size()];
    for (const auto &format : formats) {
      if (format != nil) {
        [mappedFormats addObject:format];
      }
    }
    dict[@"barcodeFormats"] = mappedFormats;
  }
  if (options.concurrency().has_value()) {
    dict[@"concurrency"] = @(options.concurrency().value());
  }

  [self handleBarcodeExtractionWithOptions:dict resolve:resolve reject:reject];
}

- (void)extractTextFromImages:
            (JS::NativeDocumentScanner::ExtractTextFromImagesRequest &)options
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject
{
  NSMutableDictionary *dict = [NSMutableDictionary new];

  auto images = options.images();
  NSMutableArray<NSString *> *mappedImages = [NSMutableArray arrayWithCapacity:images.size()];
  for (const auto &image : images) {
    if (image != nil) {
      [mappedImages addObject:image];
    }
  }
  dict[@"images"] = mappedImages;

  if (options.concurrency().has_value()) {
    dict[@"concurrency"] = @(options.concurrency().value());
  }
  if (options.ocrRotate180Fallback().has_value()) {
    dict[@"ocrRotate180Fallback"] = @(options.ocrRotate180Fallback().value());
  }

  [self handleTextExtractionWithOptions:dict resolve:resolve reject:reject];
}

- (void)analyzeScannedImages:
            (JS::NativeDocumentScanner::AnalyzeScannedImagesRequest &)options
                   resolve:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject
{
  NSMutableDictionary *dict = [NSMutableDictionary new];

  auto images = options.images();
  NSMutableArray<NSString *> *mappedImages = [NSMutableArray arrayWithCapacity:images.size()];
  for (const auto &image : images) {
    if (image != nil) {
      [mappedImages addObject:image];
    }
  }
  dict[@"images"] = mappedImages;

  if (options.extractBarcodes().has_value()) {
    dict[@"extractBarcodes"] = @(options.extractBarcodes().value());
  }
  if (options.extractText().has_value()) {
    dict[@"extractText"] = @(options.extractText().value());
  }
  if (options.extractTables().has_value()) {
    dict[@"extractTables"] = @(options.extractTables().value());
  }
  if (options.extractRegions().has_value()) {
    dict[@"extractRegions"] = @(options.extractRegions().value());
  }
  if (options.extractStructuredData().has_value()) {
    dict[@"extractStructuredData"] = @(options.extractStructuredData().value());
  }
  if (options.barcodeFormats().has_value()) {
    auto formats = options.barcodeFormats().value();
    NSMutableArray<NSString *> *mappedFormats = [NSMutableArray arrayWithCapacity:formats.size()];
    for (const auto &format : formats) {
      if (format != nil) {
        [mappedFormats addObject:format];
      }
    }
    dict[@"barcodeFormats"] = mappedFormats;
  }
  if (options.concurrency().has_value()) {
    dict[@"concurrency"] = @(options.concurrency().value());
  }
  if (options.ocrRotate180Fallback().has_value()) {
    dict[@"ocrRotate180Fallback"] = @(options.ocrRotate180Fallback().value());
  }

  [self handleAnalyzeWithOptions:dict resolve:resolve reject:reject];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeDocumentScannerSpecJSI>(params);
}

+ (NSString *)moduleName
{
  return @"DocumentScanner";
}

@end
